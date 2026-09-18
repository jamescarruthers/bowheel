#!/bin/sh
# Captures 25 s of live behaviour (real scrolling + a full timestamped log) using the
# CLI in place of the app, then relaunches the app.  ./trace.sh [extra bowheel flags]
# The CLI needs Input Monitoring + Accessibility itself; running it from Terminal
# borrows Terminal's grants.
set -e
cd "$(dirname "$0")"
[ -x ./bowheel ] || ./build.sh
APP_WAS_RUNNING=0; pgrep -x Bowheel >/dev/null && APP_WAS_RUNNING=1
pkill -x Bowheel 2>/dev/null || true
sleep 1
echo "tracing for 25 s — scroll now"
./bowheel --debug --pixels 480 --accel 10 --accel-max 6 "$@" > trace.log 2>&1 &
P=$!
sleep 25
kill $P 2>/dev/null || true
[ "$APP_WAS_RUNNING" = 1 ] && open -n /Applications/Bowheel.app 2>/dev/null || true
echo "done: $(grep -c '^rpt' trace.log) reports in trace.log"
