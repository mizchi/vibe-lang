#!/usr/bin/env bash
set -euo pipefail

# Regression for #2376's public command boundary. The lower-level
# scripts/vibe_test.sh harness already exercises filesystem-aware GC codegen,
# but `vibe test` has its own compile_to environment wiring and can silently
# fall back to direct single-file mode if VIBE_FS_COMPILE is dropped there.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

CLI_WASM="${1:-}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  echo "gc-launcher-import: compiler wasm not found" >&2
  exit 2
fi

VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
VIBE_CLI_WASM="$CLI_WASM" \
VIBE_TEST_BACKEND=gc \
  bash "$ROOT_DIR/runtime/vibe" test --no-cache \
    fixtures/gc_import_resolution_test.vibe

echo "gc-launcher-import: ok"
