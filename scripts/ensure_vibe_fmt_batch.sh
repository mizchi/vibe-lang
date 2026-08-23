#!/usr/bin/env bash
# Compile lib/@vibe/cli/fmt.vibe (the multi-file/sharded `vibe fmt` batch
# entry, #see lib/@vibe/cli/fmt.vibe header) to _build/vibe_fmt/fmt_batch.wasm
# if it's missing or stale. Mirrors scripts/ensure_vibe_fmt_entry.sh; kept
# separate because fmt.vibe pulls in @vibe/process (Process effect) which
# the single-file fmt_entry.vibe does not need.
#
# Prints the repo-root-relative path to the compiled wasm on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
entry_src="lib/@vibe/cli/fmt.vibe"
work="$ROOT_DIR/_build/vibe_fmt"
mkdir -p "$work"
batch_wasm_rel="_build/vibe_fmt/fmt_batch.wasm"

if [ ! -s "$ROOT_DIR/$batch_wasm_rel" ] || [ "$entry_src" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/format.vibe" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/compiler/fmt/index.vpkg" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/compiler/loader/loader.vibe" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/compiler/loader/index.vpkg" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/compiler/contract/contract.vibe" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/process/process.vibe" -nt "$ROOT_DIR/$batch_wasm_rel" ] \
   || [ "lib/@vibe/process/index.vpkg" -nt "$ROOT_DIR/$batch_wasm_rel" ]; then
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$seed" "$entry_src" "$batch_wasm_rel" main >&2
  [ -s "$ROOT_DIR/$batch_wasm_rel" ] || { echo "ensure_vibe_fmt_batch.sh: failed to compile fmt batch entry" >&2; exit 1; }
fi

echo "$batch_wasm_rel"
