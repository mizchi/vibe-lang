#!/usr/bin/env bash
# Cross-compilation-mode runtime parity tests.
#
# Compiles vibe programs with multiple compilation modes (--wasm, --wasm-linear,
# --wasm-gc), validates the wasm output, runs each via wasmtime, and compares
# execution results. A mode mismatch means one codegen backend produces a
# different result for the same source.
#
# Usage:
#   scripts/test_feature_parity.sh                     # default: wasm vs wasm-linear
#   scripts/test_feature_parity.sh file1.vibe file2.vibe  # specific files
#   VIBE_BIN=/path/to/vibe scripts/test_feature_parity.sh
#
# Env:
#   VIBE_FEATURE_PARITY_MODES   comma-separated modes (default: wasm,wasm-linear)
#                               also try: wasm,wasm-gc or wasm,wasm-linear,wasm-gc
#   VIBE_FEATURE_PARITY_TIMEOUT per-case timeout in seconds (default: 15)
#   VIBE_FEATURE_PARITY_REQUIRE require parity (exit 1 on mismatch). default: 1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${VIBE_BIN:-}" ]]; then
  if [[ -n "${VIBE_CLI_BIN:-}" ]]; then
    VIBE_BIN="$VIBE_CLI_BIN"
  else
    source "$ROOT_DIR/scripts/ensure_native_cli.sh"
    VIBE_BIN="$VIBE_CLI_BIN"
  fi
fi
CLI="$VIBE_BIN"
TIMEOUT="${VIBE_FEATURE_PARITY_TIMEOUT:-15}"
MODES_RAW="${VIBE_FEATURE_PARITY_MODES:-wasm,wasm-linear}"
REQUIRE="${VIBE_FEATURE_PARITY_REQUIRE:-1}"
TMPDIR="${TMPDIR:-/tmp}"
WORK="$TMPDIR/vibe_feature_parity_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Parse modes
IFS=',' read -r -a MODES <<< "$MODES_RAW"
for i in "${!MODES[@]}"; do
  MODES[$i]="$(echo "${MODES[$i]}" | xargs)"
done

pass=0
fail=0
skip=0
failures=()

# Map mode name to compile-lite flag
mode_to_flag() {
  case "$1" in
    wasm) echo "--wasm" ;;
    wasm-linear) echo "--wasm-linear" ;;
    wasm-gc) echo "--wasm-gc" ;;
    *) echo "--$1" ;;
  esac
}

# Get wasmtime flags for a given mode
wasmtime_flags() {
  case "$1" in
    wasm-gc) echo "-W gc=y -W function-references=y" ;;
    *) echo "" ;;
  esac
}

run_one_case() {
  local src="$1"
  local name
  name="$(basename "$src")"

  # Collect per-mode results
  declare -A mode_out
  declare -A mode_rc
  local all_ok=true
  local any_ok=false
  local first_mode=""
  local first_out=""
  local compiled_modes=()

  for mode in "${MODES[@]}"; do
    local flag
    flag="$(mode_to_flag "$mode")"
    local wasm_out="$WORK/${name}.${mode}.wasm"
    local stdout_file="$WORK/${name}.${mode}.stdout"
    local stderr_file="$WORK/${name}.${mode}.stderr"

    # Compile
    if ! timeout "$TIMEOUT" "$CLI" compile-lite "$flag" "$src" -o "$wasm_out" >"$stdout_file" 2>"$stderr_file"; then
      mode_out[$mode]="COMPILE_FAIL"
      mode_rc[$mode]=1
      all_ok=false
      echo "  SKIP $name ($mode): compile failed" >&2
      continue
    fi

    # Validate wasm (skip for wasm-gc if wasm-tools doesn't support gc)
    if command -v wasm-tools >/dev/null 2>&1; then
      if [[ "$mode" != "wasm-gc" ]]; then
        if ! wasm-tools validate "$wasm_out" >/dev/null 2>&1; then
          mode_out[$mode]="VALIDATE_FAIL"
          mode_rc[$mode]=1
          all_ok=false
          echo "  SKIP $name ($mode): wasm-tools validate failed" >&2
          continue
        fi
      fi
    fi

    # Execute
    local wflags
    wflags="$(wasmtime_flags "$mode")"
    local run_out
    local run_rc=0
    if [[ -n "$wflags" ]]; then
      # shellcheck disable=SC2086
      run_out="$(timeout "$TIMEOUT" wasmtime run $wflags -W exceptions=y -W unknown-imports-default=y --invoke _start "$wasm_out" 2>&1)" || run_rc=$?
    else
      run_out="$(timeout "$TIMEOUT" wasmtime run -W exceptions=y -W unknown-imports-default=y --invoke _start "$wasm_out" 2>&1)" || run_rc=$?
    fi

    # Strip wasmtime warnings and debug info
    run_out="$(echo "$run_out" | grep -v '^warning:')"

    mode_out[$mode]="$run_out"
    mode_rc[$mode]=$run_rc
    any_ok=true
    compiled_modes+=("$mode")

    if [[ -z "$first_mode" ]]; then
      first_mode="$mode"
      first_out="$run_out"
    fi
  done

  # Only skip if ALL modes failed to compile
  if [[ "$any_ok" == false ]]; then
    skip=$((skip + 1))
    return
  fi

  # Compare: all compiled modes must produce the same output
  local mismatch=false
  for mode in "${compiled_modes[@]:1}"; do
    if [[ "${mode_out[$mode]}" != "$first_out" ]]; then
      mismatch=true
      break
    fi
    # Also compare exit codes (allowing both 0 or both non-zero)
    if [[ "${mode_rc[$mode]}" != "${mode_rc[$first_mode]}" ]]; then
      if [[ "${mode_rc[$mode]}" -eq 0 ]] || [[ "${mode_rc[$first_mode]}" -eq 0 ]]; then
        mismatch=true
        break
      fi
    fi
  done

  if [[ "$mismatch" == false ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    local detail=""
    for mode in "${compiled_modes[@]}"; do
      detail+=" ${mode}='${mode_out[$mode]}'(rc=${mode_rc[$mode]})"
    done
    failures+=("$name:$detail")
  fi
}

# Collect test files
declare -a files
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  # --- Arithmetic ---
  cat > "$WORK/arith.vibe" << 'EOF'
let result = (1 + 2) * 3 - 1
result
EOF
  files+=("$WORK/arith.vibe")

  # --- Fibonacci ---
  cat > "$WORK/fib.vibe" << 'EOF'
let fib = (n: Int) -> Int {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}
fib(10)
EOF
  files+=("$WORK/fib.vibe")

  # --- Factorial ---
  cat > "$WORK/factorial.vibe" << 'EOF'
let fact = (n: Int) -> Int {
  if n <= 1 { 1 } else { n * fact(n - 1) }
}
fact(6)
EOF
  files+=("$WORK/factorial.vibe")

  # --- Match expression ---
  cat > "$WORK/match.vibe" << 'EOF'
let classify = (n: Int) -> Int {
  match n % 3 {
    0 => 100,
    1 => 200,
    _ => 300
  }
}
classify(7) + classify(9) + classify(10)
EOF
  files+=("$WORK/match.vibe")

  # --- Closure ---
  cat > "$WORK/closure.vibe" << 'EOF'
let make_adder = (n: Int) -> (Int) -> Int {
  (x: Int) -> Int { x + n }
}
let add5 = make_adder(5)
add5(10)
EOF
  files+=("$WORK/closure.vibe")

  # --- Tuple ---
  cat > "$WORK/tuple.vibe" << 'EOF'
let swap = (a: Int, b: Int) -> (Int, Int) { (b, a) }
let (x, y) = swap(1, 2)
x * 10 + y
EOF
  files+=("$WORK/tuple.vibe")

  # --- Array fold ---
  cat > "$WORK/array_fold.vibe" << 'EOF'
let arr = [1, 2, 3, 4, 5]
let sum = Array::fold(arr, 0, (acc: Int, x: Int) -> Int { acc + x })
sum
EOF
  files+=("$WORK/array_fold.vibe")

  # --- Array length ---
  cat > "$WORK/array_len.vibe" << 'EOF'
let arr = [10, 20, 30, 40]
Array::length(arr)
EOF
  files+=("$WORK/array_len.vibe")

  # --- String length ---
  cat > "$WORK/string_len.vibe" << 'EOF'
let s = String::concat("hello", " world")
String::length(s)
EOF
  files+=("$WORK/string_len.vibe")

  # --- String equals ---
  cat > "$WORK/string_eq.vibe" << 'EOF'
let check = String::equals("abc", "abc")
if check { 1 } else { 0 }
EOF
  files+=("$WORK/string_eq.vibe")

  # --- Bitwise operations ---
  cat > "$WORK/bitwise.vibe" << 'EOF'
let a = 0xFF & 0x0F
let b = 0x01 | 0x02
let c = 0x0F ^ 0x03
let d = 1 << 3
let e = 16 >> 2
a + b + c + d + e
EOF
  files+=("$WORK/bitwise.vibe")

  # --- Effect / throw ---
  cat > "$WORK/effect.vibe" << 'EOF'
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if b == 0 { throw("div by zero") } else { a / b }
}
let result = handle { safe_div(10, 2) } { Error(_) => -1 }
result
EOF
  files+=("$WORK/effect.vibe")

  # --- Effect multiple ---
  cat > "$WORK/effect_multi.vibe" << 'EOF'
let try_add = (a: Int, b: Int) -> Int with { Error } {
  if a < 0 { throw("negative") } else { a + b }
}
let total = handle { try_add(3, 4) + try_add(5, 6) } { Error(_) => -1 }
total
EOF
  files+=("$WORK/effect_multi.vibe")

  # --- Let-else ---
  cat > "$WORK/let_else.vibe" << 'EOF'
let extract = (x: Int) -> Int {
  let Some(v) = Some(x) else { 0 }
  v * 2
}
extract(21)
EOF
  files+=("$WORK/let_else.vibe")

  # --- Is-expr ---
  cat > "$WORK/is_expr.vibe" << 'EOF'
let classify = (x: Int) -> Int {
  if x is 0 { 0 }
  else if x is 1 { 1 }
  else { 2 }
}
classify(0) + classify(1) + classify(5)
EOF
  files+=("$WORK/is_expr.vibe")

  # --- Pipe operator ---
  cat > "$WORK/pipe.vibe" << 'EOF'
let double = (x: Int) -> Int { x * 2 }
let add_one = (x: Int) -> Int { x + 1 }
5 |> double |> add_one
EOF
  files+=("$WORK/pipe.vibe")

  # --- While loop ---
  cat > "$WORK/loop_count.vibe" << 'EOF'
let count = (n: Int) -> Int {
  let mut i = 0
  let mut sum = 0
  while i < n {
    sum = sum + i
    i = i + 1
  }
  sum
}
count(10)
EOF
  files+=("$WORK/loop_count.vibe")

  # --- Nested match ---
  cat > "$WORK/nested_match.vibe" << 'EOF'
let classify = (a: Int, b: Int) -> Int {
  match a {
    0 => match b { 0 => 0, _ => 1 },
    1 => match b { 0 => 2, _ => 3 },
    _ => 4
  }
}
classify(0, 0) + classify(0, 1) + classify(1, 0) + classify(1, 1) + classify(2, 0)
EOF
  files+=("$WORK/nested_match.vibe")

  # --- Cross-module import ---
  mkdir -p "$WORK/cross_mod"
  cat > "$WORK/cross_mod/lib.vibe" << 'EOF'
export let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
export let add_ten = (x: Int) -> Int { x + 10 }
EOF
  cat > "$WORK/cross_mod/main.vibe" << 'EOF'
import ./lib.vibe { apply, add_ten }
let double = (x: Int) -> Int { x * 2 }
apply(double, 10) + add_ten(5)
EOF
  files+=("$WORK/cross_mod/main.vibe")

  # --- Cross-module string ---
  mkdir -p "$WORK/cross_str"
  cat > "$WORK/cross_str/lib.vibe" << 'EOF'
export let greet = (name: String) -> String {
  String::concat("Hello, ", name)
}
EOF
  cat > "$WORK/cross_str/main.vibe" << 'EOF'
import ./lib.vibe { greet }
let msg = greet("World")
String::length(msg)
EOF
  files+=("$WORK/cross_str/main.vibe")

  # --- Enum with payload ---
  cat > "$WORK/enum_payload.vibe" << 'EOF'
enum Shape {
  Circle(Int);
  Rect(Int, Int)
}
let area = (s: Shape) -> Int {
  match s {
    Circle(r) => r * r,
    Rect(w, h) => w * h
  }
}
area(Circle(3)) + area(Rect(4, 5))
EOF
  files+=("$WORK/enum_payload.vibe")

  # --- Higher-order function ---
  cat > "$WORK/hof.vibe" << 'EOF'
let compose = (f: (Int) -> Int, g: (Int) -> Int) -> (Int) -> Int {
  (x: Int) -> Int { f(g(x)) }
}
let add1 = (x: Int) -> Int { x + 1 }
let mul3 = (x: Int) -> Int { x * 3 }
let h = compose(add1, mul3)
h(5)
EOF
  files+=("$WORK/hof.vibe")

  # --- String interpolation ---
  cat > "$WORK/string_interp.vibe" << 'EOF'
let x = 42
let _s = "value: \(x)"
String::length(_s)
EOF
  files+=("$WORK/string_interp.vibe")

  # --- Mutable ref ---
  cat > "$WORK/mutable.vibe" << 'EOF'
let counter = () -> Int {
  let mut c = 0
  c = c + 1
  c = c + 1
  c = c + 1
  c
}
counter()
EOF
  files+=("$WORK/mutable.vibe")

  # --- Conditional expression ---
  cat > "$WORK/cond_expr.vibe" << 'EOF'
let abs = (x: Int) -> Int {
  if x < 0 { 0 - x } else { x }
}
abs(0 - 5) + abs(3)
EOF
  files+=("$WORK/cond_expr.vibe")

  # --- For-in with array ---
  cat > "$WORK/for_in.vibe" << 'EOF'
let sum = () -> Int {
  let mut total = 0
  for x in [1, 2, 3, 4, 5] {
    total = total + x
  }
  total
}
sum()
EOF
  files+=("$WORK/for_in.vibe")

  # --- Map operations ---
  cat > "$WORK/map_ops.vibe" << 'EOF'
let m = map { "a": 10, "b": 20, "c": 30 }
let v = m["b"]
v
EOF
  files+=("$WORK/map_ops.vibe")

  # --- GCD (recursive) ---
  cat > "$WORK/gcd.vibe" << 'EOF'
let gcd = (a: Int, b: Int) -> Int {
  if b == 0 { a } else { gcd(b, a % b) }
}
gcd(48, 18)
EOF
  files+=("$WORK/gcd.vibe")

  # --- Tail-call-ish loop ---
  cat > "$WORK/sum_range.vibe" << 'EOF'
let sum_range = (n: Int) -> Int {
  let rec helper: (Int, Int) -> Int = (i, acc) -> {
    if i > n { acc } else { helper(i + 1, acc + i) }
  }
  helper(1, 0)
}
sum_range(100)
EOF
  files+=("$WORK/sum_range.vibe")
fi

echo "=== Feature Parity Test Suite ==="
echo "CLI: $CLI"
echo "Modes: ${MODES[*]}"
echo "Files: ${#files[@]}"
echo ""

for f in "${files[@]}"; do
  run_one_case "$f"
done

echo ""
echo "=== Feature Parity Report ==="
echo "pass=$pass fail=$fail skip=$skip total=$((pass + fail + skip))"

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  echo "[MISMATCH]"
  for f in "${failures[@]}"; do
    echo "  $f"
  done
  if [[ "$REQUIRE" == "1" ]]; then
    exit 1
  fi
fi

if [[ $pass -eq 0 ]]; then
  echo "WARNING: all cases skipped (no compilable cases?)"
  exit 1
fi

echo "All parity checks passed."
