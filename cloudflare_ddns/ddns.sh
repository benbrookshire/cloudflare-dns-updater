#!/usr/bin/env bash
# One update pass: look up the current public IP and make the Cloudflare
# DNS records match it. Exits non-zero if anything failed.
#
# Where the public IP comes from:
#   IPv4: the router itself over UPnP (required when ROUTER_UPNP=true),
#         checked against Cloudflare and AWS.
#   IPv6: Cloudflare, checked against the addresses assigned to this machine
#         (with no NAT, the AAAA record is this machine's own address).
# Records are only changed when every source that answered agrees, the
# local source (router / this machine) confirmed it, and at least
# MIN_IP_SOURCES answered in total. One bad web service can't redirect DNS.
#
# Environment:
#   CF_API_TOKEN     Cloudflare API token (Zone:Read + DNS:Edit on the zone)
#   CF_ZONE          Zone name, e.g. example.com
#   CF_RECORDS       Record names, separated by spaces/commas/newlines
#                    ("@" = the zone apex, "home" = home.<zone>)
#   CF_IPV6          "true" to also update AAAA records (default false)
#   ROUTER_UPNP      "true" to require the router's UPnP answer for IPv4
#   ROUTER_DESC_URL  Router's UPnP description URL; found by SSDP if empty
set -uo pipefail

CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
# Independent operators: Cloudflare and AWS
IPV4_URLS="${IPV4_URLS:-https://1.1.1.1/cdn-cgi/trace https://checkip.amazonaws.com}"
IPV6_URLS="${IPV6_URLS:-https://[2606:4700:4700::1111]/cdn-cgi/trace}"
CF_IPV6="${CF_IPV6:-false}"
ROUTER_UPNP="${ROUTER_UPNP:-false}"
ROUTER_DESC_URL="${ROUTER_DESC_URL:-}"
LOCAL_IPV6_CHECK="${LOCAL_IPV6_CHECK:-true}"
MIN_IP_SOURCES="${MIN_IP_SOURCES:-2}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# cf METHOD PATH [JSON_BODY] -> prints response JSON on success
cf() {
  local method=$1 path=$2 data=${3:-} resp
  local args=(-sS --max-time 20 -X "$method"
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json")
  [ -n "$data" ] && args+=(--data "$data")
  if ! resp=$(curl "${args[@]}" "${CF_API}${path}"); then
    log "ERROR: could not reach Cloudflare ($method $path)"
    return 1
  fi
  if [ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]; then
    log "ERROR: Cloudflare rejected $method $path: $(jq -c '.errors' <<<"$resp" 2>/dev/null || echo "$resp")"
    return 1
  fi
  printf '%s' "$resp"
}

# public_ipv4 IP -> true if IP is a well-formed, publicly routable IPv4 address
public_ipv4() {
  local a b c d
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
  [ $a -le 255 ] && [ $b -le 255 ] && [ $c -le 255 ] && [ $d -le 255 ] || return 1
  [ $a -eq 0 ] || [ $a -eq 10 ] || [ $a -eq 127 ] || [ $a -ge 224 ] && return 1  # this-net, private, loopback, multicast/reserved
  [ $a -eq 100 ] && [ $b -ge 64 ] && [ $b -le 127 ] && return 1                   # CGNAT 100.64/10
  [ $a -eq 169 ] && [ $b -eq 254 ] && return 1                                    # link-local
  [ $a -eq 172 ] && [ $b -ge 16 ] && [ $b -le 31 ] && return 1                    # private 172.16/12
  [ $a -eq 192 ] && [ $b -eq 168 ] && return 1                                    # private 192.168/16
  return 0
}

# expand_ipv6 IP -> prints the full 8-group lowercase form, so different
# spellings of the same address compare equal. Fails if IP isn't IPv6.
expand_ipv6() {
  local ip head tail out="" g n=0 i
  local -a hg=() tg=()
  ip=$(tr 'A-F' 'a-f' <<<"$1")
  [[ $ip =~ ^[0-9a-f:]+$ ]] && [[ $ip == *:* ]] || return 1
  if [[ $ip == *::* ]]; then
    head=${ip%%::*} tail=${ip#*::}
    [[ $tail == *::* ]] && return 1
    [ -n "$head" ] && IFS=: read -r -a hg <<<"$head"
    [ -n "$tail" ] && IFS=: read -r -a tg <<<"$tail"
    n=$((8 - ${#hg[@]} - ${#tg[@]}))
    [ $n -ge 1 ] || return 1
  else
    IFS=: read -r -a hg <<<"$ip"
    [ ${#hg[@]} -eq 8 ] || return 1
  fi
  for g in ${hg[@]+"${hg[@]}"}; do out="$out:$g"; done
  for ((i = 0; i < n; i++)); do out="$out:0"; done
  for g in ${tg[@]+"${tg[@]}"}; do out="$out:$g"; done
  local result=""
  IFS=: read -r -a hg <<<"${out#:}"
  for g in "${hg[@]}"; do
    [ ${#g} -ge 1 ] && [ ${#g} -le 4 ] || return 1
    result="$result:$(printf '%04x' "0x$g")"
  done
  echo "${result#:}"
}

# public_ipv6 IP -> true if IP is a global unicast IPv6 address (2000::/3)
public_ipv6() {
  local full
  full=$(expand_ipv6 "$1") || return 1
  [[ $full =~ ^[23] ]]
}

# same_ip A B -> true if A and B are the same address (handles IPv6 spellings)
same_ip() {
  [ "$1" = "$2" ] && return 0
  local x y
  x=$(expand_ipv6 "$1") && y=$(expand_ipv6 "$2") && [ "$x" = "$y" ]
}

# ssdp_discover -> prints the UPnP description URL of the default gateway
ssdp_discover() {
  local gw loc host
  if ! command -v socat >/dev/null; then
    log "WARNING: socat isn't installed, so the router can't be discovered; set router_upnp_url"
    return 1
  fi
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  # Only trust an answer that comes from the default gateway, not any LAN device.
  while read -r loc; do
    host=${loc#*://} host=${host%%[:/]*}
    if [ -z "$gw" ] || [ "$host" = "$gw" ]; then echo "$loc"; return 0; fi
  done < <(printf 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n' |
    socat -t3 -T3 - UDP4-DATAGRAM:239.255.255.250:1900 2>/dev/null |
    tr -d '\r' | sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p')
  log "WARNING: no UPnP gateway answered${gw:+ from $gw} (is UPnP on in the router?)"
  return 1
}

# router_ipv4 -> prints the external IPv4 address the router reports over UPnP
router_ipv4() {
  local desc=$ROUTER_DESC_URL xml st="" ctl="" rest resp re body
  if [ -z "$desc" ]; then desc=$(ssdp_discover) || return 1; fi
  if ! xml=$(curl -sS --max-time 5 "$desc" 2>/dev/null); then
    log "WARNING: couldn't read the router's UPnP description at $desc"
    return 1
  fi
  xml=$(tr -d '\r\n\t' <<<"$xml")
  re='<serviceType>(urn:schemas-upnp-org:service:WAN(IP|PPP)Connection:[0-9]+)</serviceType>(.*)'
  if [[ $xml =~ $re ]]; then
    st=${BASH_REMATCH[1]} rest=${BASH_REMATCH[3]%%</service>*}
    re='<controlURL>([^<]*)</controlURL>'
    [[ $rest =~ $re ]] && ctl=${BASH_REMATCH[1]}
  fi
  if [ -z "$ctl" ]; then
    log "WARNING: the router at $desc doesn't offer the UPnP WAN connection service"
    return 1
  fi
  case $ctl in
    http://* | https://*) ;;
    /*) ctl="$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$desc")$ctl" ;;
    *) ctl="${desc%/*}/$ctl" ;;
  esac
  body="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:GetExternalIPAddress xmlns:u=\"$st\"/></s:Body></s:Envelope>"
  if ! resp=$(curl -sS --max-time 5 -X POST \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -H "SOAPAction: \"$st#GetExternalIPAddress\"" \
    --data "$body" "$ctl" 2>/dev/null); then
    log "WARNING: the router didn't answer the UPnP request at $ctl"
    return 1
  fi
  re='<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>'
  if [[ $resp =~ $re ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  log "WARNING: the router's UPnP answer had no external IP address"
  return 1
}

# local_ipv6_addrs -> prints the global IPv6 addresses assigned to this machine
local_ipv6_addrs() {
  if [ -n "${LOCAL_IPV6_ADDRS+x}" ]; then tr ' ,' '\n\n' <<<"$LOCAL_IPV6_ADDRS"; return; fi
  if command -v ip >/dev/null; then
    ip -6 addr show scope global 2>/dev/null | awk '$1 == "inet6" {sub(/\/.*/, "", $2); print $2}'
  else
    ifconfig 2>/dev/null | awk '$1 == "inet6" {sub(/%.*/, "", $2); print $2}'
  fi
}

# is_local_ipv6 IP -> true if IP is assigned to one of this machine's interfaces
is_local_ipv6() {
  local a
  while read -r a; do
    [ -n "$a" ] && same_ip "$a" "$1" && return 0
  done < <(local_ipv6_addrs)
  return 1
}

# get_ip 4|6 -> prints the public IP, only if the sources agree
get_ip() {
  local family=$1 urls url body ip first="" answered=0 agree=1 report=""
  if [ "$family" = 4 ]; then urls=$IPV4_URLS; else urls=$IPV6_URLS; fi

  # The router is the authority for IPv4. If it's in use, it must answer.
  if [ "$family" = 4 ] && [ "$ROUTER_UPNP" = "true" ]; then
    if ! ip=$(router_ipv4); then
      log "ERROR: the router didn't report its external IPv4 address over UPnP; not updating"
      return 1
    fi
    if ! public_ipv4 "$ip"; then
      log "ERROR: the router reports '$ip', which isn't a public address (is it behind another router?); not updating"
      return 1
    fi
    first=$ip answered=1 report=" router(UPnP)=$ip"
  fi

  for url in $urls; do
    if ! body=$(curl -sS "-$family" --max-time 10 "$url" 2>/dev/null); then
      log "WARNING: no answer from $url"
      continue
    fi
    # Cloudflare's /cdn-cgi/trace returns key=value lines; the others return the bare IP.
    if grep -q '^ip=' <<<"$body"; then
      ip=$(sed -n 's/^ip=//p' <<<"$body" | head -1 | tr -d '[:space:]')
    else
      ip=$(tr -d '[:space:]' <<<"$body")
    fi
    if ! "public_ipv$family" "$ip"; then
      log "WARNING: $url returned '${ip:0:64}', which isn't a public IPv$family address; ignoring it"
      continue
    fi
    answered=$((answered + 1))
    report="$report $url=$ip"
    if [ -z "$first" ]; then first=$ip
    elif ! same_ip "$ip" "$first"; then agree=0
    fi
  done

  if [ $agree -eq 0 ]; then
    log "ERROR: IPv$family sources disagree, not updating:$report"
    return 1
  fi
  if [ "$family" = 4 ] && [ "$ROUTER_UPNP" = "true" ] && [ $answered -lt 2 ]; then
    log "ERROR: no outside service confirmed the router's IPv4 address; not updating:$report"
    return 1
  fi
  # With no NAT on IPv6, the address the outside world sees must be one of ours.
  if [ "$family" = 6 ] && [ -n "$first" ] && [ "$LOCAL_IPV6_CHECK" = "true" ]; then
    if ! is_local_ipv6 "$first"; then
      log "ERROR: $first isn't assigned to this machine; not updating AAAA:$report"
      return 1
    fi
    answered=$((answered + 1)) report="$report this-machine=$first"
  fi
  if [ $answered -lt "$MIN_IP_SOURCES" ]; then
    log "ERROR: only $answered IPv$family source(s) answered, need $MIN_IP_SOURCES; not updating:$report"
    return 1
  fi
  echo "$first"
}

fqdn() {
  local name=$1
  if [ "$name" = "@" ] || [ "$name" = "$CF_ZONE" ]; then echo "$CF_ZONE"
  elif [[ $name == *."$CF_ZONE" ]]; then echo "$name"
  else echo "$name.$CF_ZONE"
  fi
}

# sync_record ZONE_ID NAME TYPE IP
sync_record() {
  local zid=$1 name=$2 type=$3 ip=$4 resp lines id content body
  resp=$(cf GET "/zones/$zid/dns_records?type=$type&name=$name") || return 1
  lines=$(jq -r '.result[] | "\(.id) \(.content)"' <<<"$resp")

  if [ -z "$lines" ]; then
    body=$(jq -nc --arg t "$type" --arg n "$name" --arg c "$ip" \
      '{type:$t, name:$n, content:$c, ttl:1, proxied:false}')
    cf POST "/zones/$zid/dns_records" "$body" >/dev/null || return 1
    log "Created $type $name -> $ip"
    return 0
  fi

  local rc=0
  while read -r id content; do
    if same_ip "$content" "$ip"; then
      log "$type $name is already $ip"
      continue
    fi
    # Only the content changes; TTL, proxy status and comments are kept.
    body=$(jq -nc --arg c "$ip" '{content:$c}')
    if cf PATCH "/zones/$zid/dns_records/$id" "$body" >/dev/null; then
      log "Updated $type $name: $content -> $ip"
    else
      rc=1
    fi
  done <<<"$lines"
  return $rc
}

main() {
  local v zid ip4 ip6="" rc=0 rec name
  for v in CF_API_TOKEN CF_ZONE CF_RECORDS; do
    if [ -z "${!v:-}" ]; then log "ERROR: $v is not set"; return 2; fi
  done

  # Check the IP before touching Cloudflare, so a bad answer never gets near the API.
  ip4=$(get_ip 4) || return 1
  if [ "$CF_IPV6" = "true" ] && ! ip6=$(get_ip 6); then
    log "WARNING: skipping AAAA records this pass (no agreed public IPv6 address)"
    ip6=""
    rc=1
  fi

  zid=$(cf GET "/zones?name=$CF_ZONE" | jq -r '.result[0].id // empty')
  if [ -z "$zid" ]; then
    log "ERROR: zone $CF_ZONE not found (does the token have Zone:Read on it?)"
    return 1
  fi

  for rec in $(tr ',' ' ' <<<"$CF_RECORDS"); do
    name=$(fqdn "$rec")
    sync_record "$zid" "$name" A "$ip4" || rc=1
    if [ -n "$ip6" ]; then sync_record "$zid" "$name" AAAA "$ip6" || rc=1; fi
  done
  return $rc
}

# Run when executed; tests can `source` this file to use the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
  exit $?
fi
