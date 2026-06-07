#!/usr/bin/env bash
# Three-way throughput comparison on allocation-heavy loops:
#   linear  — default selfhost linear backend (bump allocator, NO reclamation)
#   rc      — selfhost linear + Perceus RC (recursive drop + free-list)
#   gc      — wasm-gc backend (`vibe compile --wasm-gc`, struct.new + engine GC)
#
# Companion to bench_selfhost_rc.sh (which does linear-vs-rc heap+time via node).
# This one answers "wasm-gc vs wasm Perceus-RC" on the SAME programs under a
# SINGLE runtime (wasmtime), because node/V8 escape-analyzes the gc allocation
# away (the loop body's tuple never escapes) and reports a misleadingly fast gc
# time — wasmtime treats struct.new + GC as real work, so it is the fair judge.
#
# Methodology: each program runs an N-iteration allocating loop in `main`. We
# also compile a TRIVIAL twin (loop bound 0 → no allocation) per backend and
# subtract its wasmtime wall time, isolating the per-loop allocation+reclaim
# cost from wasmtime startup + JIT-compile. Reported = min of REPEATS runs.
#
# Usage:  bash scripts/bench_gc_vs_rc.sh [N] [repeats]
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# shellcheck source=/dev/null
source scripts/ensure_native_cli.sh
VIBE_BIN="${VIBE_CLI_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
COMPILER_DIR="$PROJECT_ROOT/vibe/compiler"

N="${1:-1000000}"
REPEATS="${2:-7}"
STAMP="$(date +%s%N)"
WT_FLAGS="-W exceptions=y -W function-references=y -W gc=y -W unknown-imports-default=y"
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime not found on PATH; this bench needs it for a fair gc-vs-rc timing." >&2
  exit 1
fi

# Program bodies: each is the body of `main` (between the braces). $LIM is the
# loop bound (N for the real run, 0 for the trivial startup-baseline twin).
# A leading PRELUDE (struct/enum decl) is prepended verbatim where needed.
prog_flat_prelude=""
prog_flat='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let t = (i, i + 1)\n    s = s + t.0\n    i = i + 1\n  }\n  s'

prog_nested_prelude=""
prog_nested='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let t = ((i, i + 1), (i + 2, i + 3))\n    let a = t.0\n    let b = t.1\n    s = s + a.0 + b.1\n    i = i + 1\n  }\n  s'

prog_record_prelude='struct Pair { a: (Int, Int); b: (Int, Int) }\n'
prog_record='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let p = Pair::{ a: (i, i + 1), b: (i + 2, i + 3) }\n    s = s + p.a.0 + p.b.1\n    i = i + 1\n  }\n  s'

prog_enum_prelude='enum Box { Wrap((Int, Int)); Empty }\n'
prog_enum='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let e = Wrap((i, i + 1))\n    s = s + match e {\n      Wrap(p) => p.0 + p.1,\n      Empty => 0\n    }\n    i = i + 1\n  }\n  s'

NAMES=(flat nested record enum)

# Build a full source string for a program at a given loop bound.
src_for() { # name  lim
  local name="$1" lim="$2"
  local prelude body
  eval "prelude=\$prog_${name}_prelude"
  eval "body=\$prog_${name}"
  body="${body//LIM/$lim}"
  printf '%sexport let main: () -> Int = () -> {\n  %s\n}' "$prelude" "$body"
}

# 1) Emit ALL selfhost linear + rc wasms (real + trivial) in one probe compile.
emit_selfhost() {
  local probe="$COMPILER_DIR/_gcrc_emit_${STAMP}_test.vibe"
  TMPFILES+=("$probe")
  {
    echo 'import ./codegen_test_support.vibe { compile_wasi, compile_wasi_rc }'
    echo 'let emit: () -> Int with { Error, Fs } = () -> {'
    for name in "${NAMES[@]}"; do
      for lim in "$N" 0; do
        local tag; [ "$lim" = 0 ] && tag="tv" || tag="rl"
        local src; src="$(src_for "$name" "$lim")"
        # Embed as a vibe string literal. Keep the literal `\n` markers intact
        # (the vibe lexer turns them into newlines, like bench_selfhost_rc.sh);
        # only `"` needs escaping (the programs contain none, but be safe).
        local esc; esc="${src//\"/\\\"}"
        echo "  Fs::write_bytes(\"/tmp/gcrc_${name}_${tag}_lin.wasm\", compile_wasi(\"${esc}\", \"main\"))"
        echo "  Fs::write_bytes(\"/tmp/gcrc_${name}_${tag}_rc.wasm\", compile_wasi_rc(\"${esc}\", \"main\"))"
        TMPFILES+=("/tmp/gcrc_${name}_${tag}_lin.wasm" "/tmp/gcrc_${name}_${tag}_rc.wasm")
      done
    done
    echo '  0'
    echo '}'
    echo 'test "emit" { emit(); assert(true) }'
  } > "$probe"
  "$VIBE_BIN" test --no-cache "$probe" >/dev/null 2>&1 || true
}

# 2) Emit gc wasms via the CLI (real + trivial).
emit_gc() {
  for name in "${NAMES[@]}"; do
    for lim in "$N" 0; do
      local tag; [ "$lim" = 0 ] && tag="tv" || tag="rl"
      local vf="/tmp/gcrc_${name}_${tag}.vibe"
      local wf="/tmp/gcrc_${name}_${tag}_gc.wasm"
      TMPFILES+=("$vf" "$wf")
      printf '%b' "$(src_for "$name" "$lim")" > "$vf"
      "$VIBE_BIN" compile "$vf" --wasm-gc -o "$wf" >/dev/null 2>&1 || true
    done
  done
}

# Run `main` once, echo its printed integer result (or "MISSING"/"trap").
result_of() { # wasm  arg
  local wasm="$1" arg="${2:-}" out
  [ -f "$wasm" ] || { echo MISSING; return; }
  # shellcheck disable=SC2086
  out="$(wasmtime $WT_FLAGS --invoke main "$wasm" $arg 2>/dev/null | tail -1)"
  if [[ "$out" =~ ^-?[0-9]+$ ]]; then echo "$out"; else echo trap; fi
}

# Min-of-REPEATS wasmtime wall time (ms) for `main` (gc takes 0 args, lin/rc 1).
timeit() { # wasm  arg
  local wasm="$1" arg="${2:-}" best=9999999 i t0 t1 ms
  [ -f "$wasm" ] || { echo -1; return; }
  for i in $(seq 1 "$REPEATS"); do
    t0=$(date +%s%N)
    # shellcheck disable=SC2086
    wasmtime $WT_FLAGS --invoke main "$wasm" $arg >/dev/null 2>&1
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    [ $ms -lt $best ] && best=$ms
  done
  echo $best
}

# Time only if the backend produced the correct checksum; else label the failure.
timed_or_fail() { # real_wasm  triv_wasm  expected  arg
  local rw="$1" tw="$2" expected="$3" arg="${4:-}"
  [ -f "$rw" ] || { echo "FAIL(nocompile)"; return; }
  local got; got="$(result_of "$rw" "$arg")"
  if [ "$got" = trap ]; then echo "FAIL(trap)"; return; fi
  if [ "$got" != "$expected" ]; then echo "FAIL(got=$got)"; return; fi
  local rr tr; rr=$(timeit "$rw" "$arg"); tr=$(timeit "$tw" "$arg")
  echo $((rr - tr))
}

echo "== wasm-gc vs Perceus-RC vs linear (bump), N=$N, min of $REPEATS, wasmtime =="
emit_selfhost
emit_gc
echo
printf '  %-10s  %10s  %10s  %12s   %s\n' program linear_ms rc_ms gc_ms "(loop-only; gc/rc)"
for name in "${NAMES[@]}"; do
  # checksum from the linear build is the ground truth every backend must match
  expected="$(result_of "/tmp/gcrc_${name}_rl_lin.wasm" 0)"
  lin="$(timed_or_fail "/tmp/gcrc_${name}_rl_lin.wasm" "/tmp/gcrc_${name}_tv_lin.wasm" "$expected" 0)"
  rc="$(timed_or_fail "/tmp/gcrc_${name}_rl_rc.wasm"  "/tmp/gcrc_${name}_tv_rc.wasm"  "$expected" 0)"
  gc="$(timed_or_fail "/tmp/gcrc_${name}_rl_gc.wasm"  "/tmp/gcrc_${name}_tv_gc.wasm"  "$expected")"
  ratio="n/a"
  [[ "$rc" =~ ^[0-9]+$ && "$gc" =~ ^[0-9]+$ && "$rc" -gt 0 ]] && \
    ratio="x$(awk "BEGIN{printf \"%.1f\", $gc/$rc}")"
  printf '  %-10s  %10s  %10s  %12s   gc/rc=%s\n' "$name" "$lin" "$rc" "$gc" "$ratio"
done
echo
echo "Note: gc programs are compiled by the src/ wasm-gc backend (vibe compile"
echo "--wasm-gc); linear+rc by the selfhost compiler. FAIL(...) marks a wasm-gc"
echo "backend gap (parse/type/codegen) — see docs/spec/selfhost-uniform-value-repr.md."
