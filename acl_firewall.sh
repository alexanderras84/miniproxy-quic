#!/bin/bash

CHAIN="MINIPROXY_ACL"
PORT=443

# Flush or create chain
iptables -N $CHAIN 2>/dev/null || iptables -F $CHAIN

# Whitelist allowed IPs (from /etc/miniproxy/allowed_clients.list)
if [ -f /etc/miniproxy/allowed_clients.list ]; then
  while read -r ip; do
    [ -n "$ip" ] && iptables -A $CHAIN -s "$ip" -p tcp --dport $PORT -j ACCEPT
    [ -n "$ip" ] && iptables -A $CHAIN -s "$ip" -p udp --dport $PORT -j ACCEPT
  done < /etc/miniproxy/allowed_clients.list
fi

# Drop others
iptables -A $CHAIN -p tcp --dport $PORT -j DROP
iptables -A $CHAIN -p udp --dport $PORT -j DROP

# Ensure chain is hooked into INPUT
iptables -D INPUT -p tcp --dport $PORT -j $CHAIN 2>/dev/null
iptables -D INPUT -p udp --dport $PORT -j $CHAIN 2>/dev/null
iptables -I INPUT -p tcp --dport $PORT -j $CHAIN
iptables -I INPUT -p udp --dport $PORT -j $CHAIN

echo "[INFO] ACL firewall rules applied to port $PORT"
