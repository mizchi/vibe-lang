#!/usr/bin/env bash
# Differential fuzzing harness for the selfhost vibe compiler.
#
#   bash fuzz/run_fuzz.sh [--seeds A..B] [--cli path/to/stage2.wasm] [--jobs N]
#   bash fuzz/run_fuzz.sh --mutate [--seeds A..B]   # parser-robustness mode
#
# Seeds run with up to --jobs concurrent OS processes (default: nproc, capped
# at 8) via a bash job-slot pool -- real parallelism (each seed is its own
# subshell/process tree), not vibe's own cooperative TaskGroup, which never
# runs two task bodies at once (see docs/compiler-parallelism.md's
# "Shared-everything migration note"). Safe because every seed already had
# its own work dir ($WORK/s$seed) and finding dir ($FIND/seed_<n>_<class>);
# the only genuinely shared file, failing_seeds.txt, is appended to via
# `echo ... >>`, whose writes are atomic for lines under PIPE_BUF so
# concurrent seeds interleave lines but never corrupt them. --jobs 1
# reproduces the original strictly-sequential ordering exactly.
#
# Generative mode (default), per seed:
#   1. fuzz/gen_program.py emits a well-typed, trap-free-by-construction
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

cd "$(dirname "$0")/.."
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
A="${SEEDS%%..*}"; B="${SEEDS##*..}"
if [ -z "$JOBS" ]; then
  JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  [ "$JOBS" -le 8 ] || JOBS=8
fi
case "$JOBS" in
  ''|*[!0-9]*) echo "[fuzz] --jobs must be a positive integer, got: $JOBS" >&2; exit 2 ;;
esac
[ "$JOBS" -ge 1 ] || { echo "[fuzz] --jobs must be a positive integer, got: $JOBS" >&2; exit 2; }

if [ -z "$CLI" ]; then
  CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1)"
fi
if [ -z "$CLI" ] || [ ! -f "$CLI" ]; then
  echo "[fuzz] no stage2 CLI found; build one first (scripts/generations.sh build)" >&2
  exit 2
fi
echo "[fuzz] mode=$MODE gen=${GENMODE:-liveness} seeds=$A..$B cli=$CLI jobs=$JOBS"

WORK=_build/fuzz/work
FIND=_build/fuzz/findings
mkdir -p "$WORK" "$FIND"
: > _build/fuzz/failing_seeds.txt

RUNNER="bash scripts/run_wasm_vibe_host_runner.sh"
CTIMEOUT=90
RTIMEOUT=20

# compile/run_linear/run_gc/classify are shared with fuzz/classify.sh (used
# by fuzz/reduce.py) via fuzz/lib_oracle.sh -- see that file for the single
# source of truth on what counts as a finding. The FS lane also receives a
# per-seed VIBE_BUILD_CACHE_DIR from lib_oracle.sh, so its persistent compiler
# cache is not shared between these concurrent workers.
# shellcheck source=fuzz/lib_oracle.sh
source "$ROOT/fuzz/lib_oracle.sh"

record() { # seed class dir note
  local seed="$1" class="$2" dir="$3" note="$4"
  local dst="$FIND/seed_${seed}_${class}"
  mkdir -p "$dst"
  cp -f "$dir"/*.vibe "$dst"/ 2>/dev/null
  cp -f "$dir"/*.log "$dir"/*.diag "$dst"/ 2>/dev/null || true
  echo "$note" > "$dst/note.txt"
  echo "$seed $class $note" >> _build/fuzz/failing_seeds.txt
  echo "[fuzz] seed $seed: $class ($note)"
}

run_seed() { # seed -- runs entirely in its own background subshell/process
  local seed="$1"
  local dir="$WORK/s$seed"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 fuzz/gen_program.py "$seed" "$dir" $GENMODE

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

fail=$(wc -l < _build/fuzz/failing_seeds.txt | tr -d '[:space:]')
echo "[fuzz] done: $total seeds, $fail findings"
[ "$fail" -eq 0 ]
