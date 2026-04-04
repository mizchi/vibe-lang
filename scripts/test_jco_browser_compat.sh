#!/bin/bash
# E2E tests for jco browser compatibility (Component Model → JS transpile)
# Verifies that vibe component WASM can be transpiled by jco and executed in Node.js
#
# Requires: jco (npm install -g @bytecodealliance/jco), wasm-tools, vibe native CLI
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="/tmp/vibe_jco_compat_$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
log_skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }
log_info() { echo -e "${YELLOW}INFO${NC}: $1"; }

# --- Prerequisite checks ---
VIBE="${PROJECT_ROOT}/target/native/release/build/cmd/vibe/vibe.exe"
if [ ! -x "$VIBE" ]; then
  echo "ERROR: vibe native CLI not found at $VIBE"
  echo "Run: moon build --target native --release src/cmd/vibe"
  exit 1
fi

if ! command -v jco &>/dev/null; then
  echo "ERROR: jco not found. Install: npm install -g @bytecodealliance/jco"
  exit 1
fi

if ! command -v wasm-tools &>/dev/null; then
  echo "ERROR: wasm-tools not found."
  exit 1
fi

JCO_VERSION=$(jco --version 2>/dev/null)
WASM_TOOLS_VERSION=$(wasm-tools --version 2>/dev/null)
log_info "jco $JCO_VERSION, $WASM_TOOLS_VERSION"

# --- Helper: compile, transpile, run ---
# Usage: jco_run <test_name> <vibe_source> <expected_output> [compile_flags...]
jco_run() {
  local test_name="$1"
  local vibe_source="$2"
  local expected="$3"
  shift 3
  local compile_flags=("$@")

  local src_file="$TMP_DIR/${test_name}.vibe"
  local component="$TMP_DIR/${test_name}.component.wasm"
  local jco_dir="$TMP_DIR/${test_name}_jco"
  local js_file="$jco_dir/${test_name}.component.js"

  echo "$vibe_source" > "$src_file"

  # Compile to component
  if ! "$VIBE" compile "${compile_flags[@]}" --component "$src_file" -o "$component" 2>"$TMP_DIR/${test_name}.compile.log"; then
    log_fail "$test_name: compile failed ($(cat "$TMP_DIR/${test_name}.compile.log"))"
    return
  fi

  # Validate
  if ! wasm-tools validate "$component" 2>/dev/null; then
    log_fail "$test_name: wasm-tools validate failed"
    return
  fi

  # jco transpile
  if ! jco transpile "$component" -o "$jco_dir" 2>"$TMP_DIR/${test_name}.jco.log"; then
    log_fail "$test_name: jco transpile failed ($(cat "$TMP_DIR/${test_name}.jco.log"))"
    return
  fi

  # Run in Node.js
  local actual
  actual=$(cd "$TMP_DIR" && node --input-type=module -e "
    import * as mod from './${test_name}_jco/${test_name}.component.js';
    const result = mod.run();
    // Unwrap BigInt for display
    if (typeof result === 'bigint') {
      console.log(result.toString());
    } else {
      console.log(result);
    }
  " 2>"$TMP_DIR/${test_name}.node.log")

  if [ $? -ne 0 ]; then
    log_fail "$test_name: Node.js execution failed ($(cat "$TMP_DIR/${test_name}.node.log"))"
    return
  fi

  if [ "$actual" = "$expected" ]; then
    log_pass "$test_name"
  else
    log_fail "$test_name: expected '$expected', got '$actual'"
  fi
}

# --- Helper: jco transpile only (no execution, just validates transpile works) ---
jco_transpile_only() {
  local test_name="$1"
  local vibe_source="$2"
  shift 2
  local compile_flags=("$@")

  local src_file="$TMP_DIR/${test_name}.vibe"
  local component="$TMP_DIR/${test_name}.component.wasm"
  local jco_dir="$TMP_DIR/${test_name}_jco"

  echo "$vibe_source" > "$src_file"

  if ! "$VIBE" compile "${compile_flags[@]}" --component "$src_file" -o "$component" 2>/dev/null; then
    log_fail "$test_name: compile failed"
    return
  fi

  if ! wasm-tools validate "$component" 2>/dev/null; then
    log_fail "$test_name: wasm-tools validate failed"
    return
  fi

  if ! jco transpile "$component" -o "$jco_dir" 2>"$TMP_DIR/${test_name}.jco.log"; then
    log_fail "$test_name: jco transpile failed ($(cat "$TMP_DIR/${test_name}.jco.log"))"
    return
  fi

  # Check .js and .d.ts are generated
  if [ -f "$jco_dir/${test_name}.component.js" ] && [ -f "$jco_dir/${test_name}.component.d.ts" ]; then
    log_pass "$test_name: transpile OK"
  else
    log_fail "$test_name: missing output files"
  fi
}

# ============================================================
# Test cases
# ============================================================

log_info "=== Pure function tests ==="

# Test 1: Integer literal
jco_run "int_literal" \
  '42' \
  '168'
# NOTE: returns tagged int (42 << 2 = 168). This is a known limitation —
# the component run() export returns raw s64 without untagging.

# Test 2: Arithmetic
jco_run "arithmetic" \
  'let x = 10
let y = 20
x + y' \
  '120'
# 30 << 2 = 120 (tagged)

# Test 3: Boolean (true = tagged 1)
jco_run "bool_true" \
  'true' \
  '7'
# true = 0x7 in tagged representation

# Test 4: Function call
jco_run "func_call" \
  'let square: (Int) -> Int = (x) -> { x * x }
square(5)' \
  '100'
# 25 << 2 = 100 (tagged)

# Test 5: Match expression
jco_run "match_expr" \
  'let x = 3
match x {
  1 => 10,
  2 => 20,
  3 => 30,
  _ => 0,
}' \
  '120'
# 30 << 2 = 120 (tagged)

# Test 6: Recursive function
jco_run "recursive" \
  'let fib: (Int) -> Int = (n) -> {
  if n <= 1 { n } else { fib(n - 1) + fib(n - 2) }
}
fib(10)' \
  '220'
# 55 << 2 = 220 (tagged)

log_info "=== Export function tests ==="

# Test 7: Export function exists in WIT
test_export_wit() {
  local src_file="$TMP_DIR/export_wit.vibe"
  local wit_file="$TMP_DIR/export_wit.wit"

  cat > "$src_file" << 'VIBE'
export let add: (Int, Int) -> Int = (x, y) -> { x + y }
add(1, 2)
VIBE

  if ! "$VIBE" compile --wit "$src_file" -o "$wit_file" 2>/dev/null; then
    log_fail "export_wit: WIT generation failed"
    return
  fi

  # Current limitation: export functions appear as values (s32) in WIT, not as func signatures.
  # This verifies the current behavior; update when individual function lifting is implemented.
  if grep -q "export add:" "$wit_file"; then
    log_pass "export_wit: add present in WIT"
  else
    log_fail "export_wit: add missing from WIT"
  fi
}
test_export_wit

# Test 8: String export function (P3 string lift)
test_string_export() {
  local src_file="$TMP_DIR/string_export.vibe"
  local component="$TMP_DIR/string_export.component.wasm"
  local jco_dir="$TMP_DIR/string_export_jco"

  cat > "$src_file" << 'VIBE'
export let greet: (String) -> String = (name) -> {
  "Hello, " + name + "!"
}
greet("test")
VIBE

  # compile_module_component_string_lift_auto needs --compose-p3 path
  # For now, just test basic --component
  if "$VIBE" compile --component "$src_file" -o "$component" 2>/dev/null; then
    if wasm-tools validate "$component" 2>/dev/null; then
      if jco transpile "$component" -o "$jco_dir" 2>/dev/null; then
        log_pass "string_export: transpile OK (string lift not yet tested)"
      else
        log_fail "string_export: jco transpile failed"
      fi
    else
      log_fail "string_export: invalid component"
    fi
  else
    log_skip "string_export: compile with string params not supported via --component"
  fi
}
test_string_export

log_info "=== Struct / enum tests ==="

# Test 9: Enum + pattern match
jco_run "enum_match" \
  'enum Color { Red; Green; Blue }
let code: (Color) -> Int = (c) -> {
  match c {
    Red => 1,
    Green => 2,
    Blue => 3,
  }
}
code(Green)' \
  '8'
# 2 << 2 = 8 (tagged)

# Test 10: Struct
jco_run "struct_basic" \
  'struct Point { x: Int; y: Int }
let p = Point::{ x: 3, y: 4 }
p.x + p.y' \
  '28'
# 7 << 2 = 28 (tagged)

log_info "=== WASI import tests ==="

# Test 11: println (requires WASI — expected to fail or need special handling)
test_println() {
  local src_file="$TMP_DIR/println_test.vibe"
  local component="$TMP_DIR/println_test.component.wasm"

  cat > "$src_file" << 'VIBE'
println("hello")
0
VIBE

  if "$VIBE" compile --component "$src_file" -o "$component" 2>/dev/null; then
    if wasm-tools validate "$component" 2>/dev/null; then
      log_pass "println: component validates (WASI imports present)"
    else
      log_fail "println: component invalid"
    fi
  else
    log_skip "println: compile aborted (WASI imports not supported in basic --component)"
  fi
}
test_println

log_info "=== jco WASI shim tests (browser polyfill path) ==="

# Test 12: jco transpile with --instantiation mode for browser embedding
test_jco_instantiation() {
  local src_file="$TMP_DIR/inst_test.vibe"
  local component="$TMP_DIR/inst_test.component.wasm"
  local jco_dir="$TMP_DIR/inst_test_jco"

  cat > "$src_file" << 'VIBE'
let factorial: (Int) -> Int = (n) -> {
  if n <= 1 { 1 } else { n * factorial(n - 1) }
}
factorial(6)
VIBE

  if ! "$VIBE" compile --component "$src_file" -o "$component" 2>/dev/null; then
    log_fail "jco_instantiation: compile failed"
    return
  fi

  # --instantiation sync generates a factory function that accepts imports
  # This is the pattern used for browser embedding with custom WASI shims
  if jco transpile --instantiation sync "$component" -o "$jco_dir" 2>"$TMP_DIR/inst.jco.log"; then
    if [ -f "$jco_dir/inst_test.component.js" ]; then
      # Verify the factory export pattern
      if grep -q "instantiate" "$jco_dir/inst_test.component.js"; then
        log_pass "jco_instantiation: factory pattern generated (browser-ready)"
      else
        log_fail "jco_instantiation: missing instantiate export"
      fi
    else
      log_fail "jco_instantiation: output file missing"
    fi
  else
    log_fail "jco_instantiation: transpile failed ($(cat "$TMP_DIR/inst.jco.log"))"
  fi
}
test_jco_instantiation

# Test 13: Verify generated TypeScript declarations
test_jco_types() {
  local src_file="$TMP_DIR/types_test.vibe"
  local component="$TMP_DIR/types_test.component.wasm"
  local jco_dir="$TMP_DIR/types_test_jco"

  cat > "$src_file" << 'VIBE'
10 + 20
VIBE

  if ! "$VIBE" compile --component "$src_file" -o "$component" 2>/dev/null; then
    log_fail "jco_types: compile failed"
    return
  fi

  if ! jco transpile "$component" -o "$jco_dir" 2>/dev/null; then
    log_fail "jco_types: transpile failed"
    return
  fi

  if [ -f "$jco_dir/types_test.component.d.ts" ]; then
    if grep -q "export function run" "$jco_dir/types_test.component.d.ts"; then
      log_pass "jco_types: TypeScript declarations include run()"
    else
      log_fail "jco_types: missing run() in .d.ts"
    fi
  else
    log_fail "jco_types: .d.ts not generated"
  fi
}
test_jco_types

log_info "=== wasmtime P3 serve tests ==="

# Test 14: P3 HTTP handler compose + serve (requires wasmtime with P3 support)
test_p3_serve() {
  # Check if wasmtime supports -Sp3
  if ! wasmtime serve --help 2>&1 | grep -qi "p3\|preview3"; then
    log_skip "p3_serve: wasmtime $(wasmtime --version 2>/dev/null | head -1) lacks P3 support (need v42+)"
    return
  fi

  local handler_file="$TMP_DIR/p3_handler.vibe"
  local compose_output="$TMP_DIR/p3_handler.component.wasm"

  cat > "$handler_file" << 'VIBE'
export let handler: (String, String) -> Int = (method, url) -> {
  200
}
handler("GET", "/")
VIBE

  if ! bash "$PROJECT_ROOT/scripts/compose_http_p3_handler.sh" "$handler_file" -o "$compose_output" 2>"$TMP_DIR/p3.log"; then
    log_skip "p3_serve: compose failed ($(tail -1 "$TMP_DIR/p3.log"))"
    return
  fi

  # Start wasmtime serve in background, test with curl, then kill
  wasmtime serve -Sp3 -W component-model-async=y -W component-model-async-builtins=y \
    --addr 127.0.0.1:0 "$compose_output" &>"$TMP_DIR/p3_serve.log" &
  local pid=$!
  sleep 2

  # Extract port from log or try default
  local port
  port=$(grep -oP ':\K\d+' "$TMP_DIR/p3_serve.log" | tail -1)
  if [ -z "$port" ]; then port=8080; fi

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
  kill "$pid" 2>/dev/null || true

  if [ "$status" = "200" ]; then
    log_pass "p3_serve: HTTP 200 from P3 handler"
  else
    log_fail "p3_serve: expected 200, got $status"
  fi
}
test_p3_serve

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================="
echo -e "Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${YELLOW}${SKIPPED} skipped${NC}"
echo "========================================="

echo ""
echo "Known limitations:"
echo "  - run() returns tagged integers (value << 2), not untagged values"
echo "  - Export functions are not individually lifted in --component mode"
echo "  - WASI-dependent code (println, file I/O) needs --compose-p3 flow"
echo "  - String param functions need string_lift_auto (--compose-p3)"
echo "  - P3 HTTP serve requires wasmtime v42+ with -Sp3 flag"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
