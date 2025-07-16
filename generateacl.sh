#!/bin/bash

set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] [generateacl] Starting ACL generation"

# Function to resolve client list entries to IPs
function read_acl () {
  for i in "${client_list[@]}"; do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null || true)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A or AAAA for '$i' => Skipping"
      fi
    fi
  done

  # Add localhost if any resolution succeeded
  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      CLIENTS+=( "127.0.0.1" )
    fi
  fi
}

# Load client list from env var or file
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist or is not accessible!"
    exit 1
  fi
elif [ -n "${ALLOWED_CLIENTS:-}" ]; then
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
else
  echo "[ERROR] No allowed clients provided via ALLOWED_CLIENTS or ALLOWED_CLIENTS_FILE"
  exit 1
fi

read_acl

# Add internal Docker IPv6 subnet
CLIENTS+=( "fd00:beef:cafe::/64" )

# Write ACL to file
echo "[INFO] Writing /etc/miniproxy/AllowedClients.acl"
> /etc/miniproxy/AllowedClients.acl
for ip in "${CLIENTS[@]}"; do
  echo "$ip" >> /etc/miniproxy/AllowedClients.acl
done

# Debug IPs (optional)
echo "[DEBUG] Final resolved client IPs:"
printf '  %s\n' "${CLIENTS[@]}"

# Safely quote IPs as JSON array
QUOTED_CLIENTS_JSON=$(printf '%s\n' "${CLIENTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

# Config paths
BASE_CONFIG="/etc/sing-box/config.base.json"
OUT_CONFIG="/etc/sing-box/config.json"

# Ensure base config exists
if [ ! -f "$BASE_CONFIG" ]; then
  echo "[ERROR] Base config $BASE_CONFIG does not exist"
  exit 1
fi

echo "[INFO] Writing sing-box config from base template"

# Generate final config with injected ACL rules
echo "[DEBUG] QUOTED_CLIENTS_JSON: $QUOTED_CLIENTS_JSON"
jq --argjson ips "$QUOTED_CLIENTS_JSON" '
  .route.rules = [
    {type: "field", source_ip: $ips, outbound: "direct"},
    {type: "field", source_ip: ["0.0.0.0/0"], outbound: "blocked"}
  ]
' "$BASE_CONFIG" > "$OUT_CONFIG" || {
  echo "[ERROR] Failed to write config to $OUT_CONFIG"
  exit 1
}

# Validate JSON output
if ! jq empty "$OUT_CONFIG" >/dev/null 2>&1; then
  echo "[ERROR] Invalid JSON generated in $OUT_CONFIG"
  cat "$OUT_CONFIG"
  exit 1
fi

# Optional debug config output
echo "[DEBUG] Generated sing-box config:"
jq . "$OUT_CONFIG"

echo "[INFO] ACL generation complete."