#!/bin/bash
# Tests for WASM codegen behavior
# Some features compile but may require host runtime support.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="/tmp/xsh_unsupported_e2e_$$"

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
log_info "Building xsh CLI..."
cd "$PROJECT_ROOT"
moon build src/cmd/xsh/main.mbt --target native -q 2>/dev/null || {
  log_fail "Failed to build xsh CLI"
  exit 1
}

XSH="moon run src/cmd/xsh/main.mbt --target native --"

# Helper: expect compilation to fail with specific error
expect_compile_error() {
  local test_name="$1"
  local xsh_code="$2"
  local expected_error="$3"

  echo "$xsh_code" > "$TMP_DIR/test.xsh"

  local output
  output=$($XSH compile --wasm "$TMP_DIR/test.xsh" -o "$TMP_DIR/test.wasm" 2>&1) || true

  if echo "$output" | grep -q "$expected_error"; then
    log_pass "$test_name (error: $expected_error)"
  else
    log_fail "$test_name - expected error '$expected_error' but got: $output"
  fi
}

# Helper: expect compilation to succeed
expect_compile_success() {
  local test_name="$1"
  local xsh_code="$2"

  echo "$xsh_code" > "$TMP_DIR/test.xsh"

  if $XSH compile --wasm "$TMP_DIR/test.xsh" -o "$TMP_DIR/test.wasm" 2>/dev/null; then
    log_pass "$test_name"
  else
    log_fail "$test_name - compilation failed unexpectedly"
  fi
}

# Helper: expect WASM execution to return specific value
expect_wasm_result() {
  local test_name="$1"
  local xsh_code="$2"
  local expected_value="$3"

  echo "$xsh_code" > "$TMP_DIR/test.xsh"

  if ! $XSH compile --wasm "$TMP_DIR/test.xsh" -o "$TMP_DIR/test.wasm" 2>/dev/null; then
    log_fail "$test_name - compilation failed"
    return
  fi

  local result
  result=$(node -e "
    const fs = require('fs');
    const wasm = fs.readFileSync('$TMP_DIR/test.wasm');
    WebAssembly.instantiate(wasm, {}).then(({instance}) => {
      const result = instance.exports.run();
      const value = result >> 2;
      console.log(value);
    });
  " 2>/dev/null)

  if [ "$result" = "$expected_value" ]; then
    log_pass "$test_name (result: $expected_value)"
  else
    log_fail "$test_name - expected $expected_value but got $result"
  fi
}

echo "========================================"
echo "xsh Codegen Behavior Tests"
echo "========================================"
echo ""

# ============================================
# Test: Async/Await (accepted by codegen)
# ============================================
log_info "Testing async/await compile path..."

# await/yield currently compile for wasm backend.
# Note: running these modules on Node may require wasmfx/stack-switching support.
expect_compile_success "await expression compiles" \
'let x = await 42
x'

expect_compile_success "yield expression compiles" \
'let x = yield 42
x'

echo ""

# ============================================
# Test: Export statement behavior in WASM backend
# ============================================
log_info "Testing export statement handling..."

# Current wasm backend ignores unresolved export-list symbols and still evaluates
# the executable statements.
expect_wasm_result "export undefined symbol is ignored in wasm backend" \
'export { foo }
42' \
"42"

echo ""

# ============================================
# Test: Supported features (sanity checks)
# ============================================
log_info "Testing supported features (sanity checks)..."

expect_wasm_result "closure capturing outer variable" \
'let n = 5
let add_n = (x: Int) -> Int { x + n }
add_n(10)' \
"15"

expect_wasm_result "basic arithmetic" \
'1 + 2 * 3' \
"7"

expect_wasm_result "if expression" \
'if true { 10 } else { 20 }' \
"10"

expect_wasm_result "let binding" \
'let x = 5
let y = 3
x + y' \
"8"

expect_wasm_result "function call" \
'let add = (a: Int, b: Int) -> Int { a + b }
add(3, 4)' \
"7"

expect_wasm_result "while loop" \
'let mut i = 0
let mut sum = 0
while i < 5 {
  sum = sum + i
  i = i + 1
}
sum' \
"10"

expect_wasm_result "match expression" \
'let x = 3
match x {
  1 => 10
  2 => 20
  3 => 30
  _ => 0
}' \
"30"

expect_wasm_result "tuple destructuring" \
'let (a, b, c) = (1, 2, 3)
a + b + c' \
"6"

expect_wasm_result "recursive function" \
'let rec fib = (n: Int) -> Int {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}
fib(10)' \
"55"

expect_wasm_result "nested function" \
'let outer = (x: Int) -> Int {
  let inner = (y: Int) -> Int { y * 2 }
  inner(x) + 1
}
outer(5)' \
"11"

expect_wasm_result "mutable variable" \
'let mut x = 1
x = x + 1
x = x * 2
x' \
"4"

expect_wasm_result "boolean operations" \
'let a = true
let b = false
if a && not(b) { 1 } else { 0 }' \
"1"

expect_wasm_result "comparison operators" \
'let x = 5
let y = 3
if x > y { 1 } else { 0 }' \
"1"

expect_wasm_result "integer division" \
'10 / 3' \
"3"

expect_wasm_result "modulo operation" \
'10 % 3' \
"1"

expect_wasm_result "negative numbers" \
'let x = 0 - 5
0 - x' \
"5"

echo ""

# ============================================
# Test: Edge cases
# ============================================
log_info "Testing edge cases..."

expect_wasm_result "empty block" \
'let x = { }
0' \
"0"

expect_wasm_result "nested if" \
'let x = 5
if x > 0 {
  if x > 3 { 1 } else { 2 }
} else {
  3
}' \
"1"

expect_wasm_result "multiple let bindings" \
'let a = 1
let b = 2
let c = 3
let d = 4
let e = 5
a + b + c + d + e' \
"15"

expect_wasm_result "nested arithmetic" \
'let a = 1 + 2
let b = 3 + 4
let c = a * b
c + 1' \
"22"

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
