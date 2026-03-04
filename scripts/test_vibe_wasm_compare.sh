#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/examples/basics.vibe}"
WARN_LIST="${VIBE_MOON_WARN_LIST:--29}"

if [ ! -f "$ENTRY_PATH" ]; then
  echo "vibe_wasm compare gate failed: entry not found: $ENTRY_PATH" >&2
  exit 1
fi

echo "[vibe_wasm_compare] whitebox parity tests"
moon test -p mizchi/vibe/cmd/vibe_wasm -f main_wbtest.mbt --target native --warn-list "$WARN_LIST"

echo "[vibe_wasm_compare] compare run: $ENTRY_PATH"
compare_output="$(
  moon run --target native src/cmd/vibe_wasm -- compare "$ENTRY_PATH"
)"
printf '%s\n' "$compare_output"

check_mode_status_zero() {
  local mode="$1"
  local line
  line="$(printf '%s\n' "$compare_output" | awk -v m="$mode" '$1==m { print; exit }')"
  if [ -z "$line" ]; then
    echo "vibe_wasm compare gate failed: missing row for mode '$mode'" >&2
    exit 1
  fi
  local status
  status="$(printf '%s\n' "$line" | sed -n 's/.*status=\([-0-9][0-9]*\).*/\1/p')"
  if [ -z "$status" ]; then
    echo "vibe_wasm compare gate failed: unable to parse status for mode '$mode': $line" >&2
    exit 1
  fi
  if [ "$status" != "0" ]; then
    echo "vibe_wasm compare gate failed: mode '$mode' returned non-zero status=$status" >&2
    exit 1
  fi
}

check_mode_status_zero "vibe-run"
check_mode_status_zero "wasm-core"
check_mode_status_zero "component"

echo "vibe_wasm compare gate passed"
