#!/usr/bin/env bash
# Cached build+run wrapper for lib/@vibe/cli/coverage_local_merge.vibe
# (native-vibe port of coverage_drivers.sh's own merge.py + coverage_unittests.sh's
# embedded merge heredoc -- see that file's own header comment). The tool
# itself lives under lib/@vibe/cli/, not scripts/: its merge algorithm is
# generic beyond this repo, so it's consolidated there alongside
# fmt_entry.vibe rather than kept scripts/-private.
#
# Not run through scripts/vibe_run.sh: its `--invoke main` path
# double-executes `main` for any entry other than `_start` (#1182, see
# scripts/vibe_md.sh's header comment).
#
# Builds the tool ONCE and caches the wasm across invocations (rebuilding on
# a source mtime change, mirroring scripts/vibe_fmt.sh's cache check), like
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

# This tool imports the checkout-local prelude/json surface, so compile it with
# the current instrumented compiler produced by coverage_corpus.sh. The pinned
# seed may compile emitted ordinary merged source, but can be older than this
# checkout's package contracts.
compiler="${VIBE_COVERAGE_LOCAL_MERGE_COMPILER:-_build/coverage/selfhost-corpus/compiler_cov.wasm}"
if [ ! -s "$compiler" ]; then
  echo "coverage_local_merge_run.sh: current compiler wasm not found: $compiler" >&2
  echo "coverage_local_merge_run.sh: run scripts/coverage_corpus.sh first" >&2
  exit 2
fi

src="lib/@vibe/cli/coverage_local_merge.vibe"
workdir="${VIBE_COVERAGE_LOCAL_MERGE_WORKDIR:-_build/coverage_local_merge_tool}"
mkdir -p "$workdir"
tool="$workdir/coverage_local_merge.wasm"

if [ ! -s "$tool" ] || [ "$src" -nt "$tool" ] || [ "$compiler" -nt "$tool" ]; then
  rm -f "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" "$src" "$tool" main >"$workdir/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "coverage_local_merge_run.sh: failed to build $src (exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$workdir/build.log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
