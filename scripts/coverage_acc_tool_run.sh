#!/usr/bin/env bash
# Cached build+run wrapper for lib/@vibe/cli/coverage_acc_tool.vibe
# (native-vibe port of the acc_merge.py heredoc + sum/len python one-liners
# several coverage_*.sh scripts repeat -- see that file's own header
# comment). The tool itself lives under lib/@vibe/cli/, not scripts/: its
# merge/stat algorithm is generic beyond this repo, so it's consolidated
# there alongside fmt_entry.vibe rather than kept scripts/-private.
#
# Not run through scripts/vibe_run.sh: its `--invoke main` path
# double-executes `main` for any entry other than `_start` (#1182, see
# scripts/vibe_md.sh's header comment).
#
# Builds the tool ONCE and caches the wasm across invocations (rebuilding on
# a source mtime change, mirroring scripts/vibe_fmt.sh's cache check), like
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

# The tool is ordinary vibe source in this checkout, so it must be built by a
# compiler that understands THIS checkout's contracts -- not by the pinned seed.
# The seed is the previous bootstrap tag; once `lib/@vibe/builtin/index.vpkg`
# moved past it, a seed build died with
#
#   lib/@vibe/builtin/index.vpkg: contract violation: contract declaration
#   'String::join' has no implementation; ... opaque type 'Int' has no
#   implementation; ...
#
# which reads like a broken prelude but is really "the builder is too old".
# Prefer a checkout-matched compiler and keep the seed only as a last resort,
# the same precedence `runtime/vibe`'s pick_cli uses.
compiler="${VIBE_COVERAGE_ACC_TOOL_COMPILER:-}"
if [ -z "$compiler" ]; then
  for cand in dist/cli/vibe-cli.wasm $(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null) bootstrap/seed/compiler.wasm; do
    [ -s "$cand" ] && { compiler="$cand"; break; }
  done
fi
if [ ! -s "$compiler" ]; then
  echo "coverage_acc_tool_run.sh: compiler wasm not found: ${compiler:-<none>}" >&2
  exit 2
fi

src="lib/@vibe/cli/coverage_acc_tool.vibe"
workdir="${VIBE_COVERAGE_ACC_TOOL_WORKDIR:-_build/coverage_acc_tool}"
mkdir -p "$workdir"
tool="$workdir/coverage_acc_tool.wasm"

if [ ! -s "$tool" ] || [ "$src" -nt "$tool" ]; then
  rm -f "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" "$src" "$tool" main >"$workdir/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "coverage_acc_tool_run.sh: failed to build $src (exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$workdir/build.log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
