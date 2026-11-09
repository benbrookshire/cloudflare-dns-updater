#!/usr/bin/env bash
# Runs ddns.sh against a local mock of the Cloudflare API and IP services.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PORT=18765
M="http://127.0.0.1:$PORT"
python3 tests/mock_cf.py "$PORT" & PID=$!
trap 'kill $PID 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "$M/ip/1.2.3.4" >/dev/null && break; sleep 0.3; done

export CF_API="$M" CF_ZONE=example.com
GOOD="$M/trace/203.0.113.7 $M/ip/203.0.113.7"
fail=0

check() { # name expected_exit expected_output_substring -- command...
  local name=$1 want=$2 grep_for=$3; shift 4
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -qF -- "$grep_for" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $rc, wanted $want)"; printf '     %s\n' "$out"; fail=1
  fi
}
apex_ip() { curl -s -H "Authorization: Bearer good" "$M/state" | jq -r '.records[] | select(.name=="example.com" and .type=="A") | .content'; }
# shellcheck disable=SC2329  # called through check "$@"
ddns() { env CF_API_TOKEN=good "$@" bash cloudflare_ddns/ddns.sh; }

echo "-- IP source agreement"
check "disagreeing source blocks update" 1 "IPv4 sources disagree, not updating" -- \
  ddns CF_RECORDS=@ IPV4_URLS="$M/trace/203.0.113.7 $M/ip/203.0.113.7 $M/ip/198.51.100.66"
if [ "$(apex_ip)" = "1.1.1.1" ]; then echo "ok   record untouched after disagreement"; else echo "FAIL record changed after disagreement"; fail=1; fi
check "too few sources blocks update" 1 "only 1 IPv4 source(s) answered, need 2" -- \
  ddns CF_RECORDS=@ IPV4_URLS="$M/ip/203.0.113.7 http://127.0.0.1:1/down"
check "private IP answer is ignored" 1 "isn't a public IPv4 address; ignoring it" -- \
  ddns CF_RECORDS=@ IPV4_URLS="$M/ip/203.0.113.7 $M/ip/192.168.1.10"
check "garbage answer is ignored" 1 "isn't a public IPv4 address" -- \
  ddns CF_RECORDS=@ IPV4_URLS="$M/ip/203.0.113.7 $M/ip/<html>"

echo "-- Router (UPnP)"
R="ROUTER_UPNP=true"
check "router disagreeing with services blocks update" 1 "IPv4 sources disagree" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="$M/igd/198.51.100.66.xml" IPV4_URLS="$M/trace/203.0.113.7 $M/ip/203.0.113.7"
check "router behind another router blocks update" 1 "isn't a public address (is it behind another router?)" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="$M/igd/192.168.0.2.xml" IPV4_URLS="$M/trace/203.0.113.7"
check "unreachable router blocks update" 1 "router didn't report its external IPv4 address" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="http://127.0.0.1:1/igd.xml" IPV4_URLS="$M/trace/203.0.113.7 $M/ip/203.0.113.7"
check "router without WAN service blocks update" 1 "doesn't offer the UPnP WAN connection service" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="$M/igd-nowan.xml" IPV4_URLS="$M/trace/203.0.113.7"
check "router alone isn't enough" 1 "no outside service confirmed the router's IPv4 address" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="$M/igd/203.0.113.7.xml" IPV4_URLS="http://127.0.0.1:1/down"
if [ "$(apex_ip)" = "1.1.1.1" ]; then echo "ok   record untouched after all refusals"; else echo "FAIL record changed after a refusal"; fail=1; fi
check "router + one service agreeing updates" 0 "Updated A example.com: 1.1.1.1 -> 203.0.113.7" -- \
  ddns CF_RECORDS=@ "$R" ROUTER_DESC_URL="$M/igd/203.0.113.7.xml" IPV4_URLS="$M/trace/203.0.113.7 http://127.0.0.1:1/down"

echo "-- Cloudflare updates"
export IPV4_URLS="$GOOD"
check "creates missing record"   0 "Created A home.example.com -> 203.0.113.7" -- ddns CF_RECORDS=home
check "no-op when unchanged"     0 "A example.com is already 203.0.113.7"      -- ddns CF_RECORDS="@,home.example.com"
check "bad token fails"          1 "Invalid access token"                    -- env CF_API_TOKEN=bad CF_RECORDS=@ bash cloudflare_ddns/ddns.sh
check "unknown zone fails"       1 "zone nope.com not found"                 -- ddns CF_ZONE=nope.com CF_RECORDS=@
proxied=$(curl -s -H "Authorization: Bearer good" "$M/state" | jq -r '.records[] | select(.name=="example.com") | .proxied')
if [ "$proxied" = "true" ]; then echo "ok   keeps proxy setting"; else echo "FAIL keeps proxy setting"; fail=1; fi

echo "-- Address helpers"
# shellcheck source=cloudflare_ddns/ddns.sh
source cloudflare_ddns/ddns.sh
unit() { # name expected(0|1) -- command...
  local name=$1 want=$2; shift 3
  "$@" >/dev/null 2>&1; local rc=$?; [ $rc -ne 0 ] && rc=1
  if [ "$rc" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (got $rc)"; fail=1; fi
}
unit "public v4 accepted"            0 -- public_ipv4 136.62.145.65
for bad in 10.0.0.1 172.20.1.1 192.168.0.5 100.100.1.1 127.0.0.1 169.254.1.1 0.1.2.3 224.0.0.1 256.1.1.1 1.2.3; do
  unit "v4 $bad rejected"            1 -- public_ipv4 "$bad"
done
unit "public v6 accepted"            0 -- public_ipv6 2605:a601:a0af:f100:9a26:c0e8:8df6:8c32
for bad in fe80::1 fd00::1 ::1 :: 1:2:3 2605::a::1 2605:zz::1; do
  unit "v6 $bad rejected"            1 -- public_ipv6 "$bad"
done
unit "v6 spellings compare equal"    0 -- same_ip 2605:A601:0:0::0001 2605:a601::1
unit "different v6 not equal"        1 -- same_ip 2605:a601::1 2605:a601::2
export LOCAL_IPV6_ADDRS="2605:a601::5 2605:a601:0:0::9"
unit "v6 assigned here is local"     0 -- is_local_ipv6 2605:a601::9
unit "v6 not assigned here rejected" 1 -- is_local_ipv6 2605:a601::7

exit $fail
