#!/bin/sh
# Captures 25 s of live behaviour (real scrolling + full log) for debugging, then puts
# the daemon back. Run from Terminal:  sudo ./trace.sh [extra bowheel flags]
set -e
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
launchctl bootout system/org.bowheel.daemon 2>/dev/null || true
sleep 1
echo "tracing for 25 s — scroll now"
./bowheel --debug --status /dev/null "$@" > trace.log 2>&1 &
P=$!
sleep 25
kill $P 2>/dev/null || true
[ -n "$SUDO_USER" ] && chown "$SUDO_USER" trace.log
launchctl bootstrap system /Library/LaunchDaemons/org.bowheel.daemon.plist 2>/dev/null || true
echo "done: $(grep -c '^rpt' trace.log) reports in trace.log — daemon restarted"
