#!/usr/bin/env bash
# Process-pool frontend pre-warm (#1239 step 4(D)).
#
# WHAT THIS REPLACES
#
# `runtime/vibe --jobs=N` already pre-warms the persistent type-env cache
# before its serial compile, but only through scripts/parallel_frontend_warm.mjs
# -- which needs node AND the dev-repo `scripts/` tree. A shipped toolchain has
# neither, so `--jobs` there prints a note and silently compiles serially. This
# script is the same pre-warm with no node and no dev-only dependency: bash,
# plus the compiler image the launcher already picked.
#
# WHY A PROCESS POOL
#
# #1239 said real speedup needed a Wasmtime multi-instance host, because such a
# host "shares one Engine and compiled Module". #1248 measured that premise and
# it does not hold: `viberun --precompile` already pays for the sharing (AOT
# .cwasm ~8ms/job vs ~485ms JIT), so an ordinary process pool over the existing
# image scales -- 3.37x on 4 cores (scripts/bench_module_job_pool.sh). No new
# host, and separate processes satisfy the shared-nothing worker contract more
# strictly than threads would.
#
# THE SAME ADVISORY CONTRACT AS THE NODE DRIVER
#
# This is a cache pre-warm and NEVER a second source of truth. runtime/vibe
# always runs its serial compile afterward regardless of what happens here, and
# a module that fails to check here is simply absent from the publish manifest
# -- the serial walk rechecks it from scratch and reports the identical
# diagnostic. Nothing here can change what a build produces, only how much
# redundant work the serial walk has to redo. Every failure path therefore
# reports to stderr and exits nonzero for the caller to swallow; none of them
# is allowed to write a partial manifest.
#
# WHY THE ORDER COMES FROM THE COMPILER
#
# A worker receives a job DIRECTORY and nothing else, and its dependencies'
# environments arrive as VALUES (dep<i>.env, scripts/module_job_dir_test.sh).
# So a module can only be dispatched once every dependency of it has already
# produced an env -- the coordinator must know the waves BEFORE it dispatches
# anything. That is exactly plan_module_order's rank: every module of rank k
# depends only on ranks < k, so a whole rank goes out at once. We ask the
# compiler for it (VIBE_PLAN_MODULE_ORDER) rather than re-deriving a
# topological sort here, so the canonical order stays the one that is tested
# (lib/@vibe/graph/module_order_test.vibe) and modelled
# (formal/VibeFormal/Compiler/Scheduler.lean) instead of a lookalike in shell
# that could drift from it silently.
#
# Usage:
#   bash scripts/parallel_warm_pool.sh <compiler-wasm> <entry-file> <jobs> [runner]
#
# `entry-file` is passed through VERBATIM, never resolved to an absolute path:
# build_fingerprint folds each dependency's PATH into the importer's own
# fingerprint, so an absolute path here and a relative one at the serial
# compile would derive DIFFERENT fingerprints for the same importer -- every
# warmed non-leaf entry would sit under a key the serial walk never looks up,
# silently making the warm a no-op (Codex review, PR #1144).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

COMPILER="${1:-}"
ENTRY="${2:-}"
JOBS="${3:-1}"
RUNNER="${4:-}"

if [ -z "$COMPILER" ] || [ -z "$ENTRY" ]; then
  echo "usage: parallel_warm_pool.sh <compiler-wasm> <entry-file> <jobs> [runner]" >&2
  exit 2
fi
[ -s "$COMPILER" ] || { echo "warm-pool: compiler image not found: $COMPILER" >&2; exit 2; }
[ -f "$ENTRY" ] || { echo "warm-pool: entry file not found: $ENTRY" >&2; exit 2; }
case "$JOBS" in
  ''|*[!0-9]*) echo "warm-pool: jobs must be a positive integer, got '$JOBS'" >&2; exit 2 ;;
esac
[ "$JOBS" -ge 1 ] || { echo "warm-pool: jobs must be >= 1, got '$JOBS'" >&2; exit 2; }

# viberun by default -- it is the production driver (runtime/vibe calls it) and
# the only one that can load an AOT .cwasm, which is the whole point. An
# explicit runner argument overrides it (the gate passes the Node runner to
# check the two agree).
if [ -z "$RUNNER" ]; then
  RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
  [ -x "$RUNNER" ] || RUNNER="$PROJECT_ROOT/bin/viberun"
fi
[ -x "$RUNNER" ] || { echo "warm-pool: runner not executable: $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d -t vibe-warm-pool-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/disc" "$WORK/jobs"

# One invocation of the compiler image. Every mode below is a one-shot run
# whose result lands in files, so this is the only place the runner's calling
# convention appears.
run_cli() {  # run_cli <input> <output> [env assignments...]
  local input="$1" output="$2"; shift 2
  env "$@" timeout 600 "$RUNNER" "$COMPILER" "$input" "$output" __no_entry__ \
    >/dev/null 2>&1
}
export -f run_cli
export RUNNER COMPILER

# --- 1. discover the import DAG ---------------------------------------------
#
# BFS by frontier, each frontier discovered with up to $JOBS concurrent
# VIBE_LIST_DEPS runs. That mode also hands back the INGESTED source (.src) --
# imports a raw .vibe file never had can be prepended by a directory-shared
# index.vpkg, and a contract file is rewritten into its facade entirely, so the
# worker must check the same text the serial walk would (#1168).
sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }

discover_one() {  # discover_one <path> ; writes <disc>/<key>.deps and .src
  local path="$1" key
  key="$(printf '%s' "$path" | tr -c 'a-zA-Z0-9' '_')"
  local out="$DISC_DIR/$key.out"
  rm -f "$out" "$out.diag" "$out.src"
  env VIBE_LIST_DEPS=1 VIBE_IMPORT_ABI=raw timeout 600 \
    "$RUNNER" "$COMPILER" "$path" "$out" __no_entry__ >/dev/null 2>&1 || true
  # A .diag means this module does not even resolve. That is not an error for
  # the warm: the serial walk will report it identically. Drop the module.
  if [ -f "$out.diag" ] || [ ! -f "$out" ] || [ ! -f "$out.src" ]; then
    rm -f "$out" "$out.src"
    return 0
  fi
  printf '%s\n' "$path" > "$out.path"
}
export -f discover_one
DISC_DIR="$WORK/disc"; export DISC_DIR

frontier="$ENTRY"
seen_file="$WORK/seen.txt"
: > "$seen_file"
while [ -n "$frontier" ]; do
  printf '%s\n' "$frontier" | xargs -r -P "$JOBS" -I{} bash -c 'discover_one "$@"' _ {}
  printf '%s\n' "$frontier" >> "$seen_file"
  next=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    key="$(sanitize "$p")"
    [ -f "$WORK/disc/$key.out" ] || continue
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      grep -Fxq "$d" "$seen_file" && continue
      case "$next" in
        "$d"|"$d"$'\n'*|*$'\n'"$d"|*$'\n'"$d"$'\n'*) continue ;;
      esac
      next="${next:+$next$'\n'}$d"
    done < "$WORK/disc/$key.out"
  done <<< "$frontier"
  frontier="$next"
done

# Modules that resolved, in discovery order (the entry first -- the plan mode
# takes the first line's path as the root).
edges="$WORK/edges.tsv"
: > "$edges"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  key="$(sanitize "$p")"
  [ -f "$WORK/disc/$key.out" ] || continue
  { printf '%s' "$p"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      # Only edges to modules that themselves resolved; plan_module_order
      # would otherwise rank a node we have no source for.
      dkey="$(sanitize "$d")"
      [ -f "$WORK/disc/$dkey.out" ] && printf '\t%s' "$d"
    done < "$WORK/disc/$key.out"
    printf '\n'
  } >> "$edges"
done < "$seen_file"

if [ ! -s "$edges" ]; then
  echo "warm-pool: nothing to warm (entry did not resolve)" >&2
  exit 1
fi

# --- 2. ask the compiler for the wave schedule ------------------------------
plan="$WORK/plan.tsv"
rm -f "$plan" "$plan.diag"
run_cli "$edges" "$plan" VIBE_PLAN_MODULE_ORDER=1
if [ -f "$plan.diag" ]; then
  echo "warm-pool: module ordering failed: $(head -1 "$plan.diag")" >&2
  exit 1
fi
[ -f "$plan" ] || { echo "warm-pool: module ordering produced no plan" >&2; exit 1; }

MAX_RANK="$(awk -F'\t' 'NF>=2 && $1+0>m {m=$1+0} END {print m+0}' "$plan")"
MODULE_COUNT="$(awk -F'\t' 'NF>=2' "$plan" | wc -l | tr -d ' ')"

# --- 3. dispatch rank by rank -----------------------------------------------
#
# Within a rank the modules are independent by construction, so the whole rank
# goes out at once; ranks are joined in ascending order because rank k's job
# dirs need rank <k's env.out and fingerprint.out as inputs.
build_and_run_job() {  # build_and_run_job <path>
  local path="$1" key jobdir i=0 dep dkey
  key="$(printf '%s' "$path" | tr -c 'a-zA-Z0-9' '_')"
  jobdir="$JOBS_DIR/$key"
  rm -rf "$jobdir"; mkdir -p "$jobdir"
  cp "$DISC_DIR/$key.out.src" "$jobdir/source.vibe"
  {
    printf 'version\t1\n'
    printf 'path\t%s\n' "$path"
  } > "$jobdir/job.txt"
  # dep rows carry the dependency's OWN fingerprint and must stay in
  # DECLARATION order: build_fingerprint folds them as a sequence, not a set,
  # so reordering here would derive a different fingerprint than the serial
  # walk and the warmed entry would never be found.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dkey="$(printf '%s' "$dep" | tr -c 'a-zA-Z0-9' '_')"
    [ -f "$DISC_DIR/$dkey.out" ] || continue
    # A dependency that did not produce an artifact (it failed to check) makes
    # this module unwarmable. Skip it rather than sending a job with a hole:
    # the serial walk rechecks it and reports the real diagnostic.
    if [ ! -s "$JOBS_DIR/$dkey/env.out" ] || [ ! -s "$JOBS_DIR/$dkey/fingerprint.out" ]; then
      rm -rf "$jobdir"
      return 0
    fi
    printf 'dep\t%s\t%s\n' "$dep" "$(cat "$JOBS_DIR/$dkey/fingerprint.out")" >> "$jobdir/job.txt"
    cp "$JOBS_DIR/$dkey/env.out" "$jobdir/dep$i.env"
    i=$((i + 1))
  done < "$DISC_DIR/$key.out"
  env VIBE_PREOPEN_DIR="$jobdir" VIBE_MODULE_JOB_DIR=1 VIBE_IMPORT_ABI=raw \
    timeout 600 "$RUNNER" "$COMPILER" "$jobdir" "$jobdir/worker.out" __no_entry__ \
    >/dev/null 2>&1 || true
  [ "$(cat "$jobdir/outcome.txt" 2>/dev/null || true)" = "ok" ] || rm -f "$jobdir/env.out"
}
export -f build_and_run_job
JOBS_DIR="$WORK/jobs"; export JOBS_DIR

r=0
while [ "$r" -le "$MAX_RANK" ]; do
  awk -F'\t' -v want="$r" 'NF>=2 && $1+0==want {print $2}' "$plan" \
    | xargs -r -P "$JOBS" -I{} bash -c 'build_and_run_job "$@"' _ {}
  r=$((r + 1))
done

# --- 4. publish every successful artifact to the persistent cache -----------
pub="$WORK/publish"
mkdir -p "$pub"
: > "$pub/manifest.txt"
warmed=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  key="$(sanitize "$path")"
  [ -s "$JOBS_DIR/$key/env.out" ] || continue
  [ -s "$JOBS_DIR/$key/fingerprint.out" ] || continue
  cp "$JOBS_DIR/$key/env.out" "$pub/$key.env"
  printf '%s\t%s.env\n' "$(cat "$JOBS_DIR/$key/fingerprint.out")" "$key" >> "$pub/manifest.txt"
  warmed=$((warmed + 1))
done < <(awk -F'\t' 'NF>=2 {print $2}' "$plan")

if [ "$warmed" -eq 0 ]; then
  echo "warm-pool: no module checked cleanly; nothing published" >&2
  exit 1
fi

rm -f "$pub/worker.out" "$pub/worker.out.diag"
run_cli "$pub" "$pub/worker.out" VIBE_PUBLISH_ENV_CACHE=1
if [ -f "$pub/worker.out.diag" ]; then
  echo "warm-pool: env cache publish failed: $(head -1 "$pub/worker.out.diag")" >&2
  exit 1
fi

echo "warm-pool: warmed $warmed/$MODULE_COUNT modules across $((MAX_RANK + 1)) ranks at -P $JOBS"
