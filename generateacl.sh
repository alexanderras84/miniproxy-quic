#!/bin/bash
CLIENTS=()
export DYNDNS_CRON_ENABLED=false

function read_acl () {
  for i in "${client_list[@]}"
  do
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
        echo "[ERROR] Could not resolve A or AAAA records for '$i' (timeout or failure) => Skipping"
      fi
    fi
  done

  # Ensure 127.0.0.1 is present if dynamic DNS clients were resolved
  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
     # echo "[INFO] Adding '127.0.0.1' to allowed clients to prevent reload issues"
      CLIENTS+=( "127.0.0.1" )
    fi
  fi
}

# Determine client list source
if [ -n "$ALLOWED_CLIENTS_FILE" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist or is not accessible!"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
fi

# Run ACL generation
read_acl

# Hardcode Docker IPv6 subnet to allowed clients
# echo "[INFO] Adding hardcoded Docker IPv6 subnet to allowlist: fd00:beef:dead:1::/64"
CLIENTS+=( "fd00:beef:cafe::/64" )

# Generate NGINX ACL files
printf '%s\n' "${CLIENTS[@]}" > /etc/nginx/allowedClients.acl

if [ -s /etc/nginx/allowedClients.acl ]; then
  : > /etc/nginx/allowedClients.conf
  while read -r line; do
    echo "allow $line;" >> /etc/nginx/allowedClients.conf
  done < /etc/nginx/allowedClients.acl
  echo "deny all;" >> /etc/nginx/allowedClients.conf
else
  touch /etc/nginx/allowedClients.conf
fi
