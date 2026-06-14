#!/usr/bin/env bash
set -euo pipefail

LABEL="com.longxin.zuozhile.keepawake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/zuozhile-phone-keepawake.log"

if [ -f "$PLIST" ]; then
  echo "LaunchAgent: $PLIST"
else
  echo "LaunchAgent missing: $PLIST"
fi

launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'state =|runs =|last exit|run interval' || true

if [ -f "$LOG_FILE" ]; then
  echo "--- recent taps"
  tail -10 "$LOG_FILE"
else
  echo "Tap log missing: $LOG_FILE"
fi
