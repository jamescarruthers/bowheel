#!/bin/sh
set -e
if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
launchctl bootout system/com.mintylamb.bowheel 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.mintylamb.bowheel.plist
rm -f /Library/LaunchDaemons/org.bowheel.daemon.plist /usr/local/bin/bowheel
rm -rf /Applications/Bowheel.app "/Library/Application Support/bowheel"
echo "removed."
