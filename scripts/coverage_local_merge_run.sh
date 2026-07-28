#!/usr/bin/env bash
# Cached build+run wrapper for scripts/coverage_local_merge.vibex (native-vibe
# port of coverage_drivers.sh's own merge.py + coverage_unittests.sh's
# embedded merge heredoc -- see that file's own header comment).
#
# Not run through scripts/vibe_run.sh: its `--invoke main` path
# double-executes `main` for any entry other than `_start` (#1182, see
# scripts/vibe_md.sh's header comment).
#
# Builds the tool ONCE and caches the wasm across invocations, like
# scripts/coverage_unittests_run.sh / scripts/coverage_acc_tool_run.sh:
# coverage_drivers.sh calls `merge` once per driver (dozens of times) in a
# loop.
#
# Usage:
#   bash scripts/coverage_local_merge_run.sh merge <acc_path> <run_path>
#   bash scripts/coverage_local_merge_run.sh merge-list <acc_path> <list_path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

if [ $# -lt 2 ]; then
  echo "usage: bash scripts/coverage_local_merge_run.sh merge <acc> <run> | merge-list <acc> <list>" >&2
  exit 2
fi

compiler="${VIBE_COVERAGE_LOCAL_MERGE_COMPILER:-bootstrap/seed/compiler.wasm}"
if [ ! -s "$compiler" ]; then
  echo "coverage_local_merge_run.sh: compiler wasm not found: $compiler" >&2
  exit 2
fi

workdir="${VIBE_COVERAGE_LOCAL_MERGE_WORKDIR:-_build/coverage_local_merge_tool}"
mkdir -p "$workdir"
tool="$workdir/coverage_local_merge.wasm"

if [ ! -s "$tool" ]; then
  rm -f "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" scripts/coverage_local_merge.vibex "$tool" main >"$workdir/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "coverage_local_merge_run.sh: failed to build scripts/coverage_local_merge.vibex (exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$workdir/build.log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
