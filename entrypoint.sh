#!/bin/bash
set -e

# Generate the ACL and rebuild the sing-box config
/generateacl.sh

# Ensure correct permissions (optional, for Docker volume cases)
chown -R miniproxy:miniproxy /etc/sing-box/

# Start sing-box as non-root user
exec su-exec miniproxy sing-box run -c /etc/sing-box/config.json
