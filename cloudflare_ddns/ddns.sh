#!/usr/bin/env bash
# One update pass: look up the current public IP and make the Cloudflare
# DNS records match it. Exits non-zero if anything failed.
#
# Environment:
#   CF_API_TOKEN  Cloudflare API token (Zone:Read + DNS:Edit on the zone)
#   CF_ZONE       Zone name, e.g. example.com
#   CF_RECORDS    Record names, separated by spaces/commas/newlines
#                 ("@" = the zone apex, "home" = home.<zone>)
#   CF_IPV6       "true" to also update AAAA records (default false)
set -uo pipefail

CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
IPV4_URLS="${IPV4_URLS:-https://1.1.1.1/cdn-cgi/trace https://api.ipify.org}"
IPV6_URLS="${IPV6_URLS:-https://[2606:4700:4700::1111]/cdn-cgi/trace https://api6.ipify.org}"
CF_IPV6="${CF_IPV6:-false}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

for v in CF_API_TOKEN CF_ZONE CF_RECORDS; do
  if [ -z "${!v:-}" ]; then log "ERROR: $v is not set"; exit 2; fi
done

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

# get_ip 4|6 -> prints the public IP
get_ip() {
  local family=$1 urls body ip url
  if [ "$family" = 4 ]; then urls=$IPV4_URLS; else urls=$IPV6_URLS; fi
  for url in $urls; do
    body=$(curl -sS "-$family" --max-time 10 "$url" 2>/dev/null) || continue
    # Cloudflare's /cdn-cgi/trace returns key=value lines; ipify returns the bare IP.
    if grep -q '^ip=' <<<"$body"; then
      ip=$(sed -n 's/^ip=//p' <<<"$body")
    else
      ip=$(tr -d '[:space:]' <<<"$body")
    fi
    if [ "$family" = 4 ] && [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
    if [ "$family" = 6 ] && [[ $ip =~ ^[0-9a-fA-F:]+$ ]] && [[ $ip == *:* ]]; then echo "$ip"; return 0; fi
    log "WARNING: $url returned something that isn't an IPv$family address"
  done
  return 1
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
    if [ "$content" = "$ip" ]; then
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
  local zid ip4 ip6="" rc=0 rec name
  zid=$(cf GET "/zones?name=$CF_ZONE" | jq -r '.result[0].id // empty')
  if [ -z "$zid" ]; then
    log "ERROR: zone $CF_ZONE not found (does the token have Zone:Read on it?)"
    return 1
  fi

  if ! ip4=$(get_ip 4); then log "ERROR: could not determine public IPv4 address"; return 1; fi
  if [ "$CF_IPV6" = "true" ] && ! ip6=$(get_ip 6); then
    log "WARNING: IPv6 enabled but no public IPv6 address found; skipping AAAA records"
    ip6=""
  fi

  for rec in $(tr ',' ' ' <<<"$CF_RECORDS"); do
    name=$(fqdn "$rec")
    sync_record "$zid" "$name" A "$ip4" || rc=1
    if [ -n "$ip6" ]; then sync_record "$zid" "$name" AAAA "$ip6" || rc=1; fi
  done
  return $rc
}

main
