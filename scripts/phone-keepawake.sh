#!/usr/bin/env bash
set -euo pipefail

HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
TARGET="${HDC_TARGET:-}"
TAP_X="${PHONE_KEEPAWAKE_X:-520}"
TAP_Y="${PHONE_KEEPAWAKE_Y:-1180}"
LOG_FILE="${PHONE_KEEPAWAKE_LOG:-$HOME/Library/Logs/zuozhile-phone-keepawake.log}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

if [ ! -x "$HDC" ]; then
  log "missing hdc: $HDC"
  exit 1
fi

if [ -z "$TARGET" ]; then
  TARGET="$("$HDC" list targets | awk 'NF { print $1; exit }')"
fi

if [ -z "$TARGET" ]; then
  log "no connected device"
  exit 1
fi

"$HDC" -t "$TARGET" shell "uinput -T -c $TAP_X $TAP_Y" >/dev/null 2>&1
log "tap target=$TARGET x=$TAP_X y=$TAP_Y"
