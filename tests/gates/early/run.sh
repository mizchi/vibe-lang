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

echo "[compiler-gate] repository normalize delegates policy to the pinned CLI (#3674)"
bash "$ROOT_DIR/scripts/vibe_normalize_smoke.sh"

echo "[compiler-gate] SIMD BLAKE3 allocator parity (#3507)"
python3 "$ROOT_DIR/scripts/check_blake3_simd_allocators.py" "$stage2_wasm"

echo "[compiler-gate] vibe run --coverage writes a report, or fails saying why (#3674)"
bash "$ROOT_DIR/scripts/test_vibe_run_coverage.sh" "$stage2_wasm"

echo "[compiler-gate] vibe pkg subcommands run with only their granted host imports (#3673)"
bash "$ROOT_DIR/scripts/test_pkg_authority.sh" "$stage2_wasm"

echo "[compiler-gate] vibe pkg update reports the canonical surface and effect change (#3673)"
bash "$ROOT_DIR/scripts/test_pkg_update_diff.sh" "$stage2_wasm"

echo "[compiler-gate] vibe test and vibe_test.sh count tests and summarize a run the same way (#3703)"
bash "$ROOT_DIR/scripts/test_vibe_test_parity.sh" "$stage2_wasm"

echo "[compiler-gate] the vibe test parity gate fails on a mutated runner (#3703)"
bash "$ROOT_DIR/scripts/test_vibe_test_parity_test.sh" "$stage2_wasm"

echo "[compiler-gate] every scripts/*.vibex grant is least authority, and dropping it is refused (#3676)"
( cd "$ROOT_DIR" && bash scripts/vibe_run.sh scripts/check_vibex_grants.vibex -- "$stage2_wasm" )

source "$ROOT_DIR/tests/gates/early/multi_file_fs_compile_regression.sh"
source "$ROOT_DIR/tests/gates/early/extended_derive.sh"
source "$ROOT_DIR/tests/gates/early/async_for_loop_classification.sh"
