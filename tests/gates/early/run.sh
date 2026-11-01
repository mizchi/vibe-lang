#!/usr/bin/env bash
# compiler-gate lane: early (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/early/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2

echo "[compiler-gate] SIMD BLAKE3 allocator parity (#3507)"
python3 "$ROOT_DIR/scripts/check_blake3_simd_allocators.py" "$stage2_wasm"

echo "[compiler-gate] vibe run --coverage writes a report, or fails saying why (#3674)"
bash "$ROOT_DIR/scripts/test_vibe_run_coverage.sh" "$stage2_wasm"

source "$ROOT_DIR/tests/gates/early/multi_file_fs_compile_regression.sh"
source "$ROOT_DIR/tests/gates/early/extended_derive.sh"
source "$ROOT_DIR/tests/gates/early/async_for_loop_classification.sh"
