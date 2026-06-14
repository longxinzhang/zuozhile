#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNED_HAP_PATH="$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED_HAP_PATH="$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"

cd "$PROJECT_ROOT"

grep -q 'com.longxin.zuozhile' AppScope/app.json5
grep -q '坐直了' AppScope/resources/base/element/string.json
grep -q 'ohos.permission.CAMERA' entry/src/main/module.json5
grep -q '真实相机检测' README.md

./scripts/build-hap.sh --stacktrace

HAP_PATH="$UNSIGNED_HAP_PATH"
if [ -f "$SIGNED_HAP_PATH" ]; then
  HAP_PATH="$SIGNED_HAP_PATH"
fi

if [ ! -f "$HAP_PATH" ]; then
  echo "Missing HAP output" >&2
  exit 1
fi

echo "App verification passed: $HAP_PATH"
