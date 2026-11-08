#!/bin/sh
# Restarts the debug app against the local backend, quietly (no banners, no login item, panel stays hidden).
pkill -f "Debug/Laser Focus.app/Contents/MacOS"; sleep 0.5  # never the installed app
cd "$(dirname "$0")/../mac" || exit 1
MENUBAR_TODO_QUIET=1 LASER_FOCUS_CONFIG_DIR=/tmp/mbt-qa/config MENUBAR_TODO_URL=${URL:-http://localhost:8787} MENUBAR_TODO_TOKEN=${TOKEN:-mac-dev-token} \
  "build/Build/Products/Debug/Laser Focus.app/Contents/MacOS/Laser Focus" > /tmp/mbt-qa/app.log 2>&1 &
sleep 3
