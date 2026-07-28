#!/usr/bin/env bash
# Cached build+run wrapper for scripts/coverage_unittests.vibex (#1142-style
# native-vibe port of scripts/coverage_unittests.py).
#
# Not run through scripts/vibe_run.sh: its `--invoke main` path
# double-executes `main` for any entry other than `_start` (see
# scripts/vibe_md.sh's header comment / issue #1182 for the underlying
# runner bug this works around the same way vibe_md.sh does).
#
# Also builds the tool ONCE and caches the wasm across invocations (unlike
# vibe_md.sh, which rebuilds fresh every call): scripts/coverage_unittests.sh
# invokes this once PER *_test.vibe file in its own loop, and recompiling a
# fresh subprocess each time would make that loop far slower for no benefit
# (the tool's own source doesn't change mid-loop).
#
# Usage:
#   bash scripts/coverage_unittests_run.sh <support_csv> <test_file_base> <driver_out_path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

if [ $# -lt 3 ]; then
  echo "usage: bash scripts/coverage_unittests_run.sh <support_csv> <test_file_base> <driver_out_path>" >&2
  exit 2
fi

compiler="${VIBE_COVERAGE_UNITTESTS_COMPILER:-bootstrap/seed/compiler.wasm}"
if [ ! -s "$compiler" ]; then
  echo "coverage_unittests_run.sh: compiler wasm not found: $compiler" >&2
  exit 2
fi

workdir="${VIBE_COVERAGE_UNITTESTS_WORKDIR:-_build/coverage_unittests_tool}"
mkdir -p "$workdir"
tool="$workdir/coverage_unittests.wasm"

if [ ! -s "$tool" ]; then
  rm -f "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" scripts/coverage_unittests.vibex "$tool" main >"$workdir/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "coverage_unittests_run.sh: failed to build scripts/coverage_unittests.vibex (exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$workdir/build.log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
