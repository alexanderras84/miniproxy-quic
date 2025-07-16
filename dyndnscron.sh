#!/bin/bash
echo "[INFO] [DynDNSCron] Regenerating ACL..."

# Apply timeout to the generateacl.sh script (adjust as needed)
timeout 40s /bin/bash /generateacl.sh
retVal=$?
if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL regenerated!"
  # Reload sing-box to apply new config (find running process and send SIGHUP)
  SINGBOX_PID=$(pgrep -xo sing-box)
  if [ -n "$SINGBOX_PID" ]; then
    kill -SIGHUP "$SINGBOX_PID"
    echo "[INFO] [DynDNSCron] sing-box successfully reloaded"
  else
    echo "[WARNING] [DynDNSCron] sing-box process not found, cannot reload"
  fi
fi
