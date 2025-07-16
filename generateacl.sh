#!/bin/bash

set -euo pipefail

CLIENTS=()
UPSTREAM_DNS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# --- CLEANUP EXISTING CHAINS ---
echo "[INFO] Flushing existing chains: ACL-ALLOW and ACL-UNRESTRICTED"

for chain in ACL-ALLOW ACL-UNRESTRICTED; do
  for cmd in iptables ip6tables; do
    $cmd -t mangle -F "$chain" 2>/dev/null || true
    for hook in INPUT OUTPUT PREROUTING FORWARD; do
      $cmd -t mangle -D "$hook" -j "$chain" 2>/dev/null || true
    done
    $cmd -t mangle -X "$chain" 2>/dev/null || true
  done
done

# --- READ ACL CLIENT LIST ---
read_acl() {
  for i in "${client_list[@]}"; do
    if timeout 15s ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      local v4=$(timeout 5s dig +short "$i" A 2>/dev/null || true)
      local v6=$(timeout 5s dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$v4" ] || [ -n "$v6" ]; then
        [ -n "$v4" ] && while read -r ip; do
          [ -n "$ip" ] && CLIENTS+=( "$ip" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$v4"
        [ -n "$v6" ] && while read -r ip; do
          [ -n "$ip" ] && CLIENTS+=( "$ip" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$v6"
      else
        echo "[ERROR] Failed to resolve: $i — skipping"
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
  CONF="/run/systemd/resolve/resolv.conf"
  [ -f "$CONF" ] || CONF="/etc/resolv.conf"
  while read -r line; do
    [[ "$line" =~ ^nameserver[[:space:]]+([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "${BASH_REMATCH[1]}" )
  done < "$CONF"
fi

if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  echo "[WARN] No resolvers found — using public fallback"
  UPSTREAM_DNS+=( "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" )
fi

echo "[DEBUG] Upstream resolvers:"
for r in "${UPSTREAM_DNS[@]}"; do echo "  - $r"; done

# --- WRITE ALLOWED CLIENTS FILE ---
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
: > "$ACL_FILE"
printf '%s\n' "${CLIENTS[@]}" > "$ACL_FILE"
echo "[INFO] Wrote allowed clients to $ACL_FILE"

# --- ACL-UNRESTRICTED (22 & 53 allowed globally) ---
for cmd in iptables ip6tables; do
  $cmd -t mangle -N ACL-UNRESTRICTED || true
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --dport 22 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --sport 22 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p udp --dport 53 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --dport 53 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -j RETURN
done

for cmd in iptables ip6tables; do
  for hook in INPUT OUTPUT PREROUTING FORWARD; do
    $cmd -t mangle -C "$hook" -j ACL-UNRESTRICTED 2>/dev/null || \
    $cmd -t mangle -I "$hook" -j ACL-UNRESTRICTED
  done
done

# --- ACL-ALLOW (only ports 80/443 and only if IP matches) ---
for cmd in iptables ip6tables; do
  $cmd -t mangle -N ACL-ALLOW || true
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

iptables -t mangle -A ACL-ALLOW -j DROP
ip6tables -t mangle -A ACL-ALLOW -j DROP

iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] ✅ ACL setup complete: universal (22/53), conditional (80/443)"