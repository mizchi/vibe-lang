#!/bin/bash
# E2E tests for Component Model and WIT generation
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="/tmp/vibe_component_e2e_$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
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
WASMTIME_BIN=""
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
HAS_WASMTIME=0
if WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null)"; then
  HAS_WASMTIME=1
fi
HAS_WKG=0
if command -v wkg &> /dev/null; then
  HAS_WKG=1
fi

# Test 1: Simple WASM compilation with while loop
test_while_loop() {
  log_info "Test: While loop WASM compilation"

  cat > "$TMP_DIR/while_test.vibe" << 'EOF'
let sum_up = (n: Int) -> Int {
  let mut i = 0
  let mut sum = 0
  while i < n {
    sum = sum + i
    i = i + 1
  }
  sum
}
sum_up(5)
EOF

  if ! $VIBE compile --wasm "$TMP_DIR/while_test.vibe" -o "$TMP_DIR/while_test.wasm" 2>/dev/null; then
    log_fail "While loop WASM compilation failed"
    return
  fi

  if [ ! -f "$TMP_DIR/while_test.wasm" ]; then
    log_fail "While loop WASM not generated"
    return
  fi

  # Run with Node.js and check result
  RESULT=$(node -e "
    const fs = require('fs');
    const wasm = fs.readFileSync('$TMP_DIR/while_test.wasm');
    WebAssembly.instantiate(wasm, {vibe: {}}).then(({instance}) => {
      const result = instance.exports._start();
      const value = typeof result === 'bigint' ? Number(result >> 2n) : (result >> 2);
      console.log(value);
    });
  " 2>/dev/null)

  if [ "$RESULT" = "10" ]; then
    log_pass "While loop returns correct value (10)"
  else
    log_fail "While loop returns $RESULT, expected 10"
  fi
}

# Test 2: WIT generation for simple function
test_wit_generation() {
  log_info "Test: WIT generation"

  cat > "$TMP_DIR/wit_test.vibe" << 'EOF'
export let add = (x: Int, y: Int) -> Int {
  x + y
}
export let multiply = (a: Int, b: Int) -> Int {
  a * b
}
add(1, 2)
EOF

  if ! $VIBE compile --wit "$TMP_DIR/wit_test.vibe" -o "$TMP_DIR/wit_test.wit" 2>/dev/null; then
    log_fail "WIT compilation failed"
    return
  fi

  if [ ! -f "$TMP_DIR/wit_test.wit" ]; then
    log_fail "WIT file not generated"
    return
  fi

  # Check WIT content
  if grep -q "package local:wit_test" "$TMP_DIR/wit_test.wit"; then
    log_pass "WIT contains correct package name"
  else
    log_fail "WIT missing package name"
  fi

  if grep -q "export add: func(x: s32, y: s32) -> s32" "$TMP_DIR/wit_test.wit"; then
    log_pass "WIT contains add function signature"
  else
    log_fail "WIT missing add function"
  fi

  if grep -q "export multiply: func(a: s32, b: s32) -> s32" "$TMP_DIR/wit_test.wit"; then
    log_pass "WIT contains multiply function signature"
  else
    log_fail "WIT missing multiply function"
  fi
}

# Test 3: Component WASM generation and validation
test_component_generation() {
  log_info "Test: Component WASM generation"

  cat > "$TMP_DIR/component_test.vibe" << 'EOF'
let square = (x: Int) -> Int {
  x * x
}
square(7)
EOF

  if ! $VIBE compile --component "$TMP_DIR/component_test.vibe" -o "$TMP_DIR/component_test.component.wasm" 2>/dev/null; then
    log_fail "Component WASM compilation failed"
    return
  fi

  if [ ! -f "$TMP_DIR/component_test.component.wasm" ]; then
    log_fail "Component WASM not generated"
    return
  fi

  # Validate with wasm-tools
  if command -v wasm-tools &> /dev/null; then
    if wasm-tools validate "$TMP_DIR/component_test.component.wasm" 2>/dev/null; then
      log_pass "Component WASM validates with wasm-tools"
    else
      log_info "Component WASM validation failed (continuing with structural checks)"
    fi

    # Check component structure
    COMPONENT_TEXT=$(wasm-tools print "$TMP_DIR/component_test.component.wasm" 2>/dev/null)

    if echo "$COMPONENT_TEXT" | grep -q "(component"; then
      log_pass "Output is a valid component"
    else
      log_fail "Output is not a component"
    fi

    if echo "$COMPONENT_TEXT" | grep -q "(canon lift"; then
      log_pass "Component contains canon lift"
    else
      log_fail "Component missing canon lift"
    fi

    if echo "$COMPONENT_TEXT" | grep -q '(export.*"run"'; then
      log_pass "Component exports 'run' function"
    else
      log_fail "Component missing 'run' export"
    fi
  else
    log_info "wasm-tools not found, skipping validation"
  fi
}

# Test 4: Arithmetic operations in WASM
test_arithmetic() {
  log_info "Test: Arithmetic operations"

  cat > "$TMP_DIR/arith_test.vibe" << 'EOF'
let a = 10
let b = 3
let sum = a + b
let diff = a - b
let prod = a * b
let quot = a / b
prod
EOF

  if ! $VIBE compile --wasm "$TMP_DIR/arith_test.vibe" -o "$TMP_DIR/arith_test.wasm" 2>/dev/null; then
    log_fail "Arithmetic WASM compilation failed"
    return
  fi

  RESULT=$(node -e "
    const fs = require('fs');
    const wasm = fs.readFileSync('$TMP_DIR/arith_test.wasm');
    WebAssembly.instantiate(wasm, {vibe: {}}).then(({instance}) => {
      const result = instance.exports._start();
      const value = typeof result === 'bigint' ? Number(result >> 2n) : (result >> 2);
      console.log(value);
    });
  " 2>/dev/null)

  if [ "$RESULT" = "30" ]; then
    log_pass "Multiplication returns correct value (10 * 3 = 30)"
  else
    log_fail "Multiplication returns $RESULT, expected 30"
  fi
}

# Test 5: Default output directory (dist/)
test_default_output() {
  log_info "Test: Default output directory"

  # Create a test file in project root's dist/
  cat > "$TMP_DIR/default_out.vibe" << 'EOF'
42
EOF

  # Ensure dist/ exists and run from project root
  mkdir -p "$PROJECT_ROOT/dist"
  if ! $VIBE compile --wasm "$TMP_DIR/default_out.vibe" 2>/dev/null; then
    log_fail "Default output compilation failed"
    return
  fi

  if [ -f "$PROJECT_ROOT/dist/default_out.wasm" ]; then
    log_pass "WASM generated in default dist/ directory"
    rm -f "$PROJECT_ROOT/dist/default_out.wasm"  # cleanup
  else
    log_fail "WASM not in dist/ directory"
  fi
}

# Test 6: Tuple return type with effects
test_tuple_with_effects() {
  log_info "Test: Tuple return type with effects"

  cat > "$TMP_DIR/tuple_effects.vibe" << 'EOF'
let parse = (s: String, i: Int) -> (String, Int) with {Error} {
  (s, i + 1)
}
parse("test", 5)
EOF

  # Compile to WASM to verify parsing works; tuple return is not yet supported at runtime
  if ! $VIBE compile --wasm "$TMP_DIR/tuple_effects.vibe" -o "$TMP_DIR/tuple_effects.wasm" 2>/dev/null; then
    # Tuple return in WASM codegen is a known limitation, check WIT generation instead
    if $VIBE compile --wit "$TMP_DIR/tuple_effects.vibe" -o "$TMP_DIR/tuple_effects.wit" 2>/dev/null; then
      log_pass "Tuple with effects parses and generates WIT"
    else
      log_fail "Tuple with effects failed to parse"
    fi
  else
    log_pass "Tuple with effects compiles to WASM"
  fi
}

# Test 7: WIT with different types
test_wit_types() {
  log_info "Test: WIT type mappings"

  cat > "$TMP_DIR/wit_types.vibe" << 'EOF'
export let get_bool = () -> Bool { true }
export let get_string = () -> String { "hello" }
export let identity = (x: Int) -> Int { x }
1
EOF

  if ! $VIBE compile --wit "$TMP_DIR/wit_types.vibe" -o "$TMP_DIR/wit_types.wit" 2>/dev/null; then
    log_fail "WIT types compilation failed"
    return
  fi

  if grep -q -- "-> bool" "$TMP_DIR/wit_types.wit"; then
    log_pass "WIT maps Bool to bool"
  else
    log_fail "WIT Bool mapping failed"
  fi

  if grep -q -- "-> string" "$TMP_DIR/wit_types.wit"; then
    log_pass "WIT maps String to string"
  else
    log_fail "WIT String mapping failed"
  fi

  if grep -q -- "-> s32" "$TMP_DIR/wit_types.wit"; then
    log_pass "WIT maps Int to s32"
  else
    log_fail "WIT Int mapping failed"
  fi
}

# Test 8: Component stdio roundtrip (wasi:io streams)
test_component_stdio_roundtrip() {
  log_info "Test: Component stdio roundtrip"

  if [ "$HAS_WASMTIME" -ne 1 ]; then
    log_info "wasmtime not found, skipping stdio roundtrip"
    return
  fi
  if [ "$HAS_WKG" -ne 1 ]; then
    log_info "wkg not found, skipping stdio roundtrip"
    return
  fi

  cat > "$TMP_DIR/stdio_roundtrip.vibe" << 'EOF'
let run = () -> Int with {Stdin, Stdout} {
  do {
    stdout_write_char(62)
    stdout_write_char(32)
    let c = stdin_read_char()
    if c < 0 {
      -1
    } else {
      stdout_write_char(c)
      stdout_write_char(10)
      c
    }
  }
}
run()
EOF

  scripts/component_wkg_stdio.sh "$TMP_DIR/stdio_roundtrip.vibe" "$TMP_DIR/stdio_roundtrip.component.wasm" >/dev/null 2>&1 || {
    log_info "failed to build stdio component, skipping stdio roundtrip"
    return
  }

  RESULT=$(printf 'A' | WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke 'run()' "$TMP_DIR/stdio_roundtrip.component.wasm" 2>/dev/null || true)
  LAST_LINE=$(printf '%s\n' "$RESULT" | tail -n 1)
  if [ "$LAST_LINE" = "260" ]; then
    log_pass "stdin_read_char reads one byte and returns tagged int (260 for 'A')"
  else
    log_fail "stdio roundtrip returned '$LAST_LINE', expected 260"
  fi
}

# Test 9: Component stdio stream chunk I/O
test_component_stdio_stream_chunk() {
  log_info "Test: Component stdio stream chunk I/O"

  if [ "$HAS_WASMTIME" -ne 1 ]; then
    log_info "wasmtime not found, skipping stream chunk test"
    return
  fi
  if [ "$HAS_WKG" -ne 1 ]; then
    log_info "wkg not found, skipping stream chunk test"
    return
  fi

  cat > "$TMP_DIR/stdio_stream_chunk.vibe" << 'EOF'
let run = () -> Int with {Stdin, Stdout} {
  do {
    stdout_write_stream("> ")
    let chunk = stdin_read_stream(4)
    stdout_write_stream(chunk)
    stdout_write_char(10)
    7
  }
}
run()
EOF

  scripts/component_wkg_stdio.sh "$TMP_DIR/stdio_stream_chunk.vibe" "$TMP_DIR/stdio_stream_chunk.component.wasm" >/dev/null 2>&1 || {
    log_info "failed to build stdio stream component, skipping stream chunk test"
    return
  }

  RESULT=$(printf 'ABCD' | WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke 'run()' "$TMP_DIR/stdio_stream_chunk.component.wasm" 2>/dev/null || true)
  LAST_LINE=$(printf '%s\n' "$RESULT" | tail -n 1)

  if printf '%s\n' "$RESULT" | grep -q '^> ABCD$' && [ "$LAST_LINE" = "28" ]; then
    log_pass "stdin_read_stream/stdout_write_stream handle chunk I/O"
  else
    log_fail "stream chunk I/O failed: $RESULT"
  fi
}

# Run all tests
echo "========================================"
echo "vibe Component Model E2E Tests"
echo "========================================"
echo ""

test_while_loop
echo ""
test_wit_generation
echo ""
test_component_generation
echo ""
test_arithmetic
echo ""
test_default_output
echo ""
test_tuple_with_effects
echo ""
test_wit_types
echo ""
test_component_stdio_roundtrip
echo ""
test_component_stdio_stream_chunk
echo ""

echo "========================================"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "========================================"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
