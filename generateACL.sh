#!/bin/bash
CLIENTS=()
export DYNDNS_CRON_ENABLED=false

function read_acl () {
  for i in "${client_list[@]}"
  do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A or AAAA records for '$i' => Skipping"
      fi
    fi
  done

  # Add localhost to allowed if any dynamic DNS detected
  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      echo "[INFO] Adding '127.0.0.1' to allowed clients"
      CLIENTS+=( "127.0.0.1" )
    fi
  fi
}

# Parse clients from env or file
if [ -n "$ALLOWED_CLIENTS_FILE" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file missing!"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
fi

read_acl

# Begin writing firewall script
cat > /etc/miniproxy/acl_firewall.sh <<EOF
#!/bin/bash
# Flush existing rules on port 443
iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
ip6tables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
ip6tables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true

# Allow traffic from allowed clients
EOF

for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" =~ : ]]; then
    # IPv6
    echo "ip6tables -I INPUT -p tcp -s $ip --dport 443 -j ACCEPT" >> /etc/miniproxy/acl_firewall.sh
    echo "ip6tables -I INPUT -p udp -s $ip --dport 443 -j ACCEPT" >> /etc/miniproxy/acl_firewall.sh
  else
    # IPv4
    echo "iptables -I INPUT -p tcp -s $ip --dport 443 -j ACCEPT" >> /etc/miniproxy/acl_firewall.sh
    echo "iptables -I INPUT -p udp -s $ip --dport 443 -j ACCEPT" >> /etc/miniproxy/acl_firewall.sh
  fi
done

cat >> /etc/miniproxy/acl_firewall.sh <<EOF

# Drop other traffic to 443
iptables -A INPUT -p tcp --dport 443 -j DROP
iptables -A INPUT -p udp --dport 443 -j DROP

echo "[INFO] Firewall ACL rules applied."
EOF

chmod +x /etc/miniproxy/acl_firewall.sh

echo "[INFO] Firewall ACL script generated at /etc/miniproxy/acl_firewall.sh"
