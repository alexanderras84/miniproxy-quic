#!/bin/bash

set -euo pipefail

CLIENTS=()
UPSTREAM_DNS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# --- CLEANUP EXISTING CHAINS ---
echo "[INFO] Flushing existing chains: ACL-ALLOW and ACL-UNRESTRICTED"

for chain in ACL-ALLOW ACL-UNRESTRICTED; do
  for table in iptables ip6tables; do
    $table -t mangle -F "$chain" 2>/dev/null || true
    for hook in PREROUTING OUTPUT INPUT FORWARD; do
      $table -t mangle -D "$hook" -j "$chain" 2>/dev/null || true
    done
    $table -t mangle -X "$chain" 2>/dev/null || true
  done
done

# --- READ ACL CLIENT LIST ---
read_acl() {
  for i in "${client_list[@]}"; do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s dig +short "$i" A 2>/dev/null || true)
      RESOLVE_IPV6_LIST=$(timeout 5s dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        [ -n "$RESOLVE_IPV4_LIST" ] && while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        [ -n "$RESOLVE_IPV6_LIST" ] && while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A/AAAA for '$i' — skipping"
      fi
    fi
  done
}

# Load allowed client list
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE does not exist"
    exit 1
  fi
elif [ -n "${ALLOWED_CLIENTS:-}" ]; then
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
else
  echo "[ERROR] No ALLOWED_CLIENTS or ALLOWED_CLIENTS_FILE provided"
  exit 1
fi

read_acl

# --- DETECT UPSTREAM DNS RESOLVERS ---
if command -v resolvectl >/dev/null 2>&1; then
  while read -r ip; do
    [[ "$ip" =~ ^([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "$ip" )
  done < <(resolvectl status | awk '/DNS Servers:/ {print $3} /^[[:space:]]+[0-9a-fA-F:.]+$/ {print $1}')
fi

if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  DNS_CONF="/run/systemd/resolve/resolv.conf"
  [ -f "$DNS_CONF" ] || DNS_CONF="/etc/resolv.conf"
  while read -r line; do
    [[ "$line" =~ ^nameserver[[:space:]]+([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "${BASH_REMATCH[1]}" )
  done < "$DNS_CONF"
fi

if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  echo "[WARN] No resolvers found — using fallback public DNS"
  UPSTREAM_DNS+=( "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" )
fi

echo "[DEBUG] Detected upstream resolvers:"
for r in "${UPSTREAM_DNS[@]}"; do echo "  - $r"; done

# --- WRITE ALLOWED CLIENTS FILE ---
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
: > "$ACL_FILE"
printf '%s\n' "${CLIENTS[@]}" > "$ACL_FILE"
echo "[INFO] Wrote allowed clients to $ACL_FILE"

# --- CREATE ACL-UNRESTRICTED CHAIN (22, 53 allowed globally) ---
for table in iptables ip6tables; do
  $table -t mangle -N ACL-UNRESTRICTED
  # DNS
  $table -t mangle -A ACL-UNRESTRICTED -p udp --dport 53 -j RETURN
  $table -t mangle -A ACL-UNRESTRICTED -p tcp --dport 53 -j RETURN
  # SSH
  $table -t mangle -A ACL-UNRESTRICTED -p tcp --dport 22 -j RETURN
  $table -t mangle -A ACL-UNRESTRICTED -p tcp --sport 22 -j RETURN
  # Final DROP
  $table -t mangle -A ACL-UNRESTRICTED -j DROP
done

# Hook ACL-UNRESTRICTED into all directions
for table in iptables ip6tables; do
  for hook in INPUT OUTPUT PREROUTING FORWARD; do
    $table -t mangle -C "$hook" -j ACL-UNRESTRICTED 2>/dev/null || \
    $table -t mangle -I "$hook" -j ACL-UNRESTRICTED
  done
done

# --- CREATE ACL-ALLOW (allow 80/443 if source/dest is client IP) ---
for table in iptables ip6tables; do
  $table -t mangle -N ACL-ALLOW
done

for ip in "${CLIENTS[@]}"; do
  if [[ "$ip" == *:* ]]; then
    for port in 80 443; do
      ip6tables -t mangle -A ACL-ALLOW -s "$ip" -p tcp --dport "$port" -j RETURN
      ip6tables -t mangle -A ACL-ALLOW -d "$ip" -p tcp --sport "$port" -j RETURN
      ip6tables -t mangle -A ACL-ALLOW -s "$ip" -p udp --dport "$port" -j RETURN
      ip6tables -t mangle -A ACL-ALLOW -d "$ip" -p udp --sport "$port" -j RETURN
    done
  else
    for port in 80 443; do
      iptables -t mangle -A ACL-ALLOW -s "$ip" -p tcp --dport "$port" -j RETURN
      iptables -t mangle -A ACL-ALLOW -d "$ip" -p tcp --sport "$port" -j RETURN
      iptables -t mangle -A ACL-ALLOW -s "$ip" -p udp --dport "$port" -j RETURN
      iptables -t mangle -A ACL-ALLOW -d "$ip" -p udp --sport "$port" -j RETURN
    done
  fi
done

# Final DROP for ACL-ALLOW
iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

# Hook into PREROUTING only
iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] ACL setup complete: universal ports (22/53), selective (80/443)"