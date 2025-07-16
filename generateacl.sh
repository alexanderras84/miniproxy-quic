#!/bin/bash
set -euo pipefail

CLIENTS=()
UPSTREAM_DNS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# --- CLEANUP EXISTING RULES ---
iptables -t mangle -F ACL-ALLOW 2>/dev/null || true
iptables -t mangle -D PREROUTING -j ACL-ALLOW 2>/dev/null || true
iptables -t mangle -D OUTPUT -j ACL-ALLOW 2>/dev/null || true
iptables -t mangle -X ACL-ALLOW 2>/dev/null || true

ip6tables -t mangle -F ACL-ALLOW 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -j ACL-ALLOW 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -j ACL-ALLOW 2>/dev/null || true
ip6tables -t mangle -X ACL-ALLOW 2>/dev/null || true

# Load clients (same as your current logic, omitted here for brevity)
# ...
# read_acl function here
# ...

read_acl
CLIENTS+=( "fd00:beef:cafe::/64" )

# Detect upstream DNS resolvers (same as before)
# ...

# Write ACL file (same as before)
# ...

# Create ACL-ALLOW chains
iptables -t mangle -N ACL-ALLOW
ip6tables -t mangle -N ACL-ALLOW

# --- UNIVERSAL ALLOW: DNS port 53 (UDP and TCP) for everyone (including upstream resolvers) ---
iptables -t mangle -A ACL-ALLOW -p udp --dport 53 -j RETURN
iptables -t mangle -A ACL-ALLOW -p tcp --dport 53 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p udp --dport 53 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --dport 53 -j RETURN

# --- UNIVERSAL ALLOW: SSH port 22 (both directions) for everyone ---
iptables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
iptables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --dport 22 -j RETURN
ip6tables -t mangle -A ACL-ALLOW -p tcp --sport 22 -j RETURN

# --- Add two-way rules for each allowed client IP (including 443 access) ---
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -s "$ip" -j RETURN
    iptables -t mangle -A ACL-ALLOW -d "$ip" -j RETURN
  fi
done

# --- Upstream DNS resolvers: only allow two-way DNS (port 53) ---
for dns_ip in "${UPSTREAM_DNS[@]}"; do
  if [[ "$dns_ip" == *:* ]]; then
    ip6tables -t mangle -A ACL-ALLOW -p udp -s "$dns_ip" --dport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -p udp -d "$dns_ip" --sport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -p tcp -s "$dns_ip" --dport 53 -j RETURN
    ip6tables -t mangle -A ACL-ALLOW -p tcp -d "$dns_ip" --sport 53 -j RETURN
  else
    iptables -t mangle -A ACL-ALLOW -p udp -s "$dns_ip" --dport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -p udp -d "$dns_ip" --sport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -p tcp -s "$dns_ip" --dport 53 -j RETURN
    iptables -t mangle -A ACL-ALLOW -p tcp -d "$dns_ip" --sport 53 -j RETURN
  fi
done

# Final DROP everything else
iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

# Insert hooks
iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW
iptables -t mangle -C OUTPUT -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I OUTPUT -j ACL-ALLOW
ip6tables -t mangle -C OUTPUT -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I OUTPUT -j ACL-ALLOW

echo "[INFO] ACL generation complete and iprules updated"