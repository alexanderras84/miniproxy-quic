#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

###############################################################################
# READ ACL CLIENTS
###############################################################################

function read_acl () {
  echo "[INFO] Reading allowed clients from source..."

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
        echo "[ERROR] Could not resolve A or AAAA records for '$i', skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      CLIENTS+=( "127.0.0.1" )
    fi
  fi

  echo "[INFO] Final resolved clients:"
  printf '%s\n' "${CLIENTS[@]}"
}

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE set but file missing!"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi

read_acl

echo "[INFO] Starting ACL + TPROXY setup"

###############################################################################
# TPROXY POLICY ROUTING (REQUIRED FOR QUIC)
###############################################################################

echo "[INFO] Setting up policy routing for TPROXY"

# Ensure routing table exists
grep -q "^100 tproxy" /etc/iproute2/rt_tables 2>/dev/null || \
  echo "100 tproxy" >> /etc/iproute2/rt_tables

# Add fwmark rule if missing
ip rule list | grep -q "fwmark 0x1 lookup tproxy" || \
  ip rule add fwmark 1 lookup tproxy

# Add local route if missing
ip route show table tproxy | grep -q "local 0.0.0.0/0 dev lo" || \
  ip route add local 0.0.0.0/0 dev lo table tproxy

###############################################################################
# LOOP-SAFE DIVERT RULE
###############################################################################

iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT

iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT

iptables -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || \
  iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

###############################################################################
# MARK 80/443 FOR TPROXY
###############################################################################

echo "[INFO] Marking TCP/UDP 80,443 for TPROXY"

for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK

  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN

  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || \
    $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done

###############################################################################
# FILTER TABLE ACL
###############################################################################

echo "[INFO] Applying ACL filter rules"

# Allow SSH + DNS always
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT

    $cmd -C OUTPUT -p tcp --sport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I OUTPUT -p tcp --sport "$port" -j ACCEPT
  done

  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    $cmd -I INPUT -p udp --dport 53 -j ACCEPT

  $cmd -C OUTPUT -p udp --sport 53 -j ACCEPT 2>/dev/null || \
    $cmd -I OUTPUT -p udp --sport 53 -j ACCEPT
done

# Allow 80/443 only for allowed clients
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    for port in 80 443; do
      ip6tables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      ip6tables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
    done
  else
    for port in 80 443; do
      iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
    done
  fi
done

# Drop all other 80/443
for cmd in iptables ip6tables; do
  for port in 80 443; do
    $cmd -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      $cmd -A INPUT -p tcp --dport "$port" -j DROP
    $cmd -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || \
      $cmd -A INPUT -p udp --dport "$port" -j DROP
  done
done

echo "[INFO] ✅ ACL + TPROXY setup complete (TCP + QUIC ready)"
