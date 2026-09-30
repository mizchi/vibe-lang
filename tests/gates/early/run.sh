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

source "$ROOT_DIR/tests/gates/early/multi_file_fs_compile_regression.sh"
source "$ROOT_DIR/tests/gates/early/extended_derive.sh"
source "$ROOT_DIR/tests/gates/early/async_for_loop_classification.sh"
