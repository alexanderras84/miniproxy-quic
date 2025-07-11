#!/bin/bash

ACL_FILE="/etc/miniproxy/allowed_clients.list"
CHAIN_NAME="ACL-ALLOW"

echo "[INFO] Applying firewall rules from $ACL_FILE..."

# Ensure iptables is available
if ! command -v iptables >/dev/null 2>&1; then
  echo "[ERROR] iptables not found. Cannot apply firewall rules."
  exit 1
fi

# Create custom chain if it doesn't exist
iptables -nL $CHAIN_NAME >/dev/null 2>&1
if [ $? -ne 0 ]; then
  iptables -N $CHAIN_NAME
  echo "[INFO] Created iptables chain $CHAIN_NAME"
fi

# Flush old rules
iptables -F $CHAIN_NAME

# Add allowed IPs
if [ -s "$ACL_FILE" ]; then
  while read -r ip; do
    [ -n "$ip" ] && iptables -A $CHAIN_NAME -s "$ip" -p tcp --dport 443 -j ACCEPT
    [ -n "$ip" ] && iptables -A $CHAIN_NAME -s "$ip" -p udp --dport 443 -j ACCEPT
  done < "$ACL_FILE"
else
  echo "[WARN] ACL file is empty or missing — no allow rules applied."
fi

# Add default deny rule
iptables -A $CHAIN_NAME -p tcp --dport 443 -j DROP
iptables -A $CHAIN_NAME -p udp --dport 443 -j DROP

# Attach chain to INPUT if not already attached
iptables -C INPUT -j $CHAIN_NAME >/dev/null 2>&1
if [ $? -ne 0 ]; then
  iptables -I INPUT -j $CHAIN_NAME
  echo "[INFO] Attached $CHAIN_NAME to INPUT chain"
fi

echo "[INFO] Firewall ACL rules applied."
