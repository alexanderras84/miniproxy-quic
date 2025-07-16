#!/bin/bash -e

echo "[INFO] Starting sing-box in the background..."
exec sing-box run -c /etc/sing-box/config.json