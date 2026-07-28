#!/usr/bin/env bash
# Cached build+run wrapper for scripts/coverage_acc_tool.vibex (native-vibe
# port of the acc_merge.py heredoc + sum/len python one-liners several
# coverage_*.sh scripts repeat -- see that file's own header comment).
#
# Not run through scripts/vibe_run.sh: its `--invoke main` path
# double-executes `main` for any entry other than `_start` (#1182, see
# scripts/vibe_md.sh's header comment).
#
# Builds the tool ONCE and caches the wasm across invocations, like
# scripts/coverage_unittests_run.sh: several callers (coverage_corpus.sh,
# coverage_features.sh, coverage_manifestcache.sh, coverage_multimodule.sh)
# call `merge` once per workload run in a loop, and recompiling a fresh
# subprocess each time would make that loop far slower for no benefit.
#
# Usage:
#   bash scripts/coverage_acc_tool_run.sh merge <acc_path> <run_path>
#   bash scripts/coverage_acc_tool_run.sh stat <acc_path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

if [ $# -lt 2 ]; then
  echo "usage: bash scripts/coverage_acc_tool_run.sh merge <acc> <run> | stat <acc>" >&2
  exit 2
fi

compiler="${VIBE_COVERAGE_ACC_TOOL_COMPILER:-bootstrap/seed/compiler.wasm}"
if [ ! -s "$compiler" ]; then
  echo "coverage_acc_tool_run.sh: compiler wasm not found: $compiler" >&2
  exit 2
fi

workdir="${VIBE_COVERAGE_ACC_TOOL_WORKDIR:-_build/coverage_acc_tool}"
mkdir -p "$workdir"
tool="$workdir/coverage_acc_tool.wasm"

if [ ! -s "$tool" ]; then
  rm -f "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" scripts/coverage_acc_tool.vibex "$tool" main >"$workdir/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "coverage_acc_tool_run.sh: failed to build scripts/coverage_acc_tool.vibex (exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$workdir/build.log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
