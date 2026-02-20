#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

function read_acl () {
  echo "[INFO] Reading allowed clients from source..."
  for i in "${client_list[@]}"
  do
    # Check if already an IP address (IPv4 or IPv6)
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      # Resolve A records (IPv4)
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null)
      # Resolve AAAA records (IPv6)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A or AAAA records for '$i' (timeout or failure), skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      echo "[INFO] Adding '127.0.0.1' to allowed clients to prevent reload issues"
      CLIENTS+=( "127.0.0.1" )
    fi
  fi

  echo "[INFO] Final resolved clients:"
  printf '%s\n' "${CLIENTS[@]}"
}

# Determine client list source from Docker environment variable
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    echo "[INFO] Reading allowed clients from file: $ALLOWED_CLIENTS_FILE"
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist or is not accessible!"
    exit 1
  fi
else
  echo "[INFO] Reading allowed clients from environment variable ALLOWED_CLIENTS"
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi

read_acl

echo "[INFO] Starting ACL generation"

# --- ENSURE SSH (22) and DNS (53) universally allowed in FILTER table ---
echo "[INFO] Ensuring SSH (22) and DNS (53) ports are always allowed via filter table"
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
    $cmd -C OUTPUT -p tcp --sport "$port" -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p tcp --sport "$port" -j ACCEPT
  done

  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || $cmd -I INPUT -p udp --dport 53 -j ACCEPT
  $cmd -C OUTPUT -p udp --sport 53 -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p udp --sport 53 -j ACCEPT
done

# --- CLEANUP EXISTING CHAINS IN FILTER TABLE ---
echo "[INFO] Flushing existing ACL-ALLOW chain in filter table"
for cmd in iptables ip6tables; do
  if $cmd -t filter -L ACL-ALLOW &>/dev/null; then
    $cmd -t filter -F ACL-ALLOW || true
    for hook in INPUT OUTPUT; do
      $cmd -t filter -D "$hook" -j ACL-ALLOW 2>/dev/null || true
    done
    $cmd -t filter -X ACL-ALLOW || true
  fi
done
echo "[INFO] Cleanup complete — old ACL-ALLOW chain flushed/deleted from filter table"

# --- MARK ALL 80/443 TCP & UDP TRAFFIC IN MANGLE (for transparent proxy) ---
echo "[INFO] Marking all TCP/UDP traffic on ports 80 and 443 in mangle table"
for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK

  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN

  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done

# --- ACCEPT rules in FILTER table for ports 80/443 ONLY for allowed clients ---
echo "[INFO] Adding ACCEPT rules in filter table for ports 80/443 for allowed clients"
for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    # IPv6
    for port in 80 443; do
      ip6tables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      ip6tables -C OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || ip6tables -I OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT
      ip6tables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
      ip6tables -C OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT 2>/dev/null || ip6tables -I OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT
    done
  else
    # IPv4
    for port in 80 443; do
      iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      iptables -C OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT
      iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
      iptables -C OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT
    done
  fi
done
echo "[INFO] ACCEPT rules for ports 80/443 added to filter table for allowed clients"

# --- DROP all other 80/443 TCP & UDP traffic ---
echo "[INFO] Adding DROP rules in filter table for all other traffic on ports 80 and 443"
for cmd in iptables ip6tables; do
  for port in 80 443; do
    $cmd -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || $cmd -A INPUT -p tcp --dport "$port" -j DROP
    $cmd -C OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null || $cmd -A OUTPUT -p tcp --sport "$port" -j DROP
    $cmd -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || $cmd -A INPUT -p udp --dport "$port" -j DROP
    $cmd -C OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null || $cmd -A OUTPUT -p udp --sport "$port" -j DROP
  done
done

echo "[INFO] ✅ ACL setup complete: universal (22/53) allowed, marking 80/443 in mangle, filtering 80/443 for allowed clients, dropping others"
