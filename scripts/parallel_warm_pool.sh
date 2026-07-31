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
# compiler for it (VIBE_MODULE_PLAN, which also does the import resolution --
# see phase 1) rather than re-deriving a topological sort here, so the
# canonical order stays the one that is tested
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

# --- 1. discover the import DAG AND its wave schedule, in one run -----------
#
# VIBE_MODULE_PLAN walks the whole graph inside one compiler process and
# returns every reachable module -- dependency list, ingested source, and rank
# -- already in plan_module_order's canonical order. It replaces both the
# per-file VIBE_LIST_DEPS BFS this script used to run and the separate
# ordering-only call after it (a `VIBE_PLAN_MODULE_ORDER` mode, deleted in
# #1259 once this was its only would-be caller). On this repo's codegen_lexer_test.vibe
# graph (166 modules) the BFS measured 17.4s serially and 5.1s at 4-way
# concurrency, against 0.8s for the single call.
#
# The ordering rule is unchanged: the plan mode calls plan_module_order
# itself, so the canonical order is still the one that is tested
# (lib/@vibe/graph/module_order_test.vibe) and modelled
# (formal/VibeFormal/Compiler/Scheduler.lean).
#
# The INGESTED source still matters for the same reason (#1168) -- a
# directory-shared index.vpkg can prepend imports a raw .vibe file never had,
# and a contract file is rewritten into its facade entirely, so the worker
# must check the same text the serial walk would. The plan hands it back per
# module, derived from the same ingest step as that module's dep list.
#
# ONE BEHAVIOUR CHANGE. A module that does not resolve AT ALL used to be
# dropped from the graph, leaving the rest of the project still warmable; the
# plan mode fails the whole run instead. That stays inside the advisory
# contract -- the caller swallows a nonzero exit and compiles serially, which
# reports the real error anyway -- and it is what the node driver
# (parallel_frontend_warm.mjs) has always done. A module that resolves but
# fails to CHECK is unaffected: that is decided in the job phase below, which
# still drops it and warms everything else.
sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }

plan="$WORK/plan.txt"
rm -f "$plan" "$plan".*
run_cli "$ENTRY" "$plan" VIBE_MODULE_PLAN=1 VIBE_IMPORT_ABI=raw
if [ -f "$plan.diag" ]; then
  echo "warm-pool: module discovery failed: $(head -1 "$plan.diag")" >&2
  exit 1
fi
[ -s "$plan" ] || { echo "warm-pool: nothing to warm (entry did not resolve)" >&2; exit 1; }

# Materialize the two per-module files the dispatch phase reads, under the
# same sanitized key it names job dirs with. The plan already indexes every
# module, so these could be keyed by index instead -- which would also close
# the latent collision the sanitizer has always had (`a/b.vibe` and
# `a_b.vibe` sanitize alike; the node driver needed a unique id for exactly
# that, #1170). No two modules in this repo's own graph collide today, so
# that is left as a separate change rather than folded into this one.
DISC_DIR="$WORK/disc"; export DISC_DIR
while IFS="$(printf '\t')" read -r idx modpath; do
  key="$(sanitize "$modpath")"
  # Declaration order, duplicates kept -- build_fingerprint folds dep rows as
  # a sequence, so the job phase must see them exactly as declared.
  awk -F'\t' -v i="$idx" '$1=="dep" && $2==i {print $3}' "$plan" > "$DISC_DIR/$key.out"
  cp "$plan.$idx.src" "$DISC_DIR/$key.out.src"
done < <(awk -F'\t' '$1=="module" {print $2"\t"$4}' "$plan")

MAX_RANK="$(awk -F'\t' '$1=="module" && $3+0>m {m=$3+0} END {print m+0}' "$plan")"
MODULE_COUNT="$(awk -F'\t' '$1=="module"' "$plan" | wc -l | tr -d ' ')"

# --- 3. dispatch rank by rank -----------------------------------------------
#
# Within a rank the modules are independent by construction, so the whole rank
# goes out at once; ranks are joined in ascending order because rank k's job
# dirs need rank <k's env.out and fingerprint.out as inputs.
# #1259: optional concurrency trace. When VIBE_WARM_POOL_TRACE names a file,
# each job appends "+" as it starts and "-" as it finishes; the running sum is
# the number of workers in flight, and its maximum is the real peak
# parallelism. Two-byte O_APPEND writes are atomic on Linux, so concurrent
# workers cannot interleave within a marker.
#
# This exists because "bounded parallelism and backpressure" was an acceptance
# criterion with no evidence behind it: `xargs -P N` is the bound, but nothing
# checked that it IS the bound in practice. test_parallel_warm_pool_gate.sh
# now measures it. Unset in every production path -- runtime/vibe never sets
# it -- so the pool pays one `[ -z ... ]` per job for it.
build_and_run_job() {  # build_and_run_job <path>
  local rc=0
  [ -z "${VIBE_WARM_POOL_TRACE:-}" ] || printf '+\n' >> "$VIBE_WARM_POOL_TRACE"
  build_and_run_job_body "$@" || rc=$?
  [ -z "${VIBE_WARM_POOL_TRACE:-}" ] || printf -- '-\n' >> "$VIBE_WARM_POOL_TRACE"
  return "$rc"
}

build_and_run_job_body() {  # build_and_run_job_body <path>
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
export -f build_and_run_job build_and_run_job_body
JOBS_DIR="$WORK/jobs"; export JOBS_DIR

r=0
while [ "$r" -le "$MAX_RANK" ]; do
  awk -F'\t' -v want="$r" '$1=="module" && $3+0==want {print $4}' "$plan" \
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
done < <(awk -F'\t' '$1=="module" {print $4}' "$plan")

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
