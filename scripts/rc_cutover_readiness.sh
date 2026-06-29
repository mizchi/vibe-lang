#!/usr/bin/env bash
# RC cutover readiness probe (ADR-0055 #493, docs/spec/selfhost-rc-cutover-readiness.md).
#
# The reclaim suite and the heap-e2e gate exercise RC features in ISOLATION;
# cutover (making the Perceus RC path the linear default) needs realistic code
# that MIXES them. This probe compiles a corpus of feature-combined,
# allocation-heavy programs — each a `main()` loop with a fixed N returning a
# checksum — TWO ways: default linear (bump, leaks) and Perceus RC (VIBE_RC=1,
# via the FS-compile path that `vibe run` uses, #701). For each program it
# reports, at two iteration counts N1/N2:
#
#   * rc compiles+runs,
#   * default==RC result parity (correctness under RC on mixed-feature code),
#   * default and RC per-run heap (__heap_ptr delta) and whether RC is BOUNDED
#     (heap(N1) == heap(N2): reclamation, vs scaling with N: a leak).
#
# Exit non-zero (and print the offending rows) if any program fails to compile
# under RC, mismatches the default result, or shows an unbounded RC heap.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI="${VIBE_CLI_WASM:-$ROOT_DIR/dist/cli/vibe-cli.wasm}"
[ -s "$CLI" ] || { echo "rc-cutover-readiness: compiler wasm not found: $CLI (run scripts/build_cli_wasm.sh)" >&2; exit 2; }
MEASURE="$ROOT_DIR/scripts/measure_selfhost_heap.mjs"
[ -s "$MEASURE" ] || { echo "rc-cutover-readiness: $MEASURE missing" >&2; exit 2; }

N1="${RC_PROBE_N1:-1000}"
N2="${RC_PROBE_N2:-11000}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Emit program <name> at iteration count <n> to stdout. Each is a pure main()
# returning an Int checksum; the loop body mixes the named features and is what
# RC must reclaim. NOTE: match arms are comma-separated, enum variants
# semicolon-separated (vibe syntax).
emit_prog() {
  local name="$1" n="$2"
  case "$name" in
    tuple) cat <<EOF
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n { let t = (i, i + 1); acc = acc + t.0 + t.1; i = i + 1 }
  acc
}
EOF
    ;;
    enum_ast) cat <<EOF
enum Tree { Leaf(Int); Node(Tree, Tree) }
let sumt = (t: Tree) -> Int { match t { Leaf(v) => v, Node(l, r) => sumt(l) + sumt(r) } }
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n { let t = Node(Leaf(i), Node(Leaf(i + 1), Leaf(i + 2))); acc = acc + sumt(t); i = i + 1 }
  acc
}
EOF
    ;;
    option_enum) cat <<EOF
enum Opt { Som(Int); Non }
let unwrap_or = (o: Opt, d: Int) -> Int { match o { Som(v) => v, Non => d } }
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n { let o = if i % 2 == 0 { Som(i) } else { Non }; acc = acc + unwrap_or(o, 7); i = i + 1 }
  acc
}
EOF
    ;;
    captured_mut_cell) cat <<EOF
let main = () -> Int {
  let mut sink = 0
  let mut i = 0
  while i < $n { let mut c = 0; let bump = () -> { c = c + 1 }; bump(); bump(); sink = sink + c; i = i + 1 }
  sink
}
EOF
    ;;
    nested_closures) cat <<EOF
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n {
    let mut a = i
    let outer = () -> {
      let inner = () -> { a = a + 1 }
      inner()
      inner()
      a
    }
    acc = acc + outer()
    i = i + 1
  }
  acc
}
EOF
    ;;
    hof) cat <<EOF
let apply2 = (f: (Int) -> Int, x: Int) -> Int { f(f(x)) }
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  let k = 3
  while i < $n { let g = (x: Int) -> { x + k }; acc = acc + apply2(g, i); i = i + 1 }
  acc
}
EOF
    ;;
    record_tuples) cat <<EOF
struct Pair { a: (Int, Int); b: (Int, Int) }
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n { let p = Pair::{ a: (i, i + 1), b: (i + 2, i + 3) }; acc = acc + p.a.0 + p.b.1; i = i + 1 }
  acc
}
EOF
    ;;
    mixed) cat <<EOF
enum Cell { Num(Int); Pair(Int, Int) }
struct Box { c: Cell; t: (Int, Int) }
let val = (b: Box) -> Int { match b.c { Num(v) => v + b.t.0, Pair(x, y) => x + y + b.t.1 } }
let main = () -> Int {
  let mut acc = 0
  let mut i = 0
  while i < $n {
    let b = if i % 2 == 0 { Box::{ c: Num(i), t: (i, i + 1) } } else { Box::{ c: Pair(i, i + 1), t: (i + 2, i + 3) } }
    acc = acc + val(b)
    i = i + 1
  }
  acc
}
EOF
    ;;
  esac
}

PROGRAMS="tuple enum_ast option_enum captured_mut_cell nested_closures hof record_tuples mixed"

# compile <rc:0|1> <src> <out>
compile() {
  local rc="$1" src="$2" out="$3" rcenv=""
  [ "$rc" = 1 ] && rcenv="VIBE_RC=1"
  env $rcenv VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI" "$src" "$out" main >/dev/null 2>&1
}
# field <json> <key>  -> integer value or empty
field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\\([0-9-]*\\).*/\\1/p"; }

printf '%-18s | rc? | parity | def heap        | rc heap (N1/N2)    | bounded\n' "program"
printf -- '-------------------+-----+--------+-----------------+--------------------+--------\n'

fails=0
for p in $PROGRAMS; do
  emit_prog "$p" "$N1" > "$WORK/$p.n1.vibe"
  emit_prog "$p" "$N2" > "$WORK/$p.n2.vibe"
  # default at N1 (for parity) and RC at N1/N2
  compile 0 "$WORK/$p.n1.vibe" "$WORK/$p.d1.wasm"
  compile 1 "$WORK/$p.n1.vibe" "$WORK/$p.r1.wasm"
  compile 1 "$WORK/$p.n2.vibe" "$WORK/$p.r2.wasm"
  if [ ! -s "$WORK/$p.r1.wasm" ] || [ ! -s "$WORK/$p.r2.wasm" ]; then
    printf '%-18s | NO  | -      | -               | -                  | -\n' "$p"
    fails=$((fails+1)); continue
  fi
  dj1="$(node "$MEASURE" "$WORK/$p.d1.wasm" main 2>/dev/null)"
  rj1="$(node "$MEASURE" "$WORK/$p.r1.wasm" main 2>/dev/null)"
  rj2="$(node "$MEASURE" "$WORK/$p.r2.wasm" main 2>/dev/null)"
  dres="$(field "$dj1" result)"; rres="$(field "$rj1" result)"
  dheap="$(field "$dj1" heap_used)"
  rheap1="$(field "$rj1" heap_used)"; rheap2="$(field "$rj2" heap_used)"
  if [ -z "$rres" ] || [ -z "$rheap1" ] || [ -z "$rheap2" ]; then
    # compiled but the RC build trapped/failed at run (empty measure output).
    printf '%-18s | yes | RUN-FAIL | %-15s | (rc run trapped)    | -\n' "$p" "$dheap"
    fails=$((fails+1)); continue
  fi
  parity="OK"; [ "$dres" = "$rres" ] || parity="MISMATCH"
  bounded="yes"; [ "$rheap1" = "$rheap2" ] || bounded="NO"
  printf '%-18s | yes | %-6s | %-15s | %-18s | %s\n' \
    "$p" "$parity" "$dheap" "$rheap1/$rheap2" "$bounded"
  [ "$parity" = "OK" ] || fails=$((fails+1))
  [ "$bounded" = "yes" ] || fails=$((fails+1))
done

echo
if [ "$fails" -eq 0 ]; then
  echo "rc-cutover-readiness: READY — all programs compile under RC, parity holds, RC heap bounded (N1=$N1 N2=$N2)"
  exit 0
else
  echo "rc-cutover-readiness: NOT READY — $fails issue(s) above (RC-compile-fail / parity MISMATCH / heap NO-bounded)"
  exit 1
fi
