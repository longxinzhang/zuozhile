#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app}"

export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/Contents/sdk}"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_HOME/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

cd "$PROJECT_ROOT"
"$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw" assembleHap --no-daemon "$@"

