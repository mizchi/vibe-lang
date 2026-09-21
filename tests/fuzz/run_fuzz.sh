#!/usr/bin/env bash
# Differential fuzzing harness for the selfhost vibe compiler.
#
#   bash tests/fuzz/run_fuzz.sh [--seeds A..B] [--cli path/to/stage2.wasm] [--jobs N]
#   bash tests/fuzz/run_fuzz.sh --mutate [--seeds A..B]   # parser-robustness mode
#
# Seeds run with up to --jobs concurrent OS processes (default: nproc, capped
# at 8) via a bash job-slot pool -- real parallelism (each seed is its own
# subshell/process tree), not vibe's own cooperative TaskGroup, which never
# runs two task bodies at once (see docs/internal/design/compiler-parallelism.md's
# "Shared-everything migration note"). Safe because every seed already had
# its own work dir ($WORK/s$seed) and finding dir ($FIND/seed_<n>_<class>);
# the only genuinely shared file, failing_seeds.txt, is appended to via
# `echo ... >>`, whose writes are atomic for lines under PIPE_BUF so
# concurrent seeds interleave lines but never corrupt them. --jobs 1
# reproduces the original strictly-sequential ordering exactly.
#
# Generative mode (default), per seed:
#   1. tests/fuzz/gen_program.py emits a well-typed, trap-free-by-construction
#      program (single.vibe) plus an FS-linked split (defs.vibe+main.vibe).
#   2. Compile single.vibe on three backends: bump (VIBE_RC=0), RC
#      (VIBE_RC=1), wasm-gc (VIBE_BACKEND=gc); compile the split via
#      VIBE_FS_COMPILE=1 (bump).
#   3. Run all four; every result must be identical.
# Findings (any of): COMPILE_DIAG (diagnostic on a valid program),
# COMPILE_CRASH (compiler trap, no diag), COMPILE_HANG, RUN_TRAP,
# RUN_HANG, MISMATCH (backend/lane divergence). Failing inputs + logs are
# copied to _build/fuzz/findings/<seed>_<class>/ and seeds recorded in
# _build/fuzz/failing_seeds.txt.
#
# Mutation mode (--mutate): byte-mutates a generated valid program and
# feeds it to the compiler. Any outcome is fine EXCEPT a compiler trap or
# hang (a parse/type error diag is the expected rejection path).
set -uo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

SEEDS="1..50"
CLI=""
MODE="gen"
GENMODE=""   # "" = liveness-aware generation (default); "--classic" = opt out
JOBS="${FUZZ_JOBS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --seeds) SEEDS="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    --mutate) MODE="mutate"; shift ;;
    --classic) GENMODE="--classic"; shift ;;
    --liveness-bias) GENMODE="--liveness-bias=$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# The seed range is validated HERE, beside `--jobs`, and not left to the first
# arithmetic use far below. `--seeds typo` used to reach the resets before
# `total=$((B - A + 1))` ever evaluated it: the previous campaign's findings
# were deleted and its ledger truncated, and only THEN did `set -u` abort on
# the unbound expansion. A command-line typo irreversibly destroyed the last
# campaign while running none (#2955 review). Nothing destructive happens
# above this point.
A="${SEEDS%%..*}"; B="${SEEDS##*..}"
case "$SEEDS" in
  *..*) ;;
  *) echo "[fuzz] --seeds must be A..B (got: $SEEDS)" >&2; exit 2 ;;
esac
case "${A:-}" in
  ''|*[!0-9]*) echo "[fuzz] --seeds start must be a non-negative integer (got: ${A:-empty} from $SEEDS)" >&2; exit 2 ;;
esac
case "${B:-}" in
  ''|*[!0-9]*) echo "[fuzz] --seeds end must be a non-negative integer (got: ${B:-empty} from $SEEDS)" >&2; exit 2 ;;
esac
[ "$A" -le "$B" ] || { echo "[fuzz] --seeds start must not exceed end (got: $SEEDS)" >&2; exit 2; }
if [ -z "$JOBS" ]; then
  JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  [ "$JOBS" -le 8 ] || JOBS=8
fi
case "$JOBS" in
  ''|*[!0-9]*) echo "[fuzz] --jobs must be a positive integer, got: $JOBS" >&2; exit 2 ;;
esac
[ "$JOBS" -ge 1 ] || { echo "[fuzz] --jobs must be a positive integer, got: $JOBS" >&2; exit 2; }

# WHICH compiler answered (AGENTS.md, "Which compiler answered?"). This used to
# be `ls -t .../stage2.wasm | head -1` -- newest by MTIME, which is a different
# question from "the compiler built from this checkout" and answers it wrong on
# a reused workspace or while a build is touching directories. A fuzz campaign
# is a MEASUREMENT: "seeds 1..750, 0 findings" is pasted into an issue with no
# stderr attached, so a run against the wrong compiler produces a number nobody
# can tell apart from a right one. Hence the strict resolver, which takes the
# artifact you named or HEAD's own generation and refuses everything else
# rather than degrading to the newest one or the committed seed.
. "$ROOT/scripts/resolve_stage2.sh"
CLI="$(resolve_stage2_strict fuzz "$CLI")" || exit 2

# The `[fuzz] mode=... cli=...` banner is emitted BELOW, after the workspace
# reset, so that printing it means a campaign is actually starting. It used to
# print here, between the two refusals, which made it possible to announce a
# run and then exit -- and scripts/check_fuzz_compiler_identity.sh reads the
# banner's ABSENCE as proof no run began.
# `VIBE_FUZZ_ROOT` relocates the whole workspace. The reset below DELETES
# `$FIND`, and a developer who ran a campaign has inputs and logs there worth
# reducing, so a gate must not exercise the shared user-facing directory just
# because it happens to be the default (#2955 review). Tests point this at a
# temporary root; a real campaign leaves it unset.
FUZZ_ROOT="${VIBE_FUZZ_ROOT:-_build/fuzz}"
WORK="$FUZZ_ROOT/work"
FIND="$FUZZ_ROOT/findings"
SEEDS_FILE="$FUZZ_ROOT/failing_seeds.txt"
# ORDER MATTERS, and it is the reverse of the obvious one. The findings
# directory holds the previous campaign's repro inputs and logs -- the evidence
# -- so it must not be destroyed until the whole reset is known to be possible.
# Deleting it first meant a run that REFUSED over an unresettable ledger had
# already erased what the refusal existed to protect: measured, exit 2 with the
# finding gone (#2955 review). So the ledger is reset and validated FIRST; only
# then are the findings removed.
#
# Residual, stated rather than hidden: if the findings removal fails AFTER the
# ledger reset succeeded, the seed list is lost while the findings survive.
# That is the right way round -- the ledger is a list of seed numbers, which
# the findings directory's own entry names carry anyway.

mkdir -p "$FUZZ_ROOT"
# The seed ledger is the OTHER half of the same reset, and it needs the same
# check: `set -uo pipefail` carries no `-e`, so a redirection that cannot
# truncate -- a root-owned or immutable file, or a directory in its place --
# leaves the script running. Every later `record` append then fails too, and
# the final `wc -l` reads 0 while `findings/` holds a real finding: the
# campaign reports success having found something (#2955 review). Asking
# whether the file is now an empty regular file is NOT sufficient on its own:
# that is also the state of a ledger which was ALREADY empty and could not be
# truncated, and whose later appends will therefore fail silently (#2955
# review). So both are required -- the truncation must SUCCEED, and the result
# must be an empty regular file. The postcondition cannot replace the status
# here because the desired end state and the failed-but-already-there state are
# the same state.
# The subshell is not decoration: bash reports a failed redirection before the
# `2>/dev/null` on that same command takes effect, so a bare
# `: > "$f" 2>/dev/null` still prints `Operation not permitted` above the
# actionable message. Redirecting the subshell's stderr suppresses it from
# outside, leaving only the diagnostic that says what to do.
seeds_reset_ok=1
( : > "$SEEDS_FILE" ) 2>/dev/null || seeds_reset_ok=0
if [ "$seeds_reset_ok" -eq 0 ] || [ ! -f "$SEEDS_FILE" ] || [ -s "$SEEDS_FILE" ]; then
  echo "[fuzz] could not reset $SEEDS_FILE -- findings could not be recorded and the run would report 0" >&2
  echo "[fuzz] remove it by hand and re-run; refusing to measure with an unresettable seed ledger" >&2
  exit 2
fi

# Reset BOTH records of what this run found, so they always describe the same
# run. `failing_seeds.txt` was truncated here and `findings/` was not, which
# meant a finding directory from an earlier invocation sat there looking
# current -- and `findings/` is what a person reads to learn WHAT was found,
# since the summary line says only how many.
#
# Hit for real while certifying the 0.1.0 candidate (#2954): both campaigns
# printed `0 findings` while `findings/` held `seed_1_COMPILE_CRASH`, left by
# a deliberately bogus compiler in check_fuzz_compiler_identity_test.sh's red
# case an hour earlier. That one was survivable only because the two records
# CONTRADICTED each other; a stale finding from a real earlier campaign would
# have agreed with nothing and simply been read as this run's result.
#
# Anyone who needs a finding kept across runs copies it out, which is a
# deliberate act -- the right shape for evidence.
#
# The reset is CHECKED, and checked by its postcondition rather than by `rm`'s
# exit status. This script runs under `set -uo pipefail` with no `-e`, so a
# failed `rm -rf` -- root-owned or immutable contents, a busy mount -- would
# otherwise pass unnoticed, `mkdir -p` would succeed against the surviving
# directory, and the campaign would report `0 findings` with the stale ones
# still sitting there: exactly the silently-wrong measurement this reset
# exists to prevent (#2955 review). Asking whether the directory is GONE
# answers that directly; asking whether `rm` returned 0 is a proxy for it.
rm -rf "$FIND"
if [ -e "$FIND" ]; then
  echo "[fuzz] could not reset $FIND -- findings left there would be read as this run's" >&2
  echo "[fuzz] remove it by hand and re-run; refusing to measure with an unreset findings dir" >&2
  exit 2
fi
# Recreating the workspace is checked like every other step here: without
# `-e`, a failed `mkdir` (no space, no inodes, a permission change between the
# removal and now) would let the campaign announce itself and finish with
# `0 findings` and no findings directory at all -- nothing to read, and no
# error (#2955 review).
mkdir -p "$WORK" "$FIND" 2>/dev/null || true
if [ ! -d "$WORK" ] || [ ! -d "$FIND" ]; then
  echo "[fuzz] could not create the workspace ($WORK, $FIND)" >&2
  echo "[fuzz] refusing to measure without somewhere to record findings" >&2
  exit 2
fi

echo "[fuzz] mode=$MODE gen=${GENMODE:-liveness} seeds=$A..$B cli=$CLI jobs=$JOBS"

RUNNER="bash scripts/run_wasm_vibe_host_runner.sh"
CTIMEOUT=90
RTIMEOUT=20

# compile/run_linear/run_gc/classify are shared with tests/fuzz/classify.sh
# (used by tests/fuzz/reduce.py) via tests/fuzz/lib_oracle.sh -- see that
# file for the single source of truth on what counts as a finding. The FS
# lane also receives a per-seed VIBE_BUILD_CACHE_DIR from lib_oracle.sh, so
# its persistent compiler cache is not shared between these concurrent
# workers. Generated work/findings stay in _build/fuzz/.
# shellcheck source=tests/fuzz/lib_oracle.sh
source "$ROOT/tests/fuzz/lib_oracle.sh"

record() { # seed class dir note
  local seed="$1" class="$2" dir="$3" note="$4"
  local dst="$FIND/seed_${seed}_${class}"
  # A finding whose inputs silently failed to save is worse than a loud one:
  # the count stays right while the repro is gone, and `findings/` is exactly
  # what a person opens to reduce it. So both the directory and the source
  # copy are checked, and a failure is announced AND recorded in the artifact
  # itself rather than inferred later from an empty directory (#2955 review).
  if ! mkdir -p "$dst" 2>/dev/null || [ ! -d "$dst" ]; then
    echo "[fuzz] seed $seed: $class ($note) -- COULD NOT CREATE $dst; inputs NOT saved" >&2
    echo "$seed $class $note [inputs-not-saved]" >> "$SEEDS_FILE"
    echo "[fuzz] seed $seed: $class ($note)"
    return
  fi
  if ! cp -f "$dir"/*.vibe "$dst"/ 2>/dev/null; then
    echo "[fuzz] seed $seed: $class -- inputs could NOT be copied into $dst" >&2
    printf 'inputs could not be copied from %s -- this finding has no repro\n' "$dir" \
      > "$dst/INPUTS_MISSING.txt" 2>/dev/null || true
  fi
  cp -f "$dir"/*.log "$dir"/*.diag "$dst"/ 2>/dev/null || true
  echo "$note" > "$dst/note.txt"
  echo "$seed $class $note" >> "$SEEDS_FILE"
  echo "[fuzz] seed $seed: $class ($note)"
}

run_seed() { # seed -- runs entirely in its own background subshell/process
  local seed="$1"
  local dir="$WORK/s$seed"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 tests/fuzz/gen_program.py "$seed" "$dir" $GENMODE

  if [ "$MODE" = "mutate" ]; then
    # parser robustness: mutate bytes; only compiler trap/hang is a finding
    python3 - "$seed" "$dir" <<'EOF'
import random, sys
seed, d = int(sys.argv[1]), sys.argv[2]
r = random.Random(seed * 7919 + 13)
data = bytearray(open(f"{d}/single.vibe", "rb").read())
for _ in range(r.randint(1, 24)):
    k = r.random()
    if not data: break
    i = r.randrange(len(data))
    if k < 0.5: data[i] = r.randrange(32, 127)
    elif k < 0.75: del data[i]
    else: data.insert(i, r.randrange(32, 127))
open(f"{d}/mut.vibe", "wb").write(bytes(data))
EOF
    st=$(compile "$dir/mut.vibe" "$dir/mut.wasm" VIBE_RC=0)
    case "$st" in
      OK|COMPILE_DIAG) : ;;
      *) record "$seed" "MUT_$st" "$dir" "mutated input: $st" ;;
    esac
    return
  fi

  # --- generative differential mode ---
  result=$(classify "$dir")
  cls="${result%% *}"
  detail="${result#* }"
  if [ "$cls" != "OK" ]; then
    record "$seed" "$cls" "$dir" "$detail"
  fi
}

# Bounded job-slot pool: launch each seed as its own background process,
# never more than $JOBS in flight at once. `fail`/`total` are NOT mutated
# inside run_seed (background subshells can't write back to this shell's
# variables) -- total is computed directly from the seed range, and fail is
# the line count of failing_seeds.txt after every job has been waited on.
total=$((B - A + 1))
running=0
for seed in $(seq "$A" "$B"); do
  run_seed "$seed" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n
    running=$((running - 1))
  fi
done
wait

fail=$(wc -l < "$SEEDS_FILE" | tr -d '[:space:]')
echo "[fuzz] done: $total seeds, $fail findings"
[ "$fail" -eq 0 ]
