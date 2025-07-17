#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-false}" == "true" ]] && set -x

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
        echo "[ERROR] Could not resolve A or AAAA records for '$i' (timeout or failure) => Skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      echo "[INFO] Adding '127.0.0.1' to allowed clients to prevent reload issues"
      CLIENTS+=( "127.0.0.1" )
    fi
  fi
}

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    echo "[INFO] Reading allowed clients from file: $ALLOWED_CLIENTS_FILE"
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist or is not accessible!"
    exit 1
  fi
else
  if [ -z "${ALLOWED_CLIENTS:-}" ]; then
    echo "[ERROR] Neither ALLOWED_CLIENTS_FILE set nor ALLOWED_CLIENTS env var provided!"
    exit 1
  fi
  echo "[INFO] Parsing ALLOWED_CLIENTS env var"
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
fi

read_acl

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  echo "[INFO] Writing resolved clients to ACL file: $ALLOWED_CLIENTS_FILE"
  mkdir -p "$(dirname "$ALLOWED_CLIENTS_FILE")"
  printf "%s\n" "${CLIENTS[@]}" > "$ALLOWED_CLIENTS_FILE"
fi

echo "[INFO] Starting ACL generation"

# Universal allow for SSH(22) and DNS(53)
echo "[INFO] Ensuring SSH (22) and DNS (53) ports are always allowed via filter table"
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
    $cmd -C OUTPUT -p tcp --sport "$port" -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p tcp --sport "$port" -j ACCEPT
  done
  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || $cmd -I INPUT -p udp --dport 53 -j ACCEPT
  $cmd -C OUTPUT -p udp --sport 53 -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p udp --sport 53 -j ACCEPT
done

# Cleanup ACL-ALLOW chain in filter table
echo "[INFO] Cleaning up existing ACL-ALLOW chains in filter table"
for cmd in iptables ip6tables; do
  if $cmd -t filter -L ACL-ALLOW &>/dev/null; then
    echo "[DEBUG] Flushing ACL-ALLOW chain with $cmd"
    $cmd -t filter -F ACL-ALLOW || true
    for hook in INPUT OUTPUT; do
      $cmd -t filter -D "$hook" -j ACL-ALLOW 2>/dev/null || true
    done
    $cmd -t filter -X ACL-ALLOW || true
  else
    echo "[DEBUG] ACL-ALLOW chain not found for $cmd, skipping"
  fi
done

# Mark TCP/UDP ports 80/443 traffic in mangle table
echo "[INFO] Marking TCP/UDP 80/443 traffic in mangle table"
for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK
  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN
  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done

# Add ACCEPT rules for allowed clients ports 80/443 in filter table
echo "[INFO] Adding ACCEPT rules for allowed clients on ports 80/443"
for ip in "${CLIENTS[@]}"; do
  echo "[DEBUG] Processing client IP: $ip"
  if [[ "$ip" == *:* ]]; then
    for port in 80 443; do
      ip6tables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding ip6tables INPUT TCP ACCEPT for $ip port $port"
        ip6tables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      }
      ip6tables -C OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding ip6tables OUTPUT TCP ACCEPT for $ip port $port"
        ip6tables -I OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT
      }
      ip6tables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding ip6tables INPUT UDP ACCEPT for $ip port $port"
        ip6tables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
      }
      ip6tables -C OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding ip6tables OUTPUT UDP ACCEPT for $ip port $port"
        ip6tables -I OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT
      }
    done
  else
    for port in 80 443; do
      iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding iptables INPUT TCP ACCEPT for $ip port $port"
        iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
      }
      iptables -C OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding iptables OUTPUT TCP ACCEPT for $ip port $port"
        iptables -I OUTPUT -d "$ip" -p tcp --sport "$port" -j ACCEPT
      }
      iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding iptables INPUT UDP ACCEPT for $ip port $port"
        iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
      }
      iptables -C OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT 2>/dev/null || {
        echo "[DEBUG] Adding iptables OUTPUT UDP ACCEPT for $ip port $port"
        iptables -I OUTPUT -d "$ip" -p udp --sport "$port" -j ACCEPT
      }
    done
  fi
done

echo "[INFO] ACCEPT rules for ports 80/443 added to filter table for allowed clients"
echo "[INFO] ✅ ACL setup complete: universal (22/53) allowed in filter, marking 80/443 in mangle, filtering 80/443 in filter table — NO DROP rules active"