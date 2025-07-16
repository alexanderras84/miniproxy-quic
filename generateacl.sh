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

  # Always include loopback subnets
  CLIENTS+=( "127.0.0.0/8" "::1/128" )
}

read_acl
CLIENTS+=( "fd00:beef:cafe::/64" )

# Detect upstream DNS resolvers
UPSTREAM_DNS_CONF="/run/systemd/resolve/resolv.conf"
[ -f "$UPSTREAM_DNS_CONF" ] || UPSTREAM_DNS_CONF="/etc/resolv.conf"

UPSTREAM_DNS=()
while read -r line; do
  [[ "$line" =~ ^nameserver[[:space:]]+([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "${BASH_REMATCH[1]}" )
done < "$UPSTREAM_DNS_CONF"

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

# --- PRIORITY: Allow DNS from host (global rule) ---
iptables -t mangle -I ACL-ALLOW 1 -p udp --dport 53 -j RETURN
iptables -t mangle -I ACL-ALLOW 2 -p tcp --dport 53 -j RETURN
ip6tables -t mangle -I ACL-ALLOW 1 -p udp --dport 53 -j RETURN
ip6tables -t mangle -I ACL-ALLOW 2 -p tcp --dport 53 -j RETURN

# --- Add two-way rules for each ACL client IP ---
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  fi
done

# --- Add two-way rules for upstream DNS resolvers ---
for dns_ip in "${UPSTREAM_DNS[@]}"; do
  if [[ "$dns_ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$dns_ip" -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$dns_ip" -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$dns_ip" -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$dns_ip" -j RETURN
  fi
done

# --- Global two-way allow on port 22 ---
iptables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
iptables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN

# Final DROP
iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

# Ensure PREROUTING and OUTPUT hooks are in place
iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

iptables -t mangle -C OUTPUT -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I OUTPUT -j ACL-ALLOW
ip6tables -t mangle -C OUTPUT -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I OUTPUT -j ACL-ALLOW

echo "[INFO] ACL generation complete and iprules updated"