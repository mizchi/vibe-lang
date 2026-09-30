#!/usr/bin/env bash
# compiler-gate lane: late (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/late/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2

source "$ROOT_DIR/tests/gates/late/adr_0069_fn_main_sugar_entry_top_level_hardening.sh"
source "$ROOT_DIR/tests/gates/late/adr_0068_taskgroup_g_body_syntax_sugar.sh"
source "$ROOT_DIR/tests/gates/late/typed_exception_e_rows.sh"
source "$ROOT_DIR/tests/gates/late/adr_0068_opt_in_gate_check_build_serve_single_source_closure_rep.sh"
source "$ROOT_DIR/tests/gates/late/the_buffer_lane_reports_an_unknown_derive_and_agrees_with_the_bu.sh"
