#!/bin/sh
# Installs bowheel as a root LaunchDaemon. Run with sudo.
set -e
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo ./install.sh" >&2
  exit 1
fi

if [ ! -x ./bowheel ] || [ ! -d ./Bowheel.app ]; then
  echo "build first (as your own user, not root):  ./build.sh && ./build-gui.sh" >&2
  exit 1
fi

# Shared config dir. root:admin 775 so the menu bar app (running as an admin user)
# can atomically replace config.json while the root daemon reads it.
DIR="/Library/Application Support/bowheel"
install -d -o root -g admin -m 775 "$DIR"
if [ ! -f "$DIR/config.json" ]; then
  cat > "$DIR/config.json" <<'JSON'
{
  "pixelsPerDetent": 480,
  "accel": 10.0,
  "accelMax": 6.0,
  "accelStart": 2.0,
  "invertY": false,
  "invertX": false,
  "momentum": false,
  "momentumDecay": 0.96,
  "idleEndMs": 150
}
JSON
  chown root:admin "$DIR/config.json"; chmod 664 "$DIR/config.json"
fi

# Release zips downloaded through a browser carry the quarantine xattr, and neither the
# daemon nor the app is Developer-ID signed. Clearing it here is what the user asked for
# by running the installer.
xattr -dr com.apple.quarantine ./bowheel ./Bowheel.app 2>/dev/null || true

# Only replace the daemon when it actually changed: TCC pins an ad-hoc binary by code
# hash, so a needless copy of a rebuilt-but-identical file is harmless, but a changed one
# invalidates the Input Monitoring grant and the user has to re-add it.
CHANGED=1
if cmp -s ./bowheel /usr/local/bin/bowheel 2>/dev/null; then CHANGED=0; fi
install -m 755 ./bowheel /usr/local/bin/bowheel
install -m 644 ./org.bowheel.daemon.plist /Library/LaunchDaemons/org.bowheel.daemon.plist
chown root:wheel /Library/LaunchDaemons/org.bowheel.daemon.plist

# Remove the pre-rename daemon if an older install left it behind; two daemons would
# fight over the seize.
launchctl bootout system/com.mintylamb.bowheel 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.mintylamb.bowheel.plist

launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/org.bowheel.daemon.plist
launchctl enable system/org.bowheel.daemon

rm -rf /Applications/Bowheel.app
cp -R ./Bowheel.app /Applications/Bowheel.app
echo "installed /Applications/Bowheel.app (menu bar). Add it to Login Items to start at login."

echo
if [ "$CHANGED" = 1 ] && [ -n "$(tail -1 /var/log/bowheel.log 2>/dev/null)" ]; then
  echo "NOTE: the daemon binary changed. If bowheel is already in the privacy lists below,"
  echo "      remove it (-) and add it again (+) in BOTH — old grants are pinned to the old build."
fi
echo "TWO MORE STEPS — System Settings > Privacy & Security. Root is exempt from neither."
echo "  1. Input Monitoring  (to read the dial)"
echo "  2. Accessibility     (to post scroll events — without it reports flow but nothing scrolls)"
echo "  In each: enable \"bowheel\". If it is not listed: +, Shift-Cmd-G, /usr/local/bin/bowheel"
if [ -n "$SUDO_USER" ]; then
  sudo -u "$SUDO_USER" open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
fi
echo
echo "installed. log: /var/log/bowheel.log"
echo "tune via the Bowheel menu bar app, or edit $DIR/config.json (hot-reloaded)."
