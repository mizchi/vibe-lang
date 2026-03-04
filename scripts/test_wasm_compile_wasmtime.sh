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

# Build the CLI if VIBE_BIN is not set
cd "$PROJECT_ROOT"
if [ -n "${VIBE_BIN:-}" ] && [ -x "$VIBE_BIN" ]; then
  VIBE="$VIBE_BIN"
  log_info "Using VIBE_BIN=$VIBE_BIN"
else
  log_info "Building vibe CLI..."
  moon build src/cmd/vibe/main.mbt --target native -q 2>/dev/null || {
    log_fail "Failed to build vibe CLI"
    exit 1
  }
  VIBE="moon run src/cmd/vibe/main.mbt --target native --"
fi

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
# Record Field Access (dot notation)
# ============================================
log_info "Testing record field access..."

expect_wasmtime_result "record dot: first field" \
'let r = record { x: 10, y: 20 }
r.x' \
"10"

expect_wasmtime_result "record dot: second field" \
'let r = record { x: 10, y: 20 }
r.y' \
"20"

expect_wasmtime_result "record dot: sum of fields" \
'let r = record { x: 10, y: 20 }
r.x + r.y' \
"30"

expect_wasmtime_result "record dot: 3 fields" \
'let r = record { a: 1, b: 2, c: 3 }
r.a + r.b + r.c' \
"6"

expect_wasmtime_result "record dot: single field" \
'let r = record { x: 42 }
r.x' \
"42"

expect_wasmtime_result "record dot: let bind from fields" \
'let r = record { x: 10, y: 20 }
let a = r.x
let b = r.y
a + b' \
"30"

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

expect_wasmtime_result "currying (prelude name shadow)" \
'let mul = (a: Int) -> (Int) -> Int {
  (b: Int) -> Int { a * b }
}
let triple = mul(3)
triple(7)' \
"21"

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

expect_wasmtime_result "prelude name shadow: add as unary" \
'let add = (x: Int) -> Int { x + 10 }
add(3)' \
"13"

expect_wasmtime_result "prelude name shadow: sub as unary" \
'let sub = (x: Int) -> Int { x - 1 }
sub(7)' \
"6"

expect_wasmtime_result "prelude name shadow: div as unary" \
'let div = (x: Int) -> Int { x / 2 }
div(20)' \
"10"

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
# Mutable Capture (Ref Cell)
# ============================================
log_info "Testing mutable capture (ref cell)..."

expect_wasmtime_result "mutable capture: counter closure" \
'let mut total = 0
let f = () -> Int { total = total + 1; total }
f()
f()' \
"2"

expect_wasmtime_result "mutable capture: shared mutation" \
'let mut x = 10
let inc = () -> Int { x = x + 5; x }
inc()
inc()
x' \
"20"

expect_wasmtime_result "mutable capture: closure reads after outer mutation" \
'let mut total = 0
let mut i = 1
while i <= 10 { total = total + i; i = i + 1 }
let get_total = () -> Int { total }
get_total()' \
"55"

expect_wasmtime_result "mutable capture: accumulator pattern" \
'let mut sum = 0
let add = (x: Int) -> Int { sum = sum + x; sum }
add(10)
add(20)
add(30)
sum' \
"60"

echo ""

# ============================================
# String Operations
# ============================================
log_info "Testing string operations..."

expect_wasmtime_result "string_length" \
'string_length("hello")' \
"5"

expect_wasmtime_result "string_char_code_at" \
'string_char_code_at("A", 0)' \
"65"

expect_wasmtime_result "string_concat length" \
'string_length(string_concat("hello", " world"))' \
"11"

expect_wasmtime_result "string_substring length" \
'string_length(string_substring("hello world", 0, 5))' \
"5"

expect_wasmtime_result "string_index_of found" \
'string_index_of("hello world", "world")' \
"6"

expect_wasmtime_result "string_index_of not found" \
'string_index_of("hello", "xyz")' \
"-1"

expect_wasmtime_result "string_last_index_of" \
'string_last_index_of("abcabc", "abc")' \
"3"

expect_wasmtime_result "string_count" \
'string_count("abcabc", "abc")' \
"2"

expect_wasmtime_result "string_equals true" \
'if string_equals("abc", "abc") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_equals false" \
'if string_equals("abc", "xyz") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_contains true" \
'if string_contains("hello world", "world") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_contains false" \
'if string_contains("hello", "xyz") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_starts_with true" \
'if string_starts_with("hello", "hel") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_ends_with true" \
'if string_ends_with("hello", "llo") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_trim" \
'string_length(string_trim("  hi  "))' \
"2"

expect_wasmtime_result "string_to_upper" \
'if string_equals(string_to_upper("hello"), "HELLO") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_to_lower" \
'if string_equals(string_to_lower("HELLO"), "hello") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_to_upper preserves non-alpha" \
'string_char_code_at(string_to_upper("a1b"), 1)' \
"49"

expect_wasmtime_result "string_replace first occurrence" \
'if string_equals(string_replace("hello world", "world", "vibe"), "hello vibe") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_replace no match" \
'string_length(string_replace("hello", "xyz", "abc"))' \
"5"

expect_wasmtime_result "string_replace_all" \
'if string_equals(string_replace_all("abcabc", "abc", "x"), "xx") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_replace_all remove" \
'string_length(string_replace_all("hello", "l", ""))' \
"3"

expect_wasmtime_result "string_from_char_code" \
'string_char_code_at(string_from_char_code(65), 0)' \
"65"

expect_wasmtime_result "string_builder" \
'let b = string_builder()
string_builder_push(b, "hello")
string_builder_push(b, " world")
string_length(string_builder_freeze(b))' \
"11"

echo ""

# ============================================
# Array Operations
# ============================================
log_info "Testing array operations..."

expect_wasmtime_result "array_length" \
'array_length([1, 2, 3])' \
"3"

expect_wasmtime_result "array_get" \
'array_get([10, 20, 30], 1)' \
"20"

expect_wasmtime_result "array_concat length" \
'array_length(array_concat([1, 2], [3, 4]))' \
"4"

expect_wasmtime_result "array_slice length" \
'array_length(array_slice([1, 2, 3, 4, 5], 1, 3))' \
"2"

expect_wasmtime_result "array_builder" \
'let b = array_builder()
array_builder_push(b, 1)
array_builder_push(b, 2)
array_builder_push(b, 3)
array_length(array_builder_freeze(b))' \
"3"

expect_wasmtime_result "array_get from builder" \
'let b = array_builder()
array_builder_push(b, 10)
array_builder_push(b, 20)
array_builder_push(b, 30)
array_get(array_builder_freeze(b), 2)' \
"30"

echo ""

# ============================================
# For-In Loops
# ============================================
log_info "Testing for-in loops..."

expect_wasmtime_result "for-in: accumulate with outer mutable" \
'let mut total = 0
for x in [1, 2, 3, 4, 5] { total = total + x }
total' \
"15"

expect_wasmtime_result "for-in: nested for-in accumulation" \
'let mut sum = 0
for x in [1, 2, 3] {
  for y in [10, 20] {
    sum = sum + x * y
  }
}
sum' \
"180"

expect_wasmtime_result "for-in: with index variable" \
'let mut last_idx = 0
for i, x in [10, 20, 30] {
  last_idx = i
}
last_idx' \
"2"

echo ""

# ============================================
# String Builtins
# ============================================
log_info "Testing string builtins..."

expect_wasmtime_result "string_length" \
'string_length("hello")' \
"5"

expect_wasmtime_result "string_length: empty string" \
'string_length("")' \
"0"

expect_wasmtime_result "string_concat" \
'string_length(string_concat("hello", " world"))' \
"11"

expect_wasmtime_result "string_contains: found" \
'if string_contains("hello world", "world") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_contains: not found" \
'if string_contains("hello world", "xyz") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_contains: empty substring" \
'if string_contains("hello", "") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_contains: equal strings" \
'if string_contains("abc", "abc") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_contains: longer needle" \
'if string_contains("hi", "hello") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_starts_with: true" \
'if string_starts_with("hello world", "hello") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_starts_with: false" \
'if string_starts_with("hello world", "world") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_ends_with: true" \
'if string_ends_with("hello world", "world") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_ends_with: false" \
'if string_ends_with("hello world", "hello") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_index_of: found" \
'string_index_of("hello world", "world")' \
"6"

expect_wasmtime_result "string_index_of: not found" \
'string_index_of("hello", "xyz")' \
"-1"

expect_wasmtime_result "string_last_index_of: found" \
'string_last_index_of("abcabc", "abc")' \
"3"

expect_wasmtime_result "string_last_index_of: not found" \
'string_last_index_of("hello", "xyz")' \
"-1"

expect_wasmtime_result "string_substring" \
'string_length(string_substring("hello world", 6, 11))' \
"5"

expect_wasmtime_result "string_char_code_at" \
'string_char_code_at("ABC", 0)' \
"65"

expect_wasmtime_result "string_equals: true" \
'if string_equals("hello", "hello") { 1 } else { 0 }' \
"1"

expect_wasmtime_result "string_equals: false" \
'if string_equals("hello", "world") { 1 } else { 0 }' \
"0"

expect_wasmtime_result "string_from_char_code" \
'string_char_code_at(string_from_char_code(65), 0)' \
"65"

expect_wasmtime_result "string_to_upper" \
'string_char_code_at(string_to_upper("abc"), 0)' \
"65"

expect_wasmtime_result "string_to_upper: non-alpha preserved" \
'string_char_code_at(string_to_upper("1a"), 0)' \
"49"

expect_wasmtime_result "string_to_lower" \
'string_char_code_at(string_to_lower("ABC"), 0)' \
"97"

expect_wasmtime_result "string_to_lower: non-alpha preserved" \
'string_char_code_at(string_to_lower("1A"), 0)' \
"49"

expect_wasmtime_result "string_trim" \
'string_length(string_trim("  hello  "))' \
"5"

expect_wasmtime_result "string_trim_start" \
'string_length(string_trim_start("  hello  "))' \
"7"

expect_wasmtime_result "string_trim_end" \
'string_length(string_trim_end("  hello  "))' \
"7"

expect_wasmtime_result "string_count" \
'string_count("abcabcabc", "abc")' \
"3"

expect_wasmtime_result "string_count: no match" \
'string_count("hello", "xyz")' \
"0"

expect_wasmtime_result "string_replace: first occurrence" \
'string_length(string_replace("hello world", "world", "vibe"))' \
"10"

expect_wasmtime_result "string_replace: no match returns original" \
'string_length(string_replace("hello", "xyz", "!"))' \
"5"

expect_wasmtime_result "string_replace: first only" \
'string_length(string_replace("aaa", "a", "bb"))' \
"4"

expect_wasmtime_result "string_replace_all: all occurrences" \
'string_length(string_replace_all("abcabc", "abc", "x"))' \
"2"

expect_wasmtime_result "string_replace_all: multiple" \
'string_length(string_replace_all("aaa", "a", "bb"))' \
"6"

expect_wasmtime_result "string_replace_all: no match" \
'string_length(string_replace_all("hello", "xyz", "!"))' \
"5"

expect_wasmtime_result "string_replace_all: real-world" \
'string_length(string_replace_all("hello world hello", "hello", "hi"))' \
"11"

expect_wasmtime_result "string_builder + freeze" \
'let b = string_builder()
string_builder_push(b, "hello")
string_builder_push(b, " ")
string_builder_push(b, "world")
string_length(string_builder_freeze(b))' \
"11"

echo ""

# ============================================
# Array Operations
# ============================================
log_info "Testing array operations..."

expect_wasmtime_result "array indexing" \
'let arr = [10, 20, 30]
arr[1]' \
"20"

expect_wasmtime_result "array_length" \
'array_length([1, 2, 3, 4, 5])' \
"5"

expect_wasmtime_result "array set and read" \
'let arr = [10, 20, 30]
arr[1] = 99
arr[1]' \
"99"

echo ""

# ============================================
# Record Field Access
# ============================================
log_info "Testing record field access..."

expect_wasmtime_result "record field access" \
'let r = record { x: 10, y: 20 }
r.x + r.y' \
"30"

expect_wasmtime_result "record field access: nested" \
'let r = record { a: record { b: 42 } }
r.a.b' \
"42"

echo ""

# ============================================
# Pipe Operator
# ============================================
log_info "Testing pipe operator..."

expect_wasmtime_result "pipe: basic" \
'let double = (x: Int) -> Int { x * 2 }
5 |> double' \
"10"

expect_wasmtime_result "pipe: chain" \
'let inc = (x: Int) -> Int { x + 1 }
let double = (x: Int) -> Int { x * 2 }
3 |> inc |> double' \
"8"

echo ""

# ============================================
# User-defined Enums
# ============================================
log_info "Testing user-defined enums..."

expect_wasmtime_result "enum: simple match" \
'enum Color { Red; Green; Blue }
match Green { Red => 1, Green => 2, Blue => 3 }' \
"2"

expect_wasmtime_result "enum: match with payload" \
'enum Shape { Circle(Int); Rect(Int, Int) }
match Rect(5, 4) { Circle(r) => r * r, Rect(w, h) => w * h }' \
"20"

expect_wasmtime_result "enum: nested match" \
'enum Tree { Leaf(Int); Node(Tree, Tree) }
let t = Node(Leaf(10), Leaf(20))
match t { Leaf(v) => v, Node(l, r) => {
  let lv = match l { Leaf(v) => v, _ => 0 }
  let rv = match r { Leaf(v) => v, _ => 0 }
  lv + rv
}}' \
"30"

expect_wasmtime_result "enum: match wildcard" \
'enum Dir { Up; Down; Left; Right }
match Left { Up => 1, Down => 2, _ => 99 }' \
"99"

expect_wasmtime_result "enum: single-variant with payload" \
'enum Wrapper { Val(Int) }
let w = Val(42)
match w { Val(x) => x }' \
"42"

expect_wasmtime_result "enum: recursive list length" \
'enum List { Nil; Cons(Int, List) }
let rec len = (xs: List) -> Int {
  match xs { Nil => 0, Cons(_, rest) => 1 + len(rest) }
}
len(Cons(1, Cons(2, Cons(3, Nil))))' \
"3"

expect_wasmtime_result "enum: recursive list sum" \
'enum List { Nil; Cons(Int, List) }
let rec sum_list = (xs: List) -> Int {
  match xs { Nil => 0, Cons(v, rest) => v + sum_list(rest) }
}
sum_list(Cons(10, Cons(20, Cons(30, Nil))))' \
"60"

echo ""

# ============================================
# User-defined Structs
# ============================================
log_info "Testing user-defined structs..."

expect_wasmtime_result "struct: basic field access" \
'struct Point { x: Int; y: Int }
let p = Point::{ x: 10, y: 20 }
p.x + p.y' \
"30"

expect_wasmtime_result "struct: pass to function" \
'struct Pair { a: Int; b: Int }
let sum_pair = (p: Pair) -> Int { p.a + p.b }
sum_pair(Pair::{ a: 3, b: 7 })' \
"10"

expect_wasmtime_result "struct: nested struct" \
'struct Inner { val: Int }
struct Outer { inner: Inner; extra: Int }
let o = Outer::{ inner: Inner::{ val: 5 }, extra: 10 }
o.inner.val + o.extra' \
"15"

expect_wasmtime_result "struct: enum with struct payload" \
'struct Coord { x: Int; y: Int }
enum Geom { Pt(Coord); Dist(Int) }
let g = Pt(Coord::{ x: 3, y: 4 })
match g { Pt(c) => c.x + c.y, Dist(d) => d }' \
"7"

echo ""

# ============================================
# Break and Continue
# ============================================
log_info "Testing break and continue..."

expect_wasmtime_result "break: basic" \
'let mut sum = 0
let mut i = 0
while i < 10 {
  i = i + 1
  if i == 5 { break }
  sum = sum + i
}
sum' \
"10"

expect_wasmtime_result "continue: skip even" \
'let mut sum = 0
let mut i = 0
while i < 10 {
  i = i + 1
  if i % 2 == 0 { continue }
  sum = sum + i
}
sum' \
"25"

expect_wasmtime_result "break: nested while" \
'let mut total = 0
let mut i = 0
while i < 5 {
  let mut j = 0
  while j < 5 {
    j = j + 1
    if j == 3 { break }
    total = total + 1
  }
  i = i + 1
}
total' \
"10"

expect_wasmtime_result "break+continue: combined" \
'let mut sum = 0
let mut i = 0
while i < 100 {
  i = i + 1
  if i % 3 == 0 { continue }
  if i > 10 { break }
  sum = sum + i
}
sum' \
"37"

echo ""

# ============================================
# Throw and Handle (requires exceptions proposal)
# ============================================
log_info "Testing throw/handle (exceptions proposal)..."

# Helper for tests that need the WASM exceptions proposal
expect_wasmtime_result_exceptions() {
  local test_name="$1"
  local vibe_code="$2"
  local expected_value="$3"

  echo "$vibe_code" > "$TMP_DIR/test.vibe"

  if ! $VIBE compile --wasm "$TMP_DIR/test.vibe" -o "$TMP_DIR/test.wasm" 2>/dev/null; then
    log_fail "$test_name - compilation failed"
    return
  fi

  local wasm_tagged
  wasm_tagged=$(VIBE_WASMTIME_WASM_FLAGS="exceptions=y" "$WASMTIME_RUN" --invoke run "$TMP_DIR/test.wasm" 2>/dev/null | grep -v "^warning") || true

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

expect_wasmtime_result_exceptions "throw/handle: catch division by zero" \
'let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if b == 0 { throw("division by zero") }
  a / b
}
handle { safe_div(10, 0) } { Error(_) => 99 }' \
"99"

expect_wasmtime_result_exceptions "throw/handle: no error path" \
'let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if b == 0 { throw("division by zero") }
  a / b
}
handle { safe_div(10, 2) } { Error(_) => 99 }' \
"5"

expect_wasmtime_result_exceptions "throw/handle: nested handle" \
'let fail = (msg: String) -> Int with { Error } {
  throw(msg)
}
let outer = handle {
  let inner = handle { fail("inner") } { Error(_) => 42 }
  inner + 1
} { Error(_) => 0 }
outer' \
"43"

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
