#!/bin/sh
# Removes Bowheel.app, and the 0.1.x root daemon if present.
set -e
pkill -x Bowheel 2>/dev/null || true
rm -rf /Applications/Bowheel.app
if [ -f /Library/LaunchDaemons/org.bowheel.daemon.plist ] || [ -f /Library/LaunchDaemons/com.mintylamb.bowheel.plist ]; then
  sudo sh -c '
    launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
    launchctl bootout system/com.mintylamb.bowheel 2>/dev/null || true
    rm -f /Library/LaunchDaemons/org.bowheel.daemon.plist /Library/LaunchDaemons/com.mintylamb.bowheel.plist /usr/local/bin/bowheel
    rm -rf "/Library/Application Support/bowheel"
  '
fi
echo "removed. If \"Start at login\" was on, remove Bowheel from System Settings > General > Login Items."
echo "Stale \"Bowheel\" entries can be deleted from Input Monitoring and Accessibility."
