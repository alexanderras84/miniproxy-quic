#!/bin/bash

IPSET_NAME="allowed_clients"
IPSET_NAME_V6="allowed_clients_v6"
CHAIN_NAME="ALLOW_ALLOWED_CLIENTS"
CHAIN_NAME_V6="ALLOW_ALLOWED_CLIENTS_V6"

echo "[INFO] Applying firewall rules from ACL..."

# IPv4 ipset
ipset list "$IPSET_NAME" >/dev/null 2>&1 && ipset flush "$IPSET_NAME" || ipset create "$IPSET_NAME" hash:ip timeout 300

# IPv6 ipset
ipset list "$IPSET_NAME_V6" >/dev/null 2>&1 && ipset flush "$IPSET_NAME_V6" || ipset create "$IPSET_NAME_V6" hash:ip family inet6 timeout 300

# Extract from JSON
IPV4_LIST=$(jq -r '.routing.rules[].source_ip[] | select(test(":") | not)' /etc/sing-box/acl.json)
IPV6_LIST=$(jq -r '.routing.rules[].source_ip[] | select(test(":"))' /etc/sing-box/acl.json)

for ip in $IPV4_LIST; do ipset add "$IPSET_NAME" "$ip" timeout 300 2>/dev/null || true; done
for ip in $IPV6_LIST; do ipset add "$IPSET_NAME_V6" "$ip" timeout 300 2>/dev/null || true; done

# IPv4 iptables chain
iptables -N "$CHAIN_NAME" 2>/dev/null || true
iptables -F "$CHAIN_NAME"
iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_NAME" src -j ACCEPT
iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null || iptables -I INPUT -j "$CHAIN_NAME"

# IPv6 ip6tables chain
ip6tables -N "$CHAIN_NAME_V6" 2>/dev/null || true
ip6tables -F "$CHAIN_NAME_V6"
ip6tables -A "$CHAIN_NAME_V6" -m set --match-set "$IPSET_NAME_V6" src -j ACCEPT
ip6tables -C INPUT -j "$CHAIN_NAME_V6" 2>/dev/null || ip6tables -I INPUT -j "$CHAIN_NAME_V6"

echo "[INFO] Firewall ACL rules applied."