#!/usr/bin/env bash
# ADR-0055 RC cutover-readiness probe (#493). The reclaim suite and heap-e2e
# gate exercise RC features in ISOLATION; cutover needs realistic code that
# MIXES them. This compiles a corpus of feature-combined, allocation-heavy
# programs (each a parameterised `main(n)` loop returning a checksum) both ways —
# default linear (bump, leaks) and Perceus RC — and reports, per program:
#   - compiles:  does RC compile + validate (RC compile-coverage on real shapes)
#   - parity:    default result == RC result (RC correctness on real code)
#   - def B/iter / rc B/iter:  per-iteration heap growth (RC bounded? leaks?)
#
# Readiness == every program compiles under RC, parity holds, and rc B/iter is
# ~0 (bounded). A non-zero rc B/iter flags a residual leak that bites real code.
#
# Usage:  bash scripts/rc_cutover_readiness.sh [N1] [N2]
set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# shellcheck source=/dev/null
source scripts/ensure_native_cli.sh
VIBE_BIN="${VIBE_CLI_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
COMPILER_DIR="$PROJECT_ROOT/vibe/compiler"
N1="${1:-1000}"
N2="${2:-11000}"
STAMP="$(date +%s%N)"
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

# Each program body is the `main` body with `LIM` for the loop bound. They mix
# enums+match, records, tuples, arrays, closures/HOF, recursion-via-helpers.
prog_eval='let lit = (v) -> { Lit(v) }\n  let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let e = Add(lit(i), lit(i + 1))\n    s = s + match e {\n      Add(a, b) => (match a { Lit(x) => x, Add(_, _) => 0 }) + (match b { Lit(y) => y, Add(_, _) => 0 }),\n      Lit(x) => x\n    }\n    i = i + 1\n  }\n  s'
prog_eval_pre='enum Expr { Lit(Int); Add(Expr, Expr) }\n'

prog_record_pre='struct Node { lo: (Int, Int); hi: (Int, Int) }\n'
prog_record='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let n = Node::{ lo: (i, i + 1), hi: (i + 2, i + 3) }\n    s = s + n.lo.0 + n.hi.1\n    i = i + 1\n  }\n  s'

prog_hof_pre=''
prog_hof='let apply = (f, x) -> { f(x) }\n  let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let t = (i, i + 1)\n    let g = (p) -> { p.0 + p.1 }\n    s = s + apply(g, t)\n    i = i + 1\n  }\n  s'

prog_clos_pre=''
prog_clos='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let base = (i, i + 1)\n    let add = (d) -> { base.0 + base.1 + d }\n    let arr = [add(1), add(2), add(3)]\n    s = s + Array::get(arr, 0) + Array::get(arr, 2)\n    i = i + 1\n  }\n  s'

prog_opt_pre='enum Opt { Som((Int, Int)); Non }\n'
prog_opt='let unwrap = (o, d) -> { match o { Som(p) => p.0 + p.1, Non => d } }\n  let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let o = if i % 2 == 0 { Som((i, i + 1)) } else { Non }\n    s = s + unwrap(o, 0)\n    i = i + 1\n  }\n  s'

prog_mixed_pre='enum Tag { Pair((Int, Int)); Triple((Int, Int)) }\nstruct Box { t: Tag; n: Int }\n'
prog_mixed='let mut s = 0\n  let mut i = 0\n  while i < LIM {\n    let b = Box::{ t: Pair((i, i + 1)), n: i }\n    s = s + b.n + match b.t {\n      Pair(p) => p.0,\n      Triple(p) => p.1\n    }\n    i = i + 1\n  }\n  s'

NAMES=(eval record hof clos opt mixed)

src_for() { # name lim
  local name="$1" lim="$2" pre body
  eval "pre=\${prog_${name}_pre:-}"
  eval "body=\$prog_${name}"
  body="${body//LIM/$lim}"
  printf '%sexport let main: () -> Int = () -> {\n  %s\n}' "$pre" "$body"
}

# Emit default + rc wasm for every program at both N via one probe compile.
emit_all() {
  local probe="$COMPILER_DIR/_rcready_${STAMP}_test.vibe"
  TMPFILES+=("$probe")
  {
    echo 'import ./codegen_test_support.vibe { compile_wasi, compile_wasi_rc }'
    echo 'let emit: () -> Int with { Error, Fs } = () -> {'
    for name in "${NAMES[@]}"; do
      for lim in "$N1" "$N2"; do
        local src esc
        src="$(src_for "$name" "$lim")"
        esc="${src//\"/\\\"}"
        echo "  Fs::write_bytes(\"/tmp/rcready_${name}_${lim}_d.wasm\", compile_wasi(\"${esc}\", \"main\"))"
        echo "  Fs::write_bytes(\"/tmp/rcready_${name}_${lim}_r.wasm\", compile_wasi_rc(\"${esc}\", \"main\"))"
        TMPFILES+=("/tmp/rcready_${name}_${lim}_d.wasm" "/tmp/rcready_${name}_${lim}_r.wasm")
      done
    done
    echo '  0'
    echo '}'
    echo 'test "emit" { emit(); assert(true) }'
  } > "$probe"
  "$VIBE_BIN" test --no-cache "$probe" >/dev/null 2>&1 || true
}

field() { # wasm jsonfield
  [ -f "$1" ] || { echo MISSING; return; }
  node scripts/measure_selfhost_heap.mjs "$1" main 2>/dev/null \
    | node -e "process.stdin.once('data',d=>{try{console.log(JSON.parse(d).$2)}catch(e){console.log('ERR')}})"
}

echo "== ADR-0055 RC cutover readiness (N1=$N1 N2=$N2) =="
emit_all
echo
printf '  %-9s  %-9s  %-8s  %12s  %10s\n' program rc-compiles parity def-B/iter rc-B/iter
ready=1
for name in "${NAMES[@]}"; do
  d2="/tmp/rcready_${name}_${N2}_d.wasm"; r1="/tmp/rcready_${name}_${N1}_r.wasm"; r2="/tmp/rcready_${name}_${N2}_r.wasm"
  d1="/tmp/rcready_${name}_${N1}_d.wasm"
  if [ ! -f "$r2" ]; then printf '  %-9s  %-9s\n' "$name" "NO"; ready=0; continue; fi
  local_rc_compiles="yes"
  dres="$(field "$d2" result)"; rres="$(field "$r2" result)"
  par="OK"; [ "$dres" = "$rres" ] || { par="FAIL($dres!=$rres)"; ready=0; }
  dh1="$(field "$d1" heap_used)"; dh2="$(field "$d2" heap_used)"
  rh1="$(field "$r1" heap_used)"; rh2="$(field "$r2" heap_used)"
  dpi="$(node -e "console.log((($dh2)-($dh1))/(($N2)-($N1)))" 2>/dev/null || echo ERR)"
  rpi="$(node -e "console.log((($rh2)-($rh1))/(($N2)-($N1)))" 2>/dev/null || echo ERR)"
  [ "$rpi" = "0" ] || ready=0
  printf '  %-9s  %-9s  %-8s  %12s  %10s\n' "$name" "$local_rc_compiles" "$par" "$dpi" "$rpi"
done
echo
if [ "$ready" = "1" ]; then echo "READY: all programs compile under RC, parity holds, RC heap bounded (0 B/iter)."; else echo "NOT FULLY READY: see rows above (compile gap / parity fail / non-zero rc B/iter)."; fi
