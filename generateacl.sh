#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-false}" == "true" ]] && set -x

CLIENTS=()
UPSTREAM_DNS=()
export DYNDNS_CRON_ENABLED=false

echo "[INFO] Starting ACL generation"

# --- ENSURE SSH ACCESS BEFORE ANYTHING ---
echo "[INFO] Ensuring SSH (port 22) is always allowed via filter table"
for cmd in iptables ip6tables; do
  $cmd -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || $cmd -I INPUT -p tcp --dport 22 -j ACCEPT
  $cmd -C OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p tcp --sport 22 -j ACCEPT
done

# --- CLEANUP EXISTING CHAINS ---
echo "[INFO] Flushing existing chains: ACL-ALLOW and ACL-UNRESTRICTED"

for chain in ACL-ALLOW ACL-UNRESTRICTED; do
  for cmd in iptables ip6tables; do
    if $cmd -t mangle -L "$chain" &>/dev/null; then
      echo "[DEBUG] Flushing existing chain $chain with $cmd"
      $cmd -t mangle -F "$chain" || true
      for hook in INPUT OUTPUT PREROUTING FORWARD; do
        $cmd -t mangle -D "$hook" -j "$chain" 2>/dev/null || true
      done
      $cmd -t mangle -X "$chain" || true
    else
      echo "[DEBUG] Skipping undefined chain $chain for $cmd"
    fi
  done
done

echo "[DEBUG] Cleanup complete — all old ACL-ALLOW and ACL-UNRESTRICTED chains flushed/deleted"

# --- READ ACL CLIENT LIST ---
read_acl() {
  echo "[DEBUG] Starting read_acl resolution process"
  for i in "${client_list[@]}"; do
    if timeout 15s ipcalc -cs "$i" >/dev/null 2>&1; then
      echo "[DEBUG] Accepted IP/net directly: $i"
      CLIENTS+=( "$i" )
    else
      echo "[DEBUG] Attempting DNS resolution for: $i"
      local v4=$(timeout 5s dig +short "$i" A 2>/dev/null || true)
      local v6=$(timeout 5s dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$v4" ] || [ -n "$v6" ]; then
        [ -n "$v4" ] && while read -r ip; do
          [ -n "$ip" ] && CLIENTS+=( "$ip" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$v4"
        [ -n "$v6" ] && while read -r ip; do
          [ -n "$ip" ] && CLIENTS+=( "$ip" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$v6"
        echo "[DEBUG] Resolved $i to: ${v4:-<no A>}, ${v6:-<no AAAA>}"
      else
        echo "[ERROR] Failed to resolve: $i — skipping"
      fi
    fi
  done
  echo "[DEBUG] Finished resolving dynamic client list"
}

# Load allowed client list
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  echo "[INFO] Loading client list from file: $ALLOWED_CLIENTS_FILE"
  [[ -f "$ALLOWED_CLIENTS_FILE" ]] || { echo "[ERROR] ALLOWED_CLIENTS_FILE does not exist"; exit 1; }
  mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
elif [ -n "${ALLOWED_CLIENTS:-}" ]; then
  echo "[INFO] Loading client list from environment"
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
else
  echo "[ERROR] No ALLOWED_CLIENTS or ALLOWED_CLIENTS_FILE provided"; exit 1
fi

# Debug: show what we loaded
echo "[DEBUG] Parsed client_list:"
for ip in "${client_list[@]}"; do
  echo "  - $ip"
done

read_acl

# Debug: show final resolved IP list
echo "[DEBUG] Final resolved CLIENTS list:"
for ip in "${CLIENTS[@]}"; do
  echo "  - $ip"
done

# --- DETECT UPSTREAM DNS RESOLVERS ---
echo "[INFO] Detecting upstream DNS resolvers"
if command -v resolvectl &>/dev/null; then
  echo "[DEBUG] Using resolvectl to get DNS servers"
  while read -r ip; do
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] && UPSTREAM_DNS+=( "$ip" )
  done < <(resolvectl status | awk '/DNS Servers:/ {print $3} /^[[:space:]]+[0-9a-fA-F:.]+$/ {print $1}')
fi

if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  CONF="/run/systemd/resolve/resolv.conf"
  [ -f "$CONF" ] || CONF="/etc/resolv.conf"
  echo "[DEBUG] Falling back to parsing $CONF"
  while read -r line; do
    [[ "$line" =~ ^nameserver[[:space:]]+([0-9a-fA-F:.]+)$ ]] && UPSTREAM_DNS+=( "${BASH_REMATCH[1]}" )
  done < "$CONF"
fi

if [ ${#UPSTREAM_DNS[@]} -eq 0 ]; then
  echo "[WARN] No resolvers found — using public fallback"
  UPSTREAM_DNS=( "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" )
fi

echo "[DEBUG] Upstream resolvers:"
for r in "${UPSTREAM_DNS[@]}"; do
  echo "  - $r"
done

# --- WRITE ALLOWED CLIENTS FILE ---
ACL_FILE="/etc/miniproxy/AllowedClients.acl"
: > "$ACL_FILE"
printf '%s\n' "${CLIENTS[@]}" > "$ACL_FILE"
echo "[INFO] Wrote allowed clients to $ACL_FILE"

# --- ACL-UNRESTRICTED (22 & 53 allowed globally) ---
echo "[INFO] Creating ACL-UNRESTRICTED for ports 22/53"
for cmd in iptables ip6tables; do
  echo "[DEBUG] Creating ACL-UNRESTRICTED in $cmd"
  $cmd -t mangle -N ACL-UNRESTRICTED || true
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --dport 22 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --sport 22 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p udp --dport 53 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -p tcp --dport 53 -j RETURN
  $cmd -t mangle -A ACL-UNRESTRICTED -j RETURN
done
for cmd in iptables ip6tables; do
  for hook in INPUT OUTPUT PREROUTING FORWARD; do
    $cmd -t mangle -C "$hook" -j ACL-UNRESTRICTED 2>/dev/null \
      || $cmd -t mangle -I "$hook" -j ACL-UNRESTRICTED
  done
done
echo "[DEBUG] ACL-UNRESTRICTED chain created and linked"

# --- ACL-ALLOW (only ports 80/443 and only if IP matches) ---
echo "[INFO] Creating ACL-ALLOW for matched clients (ports 80/443)"
for cmd in iptables ip6tables; do
  echo "[DEBUG] Creating ACL-ALLOW in $cmd"
  $cmd -t mangle -N ACL-ALLOW || true
done

for ip in "${CLIENTS[@]}"; do
  echo "[DEBUG] Processing client IP: $ip"
  if [[ "$ip" == *:* ]]; then
    for port in 80 443; do
      ip6tables -t mangle -A ACL-ALLOW -s "$ip" -p tcp --dport "$port" -j RETURN || echo "[ERROR] IPv6 tcp dport fail"
      ip6tables -t mangle -A ACL-ALLOW -d "$ip" -p tcp --sport "$port" -j RETURN || echo "[ERROR] IPv6 tcp sport fail"
      ip6tables -t mangle -A ACL-ALLOW -s "$ip" -p udp --dport "$port" -j RETURN || echo "[ERROR] IPv6 udp dport fail"
      ip6tables -t mangle -A ACL-ALLOW -d "$ip" -p udp --sport "$port" -j RETURN || echo "[ERROR] IPv6 udp sport fail"
    done
  else
    for port in 80 443; do
      iptables -t mangle -A ACL-ALLOW -s "$ip" -p tcp --dport "$port" -j RETURN || echo "[ERROR] IPv4 tcp dport fail"
      iptables -t mangle -A ACL-ALLOW -d "$ip" -p tcp --sport "$port" -j RETURN || echo "[ERROR] IPv4 tcp sport fail"
      iptables -t mangle -A ACL-ALLOW -s "$ip" -p udp --dport "$port" -j RETURN || echo "[ERROR] IPv4 udp dport fail"
      iptables -t mangle -A ACL-ALLOW -d "$ip" -p udp --sport "$port" -j RETURN || echo "[ERROR] IPv4 udp sport fail"
    done
  fi
done

echo "[DEBUG] Adding DROP fallback to ACL-ALLOW"
iptables -t mangle -A ACL-ALLOW -j DROP || echo "[ERROR] DROP rule fail"
ip6tables -t mangle -A ACL-ALLOW -j DROP || echo "[ERROR] DROP rule v6 fail"

echo "[DEBUG] Hooking ACL-ALLOW into PREROUTING"
iptables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null \
  || iptables -t mangle -I PREROUTING -j ACL-ALLOW
ip6tables -t mangle -C PREROUTING -j ACL-ALLOW 2>/dev/null \
  || ip6tables -t mangle -I PREROUTING -j ACL-ALLOW

echo "[INFO] ✅ ACL setup complete: universal (22/53), conditional (80/443)"