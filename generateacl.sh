#!/bin/bash

set -e

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

function read_acl () {
  for i in "${client_list[@]}"
  do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A or AAAA records for '$i' (timeout or failure) => Skipping"
      fi
    fi
  done
  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      CLIENTS+=( "127.0.0.1" )
    fi
  fi
}

# Source client list
if [ -n "$ALLOWED_CLIENTS_FILE" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist or is not accessible!"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
fi

read_acl

# Add Docker IPv6 subnet if needed
CLIENTS+=( "fd00:beef:cafe::/64" )

# Write to ACL file
> /etc/miniproxy/AllowedClients.acl  # Clear existing file
for ip in "${CLIENTS[@]}"; do
  echo "$ip" >> /etc/miniproxy/AllowedClients.acl
done

# Generate the Sing-box ACL rule section
ACL_JSON=$(printf ',\n        "%s"' "${CLIENTS[@]}")
ACL_JSON=${ACL_JSON:2}  # Remove leading comma & newline

# Insert into config.json (assumes a base config with a placeholder)
jq --argjson ips "[${ACL_JSON}]" '
  .route.rules = [
    {type: "field", source_ip: $ips, outbound: "direct"},
    {type: "field", source_ip: ["0.0.0.0/0"], outbound: "blocked"}
  ]
' /etc/singbox/config.base.json > /etc/singbox/config.json

echo "[INFO] Reloading sing-box"
kill -SIGHUP "$(pgrep -xo sing-box)"

echo "[INFO] ACL updated and sing-box reloaded."
