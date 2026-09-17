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
  "momentumDecay": 0.94,
  "idleEndMs": 150
}
JSON
  chown root:admin "$DIR/config.json"; chmod 664 "$DIR/config.json"
fi

# Release zips downloaded through a browser carry the quarantine xattr, and neither the
# daemon nor the app is Developer-ID signed. Clearing it here is what the user asked for
# by running the installer.
xattr -dr com.apple.quarantine ./bowheel ./Bowheel.app 2>/dev/null || true

install -m 755 ./bowheel /usr/local/bin/bowheel
install -m 644 ./org.bowheel.daemon.plist /Library/LaunchDaemons/org.bowheel.daemon.plist
chown root:wheel /Library/LaunchDaemons/org.bowheel.daemon.plist

launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/org.bowheel.daemon.plist
launchctl enable system/org.bowheel.daemon

rm -rf /Applications/Bowheel.app
cp -R ./Bowheel.app /Applications/Bowheel.app
echo "installed /Applications/Bowheel.app (menu bar). Add it to Login Items to start at login."

echo
echo "ONE MORE STEP — grant Input Monitoring to the daemon:"
echo "  System Settings > Privacy & Security > Input Monitoring > enable \"bowheel\""
echo "  The daemon has registered itself in that list and restarts on its own once ticked."
echo "  Root is not exempt from this; without it the dial opens fine and stays silent."
if [ -n "$SUDO_USER" ]; then
  sudo -u "$SUDO_USER" open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
fi
echo
echo "installed. log: /var/log/bowheel.log"
echo "tune via the Bowheel menu bar app, or edit $DIR/config.json (hot-reloaded)."
