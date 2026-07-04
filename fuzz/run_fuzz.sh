#!/usr/bin/env bash
# Differential fuzzing harness for the selfhost vibe compiler.
#
#   bash fuzz/run_fuzz.sh [--seeds A..B] [--cli path/to/stage2.wasm]
#   bash fuzz/run_fuzz.sh --mutate [--seeds A..B]   # parser-robustness mode
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
while [ $# -gt 0 ]; do
  case "$1" in
    --seeds) SEEDS="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    --mutate) MODE="mutate"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
A="${SEEDS%%..*}"; B="${SEEDS##*..}"

if [ -z "$CLI" ]; then
  CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1)"
fi
if [ -z "$CLI" ] || [ ! -f "$CLI" ]; then
  echo "[fuzz] no stage2 CLI found; build one first (scripts/selfhost_generations.sh build)" >&2
  exit 2
fi
echo "[fuzz] mode=$MODE seeds=$A..$B cli=$CLI"

WORK=_build/fuzz/work
FIND=_build/fuzz/findings
mkdir -p "$WORK" "$FIND"
: > _build/fuzz/failing_seeds.txt

RUNNER="bash scripts/run_wasm_vibe_host_runner.sh"
CTIMEOUT=90
RTIMEOUT=20

compile() { # src out extra-env...
  local src="$1" out="$2"; shift 2
  rm -f "$out" "$out.diag"
  timeout $CTIMEOUT env VIBE_PREOPEN_DIR="$ROOT" VIBE_SELFHOST_IMPORT_ABI=raw "$@" \
    $RUNNER --invoke cli_main "$CLI" "$src" "$out" _start \
    > "$out.log" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then echo "COMPILE_HANG"; return; fi
  if [ -s "$out" ]; then echo "OK"; return; fi
  if [ -s "$out.diag" ]; then echo "COMPILE_DIAG"; return; fi
  echo "COMPILE_CRASH"
}

run_linear() { # wasm -> prints result or RUN_TRAP/RUN_HANG
  local wasm="$1"
  local out
  out=$(timeout $RTIMEOUT env VIBE_PREOPEN_DIR="$ROOT" \
    $RUNNER --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

run_gc() {
  local wasm="$1"
  local out
  out=$(timeout $RTIMEOUT wasmtime run -W gc=y,function-references=y,exceptions=y \
    --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

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

fail=0
total=0
for seed in $(seq "$A" "$B"); do
  total=$((total + 1))
  dir="$WORK/s$seed"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 fuzz/gen_program.py "$seed" "$dir"

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
      *) record "$seed" "MUT_$st" "$dir" "mutated input: $st"; fail=$((fail+1)) ;;
    esac
    continue
  fi

  # --- generative differential mode ---
  st_bump=$(compile "$dir/single.vibe" "$dir/bump.wasm" VIBE_RC=0)
  st_rc=$(compile "$dir/single.vibe" "$dir/rc.wasm" VIBE_RC=1)
  st_gc=$(compile "$dir/single.vibe" "$dir/gc.wasm" VIBE_RC=0 VIBE_BACKEND=gc)
  rm -f _build/vibe_selfhost_source_list_* _build/vibe_selfhost_source_groups_*
  st_fs=$(compile "$dir/main.vibe" "$dir/fs.wasm" VIBE_RC=0 VIBE_FS_COMPILE=1)

  bad=""
  for pair in "bump:$st_bump" "rc:$st_rc" "gc:$st_gc" "fs:$st_fs"; do
    lane="${pair%%:*}"; st="${pair##*:}"
    if [ "$st" != "OK" ]; then bad="$bad $lane=$st"; fi
  done
  if [ -n "$bad" ]; then
    cls=$(echo "$bad" | grep -oE "COMPILE_[A-Z]+" | sort -u | head -1)
    record "$seed" "$cls" "$dir" "$bad"
    fail=$((fail + 1))
    continue
  fi

  r_bump=$(run_linear "$dir/bump.wasm")
  r_rc=$(run_linear "$dir/rc.wasm")
  r_gc=$(run_gc "$dir/gc.wasm")
  r_fs=$(run_linear "$dir/fs.wasm")

  case "$r_bump$r_rc$r_gc$r_fs" in
    *RUN_TRAP*) record "$seed" "RUN_TRAP" "$dir" \
      "bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; fail=$((fail+1)); continue ;;
    *RUN_HANG*) record "$seed" "RUN_HANG" "$dir" \
      "bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; fail=$((fail+1)); continue ;;
  esac
  if [ "$r_bump" != "$r_rc" ] || [ "$r_bump" != "$r_gc" ] || [ "$r_bump" != "$r_fs" ]; then
    record "$seed" "MISMATCH" "$dir" \
      "bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"
    fail=$((fail + 1))
    continue
  fi
done

echo "[fuzz] done: $total seeds, $fail findings"
[ "$fail" -eq 0 ]
