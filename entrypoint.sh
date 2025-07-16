#!/bin/bash -e

echo "[INFO] Starting sing-box..."
exec sing-box run -c /etc/sing-box/config.json
