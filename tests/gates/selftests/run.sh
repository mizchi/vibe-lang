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
# The relocation measurement is not a check_* gate, so its synthetic-module
# regression is explicit here. gate_resolve_stage2 supplies this lane's compiler.
bash "$ROOT_DIR/scripts/reloc_crossbuild_test.sh"
# Same reason for the checked-module parity oracle (#1959): `checked_module_*`
# does not match the `check_*` glob discovery uses, so its companion is named
# here rather than found. Its rows decide when a module may keep a checked
# artifact across an edit -- reusing one whose dependency changed its public
# interface is a silently wrong build, so the rows have to be able to fail.
bash "$ROOT_DIR/scripts/checked_module_cache_parity_test.sh"
# The two incremental MEASUREMENTS, named here for the same glob reason. They
# are not checks and hold no budget, but each one now refuses a sample it
# cannot show is what it is called -- a warm run that reused nothing, a cold
# run that did not start cold -- and a refusal nobody has made fire is a
# comment (#2836 §2). Both narrow their corpus so the mutations cost
# seconds rather than minutes.
bash "$ROOT_DIR/scripts/checked_module_cache_cost_test.sh"
bash "$ROOT_DIR/scripts/incremental_kpi_test.sh"
# And the resolver both of them ask which compiler to measure. Its strict half
# exists to REFUSE -- a stale generation, an empty artifact, a missing override
# -- and a resolver that answered anyway would hand every measurement above a
# compiler that does not contain the change, with nothing in the report saying
# so (#2836 §1). Cheap: no compiler, synthetic git trees.
bash "$ROOT_DIR/scripts/resolve_stage2_test.sh"
# The host half of the capability contract (#2825 step 1,
# docs/internal/design/capability-host-contract.md). Same glob reason again -- and this one is
# a case where the gate that already exists could not see the property:
# `check_host_runtime_contract.py` proves both runners IMPLEMENT every portable
# import, which is a different question from whether either can withhold one.
# Measured, the node runner could not: any `vibe.*` field it did not implement
# answered `0`, so removing a method did not withhold a capability, it made the
# capability lie. The companion asserts the withheld run traps by name AFTER
# instantiating, and that removing the branch lets the same run succeed.
bash "$ROOT_DIR/scripts/host_capability_withhold_test.sh"
echo "[compiler-gate] gate self-tests ok (#2248)"
