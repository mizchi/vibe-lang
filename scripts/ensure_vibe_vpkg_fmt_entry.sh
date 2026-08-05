#!/usr/bin/env bash
# Compile lib/@vibe/cli/vpkg_fmt_entry.vibe (the `vpkg_fmt.sh` entry point,
# #1435) to _build/vibe_vpkg_fmt/vpkg_fmt_entry.wasm if it's missing or
# stale. Mirrors scripts/ensure_vibe_fmt_entry.sh (the `.vibe` formatter's
# equivalent) exactly, one directory over.
#
# Prints the repo-root-relative path to the compiled wasm on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
entry_src="lib/@vibe/cli/vpkg_fmt_entry.vibe"
work="$ROOT_DIR/_build/vibe_vpkg_fmt"
mkdir -p "$work"
entry_wasm_rel="_build/vibe_vpkg_fmt/vpkg_fmt_entry.wasm"

if [ ! -s "$ROOT_DIR/$entry_wasm_rel" ] || [ "$entry_src" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/format.vibe" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/index.vpkg" -nt "$ROOT_DIR/$entry_wasm_rel" ]; then
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$seed" "$entry_src" "$entry_wasm_rel" main >&2
  [ -s "$ROOT_DIR/$entry_wasm_rel" ] || { echo "ensure_vibe_vpkg_fmt_entry.sh: failed to compile formatter" >&2; exit 1; }
fi

echo "$entry_wasm_rel"
