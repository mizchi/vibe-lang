#!/usr/bin/env bash
set -euo pipefail

stage2_wasm="${1:?usage: stage2_oracles.sh <stage2.wasm>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

echo "[compiler-gate] selfhost split CLI core"
# On a clean Linux checkout, header discovery for this import graph retains
# about 1.03 GB and the cold RC path traps before codegen. build_cli_core first
# warms the source-fingerprinted header cache, reducing that phase to about
# 189 MB. The subsequent compile still peaks at about 4.18 GB, so reserve its
# measured wasm32 space up front for this build only; test_cli_core deliberately
# does not pass it to the smaller consumer invocations.
VIBE_CLI_CORE_BASE_COMPILER="$stage2_wasm" \
  VIBE_CLI_CORE_BUILD_PRE_GROW_PAGES=65000 \
  VIBE_RC=1 \
  bash scripts/test_cli_core.sh

echo "[compiler-gate] FS heap mark lane smoke"
heapmarkdir="_build/_gate_fs_heap_marks"
rm -rf "$heapmarkdir"
mkdir -p "$heapmarkdir"
printf 'export let _start: () -> Int = () -> { 42 }\n' > "$heapmarkdir/input.vibe"
for heap_backend in rc bump; do
  heap_rc=1
  heap_boundary=codegen_rc
  if [ "$heap_backend" = bump ]; then
    heap_rc=0
    heap_boundary=codegen_bump
  fi
  heap_log="$heapmarkdir/$heap_backend.log"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_RC="$heap_rc" VIBE_PROFILE_MEMORY_MARKS=1 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$heapmarkdir/input.vibe" "$heapmarkdir/$heap_backend.wasm" _start \
    >/dev/null 2>"$heap_log" || true
  if [ ! -s "$heapmarkdir/$heap_backend.wasm" ] \
    || ! grep -q "name=start" "$heap_log" \
    || ! grep -q "name=$heap_boundary" "$heap_log"; then
    echo "[compiler-gate] FAIL: compiled CLI did not emit selected $heap_backend heap marks" >&2
    cat "$heap_log" >&2 || true
    exit 1
  fi
done
rm -rf "$heapmarkdir"

VIBE_RC=0 node scripts/artifact_input_trace_oracle.mjs "$stage2_wasm"
bash scripts/test_rc_entry_result_parity.sh "$stage2_wasm"
mkdir -p _build/ci-artifacts
VIBE_RC=0 \
  VIBE_SHADOW_DECISION_DIFF_OUT="$ROOT_DIR/_build/ci-artifacts/incremental-shadow-decision-diff.json" \
  node scripts/incremental_invalidation_oracle.mjs "$stage2_wasm"
VIBE_RC=0 node scripts/experimental_typing_env_reuse_oracle.mjs "$stage2_wasm"
