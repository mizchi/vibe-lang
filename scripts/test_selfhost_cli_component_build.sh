#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d "/tmp/vibe_selfhost_cli_component_build.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required" >&2
  exit 1
fi

OUT_COMPONENT="$TMP_DIR/selfhost_cli.component.wasm"

scripts/component_wkg_stdio.sh \
  vibe/compiler/selfhost_cli_stage1_entry.vibe \
  "$OUT_COMPONENT"

wasm-tools validate "$OUT_COMPONENT" >/dev/null

echo "selfhost cli component build passed"
