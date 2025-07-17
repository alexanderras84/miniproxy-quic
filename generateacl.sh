#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-false}" == "true" ]] && set -x

echo "[INFO] Starting ACL generation"

# --- ENSURE SSH (22) and DNS (53) universally allowed in FILTER table ---
echo "[INFO] Ensuring SSH (22) and DNS (53) ports are always allowed via filter table"
for cmd in iptables ip6tables; do
  for port in 22 53; do
    # TCP allow
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
    $cmd -C OUTPUT -p tcp --sport "$port" -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p tcp --sport "$port" -j ACCEPT
  done

  # UDP 53 allow (DNS)
  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || $cmd -I INPUT -p udp --dport 53 -j ACCEPT
  $cmd -C OUTPUT -p udp --sport 53 -j ACCEPT 2>/dev/null || $cmd -I OUTPUT -p udp --sport 53 -j ACCEPT
done

# --- CLEANUP EXISTING CHAINS IN FILTER TABLE ---
echo "[INFO] Flushing existing ACL-ALLOW chain in filter table"
for cmd in iptables ip6tables; do
  if $cmd -t filter -L ACL-ALLOW &>/dev/null; then
    echo "[DEBUG] Flushing existing chain ACL-ALLOW with $cmd"
    $cmd -t filter -F ACL-ALLOW || true
    for hook in INPUT OUTPUT; do
      $cmd -t filter -D "$hook" -j ACL-ALLOW 2>/dev/null || true
    done
    $cmd -t filter -X ACL-ALLOW || true
  else
    echo "[DEBUG] Skipping undefined chain ACL-ALLOW for $cmd"
  fi
done
echo "[DEBUG] Cleanup complete — old ACL-ALLOW chain flushed/deleted from filter table"

# --- MARK ALL 80/443 TCP & UDP TRAFFIC IN MANGLE (for transparent proxy) ---
echo "[INFO] Marking all TCP/UDP traffic on ports 80 and 443 in mangle table"
for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK

  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN

  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done
echo "[DEBUG] Marking all 80/443 TCP & UDP traffic done"

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

echo "[INFO] ✅ ACL setup complete: universal (22/53) allowed in filter, marking 80/443 in mangle, filtering 80/443 in filter table — NO DROP rules active"