#!/usr/bin/env bash
# Real-path scheduler oracle (#1239 step 8, #1259).
#
# formal/VibeFormal/Compiler/Scheduler.lean models the parallel frontend as a
# nondeterministic step relation over a coordinator-owned result store, and
# proves its results are schedule-independent GIVEN a worker that satisfies
# `JobCorrect`. What it could not say is whether this compiler is an instance
# of that model: the only thing ever checked against it was
# scripts/parallel_selfhost_checker.mjs's SYNTHETIC worker, which can show the
# model is self-consistent and nothing more.
#
# This checks the real thing. VIBE_SCHEDULER_TRACE makes
# ensure_fingerprint_fs_impl (lib/@vibe/compiler/runtime/typecheck_fs.vibe)
# record what it planned and what it actually did:
#
#   project<TAB><path><TAB><rank>[<TAB><dep>...]   Project.dependencies / .rank
#   step<TAB><path><TAB><fingerprint><TAB><envhash>  the Step.run sequence, in
#                                                    execution order
#
# and each Lean definition becomes a check over those rows:
#
#   Project.dependencyRankLt  every dep of a module has a strictly smaller
#                             rank -- the well-founded order the whole model
#                             rests on
#   Ready                     at each step, (a) the module has no result yet
#                             (`state.results moduleId = none`, i.e. it appears
#                             exactly once) and (b) every dependency already
#                             does (appears strictly earlier)
#   Complete                  every planned module has a terminal result
#   StoreCorrect / JobCorrect every published result equals the canonical one.
#                             The result compared is the ENV HASH, not the
#                             fingerprint: build_fingerprint(source, dep_fps) is
#                             a pure function of the source graph computed
#                             before the module is checked, so comparing
#                             fingerprints across schedules compares cache KEYS
#                             that agree by construction and would hold even if
#                             two schedules produced different TypeEnvs (Codex
#                             review of PR #1264). The env hash is the checked
#                             environment the module actually published.
#                             `expected` is the store a serial run produces;
#                             the model says any `Runs` from `empty` reaches
#                             it, so re-running under a different interleaving
#                             must publish the same fingerprint for every
#                             module. VIBE_DEP_ORDER_SEED is the interleaving
#                             knob -- it permutes the order WITHIN a wave,
#                             which is exactly the choice a scheduler makes.
#
# What this does NOT establish: the Lean proofs still assume `JobCorrect` of
# the worker rather than deriving it, and fairness/termination are unproven.
# Agreement here is evidence the compiler satisfies the model's premises on
# real input, not a machine-checked link between the two artifacts.
#
# Usage: scheduler_trace_oracle.sh [entry.vibe]
# Env:
#   VIBE_SCHEDULER_ORACLE_COMPILER  stage2 wasm override
#   VIBE_SCHEDULER_ORACLE_SEEDS     seeds to compare (default "1 7 23")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

ENTRY="${1:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
SEEDS="${VIBE_SCHEDULER_ORACLE_SEEDS:-1 7 23}"

COMPILER="${VIBE_SCHEDULER_ORACLE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$ROOT_DIR"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
fi
if [ ! -s "$COMPILER" ]; then
  echo "[scheduler-oracle] no stage2 compiler found (set VIBE_SCHEDULER_ORACLE_COMPILER)" >&2
  exit 1
fi

OUT="$ROOT_DIR/_build/scheduler_oracle"
rm -rf "$OUT"; mkdir -p "$OUT"

# One traced compile. Each run gets its own cache dir: a warm persistent cache
# short-circuits modules out of the plan entirely, so a second run against a
# shared cache would produce a legitimately EMPTY trace and every check below
# would pass vacuously.
run_traced() {  # run_traced <tag> [seed]
  local tag="$1"
  local seed="${2:-}"
  local cache="$OUT/cache.$tag"
  rm -rf "$cache"; mkdir -p "$cache"
  local extra=""
  [ -z "$seed" ] || extra="VIBE_DEP_ORDER_SEED=$seed"
  # shellcheck disable=SC2086
  env $extra VIBE_SCHEDULER_TRACE="$OUT/trace.$tag" VIBE_BUILD_CACHE_DIR="$cache" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
    "$ENTRY" "$OUT/$tag.wasm" __no_entry__ >/dev/null 2>&1 || true
  [ -s "$OUT/trace.$tag" ] || { echo "[scheduler-oracle] no trace produced for $tag" >&2; return 1; }
}

echo "[scheduler-oracle] compiler: $COMPILER"
echo "[scheduler-oracle] entry:    $ENTRY"
run_traced serial

# --- the model's premises, over one real trace -------------------------------
awk -F'\t' '
  $1 == "project" {
    path = $2
    if (path in rank) { printf "duplicate project row for %s\n", path; bad++ }
    rank[path] = $3 + 0
    planned[++nplanned] = path
    deps[path] = ""
    for (i = 4; i <= NF; i++) if ($i != "") deps[path] = deps[path] SUBSEP $i
    next
  }
  $1 == "step" {
    path = $2
    nsteps++
    # Ready (a): a job may start exactly once. A module stepped twice would
    # mean `state.results moduleId = none` was false at its second Step.run.
    if (path in done) { printf "module stepped twice: %s\n", path; bad++ }
    if (!(path in rank)) { printf "stepped a module that was never planned: %s\n", path; bad++ }
    # Ready (b): every direct dependency has already completed.
    n = split(deps[path], d, SUBSEP)
    for (i = 1; i <= n; i++) {
      if (d[i] == "") continue
      if (!(d[i] in done)) { printf "Ready violated: %s stepped before its dependency %s completed\n", path, d[i]; bad++ }
      # Project.dependencyRankLt: strictly smaller rank, which is what makes
      # the dependency order well-founded in the first place.
      if (!(d[i] in rank)) { printf "dependency outside the planned project: %s -> %s\n", path, d[i]; bad++ }
      else if (rank[d[i]] >= rank[path]) { printf "dependencyRankLt violated: %s (rank %d) -> %s (rank %d)\n", path, rank[path], d[i], rank[d[i]]; bad++ }
    }
    done[path] = 1
    next
  }
  { printf "unrecognized trace row: %s\n", $0; bad++ }
  END {
    # Complete: every planned module has a terminal result.
    for (i = 1; i <= nplanned; i++)
      if (!(planned[i] in done)) { printf "Complete violated: %s was planned but never stepped\n", planned[i]; bad++ }
    if (bad > 0) exit 1
    printf "ok %d planned, %d steps\n", nplanned, nsteps
  }' "$OUT/trace.serial" > "$OUT/check.serial" || {
      echo "[scheduler-oracle] FAIL: the real trace violates the Scheduler.lean model:" >&2
      head -10 "$OUT/check.serial" >&2
      exit 1
    }
read -r _ NPLANNED _ NSTEPS _ < "$OUT/check.serial"
# A trace with no steps satisfies Ready and Complete trivially.
if [ "${NSTEPS:-0}" -lt 2 ]; then
  echo "[scheduler-oracle] FAIL: only ${NSTEPS:-0} step(s) in the trace -- every check above is vacuous" >&2
  exit 1
fi
echo "[scheduler-oracle] Project/Ready/Complete hold: $NPLANNED planned, $NSTEPS steps"

# --- StoreCorrect: the published store is schedule-independent ---------------
#
# Compared as a SET of (module, fingerprint) pairs, deliberately not as a
# sequence: the step ORDER is supposed to differ between seeds -- that is the
# nondeterminism being probed -- while the store the run reaches must not.
store_of() { sort < "$1" | awk -F'\t' '$1 == "step" { print $2 "\t" $3 "\t" $4 }'; }
store_of "$OUT/trace.serial" > "$OUT/store.serial"

# The env hash is "-" for steps that publish no environment (a reusable cached
# fingerprint, or a persistent leaf-fingerprint hit). Each run uses a cold
# cache dir so those should be rare; if most steps carried "-" the comparison
# would be back to comparing content-addressed keys, which agree by
# construction. Require a clear majority to carry a real hash.
REAL_ENVS="$(awk -F'\t' '$1 == "step" && $4 != "-" && $4 != "" { n++ } END { print n + 0 }' "$OUT/trace.serial")"
if [ "$REAL_ENVS" -lt $(( NSTEPS / 2 )) ]; then
  echo "[scheduler-oracle] FAIL: only $REAL_ENVS of $NSTEPS steps published a checked environment -- StoreCorrect would be comparing cache keys, which agree by construction" >&2
  exit 1
fi
echo "[scheduler-oracle] $REAL_ENVS of $NSTEPS steps carry a real published environment"

reordered=0
for seed in $SEEDS; do
  run_traced "seed$seed" "$seed"
  store_of "$OUT/trace.seed$seed" > "$OUT/store.seed$seed"
  if ! cmp -s "$OUT/store.serial" "$OUT/store.seed$seed"; then
    echo "[scheduler-oracle] FAIL: seed $seed reached a different store -- StoreCorrect does not hold on the real path" >&2
    diff "$OUT/store.serial" "$OUT/store.seed$seed" | head -10 >&2
    exit 1
  fi
  # Vacuity guard for the comparison above: the seed must actually have
  # produced a different INTERLEAVING. If every seed replayed the same step
  # order, "same store" would say nothing about schedule independence.
  if ! cmp -s <(awk -F'\t' '$1=="step"{print $2}' "$OUT/trace.serial") \
              <(awk -F'\t' '$1=="step"{print $2}' "$OUT/trace.seed$seed"); then
    reordered=$((reordered + 1))
  fi
done

if [ "$reordered" -eq 0 ]; then
  echo "[scheduler-oracle] FAIL: no seed changed the step order, so the store comparison is vacuous" >&2
  exit 1
fi
echo "[scheduler-oracle] StoreCorrect holds across $(echo "$SEEDS" | wc -w | tr -d ' ') seeds ($reordered of them really reordered the schedule)"
echo "[scheduler-oracle] ok"
