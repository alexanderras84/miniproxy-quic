#!/bin/bash

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

function read_acl () {
  for i in "${client_list[@]}"
  do
    if timeout 15s ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s dig +short "$i" A)
      RESOLVE_IPV6_LIST=$(timeout 5s dig +short "$i" AAAA)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"
        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A/AAAA for '$i' — skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${CLIENTS[@]}" | grep -q '127.0.0.1'; then
    echo "[INFO] Adding '127.0.0.1' to allowed clients"
    CLIENTS+=( "127.0.0.1" )
  fi
}

if [ -n "$ALLOWED_CLIENTS_FILE" ] && [ -f "$ALLOWED_CLIENTS_FILE" ]; then
  mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
else
  IFS=', ' read -ra client_list <<< "$ALLOWED_CLIENTS"
fi

read_acl

cat > /etc/sing-box/acl.json <<EOF
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "source_ip": [
EOF

for ip in "${CLIENTS[@]}"; do
  echo "          \"$ip\"," >> /etc/sing-box/acl.json
done

sed -i '$ s/,$//' /etc/sing-box/acl.json

cat >> /etc/sing-box/acl.json <<EOF
        ],
        "outbound": "direct"
      }
    ]
  }
}
EOF

echo "[INFO] ACL JSON generated at /etc/sing-box/acl.json"