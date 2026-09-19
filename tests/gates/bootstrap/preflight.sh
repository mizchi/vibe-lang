#!/usr/bin/env bash
# Fast, stage-independent bootstrap checks. CI runs this in parallel with the
# selfbuild; the local bootstrap lane invokes it before building.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

echo "[compiler-gate] 0/3 builtin parity (#415 B-3)"
bash scripts/check_builtin_parity.sh
bash scripts/check_gate_registry.sh
bash scripts/check_inline_builtin_capture.sh
node scripts/check_fixture_snapshots.test.mjs
bash scripts/check_fixture_execution.sh
bash scripts/vibe_fmt_parse_guard_test.sh

echo "[compiler-gate] parser binder-context spine"
node --test scripts/parser_binder_context_spine.test.mjs
node scripts/test_immutable_publish_plumbing.js

echo "[compiler-gate] 1-2/3 generated compiler artifacts"
bash scripts/ensure_generated.sh

echo "[compiler-gate] 2a/3 FS heap measurement protocol"
bash scripts/measure_fs_heap_test.sh

# #2877: what environment does a `pkf` task actually inherit? The nix wrapper
# exports LD_LIBRARY_PATH unscoped, so a system binary in a task resolves out
# of the nix closure against the system glibc and `/usr/bin/sort` exits
# non-zero writing NOTHING -- a `find | sort` expansion then reads as "no
# files matched". Taskfile.pkl's `defaults.env` clears it for every task.
#
# HERE and not in a gate lane: the gate asks its question by running a real
# `pkf` task, and the early/mid/late/selftests lanes call `setup-vibe` WITHOUT
# `pkfire: true`, so `pkf` is not installed there. Wiring it into one of those
# gave `pkf: command not found` -- a gate failing for a reason unrelated to its
# subject, which is the #2252 shape that gets a gate exempted rather than
# fixed. This job (`compiler-gate (preflight)`) installs pkfire by
# construction, because it IS invoked through `pkf run`.
echo "[compiler-gate] 2b/3 task environment (#2877)"
bash scripts/check_task_env_sanitized.sh
bash scripts/check_task_env_sanitized_test.sh

echo "[compiler-gate] bootstrap preflight ok"
