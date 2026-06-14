#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.longxin.zuozhile.keepawake"
RUNTIME_DIR="$HOME/Library/Zuozhile"
PLIST_DIR="$HOME/Library/LaunchAgents"
RUNTIME_SCRIPT="$RUNTIME_DIR/phone-keepawake.sh"
PLIST="$PLIST_DIR/$LABEL.plist"

mkdir -p "$RUNTIME_DIR" "$PLIST_DIR" "$HOME/Library/Logs"
cp "$PROJECT_ROOT/scripts/phone-keepawake.sh" "$RUNTIME_SCRIPT"
chmod +x "$RUNTIME_SCRIPT"

cp "$PROJECT_ROOT/scripts/phone-keepawake-launchagent.plist" "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

"$PROJECT_ROOT/scripts/keepawake-status.sh"
