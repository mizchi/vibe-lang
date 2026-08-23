#!/usr/bin/env bash
# Compile lib/@vibe/cli/fmt_entry.vibe (the `vibe fmt` entry point) to
# _build/vibe_fmt/fmt_entry.wasm if it's missing or stale. Shared by
# scripts/vibe_fmt.sh (single-file) and scripts/vibe_fmt_parallel.mjs
# (multi-worker bulk apply/check) so both compile the exact same way and
# reuse the exact same cached artifact.
#
# Prints the repo-root-relative path to the compiled wasm on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
entry_src="lib/@vibe/cli/fmt_entry.vibe"
work="$ROOT_DIR/_build/vibe_fmt"
mkdir -p "$work"
entry_wasm_rel="_build/vibe_fmt/fmt_entry.wasm"

if [ ! -s "$ROOT_DIR/$entry_wasm_rel" ] || [ "$entry_src" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/format.vibe" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/index.vpkg" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/contract/contract.vibe" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/compiler/contract/index.vpkg" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/parser/lexer.vibe" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/parser/parser.vibe" -nt "$ROOT_DIR/$entry_wasm_rel" ] \
   || [ "lib/@vibe/parser/index.vpkg" -nt "$ROOT_DIR/$entry_wasm_rel" ]; then
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$seed" "$entry_src" "$entry_wasm_rel" main >&2
  [ -s "$ROOT_DIR/$entry_wasm_rel" ] || { echo "ensure_vibe_fmt_entry.sh: failed to compile formatter" >&2; exit 1; }
fi

echo "$entry_wasm_rel"
