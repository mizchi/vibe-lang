#!/usr/bin/env bash
# vibe_md.sh — build+run wrapper for scripts/vibe_md.vibex (#1142 / #1137).
#
# vibe_md.vibex is the selfhost-native replacement for the old
# scripts/vibe_md.py: it runs ```vibe run blocks embedded in *.vibe.md docs
# and verifies (or rewrites) the paired ```output block. Since it is itself
# a vibe source file, it has to be compiled before it can run.
#
# This does NOT go through scripts/vibe_run.sh: that launcher always
# `--invoke`s the compiled `main` export directly, but
# scripts/wasm_vibe_host_runner.js's pre-invoke step ALSO runs `_start` for
# any `--invoke` target other than `_start` itself (needed so test/bench
# module globals get initialized before a specific test/bench export runs) --
# and for a normal `entry=main` program, that `_start` already calls `main`
# internally per the WASI `_start` convention, so `main` ends up invoked
# TWICE per run. Reproduces with any .vibex tool run through vibe_run.sh
# (confirmed with scripts/cache_clean.vibex too), so it's a
# vibe_run.sh/runner-level issue, not specific to this file -- tracked
# separately. Invoking `_start` directly here (as this script does) runs the
# program exactly once.
#
# Usage:
#   bash scripts/vibe_md.sh check <file.vibe.md> [more...]
#   bash scripts/vibe_md.sh write <file.vibe.md> [more...]
#   bash scripts/vibe_md.sh fmt <file.vibe.md> [more...]
#   bash scripts/vibe_md.sh fmt-check <file.vibe.md> [more...]
#
# Environment:
#   VIBE_MD_COMPILER   compiler wasm to build the tool with. Default: newest
#                       _build/selfhost/generations/*/stage2.wasm, falling
#                       back to bootstrap/seed/compiler.wasm.
#   VIBE_MD_WORKDIR     where the compiled tool wasm is cached (default
#                       _build/vibe_md_tool).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

case "${1:-}" in
  check | write | fmt | fmt-check) ;;
  *)
    echo "usage: bash scripts/vibe_md.sh <check|write|fmt|fmt-check> <file.vibe.md> [more...]" >&2
    exit 2
    ;;
esac
if [ $# -lt 2 ]; then
  echo "usage: bash scripts/vibe_md.sh <check|write|fmt|fmt-check> <file.vibe.md> [more...]" >&2
  exit 2
fi

compiler="${VIBE_MD_COMPILER:-}"
if [ -z "$compiler" ]; then
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${gen}stage2.wasm" ]; then
      compiler="${gen}stage2.wasm"
      break
    fi
  done
  if [ -z "$compiler" ]; then
    compiler="bootstrap/seed/compiler.wasm"
  fi
fi
if [ ! -s "$compiler" ]; then
  echo "vibe_md.sh: compiler wasm not found: $compiler" >&2
  exit 2
fi

workdir="${VIBE_MD_WORKDIR:-_build/vibe_md_tool}"
mkdir -p "$workdir"
tool="$workdir/vibe_md.wasm"
build_log="$workdir/vibe_md.build.log"

# Remove any wasm left over from a prior successful build first: otherwise a
# compile failure that leaves the old artifact untouched would silently pass
# the `-s "$tool"` check below and run stale, already-superseded behavior
# instead of surfacing that the committed vibe_md.vibex is unbuildable.
rm -f "$tool" "$tool.diag" "$tool.funcmap"

build_status=0
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$compiler" scripts/vibe_md.vibex "$tool" main >"$build_log" 2>&1 || build_status=$?

if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
  echo "vibe_md.sh: failed to build scripts/vibe_md.vibex (compiler: $compiler, exit: $build_status)" >&2
  [ -s "$tool.diag" ] && cat "$tool.diag" >&2
  cat "$build_log" >&2
  rm -f "$tool" "$tool.diag"
  exit 2
fi
rm -f "$tool.diag" "$tool.funcmap"

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$@"
