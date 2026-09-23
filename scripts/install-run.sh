#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
TARGET="${HDC_TARGET:-}"
SIGNED_HAP="$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED_HAP="$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
BUNDLE_NAME="com.longxin.zuozhile"
ABILITY_NAME="EntryAbility"

if [ ! -x "$HDC" ]; then
  echo "Missing hdc: $HDC" >&2
  exit 1
fi

if [ -z "$TARGET" ]; then
  TARGET="$("$HDC" list targets | awk 'NF { print $1; exit }')"
fi

if [ -z "$TARGET" ]; then
  echo "No connected HarmonyOS device." >&2
  exit 1
fi

"$PROJECT_ROOT/scripts/verify-app.sh"

HAP_PATH="$UNSIGNED_HAP"
if [ -f "$SIGNED_HAP" ]; then
  HAP_PATH="$SIGNED_HAP"
fi

INSTALL_OUTPUT="$("$HDC" -t "$TARGET" install -r "$HAP_PATH")"
printf '%s\n' "$INSTALL_OUTPUT"
if [[ "$INSTALL_OUTPUT" != *"install bundle successfully"* ]]; then
  echo "Device did not confirm installation. App was not started." >&2
  exit 1
fi

START_OUTPUT="$("$HDC" -t "$TARGET" shell "aa start -a $ABILITY_NAME -b $BUNDLE_NAME")"
printf '%s\n' "$START_OUTPUT"
if [[ "$START_OUTPUT" != *"start ability successfully"* ]]; then
  echo "App installed, but device did not confirm launch (check screen lock)." >&2
  exit 1
fi

echo "Installed and started $BUNDLE_NAME on $TARGET"
"$HDC" -t "$TARGET" shell 'aa dump -r' | grep -A 4 "$BUNDLE_NAME" || true
