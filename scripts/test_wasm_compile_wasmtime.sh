#!/bin/bash
# E2E tests: compile .vibe to .wasm and run with wasmtime
# Covers general language features (arithmetic, functions, loops, closures, etc.)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="/tmp/vibe_wasm_wasmtime_e2e_$$"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

log_pass() {
  echo -e "${GREEN}PASS${NC}: $1"
  PASSED=$((PASSED + 1))
}

log_fail() {
  echo -e "${RED}FAIL${NC}: $1"
  FAILED=$((FAILED + 1))
}

log_info() {
  echo -e "${YELLOW}INFO${NC}: $1"
}

# Build the CLI first
log_info "Building vibe CLI..."
cd "$PROJECT_ROOT"
moon build src/cmd/vibe/main.mbt --target native -q 2>/dev/null || {
  log_fail "Failed to build vibe CLI"
  exit 1
}

VIBE="moon run src/cmd/vibe/main.mbt --target native --"

# Helper: compile .vibe to .wasm, run with wasmtime, compare untagged result
expect_wasmtime_result() {
  local test_name="$1"
  local vibe_code="$2"
  local expected_value="$3"

  echo "$vibe_code" > "$TMP_DIR/test.vibe"

  if ! $VIBE compile --wasm "$TMP_DIR/test.vibe" -o "$TMP_DIR/test.wasm" 2>/dev/null; then
    log_fail "$test_name - compilation failed"
    return
  fi

  local wasm_tagged
  wasm_tagged=$("$WASMTIME_RUN" --invoke run "$TMP_DIR/test.wasm" 2>/dev/null | grep -v "^warning") || true

  if [ -z "$wasm_tagged" ]; then
    log_fail "$test_name - wasmtime returned no output"
    return
  fi

  local result=$((wasm_tagged >> 2))

  if [ "$result" = "$expected_value" ]; then
    log_pass "$test_name (result: $expected_value)"
  else
    log_fail "$test_name - expected $expected_value but got $result (tagged: $wasm_tagged)"
  fi
}

echo "========================================"
echo "WASM compile → wasmtime E2E Tests"
echo "========================================"
echo ""

# ============================================
# Basic Arithmetic
# ============================================
log_info "Testing basic arithmetic..."

expect_wasmtime_result "addition" \
'1 + 2' \
"3"

expect_wasmtime_result "subtraction" \
'10 - 3' \
"7"

expect_wasmtime_result "multiplication" \
'4 * 5' \
"20"

expect_wasmtime_result "integer division" \
'10 / 3' \
"3"

expect_wasmtime_result "modulo" \
'10 % 3' \
"1"

expect_wasmtime_result "operator precedence" \
'1 + 2 * 3' \
"7"

expect_wasmtime_result "parenthesized expression" \
'(1 + 2) * 3' \
"9"

expect_wasmtime_result "negative numbers" \
'0 - 5 + 8' \
"3"

echo ""

# ============================================
# Comparison Operators
# ============================================
log_info "Testing comparison operators..."

expect_wasmtime_result "greater than (true)" \
'if 5 > 3 { 1 } else { 0 }' \
"1"

expect_wasmtime_result "greater than (false)" \
'if 3 > 5 { 1 } else { 0 }' \
"0"

expect_wasmtime_result "less than" \
'if 2 < 10 { 1 } else { 0 }' \
"1"

expect_wasmtime_result "equal" \
'if 5 == 5 { 1 } else { 0 }' \
"1"

expect_wasmtime_result "not equal" \
'if 5 != 3 { 1 } else { 0 }' \
"1"

expect_wasmtime_result "greater or equal" \
'if 5 >= 5 { 1 } else { 0 }' \
"1"

expect_wasmtime_result "less or equal" \
'if 3 <= 5 { 1 } else { 0 }' \
"1"

echo ""

# ============================================
# If Expressions
# ============================================
log_info "Testing if expressions..."

expect_wasmtime_result "if true" \
'if true { 10 } else { 20 }' \
"10"

expect_wasmtime_result "if false" \
'if false { 10 } else { 20 }' \
"20"

expect_wasmtime_result "nested if" \
'let x = 5
if x > 0 {
  if x > 3 { 1 } else { 2 }
} else {
  3
}' \
"1"

echo ""

# ============================================
# Let Bindings / Mutable Variables
# ============================================
log_info "Testing let bindings and mutable variables..."

expect_wasmtime_result "let binding" \
'let x = 5
let y = 3
x + y' \
"8"

expect_wasmtime_result "multiple let bindings" \
'let a = 1
let b = 2
let c = 3
let d = 4
let e = 5
a + b + c + d + e' \
"15"

expect_wasmtime_result "mutable variable" \
'let mut x = 1
x = x + 1
x = x * 2
x' \
"4"

expect_wasmtime_result "mutable variable reassignment" \
'let mut x = 10
x = x - 3
x = x * 2
x + 1' \
"15"

echo ""

# ============================================
# While Loop
# ============================================
log_info "Testing while loops..."

expect_wasmtime_result "while loop sum" \
'let mut i = 0
let mut sum = 0
while i < 5 {
  sum = sum + i
  i = i + 1
}
sum' \
"10"

expect_wasmtime_result "while loop factorial" \
'let mut n = 5
let mut result = 1
while n > 0 {
  result = result * n
  n = n - 1
}
result' \
"120"

echo ""

# ============================================
# Function Definition & Call
# ============================================
log_info "Testing function definition and call..."

expect_wasmtime_result "simple function call" \
'let add = (a: Int, b: Int) -> Int { a + b }
add(3, 4)' \
"7"

expect_wasmtime_result "function with body" \
'let double = (x: Int) -> Int { x * 2 }
double(21)' \
"42"

expect_wasmtime_result "multiple function calls" \
'let square = (x: Int) -> Int { x * x }
square(3) + square(4)' \
"25"

echo ""

# ============================================
# Closures
# ============================================
log_info "Testing closures..."

expect_wasmtime_result "closure capturing outer variable" \
'let n = 5
let add_n = (x: Int) -> Int { x + n }
add_n(10)' \
"15"

expect_wasmtime_result "closure capturing multiple variables" \
'let a = 2
let b = 3
let compute = (x: Int) -> Int { x * a + b }
compute(5)' \
"13"

echo ""

# ============================================
# Recursive Functions
# ============================================
log_info "Testing recursive functions..."

expect_wasmtime_result "recursive fibonacci" \
'let rec fib = (n: Int) -> Int {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}
fib(10)' \
"55"

expect_wasmtime_result "recursive factorial" \
'let rec fact = (n: Int) -> Int {
  if n <= 1 { 1 } else { n * fact(n - 1) }
}
fact(6)' \
"720"

echo ""

# ============================================
# Match Expressions
# ============================================
log_info "Testing match expressions..."

expect_wasmtime_result "match int literal" \
'let x = 3
match x {
  1 => 10
  2 => 20
  3 => 30
  _ => 0
}' \
"30"

expect_wasmtime_result "match wildcard" \
'match 99 {
  1 => 10
  2 => 20
  _ => 0
}' \
"0"

expect_wasmtime_result "match bool true" \
'match true {
  true => 1
  _ => 0
}' \
"1"

expect_wasmtime_result "match bool false" \
'match false {
  true => 1
  _ => 0
}' \
"0"

expect_wasmtime_result "match Option Some" \
'match Some(42) {
  Some(x) => x
  _ => 0
}' \
"42"

expect_wasmtime_result "match Option None" \
'match None {
  Some(x) => x
  _ => 99
}' \
"99"

echo ""

# ============================================
# Tuple Destructuring
# ============================================
log_info "Testing tuple destructuring..."

expect_wasmtime_result "tuple let destructuring" \
'let (a, b, c) = (1, 2, 3)
a + b + c' \
"6"

expect_wasmtime_result "nested tuple destructuring" \
'let (a, (b, c)) = (1, (2, 3))
a + b + c' \
"6"

expect_wasmtime_result "tuple in match" \
'match (1, 2) {
  (a, b) => a * b
  _ => 0
}' \
"2"

echo ""

# ============================================
# Nested Functions
# ============================================
log_info "Testing nested functions..."

expect_wasmtime_result "nested function" \
'let outer = (x: Int) -> Int {
  let inner = (y: Int) -> Int { y * 2 }
  inner(x) + 1
}
outer(5)' \
"11"

expect_wasmtime_result "nested function with capture" \
'let make_adder = (n: Int) -> (Int) -> Int {
  (x: Int) -> Int { x + n }
}
let add5 = make_adder(5)
add5(10)' \
"15"

echo ""

# ============================================
# Block Expressions
# ============================================
log_info "Testing block expressions..."

expect_wasmtime_result "block expression" \
'let x = {
  let a = 3
  let b = 4
  a + b
}
x' \
"7"

expect_wasmtime_result "nested block expression" \
'let x = {
  let a = {
    let b = 2
    b * 3
  }
  a + 1
}
x' \
"7"

echo ""

# ============================================
# Bit Operations
# ============================================
log_info "Testing bit operations..."

expect_wasmtime_result "bitwise AND" \
'12 & 10' \
"8"

expect_wasmtime_result "bitwise OR" \
'12 | 3' \
"15"

expect_wasmtime_result "bitwise XOR" \
'12 ^ 10' \
"6"

expect_wasmtime_result "left shift" \
'1 << 4' \
"16"

expect_wasmtime_result "right shift" \
'32 >> 2' \
"8"

echo ""

# ============================================
# Boolean Operations
# ============================================
log_info "Testing boolean operations..."

expect_wasmtime_result "and operation" \
'let a = true
let b = false
if a && not(b) { 1 } else { 0 }' \
"1"

expect_wasmtime_result "or operation" \
'if false || true { 1 } else { 0 }' \
"1"

echo ""

# ============================================
# Or Patterns
# ============================================
log_info "Testing or patterns..."

expect_wasmtime_result "or pattern (match)" \
'match 2 { 1 | 2 | 3 => 100, _ => 0 }' \
"100"

expect_wasmtime_result "or pattern (no match)" \
'match 5 { 1 | 2 | 3 => 100, _ => 0 }' \
"0"

echo ""

# ============================================
# Record Patterns
# ============================================
log_info "Testing record patterns..."

expect_wasmtime_result "record let destructuring" \
'let record { x: a, y: b } = record { x: 10, y: 20 }
a + b' \
"30"

expect_wasmtime_result "record match" \
'match record { a: 1, b: 2 } {
  record { a: x, b: y } => x + y
  _ => 0
}' \
"3"

expect_wasmtime_result "record wildcard field" \
'let record { x: a, y: _ } = record { x: 10, y: 20 }
a' \
"10"

echo ""

# ============================================
# Nested / Complex Patterns
# ============================================
log_info "Testing nested and complex patterns..."

expect_wasmtime_result "nested Option-tuple: Some((a, b))" \
'match Some((1, 2)) {
  Some((a, b)) => a + b
  _ => 0
}' \
"3"

expect_wasmtime_result "tuple of Options: (Some(a), None)" \
'match (Some(10), None) {
  (Some(a), None) => a
  _ => 0
}' \
"10"

expect_wasmtime_result "let Some destructuring" \
'let Some(x) = Some(100)
x' \
"100"

expect_wasmtime_result "wildcard in tuple" \
'let (a, _, c) = (1, 2, 3)
a + c' \
"4"

expect_wasmtime_result "deeply nested tuple" \
'let (a, (b, (c, d))) = (1, (2, (3, 4)))
a + b + c + d' \
"10"

expect_wasmtime_result "match with computation in arms" \
'let x = 3
match x {
  1 => { let a = 10; a * 2 }
  2 => { let a = 20; a * 2 }
  3 => { let a = 30; a * 2 }
  _ => 0
}' \
"60"

echo ""

# ============================================
# Higher-Order Functions
# ============================================
log_info "Testing higher-order functions..."

expect_wasmtime_result "function as argument" \
'let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
let double = (x: Int) -> Int { x * 2 }
apply(double, 21)' \
"42"

# NOTE: currying with prelude names (mul, add, sub, etc.) fails because
# the checker drops `let mul = ...` when the name shadows a prelude function.
# Use non-prelude names (e.g., make_multiplier) to work around this.

expect_wasmtime_result "currying (non-prelude name)" \
'let make_multiplier = (a: Int) -> (Int) -> Int {
  (b: Int) -> Int { a * b }
}
let triple = make_multiplier(3)
triple(7)' \
"21"

expect_wasmtime_result "compose closures" \
'let inc = (x: Int) -> Int { x + 1 }
let dbl = (x: Int) -> Int { x + x }
let compose = (f: (Int) -> Int, g: (Int) -> Int) -> (Int) -> Int {
  (x: Int) -> Int { f(g(x)) }
}
let dbl_inc = compose(dbl, inc)
dbl_inc(5)' \
"12"

expect_wasmtime_result "apply twice" \
'let apply_twice = (f: (Int) -> Int, x: Int) -> Int { f(f(x)) }
let inc = (x: Int) -> Int { x + 1 }
apply_twice(inc, 10)' \
"12"

expect_wasmtime_result "function selecting function" \
'let dbl = (x: Int) -> Int { x * 2 }
let sqr = (x: Int) -> Int { x * x }
let pick = (use_dbl: Bool) -> (Int) -> Int {
  if use_dbl { dbl } else { sqr }
}
let f = pick(false)
f(5)' \
"25"

echo ""

# ============================================
# Complex Recursion
# ============================================
log_info "Testing complex recursion..."

expect_wasmtime_result "recursive GCD" \
'let rec gcd = (a: Int, b: Int) -> Int {
  if b == 0 { a } else { gcd(b, a % b) }
}
gcd(48, 18)' \
"6"

expect_wasmtime_result "recursive power" \
'let rec pow = (base: Int, exp: Int) -> Int {
  if exp == 0 { 1 } else { base * pow(base, exp - 1) }
}
pow(2, 10)' \
"1024"

expect_wasmtime_result "recursive sum of digits" \
'let rec sum_digits = (n: Int) -> Int {
  if n < 10 { n } else { n % 10 + sum_digits(n / 10) }
}
sum_digits(12345)' \
"15"

echo ""

# ============================================
# Complex Closures
# ============================================
log_info "Testing complex closures..."

expect_wasmtime_result "closure over loop result" \
'let mut total = 0
let mut i = 1
while i <= 10 {
  total = total + i
  i = i + 1
}
let get_total = () -> Int { total }
get_total()' \
"55"

expect_wasmtime_result "multiple closures sharing scope" \
'let base = 100
let add_base = (x: Int) -> Int { x + base }
let sub_base = (x: Int) -> Int { x - base }
add_base(50) + sub_base(200)' \
"250"

expect_wasmtime_result "closure chain (3 levels)" \
'let a = 1
let f = () -> Int {
  let b = 2
  let g = () -> Int {
    let c = 3
    a + b + c
  }
  g()
}
f()' \
"6"

echo ""

# ============================================
# Nested Loops & Complex Control Flow
# ============================================
log_info "Testing nested loops and complex control flow..."

expect_wasmtime_result "nested while loops (multiplication table sum)" \
'let mut sum = 0
let mut i = 1
while i <= 3 {
  let mut j = 1
  while j <= 3 {
    sum = sum + i * j
    j = j + 1
  }
  i = i + 1
}
sum' \
"36"

expect_wasmtime_result "loop with conditional accumulation" \
'let mut i = 0
let mut even_sum = 0
let mut odd_sum = 0
while i < 10 {
  if i % 2 == 0 {
    even_sum = even_sum + i
  } else {
    odd_sum = odd_sum + i
  }
  i = i + 1
}
even_sum * odd_sum' \
"500"

expect_wasmtime_result "iterative fibonacci" \
'let mut a = 0
let mut b = 1
let mut i = 0
while i < 10 {
  let tmp = a + b
  a = b
  b = tmp
  i = i + 1
}
a' \
"55"

echo ""

# ============================================
# Match with Multiple Complex Arms
# ============================================
log_info "Testing complex match patterns..."

expect_wasmtime_result "match calling functions in arms" \
'let square = (x: Int) -> Int { x * x }
let cube = (x: Int) -> Int { x * x * x }
let op = 2
match op {
  1 => square(5)
  2 => cube(3)
  _ => 0
}' \
"27"

expect_wasmtime_result "match result used in computation" \
'let x = 5
let y = match x {
  1 => 10
  5 => 50
  _ => 0
}
y * 2 + 1' \
"101"

expect_wasmtime_result "nested match" \
'let x = Some(3)
match x {
  Some(n) => match n {
    1 => 10
    2 => 20
    3 => 30
    _ => 0
  }
  _ => 0
}' \
"30"

expect_wasmtime_result "match with tuple construction" \
'let classify = (n: Int) -> Int {
  match (n > 0, n % 2 == 0) {
    (true, true) => 1
    (true, false) => 2
    _ => 0
  }
}
classify(7) * 10 + classify(4)' \
"21"

echo ""

# ============================================
# Complex Combinations
# ============================================
log_info "Testing complex combinations..."

expect_wasmtime_result "recursive with closure" \
'let multiplier = 3
let rec apply_n = (f: (Int) -> Int, n: Int, x: Int) -> Int {
  if n == 0 { x } else { apply_n(f, n - 1, f(x)) }
}
let add_mul = (x: Int) -> Int { x + multiplier }
apply_n(add_mul, 4, 0)' \
"12"

expect_wasmtime_result "loop building result used in match" \
'let mut sum = 0
let mut i = 1
while i <= 5 {
  sum = sum + i
  i = i + 1
}
match sum {
  10 => 0
  15 => 1
  _ => 2
}' \
"1"

expect_wasmtime_result "functions with pattern destructuring" \
'let sum_pair = (p: (Int, Int)) -> Int {
  let (a, b) = p
  a + b
}
let x = (10, 20)
let y = (30, 40)
sum_pair(x) + sum_pair(y)' \
"100"

expect_wasmtime_result "collatz steps" \
'let rec collatz = (n: Int, steps: Int) -> Int {
  if n == 1 { steps }
  else if n % 2 == 0 { collatz(n / 2, steps + 1) }
  else { collatz(3 * n + 1, steps + 1) }
}
collatz(27, 0)' \
"111"

echo ""

# ============================================
# Summary
# ============================================
echo "========================================"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "========================================"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
