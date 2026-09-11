#!/usr/bin/env bash
# compiler-gate lane: selftests.
#
# Every gate in this repository must be able to FAIL and must prove it: a gate
# ships with a companion `*_test.sh` that mutates a real input and asserts the
# gate rejects it (#2248). check_gate_self_tests.sh is what enforces that --
# it discovers the companions by glob and RUNS them all, because crediting a
# self-test for existing as a file makes the guarantee a filename convention.
#
# It used to run inside the late lane, and it is 208s of the 397s that lane
# spent -- while the late lane's 411s was the entire 419s critical path of the
# run (measured from the per-line log timestamps of run 34590373673). Half of
# every CI run was this one script, waiting behind the compiler's own gate for
# no reason: it runs shell gates, not compiled programs.
#
# Here it overlaps early/mid/late instead of extending the longest of them.
#
# WHY A LANE AND NOT A STANDALONE JOB. Three companions take the compiler from
# the environment -- check_compile_only_lanes_test.sh and
# check_freeze_surface_test.sh read VIBE_STAGE2_WASM, check_book_console_test.sh
# reads VIBE_TEST_CLI_WASM. A job without those does not fail; it falls back to
# the committed seed and answers green about a compiler that does not contain
# the change (AGENTS.md, "Which compiler answered?"). Sharing the lanes' matrix
# means this lane's environment is the late lane's by construction.
#
# STILL SERIAL INSIDE, and it has to be: the companions share the working tree.
# check_portable_boundary_test.sh mutates tracked files under lib/ and restores
# them with `git checkout`, and running the set over `xargs -P 4` produced
# failures that differed run to run -- the long comment in
# check_gate_self_tests.sh records both interleavings. A lane is a whole tree
# of its own, so the parallelism is between lanes, not inside one.
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2

echo "[compiler-gate] selftests: every gate self-test, serially"
bash "$ROOT_DIR/scripts/check_gate_self_tests.sh"
bash "$ROOT_DIR/scripts/check_gate_self_tests_test.sh"
# The gate LIBRARY's own helpers. check_gate_self_tests.sh discovers companions
# by globbing scripts/, so anything under tests/gates/ is invisible to it --
# and `gate_split_cli_cache_is_current` decides WHICH compiler the #2305 lane
# questions, which is exactly the kind of answer that must not go unchecked.
bash "$ROOT_DIR/tests/gates/lib_test.sh"
echo "[compiler-gate] gate self-tests ok (#2248)"
