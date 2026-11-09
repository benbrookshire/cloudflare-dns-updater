#!/usr/bin/with-contenv bashio
# Reads the app options and runs an update pass every N minutes.

CF_API_TOKEN="$(bashio::config 'api_token')"
CF_ZONE="$(bashio::config 'zone')"
CF_RECORDS="$(bashio::config 'records')"
CF_IPV6="$(bashio::config 'ipv6')"
export CF_API_TOKEN CF_ZONE CF_RECORDS CF_IPV6
INTERVAL="$(bashio::config 'interval_minutes')"

if bashio::var.is_empty "${CF_API_TOKEN}"; then
  bashio::exit.nok "Set api_token in the app's Configuration tab."
fi
if bashio::var.is_empty "${CF_ZONE}"; then
  bashio::exit.nok "Set zone (your domain, e.g. example.com) in the app's Configuration tab."
fi

bashio::log.info "Updating ${CF_RECORDS//$'\n'/, } in ${CF_ZONE} every ${INTERVAL} minutes"

while true; do
  if ! /usr/bin/ddns.sh; then
    bashio::log.warning "Update pass had errors; retrying in ${INTERVAL} minutes"
  fi
  sleep "$((INTERVAL * 60))"
done
