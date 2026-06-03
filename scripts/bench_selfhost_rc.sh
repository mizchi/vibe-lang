#!/usr/bin/env bash
# Throughput + peak-heap benchmark: default (bump, no reclamation) vs RC
# (Perceus recursive drop + free-list) on allocation-heavy loops. ADR-0055
# Stage 5. The payoff of the RC vertical (Stages 1-4) is that nested heap is
# reclaimed, so RC keeps the heap BOUNDED while the default path grows linearly
# with the iteration count; this measures both the memory bound and the
# per-iteration time cost of the rc ops.
#
# Each benchmark `main` runs an N-iteration allocating loop internally and
# returns a checksum; we compile it with compile_wasi (default) and
# compile_wasi_rc (RC), then time a single call + read __heap_ptr for peak heap.
#
# Usage:  bash scripts/bench_selfhost_rc.sh [N] [repeats]
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
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

# Compile one source (given as a vibe expression that builds the source string
# using N) both ways and emit two wasm files. Echoes "<default.wasm> <rc.wasm>".
compile_both() { # name  body_expr
  local name="$1" body="$2"
  local probe="$COMPILER_DIR/_bench_${name}_${STAMP}_test.vibe"
  local wd="/tmp/_bench_${name}_${STAMP}_d.wasm"
  local wr="/tmp/_bench_${name}_${STAMP}_r.wasm"
  TMPFILES+=("$probe" "$wd" "$wr")
  cat > "$probe" <<EOF
import ./codegen_test_support.vibe { compile_wasi, compile_wasi_rc }
import ./core/polyfill.vibe { __to_string }
let emit: () -> Int with { Error, Fs } = () -> {
  let n = $N
  let src = $body
  Fs::write_bytes("$wd", compile_wasi(src, "main"))
  Fs::write_bytes("$wr", compile_wasi_rc(src, "main"))
  0
}
test "emit" { emit(); assert(true) }
EOF
  "$VIBE_BIN" test --no-cache "$probe" >/dev/null 2>&1 || true
  echo "$wd $wr"
}

bench() { # name  body_expr
  local name="$1" body="$2"
  read -r wd wr < <(compile_both "$name" "$body")
  if [ ! -f "$wd" ] || [ ! -f "$wr" ]; then
    printf '  %-16s COMPILE FAILED\n' "$name"; return
  fi
  local jd jr
  jd="$(node scripts/bench_selfhost_rc.mjs "$wd" main "$REPEATS")"
  jr="$(node scripts/bench_selfhost_rc.mjs "$wr" main "$REPEATS")"
  local td hd tr hr
  td="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).median_ms))" "$jd")"
  hd="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).heap_used))" "$jd")"
  tr="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).median_ms))" "$jr")"
  hr="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).heap_used))" "$jr")"
  local ratio hdm hrm
  ratio="$(node -e "console.log((($tr)/($td)).toFixed(2))")"
  hdm="$(node -e "console.log((($hd)/1048576).toFixed(1))")"
  hrm="$(node -e "console.log((($hr)/1048576).toFixed(3))")"
  printf '  %-16s default %8s ms / %7s MB   |   RC %8s ms / %8s MB   (RC time x%s, heap %sx smaller)\n' \
    "$name" "$td" "$hdm" "$tr" "$hrm" "$ratio" \
    "$(node -e "console.log(($hr)==0?'inf':(($hd)/($hr)).toFixed(0))")"
}

echo "== ADR-0055 Stage 5: RC vs default, N=$N iterations, median of $REPEATS =="
echo

bench flat_tuple '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    s = s + t.0\n    i = i + 1\n  }\n  s\n}"'

bench nested_tuple '"let main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = ((i, i + 1), (i + 2, i + 3))\n    let a = t.0\n    let b = t.1\n    s = s + a.0 + b.1\n    i = i + 1\n  }\n  s\n}"'

bench record_tuples '"struct Pair { a: (Int, Int); b: (Int, Int) }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let p = Pair::{ a: (i, i + 1), b: (i + 2, i + 3) }\n    s = s + p.a.0 + p.b.1\n    i = i + 1\n  }\n  s\n}"'

bench enum_tuple '"enum Box { Wrap((Int, Int)); Empty }\nlet main: () -> Int = () -> {\n  let mut s = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let e = Wrap((i, i + 1))\n    s = s + match e {\n      Wrap(p) => p.0 + p.1,\n      Empty => 0\n    }\n    i = i + 1\n  }\n  s\n}"'

echo
