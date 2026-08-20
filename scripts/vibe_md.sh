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

# Refuse a document this is not the harness for. There are TWO doctest
# harnesses and they are not interchangeable:
#
#   scripts/vibe_md.sh            *.vibe.md (the book) -- runs each
#                                 ```vibe run block and checks the paired
#                                 ```output block
#   scripts/doctest_extract_run.sh  prose docs (README, cheatsheet, spec) --
#                                 compile-only, symlinks `lib` next to the
#                                 block so `import ./lib/@vibe/core` resolves,
#                                 and tolerates a declaration-only block
#
# Handed `docs/cheatsheet.md`, this one used to answer "30 pass, 3 fail" for a
# document `pkf run doctest` calls clean -- two harnesses, one document, two
# answers, and the failures were entirely the two differences above. A
# contributor following CLAUDE.md's `scripts/vibe_md.sh check` had no way to
# tell which was right. Naming the other harness is the answer; making this
# one accept prose docs would just move the disagreement.
for arg in "${@:2}"; do
  case "$arg" in
    *.vibe.md) ;;
    *)
      echo "vibe_md.sh: $arg is not a *.vibe.md document." >&2
      echo "  This harness runs \`\`\`vibe run blocks and checks their paired \`\`\`output block," >&2
      echo "  which only *.vibe.md documents carry (book/en, book/ja)." >&2
      echo "  For a prose document, use: bash scripts/doctest_extract_run.sh $arg" >&2
      exit 2
      ;;
  esac
done

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
build_log="$workdir/vibe_md.build.log"

# #819: the tool's own build is CONTENT-ADDRESSED, not rebuilt per run.
#
# vibe_md.vibex is ~1300 lines and takes ~1.27s to compile -- measured at 22%
# of a 5.8s `check docs/tutorial/*.vibe.md`, paid on every invocation because
# this script used to unconditionally `rm -f` the artifact and rebuild.
#
# The key is the CONTENT of both inputs (the tool source and the compiler
# wasm), hashed for ~9ms total. That is what preserves the property the old
# unconditional rebuild existed for: a cached artifact can only ever be
# returned for the exact (source, compiler) pair that produced it, so there is
# no way to silently run behavior that the committed vibe_md.vibex no longer
# describes. An mtime/size proxy would have been cheaper and would have
# reopened exactly that hole.
#
# VIBE_MD_NO_TOOL_CACHE=1 forces a rebuild (into the same keyed path).
tool_key="$(sha256sum scripts/vibe_md.vibex "$compiler" | sha256sum | cut -c1-16)"
tool="$workdir/vibe_md.$tool_key.wasm"

if [ "${VIBE_MD_NO_TOOL_CACHE:-0}" = "1" ] || [ ! -s "$tool" ]; then
  # Drop artifacts keyed on any other (source, compiler) pair -- one entry is
  # all that is ever reused, and a growing directory of stale wasm is the only
  # cost this cache could otherwise impose.
  find "$workdir" -maxdepth 1 -name 'vibe_md.*.wasm' ! -name "vibe_md.$tool_key.wasm" -delete 2>/dev/null || true
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
fi

# #819: run one tool process PER DOC, in parallel.
#
# Docs are independent -- each block's scratch source is named from its own
# doc's basename, and the per-doc merged module (#819) is likewise per-doc --
# so nothing is shared between workers except the content-addressed execute
# cache, whose writes were made atomic for exactly this (see
# write_doctest_cache in vibe_md.vibex).
#
# Measured breakdown of a 7-doc / 32-block `check` before this: ~3.9s of
# compiles, ~1.7s of per-block runner subprocesses, and neither shrinks by
# batching (the whole-run merged module was measured SLOWER -- see #819). They
# do both shrink by running docs concurrently, which is the one lever that
# does not depend on making any single step cheaper.
#
# VIBE_MD_JOBS=1 forces the original single-process path (also taken for a
# single doc, where there is nothing to overlap).
mode="$1"
shift
jobs="${VIBE_MD_JOBS:-}"
if [ -z "$jobs" ]; then
  jobs="$(nproc 2>/dev/null || echo 1)"
fi
if [ "$#" -le 1 ] || [ "$jobs" -le 1 ]; then
  VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool" "$mode" "$@"
fi

outdir="$(mktemp -d)"
trap 'rm -rf "$outdir"' EXIT

idx=0
running=0
for f in "$@"; do
  idx=$((idx + 1))
  (
    # `set -e` is on: without the `|| wrc=$?` the subshell would DIE on a
    # worker that reports failures (which is the normal path for a doc with a
    # stale ```output), never write its .rc, and the aggregator would read the
    # missing file as a hard error 2 instead of the real 1.
    wrc=0
    VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$tool" "$mode" "$f" >"$outdir/$idx.out" 2>"$outdir/$idx.err" || wrc=$?
    echo "$wrc" >"$outdir/$idx.rc"
  ) &
  running=$((running + 1))
  if [ "$running" -ge "$jobs" ]; then
    # `wait -n` (bash 4.3+) frees one slot; without it, drain to empty. Both
    # are correct -- the fallback just refills the pool in batches.
    if wait -n 2>/dev/null; then
      running=$((running - 1))
    else
      wait
      running=0
    fi
  fi
done
wait

# Reassemble in the ORDER THE DOCS WERE GIVEN, so output does not depend on
# which worker finished first.
#
# Each worker's stdout is: a `vibe_md: mode=...` header line, its own block
# lines, a blank line, and a `vibe_md: N blocks -- ...` summary. Only the
# first and last two lines are dropped, BY POSITION rather than by matching
# `^vibe_md: ` -- a FAIL report embeds the block's actual stdout verbatim, and
# a pattern filter would silently swallow a line of it that happened to start
# that way.
i=0
while [ "$i" -lt "$idx" ]; do
  i=$((i + 1))
  if [ -s "$outdir/$i.out" ]; then
    head -1 "$outdir/$i.out"
    break
  fi
done

total=0
pass=0
fail=0
skip=0
worst=0
i=0
while [ "$i" -lt "$idx" ]; do
  i=$((i + 1))
  if [ -s "$outdir/$i.err" ]; then
    cat "$outdir/$i.err" >&2
  fi
  rc="$(cat "$outdir/$i.rc" 2>/dev/null || true)"
  if [ -z "$rc" ]; then
    rc=2
  fi
  if [ "$rc" -gt "$worst" ]; then
    worst="$rc"
  fi
  if [ ! -s "$outdir/$i.out" ]; then
    continue
  fi
  lines="$(wc -l <"$outdir/$i.out")"
  if [ "$lines" -gt 3 ]; then
    sed -n "2,$((lines - 2))p" "$outdir/$i.out"
  fi
  summary="$(tail -1 "$outdir/$i.out")"
  case "$summary" in
    "vibe_md: "*" blocks -- "*)
      # `vibe_md: N blocks -- P pass, F fail, S skip` -> the four numbers.
      nums="$(printf '%s' "$summary" | sed 's/[^0-9]/ /g')"
      # shellcheck disable=SC2086
      set -- $nums
      total=$((total + $1))
      pass=$((pass + $2))
      fail=$((fail + $3))
      skip=$((skip + $4))
      ;;
    *)
      # A worker that died before printing its summary already contributed its
      # exit code above; do not invent counts for it.
      ;;
  esac
done

printf '\nvibe_md: %s blocks -- %s pass, %s fail, %s skip\n' "$total" "$pass" "$fail" "$skip"
if [ "$worst" -ne 0 ]; then
  exit "$worst"
fi
exit 0
