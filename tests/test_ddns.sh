#!/usr/bin/env bash
# Runs ddns.sh against a local mock of the Cloudflare API.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=18765
python3 tests/mock_cf.py "$PORT" & PID=$!
trap 'kill $PID 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$PORT/ip" >/dev/null && break; sleep 0.3; done

export CF_API="http://127.0.0.1:$PORT" IPV4_URLS="http://127.0.0.1:$PORT/ip" CF_ZONE=example.com
fail=0
check() { # name expected_exit expected_output_substring -- command...
  local name=$1 want=$2 grep_for=$3; shift 4
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -qF -- "$grep_for" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $rc, wanted $want)"; echo "$out" | sed 's/^/     /'; fail=1
  fi
}
check "updates changed record"   0 "Updated A example.com: 1.1.1.1 -> 203.0.113.7" -- env CF_API_TOKEN=good CF_RECORDS="example.com" bash cloudflare_ddns/ddns.sh
check "creates missing record"   0 "Created A home.example.com -> 203.0.113.7"     -- env CF_API_TOKEN=good CF_RECORDS="home" bash cloudflare_ddns/ddns.sh
check "no-op when unchanged"     0 "A example.com is already 203.0.113.7"          -- env CF_API_TOKEN=good CF_RECORDS="@,home.example.com" bash cloudflare_ddns/ddns.sh
check "bad token fails"          1 "Invalid access token"                         -- env CF_API_TOKEN=bad CF_RECORDS="@" bash cloudflare_ddns/ddns.sh
check "unknown zone fails"       1 "zone nope.com not found"                      -- env CF_API_TOKEN=good CF_ZONE=nope.com CF_RECORDS="@" bash cloudflare_ddns/ddns.sh
check "IP lookup failure fails"  1 "could not determine public IPv4"             -- env CF_API_TOKEN=good IPV4_URLS="http://127.0.0.1:1/x" CF_RECORDS="@" bash cloudflare_ddns/ddns.sh

proxied=$(curl -s -H "Authorization: Bearer good" "$CF_API/state" | jq -r '.records[] | select(.name=="example.com") | .proxied')
if [ "$proxied" = "true" ]; then echo "ok   keeps proxy setting"; else echo "FAIL keeps proxy setting"; fail=1; fi

exit $fail
