#!/usr/bin/env bash
# Reliable verification loop for the selfhost Perceus RC work (ADR-0055).
#
# WHY THIS EXISTS — two traps make naive verification unreliable:
#   1. `vibe test` MEMOIZES pure-test results, and `--no-cache` does NOT bust
#      that memo: only a *change to the test file's content/path* forces a real
#      re-run. So `vibe test codegen_heap_e2e_test.vibe` can report a stale pass
#      that does not reflect edited codegen. We sidestep this by running the gate
#      from a UNIQUELY-NAMED COPY (fresh path => fresh cache key) every time.
#   2. Ad-hoc `compile_wasi_rc` -> wasmtime `--invoke main` probes are unreliable
#      for *correctness* (the entry takes a closure-env arg; `--invoke` mishandles
#      it). The `__heap_ptr` global, however, is reliable for *reclamation*.
#
# So this script gives two authoritative signals:
#   A. CORRECTNESS — the heap-e2e gate (default vs RC, identical results on
#      wasmtime), run from a fresh copy so the result is never stale.
#   B. RECLAMATION — per-iteration heap growth of RC-compiled allocating loops
#      (tuple / record / enum / array / nested), asserted ~0 (reused, not leaked).
#
# Usage:  bash scripts/verify_selfhost_rc.sh [--reclaim-threshold N]
# Exit 0 iff the gate is all-pass AND every reclamation case is within threshold.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

RECLAIM_THRESHOLD="${RECLAIM_THRESHOLD:-1}"   # bytes/iter; 0 reclamation == ~0
N1="${VIBE_RC_N1:-1000}"
N2="${VIBE_RC_N2:-11000}"
while [ $# -gt 0 ]; do
  case "$1" in
    --reclaim-threshold) RECLAIM_THRESHOLD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
source scripts/ensure_native_cli.sh
VIBE_BIN="${VIBE_CLI_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
COMPILER_DIR="$PROJECT_ROOT/vibe/compiler"

STAMP="$(date +%s%N)"
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

FAIL=0

# ---------------------------------------------------------------------------
# A. CORRECTNESS GATE (fresh copy => never stale)
# ---------------------------------------------------------------------------
echo "== A. correctness gate (heap-e2e, default vs RC) =="
GATE_SRC="$COMPILER_DIR/codegen_heap_e2e_test.vibe"
GATE_COPY="$COMPILER_DIR/_verify_gate_${STAMP}_test.vibe"
TMPFILES+=("$GATE_COPY")
# A unique filename guarantees a fresh cache key; the trailing comment makes the
# content unique too (belt and suspenders).
{ cat "$GATE_SRC"; printf '\n// verify-run %s\n' "$STAMP"; } > "$GATE_COPY"
GATE_LOG="$(mktemp)"; TMPFILES+=("$GATE_LOG")
"$VIBE_BIN" test --no-cache "$GATE_COPY" > "$GATE_LOG" 2>&1 || true
SUMMARY="$(grep -oE 'summary: files=[0-9]+ total=[0-9]+ passed=[0-9]+ failed=[0-9]+ skipped=[0-9]+' "$GATE_LOG" | tail -1)"
if [ -z "$SUMMARY" ]; then
  red "  gate did not produce a summary (build error?)"
  grep -vE 'warning|unused|^import|^\^|help:' "$GATE_LOG" | grep -iE 'error|throw|panic' | head -5
  FAIL=1
else
  GTOTAL="$(echo "$SUMMARY" | grep -oE 'total=[0-9]+' | cut -d= -f2)"
  GFAIL="$(echo "$SUMMARY" | grep -oE 'failed=[0-9]+' | cut -d= -f2)"
  if [ "$GFAIL" = "0" ] && [ "$GTOTAL" -gt 0 ]; then
    green "  gate OK ($SUMMARY)"
  else
    red "  gate FAIL ($SUMMARY)"
    grep -E '  - heap e2e:' "$GATE_LOG" | head -10
    FAIL=1
  fi
fi

# ---------------------------------------------------------------------------
# B. RECLAMATION (RC path; __heap_ptr is reliable)
# ---------------------------------------------------------------------------
echo "== B. RC reclamation (bytes/iter, want <= $RECLAIM_THRESHOLD) =="

# Each case is an allocating loop body that binds-and-drops one heap value per
# iteration. `__BODY__` is substituted; the loop count `__N__` parametrises it.
reclaim_case() { # name  loop_body_with___N__
  local name="$1" body="$2"
  local probe="$COMPILER_DIR/_verify_reclaim_${name}_${STAMP}_test.vibe"
  TMPFILES+=("$probe")
  cat > "$probe" <<EOF
import ./codegen_test_support.vibe { compile_wasi_rc }
import ./core/polyfill.vibe { __to_string }
let emit: (Int) -> Int with { Error, Fs } = (n) -> {
  let src = $body
  Fs::write_bytes("/tmp/_verify_${name}_${STAMP}_" + __to_string(n) + ".wasm", compile_wasi_rc(src, "main"))
  0
}
test "emit" { emit($N1); emit($N2); assert(true) }
EOF
  "$VIBE_BIN" test --no-cache "$probe" >/dev/null 2>&1 || true
  local w1="/tmp/_verify_${name}_${STAMP}_${N1}.wasm"
  local w2="/tmp/_verify_${name}_${STAMP}_${N2}.wasm"
  TMPFILES+=("$w1" "$w2")
  if [ ! -f "$w1" ] || [ ! -f "$w2" ]; then
    red "  $name: FAIL (RC compile produced no wasm)"; FAIL=1; return
  fi
  local u1 u2 per
  u1="$(node scripts/measure_selfhost_heap.mjs "$w1" main | node -e 'process.stdin.once("data",d=>console.log(JSON.parse(d).heap_used))')"
  u2="$(node scripts/measure_selfhost_heap.mjs "$w2" main | node -e 'process.stdin.once("data",d=>console.log(JSON.parse(d).heap_used))')"
  per="$(node -e "console.log((($u2)-($u1))/(($N2)-($N1)))")"
  local over
  over="$(node -e "console.log((($per) > ($RECLAIM_THRESHOLD)) ? 1 : 0)")"
  if [ "$over" = "1" ]; then
    red "  $name: LEAK ${per} B/iter (heap ${u1}->${u2})"; FAIL=1
  else
    green "  $name: OK ${per} B/iter (heap ${u1}->${u2})"
  fi
}

# Note: source strings use \n line breaks inside the vibe string literal.
reclaim_case tuple   '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    s = s + t.0\n    i = i + 1\n  }\n  s\n}"'
reclaim_case record  '"struct P { x: Int; y: Int }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let p = P::{ x: i, y: i + 1 }\n    s = s + p.x\n    i = i + 1\n  }\n  s\n}"'
reclaim_case enum    '"enum E { A(Int); B }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let e = A(i)\n    s = s + match e { A(v) => v, B => 0 }\n    i = i + 1\n  }\n  s\n}"'
reclaim_case array   '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let a = [i, i + 1, i + 2]\n    s = s + Array::get(a, 1)\n    i = i + 1\n  }\n  s\n}"'
# ADR-0055 Stage 3: a NESTED tuple per iteration. Without recursive drop the
# outer block is reused but the two inner tuple blocks leak (heap grows). With
# the recursive rc_drop helper all three are reclaimed → ~0 B/iter.
reclaim_case nested  '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = ((i, i + 1), (i + 2, i + 3))\n    let a = t.0\n    s = s + a.0\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4: an owned heap binding moved into a container element
# (`let t = (..); let a = [t]`). Two block sizes (tuple 32 B, container) are
# allocated then freed-in-reverse each iteration; the old head-only free-list
# bump-allocated a fresh tuple every iter (32 B/iter leak). The __rc_alloc
# free-list search reclaims fully. Pins the array / enum / record forms.
reclaim_case owned_in_array  '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    let a = [t]\n    s = s + (Array::get(a, 0)).0\n    i = i + 1\n  }\n  s\n}"'
reclaim_case owned_in_enum   '"enum Box { Wrap((Int, Int)); Empty }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    let e = Wrap(t)\n    s = s + match e { Wrap(p) => p.0, Empty => 0 }\n    i = i + 1\n  }\n  s\n}"'
reclaim_case owned_in_record '"struct H { v: (Int, Int) }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    let h = H::{ v: t }\n    s = s + h.v.0\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4: reassigning a heap `mut` binding must drop the old value.
# `b = t` each iteration would otherwise leak the previous tuple (32 B/iter);
# the assignment drop reclaims it (bounded heap, two blocks cycling).
reclaim_case mut_reassign '"let main: () -> Int = () -> {\n  let mut b = (0, 0)\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    b = t\n    i = i + 1\n  }\n  b.0\n}"'

# ADR-0055 Stage 4: the FINAL value of a heap mut binding is dropped at scope end.
reclaim_case mut_final '"let main: () -> Int = () -> {\n  let mut acc = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let mut b = (i, i + 1)\n    b = (i + 2, i + 3)\n    acc = acc + b.0\n    i = i + 1\n  }\n  acc\n}"'

# ADR-0055 Stage 4 (owned-vs-borrowed): an owned heap parameter used only by
# borrows is dropped by the callee, else the caller's transferred tuple leaks.
reclaim_case owned_param '"let consume: ((Int, Int)) -> Int = (p) -> {\n  p.0 + p.1\n}\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    s = s + consume(t)\n    i = i + 1\n  }\n  s\n}"'
# An owned param returned by projection (tail-aliasing guard dups the result).
reclaim_case owned_param_proj '"let fst: (((Int, Int), (Int, Int))) -> (Int, Int) = (p) -> {\n  p.0\n}\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = ((i, i + 1), (i + 2, i + 3))\n    let r = fst(t)\n    s = s + r.0\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4 (closures): a closure capturing a heap value is a headered RC
# env block (drop-class 1) — capturing consumes the value, dropping the closure
# binding recursively frees it. Without it the captured tuple + env leak.
reclaim_case closure_capture '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    let g = () -> { t.0 + t.1 }\n    s = s + g()\n    i = i + 1\n  }\n  s\n}"'
# Closure capturing two heap values, called twice (not consumed per call).
reclaim_case closure_two '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let a = (i, i + 1)\n    let b = (i + 2, i + 3)\n    let g = () -> { a.0 + b.1 }\n    s = s + g() + g()\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4 (owned param, UNANNOTATED): a nested closure param has no type
# annotation (the signature lives on an outer binding the lambda does not see),
# so it used to be classified non-heap and never dropped — leaking the owned
# argument (32 B/iter). `param_is_heap_in_body` now proves heap-ness from the
# body: a param that is PROJECTED (`p.0`) or MATCHED is necessarily a
# tuple/record/enum (a closure or scalar can be neither), so the callee drops it.
reclaim_case nested_closure_param '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let apply = (p) -> { p.0 + p.1 }\n    let t = (i, i + 1)\n    s = s + apply(t)\n    i = i + 1\n  }\n  s\n}"'
# Same, proven via a match scrutinee instead of a projection.
reclaim_case nested_closure_match '"enum Box { Wrap((Int, Int)); Empty }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let unwrap = (e) -> { match e { Wrap(p) => p.0 + p.1, Empty => 0 } }\n    let t = Wrap((i, i + 1))\n    s = s + unwrap(t)\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4 (container-owning-escape via assignment): a projection RHS
# (`keep = box.0`) makes the outer mut `keep` co-own a field of the live local
# container `box`. Without a dup at the assignment, box.0 takes no reference, so
# box.0 escapes into keep while box.0.s recursive drop frees it (16 B/iter leak,
# then a double-free on the next reassign-drop). The guarded dup at the
# assignment gives keep its own reference; its reassign/scope-end drop balances.
reclaim_case escape_assign_proj '"let main: () -> Int = () -> {\n  let mut keep = (0, 0)\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    let box = (t, i)\n    keep = box.0\n    i = i + 1\n  }\n  keep.0\n}"'

# ADR-0055 Stage 4 (local heap-type inference): an UNANNOTATED nested-closure
# param that is unused / borrow-only in its body cannot be proven heap from the
# body, so it used to leak the caller-transferred value (32 B/iter). The
# elaborate_heap_params pass infers it from the CALL SITES: the non-escaping
# local lambda is only ever called with a follow-able-heap arg, so its param is
# heap and the callee drops it.
reclaim_case unused_param_callsite '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let f = (p) -> { 42 }\n    let t = (i, i + 1)\n    s = s + f(t)\n    i = i + 1\n  }\n  s\n}"'

# ADR-0055 Stage 4 (opaque args): the call-site heap inference also classifies a
# constructor call carrying a payload (`f(Wrap((i, i+1)))`) and a call to a
# heap-returning top-level function (`let r = mk(i); f(r)`) as a follow-able heap
# arg, so an otherwise-unprovable unannotated param is dropped.
reclaim_case opaque_ctor_arg '"enum Box { Wrap((Int, Int)); Empty }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let f = (p) -> { 42 }\n    s = s + f(Wrap((i, i + 1)))\n    i = i + 1\n  }\n  s\n}"'
reclaim_case opaque_fncall_arg '"let mk: (Int) -> (Int, Int) = (x) -> {\n  (x, x + 1)\n}\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let f = (p) -> { 42 }\n    let r = mk(i)\n    s = s + f(r)\n    i = i + 1\n  }\n  s\n}"'

# KNOWN PRE-EXISTING GAP (not a regression): a *nested* tuple built in a loop
# (`let t = ((i, i+1), (i+2, i+3))`) fails to compile under RC at BOTH HEAD and
# the Stage-1 baseline — so it is excluded from the reclamation set rather than
# flagged as a failure. Literal nested tuples compile fine (heap-e2e "nested
# tuple field access" passes). This gap matters for Stage 3 (recursive drop of
# nested heap) and should be fixed there; until then it is not measurable here.

echo
if [ "$FAIL" = "0" ]; then
  green "ALL VERIFICATION PASSED"
else
  red "VERIFICATION FAILED"
fi
exit "$FAIL"
