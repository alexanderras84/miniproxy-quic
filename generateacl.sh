#!/bin/bash

set -euo pipefail
set -x  # Optional: enables shell debug output

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] [generateacl] Starting ACL generation"

# Function to resolve hostnames and IPs into CLIENTS[]
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

# Build CLIENTS[]
read_acl

# Always add localhost
CLIENTS+=( "127.0.0.1" )

# Always add internal Docker subnet
CLIENTS+=( "fd00:beef:cafe::/64" )

# Write to ACL file
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
echo "[INFO] Writing $ACL_FILE"
: > "$ACL_FILE"
for ip in "${CLIENTS[@]}"; do
  echo "$ip" >> "$ACL_FILE"
done

echo "[DEBUG] Wrote the following clients to $ACL_FILE:"
printf '  %s\n' "${CLIENTS[@]}"

# -----------------------
# 🔒 Set iptables rules
# -----------------------

echo "[INFO] Applying iptables ACL rules"

# Clear previous rules
iptables -F ACL-ALLOW 2>/dev/null || iptables -N ACL-ALLOW
ip6tables -F ACL-ALLOW 2>/dev/null || ip6tables -N ACL-ALLOW

# Add rules
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    ip6tables -A ACL-ALLOW -s "$ip" -j RETURN
  else
    iptables -A ACL-ALLOW -s "$ip" -j RETURN
  fi
done

# Default DROP rule
iptables -A ACL-ALLOW -j DROP
ip6tables -A ACL-ALLOW -j DROP

# Hook into PREROUTING chain
iptables -C PREROUTING -t mangle -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -C PREROUTING -t mangle -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] iptables ACL rules applied."
echo "[INFO] ACL generation complete."