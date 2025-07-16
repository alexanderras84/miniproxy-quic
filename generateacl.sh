#!/bin/bash

set -euo pipefail

CLIENTS=()
UPSTREAM_DNS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# --- CLEANUP EXISTING CHAINS ---
echo "[INFO] Flushing existing ACL-ALLOW and ACL-DNS chains and rules"

for chain in ACL-ALLOW ACL-DNS; do
  iptables -t mangle -F "$chain" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j "$chain" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -j "$chain" 2>/dev/null || true
  iptables -t mangle -X "$chain" 2>/dev/null || true

  ip6tables -t mangle -F "$chain" 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -j "$chain" 2>/dev/null || true
  ip6tables -t mangle -D OUTPUT -j "$chain" 2>/dev/null || true
  ip6tables -t mangle -X "$chain" 2>/dev/null || true
done

# Function to resolve clients and populate CLIENTS array
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

# Call the function to populate CLIENTS array
read_acl

CLIENTS+=( "fd00:beef:cafe::/64" )

# Detect upstream DNS resolvers (systemd-resolved aware)
if command -v resolvectl >/dev/null 2>&1; then
  while read -r ip; do
    [[ "$ip" =~ ^([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "$ip" )
  done < <(resolvectl status | awk '/DNS Servers:/ {print $3} /^[[:space:]]+[0-9a-fA-F:.]+$/ {print $1}')
fi

# Fallback: parse resolv.conf
if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  UPSTREAM_DNS_CONF="/run/systemd/resolve/resolv.conf"
  [ -f "$UPSTREAM_DNS_CONF" ] || UPSTREAM_DNS_CONF="/etc/resolv.conf"
  while read -r line; do
    [[ "$line" =~ ^nameserver[[:space:]]+([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "${BASH_REMATCH[1]}" )
  done < "$UPSTREAM_DNS_CONF"
fi

# Final fallback to public resolvers
if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  echo "[WARN] No upstream DNS resolvers found — using fallback public resolvers"
  UPSTREAM_DNS+=( "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" )
fi

# Debug print upstream DNS resolvers
echo "[DEBUG] Upstream DNS resolvers detected:"
for dns_ip in "${UPSTREAM_DNS[@]}"; do
  echo "  - $dns_ip"
done

# Write ACL file
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
: > "$ACL_FILE"
printf '%s\n' "${CLIENTS[@]}" > "$ACL_FILE"

echo "[INFO] Wrote ACL entries to $ACL_FILE"

# --- CREATE ACL-DNS chain for universal outbound DNS allow ---
iptables -t mangle -N ACL-DNS 2>/dev/null || true
ip6tables -t mangle -N ACL-DNS 2>/dev/null || true

iptables -t mangle -A ACL-DNS -p udp --dport 53 -j RETURN
iptables -t mangle -A ACL-DNS -p tcp --dport 53 -j RETURN
ip6tables -t mangle -A ACL-DNS -p udp --dport 53 -j RETURN
ip6tables -t mangle -A ACL-DNS -p tcp --dport 53 -j RETURN

iptables -t mangle -A ACL-DNS -j DROP
ip6tables -t mangle -A ACL-DNS -j DROP

# Hook ACL-DNS chain into OUTPUT
iptables -t mangle -C OUTPUT -j ACL-DNS 2>/dev/null || iptables -t mangle -I OUTPUT -j ACL-DNS
ip6tables -t mangle -C OUTPUT -j ACL-DNS 2>/dev/null || ip6tables -t mangle -I OUTPUT -j ACL-DNS

# --- CREATE ACL-ALLOW chain for allowed clients on all ports ---
iptables -t mangle -N ACL-ALLOW 2>/dev/null || true
ip6tables -t mangle -N ACL-ALLOW 2>/dev/null || true

# Universal allow SSH 22 both directions
iptables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
iptables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN

# Add two-way rules for each allowed client IP on all protocols and ports, esp 443
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  fi
done

# Add two-way rules for upstream DNS resolvers on port 53 only (UDP/TCP)
for dns_ip in "${UPSTREAM_DNS[@]}"; do
  if [[ "$dns_ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$dns_ip" -p udp --dport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$dns_ip" -p udp --sport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -s "$dns_ip" -p tcp --dport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$dns_ip" -p tcp --sport 53 -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$dns_ip" -p udp --dport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$dns_ip" -p udp --sport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -s "$dns_ip" -p tcp --dport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$dns_ip" -p tcp --sport 53 -j RETURN
  fi
done

# Final DROP in ACL-ALLOW
iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

# Hook ACL-ALLOW into PREROUTING
iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] ACL generation complete and iptables rules updated"