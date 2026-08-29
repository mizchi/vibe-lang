#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_WASM="${1:-}"
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  echo "usage: scripts/test_gc_direct_import_diag.sh <stage2.wasm>" >&2
  exit 2
fi

work_dir="$(mktemp -d -t vibe-gc-direct-import-XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
out_wasm="$work_dir/out.wasm"

if VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$CLI_WASM" fixtures/gc_import_diag_use.vibe "$out_wasm" main \
    >/dev/null 2>&1; then
  echo "[gc-direct-import-diag] FAIL: direct mode accepted an unresolved import" >&2
  exit 1
fi

diag="$out_wasm.diag"
if [ ! -s "$diag" ] || ! grep -qF 'direct single-file mode' "$diag" || \
    ! grep -qF 'VIBE_FS_COMPILE=1 together with VIBE_BACKEND=gc' "$diag"; then
  echo "[gc-direct-import-diag] FAIL: missing actionable direct-mode diagnostic" >&2
  [ -s "$diag" ] && cat "$diag" >&2
  exit 1
fi

echo "[gc-direct-import-diag] ok"
