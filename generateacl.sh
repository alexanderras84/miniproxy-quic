#!/bin/bash
set -euo pipefail

echo "[INFO] Opening ports 80 and 443 for TCP and UDP..."

###############################################################################
# ALLOW 80/443 (TCP + UDP)
###############################################################################

for cmd in iptables ip6tables; do
  for port in 80 443; do
    # Check if the rule exists, if not, insert it at the top (-I)
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT

    $cmd -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p udp --dport "$port" -j ACCEPT
  done

  # Always allow Established/Related traffic so the proxy can talk back to CDNs
  $cmd -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    $cmd -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

###############################################################################
# ENSURE NO EXISTING DROP RULES INTERFERE
###############################################################################

for cmd in iptables ip6tables; do
  for port in 80 443; do
    # Remove any existing DROP rules for these specific ports if they exist
    while $cmd -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; do :; done
    while $cmd -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do :; done
  done
done

echo "[INFO] ✅ Ports 80/443 are now open for both TCP and UDP."
echo "[INFO] Sing-box can now receive traffic for your SNI proxy setup."
