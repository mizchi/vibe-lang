#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# trial_gate.sh was a MoonBit-host hop that only exec'd compiler_gate.sh.
exec bash "$SCRIPT_DIR/compiler_gate.sh" "$@"
