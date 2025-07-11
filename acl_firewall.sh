#!/bin/bash

IPSET_NAME="allowed_clients"
CHAIN_NAME="ALLOW_ALLOWED_CLIENTS"

echo "[INFO] Applying firewall rules from ACL..."

# Check if ipset exists, create or flush it
if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
  echo "[INFO] Flushing existing ipset $IPSET_NAME"
  ipset flush "$IPSET_NAME"
else
  echo "[INFO] Creating ipset $IPSET_NAME"
  ipset create "$IPSET_NAME" hash:ip
fi

# Extract IPs from ACL JSON and add to ipset
IP_LIST=$(jq -r '.routing.rules[].ip[]' /etc/sing-box/acl.json)
for ip in $IP_LIST; do
  ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
done

# Create iptables chain if not exists
if ! iptables -L "$CHAIN_NAME" -n >/dev/null 2>&1; then
  echo "[INFO] Creating iptables chain $CHAIN_NAME"
  iptables -N "$CHAIN_NAME"
fi

# Flush chain rules
iptables -F "$CHAIN_NAME"

# Add rule to allow traffic from IPs in ipset
iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_NAME" src -j ACCEPT

# Insert chain into INPUT if not already present
if ! iptables -C INPUT -j "$CHAIN_NAME" >/dev/null 2>&1; then
  echo "[INFO] Inserting $CHAIN_NAME into INPUT chain"
  iptables -I INPUT -j "$CHAIN_NAME"
fi

# Finally, add a default drop rule in the chain if desired
# Comment out if you want to allow all other traffic
#iptables -A "$CHAIN_NAME" -j DROP

echo "[INFO] Firewall ACL rules applied successfully."
