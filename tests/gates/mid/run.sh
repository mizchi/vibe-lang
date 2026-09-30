#!/usr/bin/env bash
# compiler-gate lane: mid (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/mid/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2

source "$ROOT_DIR/tests/gates/mid/retired_v128_intrinsics_stay_retired.sh"
source "$ROOT_DIR/tests/gates/mid/6b_40_wasm_gc_region_arena_reclamation.sh"
source "$ROOT_DIR/tests/gates/mid/self_discharging_owner_s_closure_typed_parameter.sh"
