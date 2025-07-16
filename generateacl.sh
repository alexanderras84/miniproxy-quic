#!/bin/bash

set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# Load client list
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

# Resolve hostnames and collect IPs
read_acl() {
  for i in "${client_list[@]}"; do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null || true)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        if [ -n "$RESOLVE_IPV4_LIST" ]; then
          while read -r ip4; do
            [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
          done <<< "$RESOLVE_IPV4_LIST"
        fi
        if [ -n "$RESOLVE_IPV6_LIST" ]; then
          while read -r ip6; do
            [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
          done <<< "$RESOLVE_IPV6_LIST"
        fi
      else
        echo "[ERROR] Could not resolve A or AAAA records for '$i' — skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '^127\.0\.0\.1$'; then
    CLIENTS+=( "127.0.0.1" )
  fi
}

read_acl
CLIENTS+=( "fd00:beef:cafe::/64" )

# Write ACL file
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
: > "$ACL_FILE"
printf '%s\n' "${CLIENTS[@]}" > "$ACL_FILE"

echo "[INFO] Wrote ACL entries to $ACL_FILE"

# Apply iptables rules in mangle table
echo "[INFO] Applying iptables ACL rules"

if iptables -t mangle -nL ACL-ALLOW >/dev/null 2>&1; then
  iptables -t mangle -F ACL-ALLOW
else
  iptables -t mangle -N ACL-ALLOW
fi

if ip6tables -t mangle -nL ACL-ALLOW >/dev/null 2>&1; then
  ip6tables -t mangle -F ACL-ALLOW
else
  ip6tables -t mangle -N ACL-ALLOW
fi

for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
  fi
done

iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] ACL generation complete and iprules updated"