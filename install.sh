#!/bin/sh
# Installs Bowheel.app to /Applications and removes the root daemon from bowheel <= 0.1.x
# if one is present. No sudo needed unless that old daemon has to be removed.
set -e
cd "$(dirname "$0")"
[ -d ./Bowheel.app ] || { echo "no Bowheel.app here — build it first: ./build-gui.sh" >&2; exit 1; }

# Old daemon-based install (0.1.x). It seizes the dial, so it must go first.
if [ -f /Library/LaunchDaemons/org.bowheel.daemon.plist ] || [ -f /Library/LaunchDaemons/com.mintylamb.bowheel.plist ]; then
  echo "Removing the bowheel 0.1.x root daemon (needs your password)…"
  sudo sh -c '
    launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
    launchctl bootout system/com.mintylamb.bowheel 2>/dev/null || true
    rm -f /Library/LaunchDaemons/org.bowheel.daemon.plist /Library/LaunchDaemons/com.mintylamb.bowheel.plist
    rm -f /usr/local/bin/bowheel
    rm -rf "/Library/Application Support/bowheel"
  '
  echo "  removed. You can also delete the old \"bowheel\" entries from Input Monitoring and Accessibility."
fi

pkill -x Bowheel 2>/dev/null || true
rm -rf /Applications/Bowheel.app
cp -R ./Bowheel.app /Applications/Bowheel.app
# Release zips downloaded through a browser carry the quarantine flag, and the app is
# not notarized. Running this installer is the user's explicit choice to trust it.
xattr -dr com.apple.quarantine /Applications/Bowheel.app 2>/dev/null || true

open -n /Applications/Bowheel.app
echo "installed /Applications/Bowheel.app and launched it."
echo "On first launch it asks for Input Monitoring and Accessibility, then relaunches itself."
echo "Turn on \"Start at login\" in its menu to have it at every login."
