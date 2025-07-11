#!/bin/bash

IPSET_NAME="allowed_clients"
IPSET_NAME_V6="allowed_clients_v6"
CHAIN_NAME="ALLOW_ALLOWED_CLIENTS"
CHAIN_NAME_V6="ALLOW_ALLOWED_CLIENTS_V6"

echo "[INFO] Applying firewall rules from ACL..."

# --- IPv4 ipset management ---
if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
  echo "[INFO] Flushing existing ipset $IPSET_NAME"
  ipset flush "$IPSET_NAME"
else
  echo "[INFO] Creating ipset $IPSET_NAME"
  ipset create "$IPSET_NAME" hash:ip
fi

# --- IPv6 ipset management ---
if ipset list "$IPSET_NAME_V6" >/dev/null 2>&1; then
  echo "[INFO] Flushing existing ipset $IPSET_NAME_V6"
  ipset flush "$IPSET_NAME_V6"
else
  echo "[INFO] Creating ipset $IPSET_NAME_V6"
  ipset create "$IPSET_NAME_V6" hash:ip family inet6
fi

# Extract IPv4 and IPv6 IPs from ACL JSON
IPV4_LIST=$(jq -r '.routing.rules[].ip[] | select(test(":") | not)' /etc/sing-box/acl.json)
IPV6_LIST=$(jq -r '.routing.rules[].ip[] | select(test(":"))' /etc/sing-box/acl.json)

# Add IPv4 IPs to ipset
for ip in $IPV4_LIST; do
  ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
done

# Add IPv6 IPs to ipset
for ip in $IPV6_LIST; do
  ipset add "$IPSET_NAME_V6" "$ip" 2>/dev/null || true
done

# --- IPv4 iptables chain ---
if ! iptables -L "$CHAIN_NAME" -n >/dev/null 2>&1; then
  echo "[INFO] Creating iptables chain $CHAIN_NAME"
  iptables -N "$CHAIN_NAME"
fi

iptables -F "$CHAIN_NAME"
iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_NAME" src -j ACCEPT

if ! iptables -C INPUT -j "$CHAIN_NAME" >/dev/null 2>&1; then
  echo "[INFO] Inserting $CHAIN_NAME into INPUT chain"
  iptables -I INPUT -j "$CHAIN_NAME"
fi

# --- IPv6 ip6tables chain ---
if ! ip6tables -L "$CHAIN_NAME_V6" -n >/dev/null 2>&1; then
  echo "[INFO] Creating ip6tables chain $CHAIN_NAME_V6"
  ip6tables -N "$CHAIN_NAME_V6"
fi

ip6tables -F "$CHAIN_NAME_V6"
ip6tables -A "$CHAIN_NAME_V6" -m set --match-set "$IPSET_NAME_V6" src -j ACCEPT

if ! ip6tables -C INPUT -j "$CHAIN_NAME_V6" >/dev/null 2>&1; then
  echo "[INFO] Inserting $CHAIN_NAME_V6 into INPUT chain"
  ip6tables -I INPUT -j "$CHAIN_NAME_V6"
fi

echo "[INFO] Firewall ACL rules applied successfully."
