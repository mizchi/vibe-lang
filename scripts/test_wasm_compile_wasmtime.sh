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

# NOTE: Option match (Some/None) skipped — known codegen i32/i64 type mismatch

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

# NOTE: tuple match skipped — known codegen i32/i64 type mismatch

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
# Summary
# ============================================
echo "========================================"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "========================================"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
