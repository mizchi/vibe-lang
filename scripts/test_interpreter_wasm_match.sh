#!/bin/bash
# Test that interpreter and WASM produce the same output for pattern matching
# This verifies codegen correctness by comparing evaluation results

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEMP_DIR="/tmp/interpreter_wasm_match"
WASMTIME_BIN="${WASMTIME_BIN:-$("$PROJECT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$PROJECT_DIR/scripts/wasmtime_run.sh"

mkdir -p "$TEMP_DIR"

failed=0
passed=0

# Test cases: each prints a result value
test_cases=(
  # Tuple patterns
  'let (a, b) = (1, 2); a + b'
  'let (a, (b, c)) = (1, (2, 3)); a + b + c'
  'match (1, 2) { (a, b) => a * b, _ => 0 }'

  # Record patterns
  'let record { x: a, y: b } = record { x: 10, y: 20 }; a + b'
  'match record { a: 1, b: 2 } { record { a: x, b: y } => x + y, _ => 0 }'

  # Ctor patterns (Option)
  'match Some(42) { Some(x) => x, _ => 0 }'
  'match None { Some(x) => x, _ => 99 }'
  'let Some(x) = Some(100); x'

  # Or patterns
  'match 2 { 1 | 2 | 3 => 100, _ => 0 }'
  'match 5 { 1 | 2 | 3 => 100, _ => 0 }'

  # Int patterns
  'match 42 { 0 => 0, 42 => 1, _ => 2 }'
  'match 99 { 0 => 0, 42 => 1, _ => 2 }'

  # Bool patterns
  'match true { true => 1, _ => 0 }'
  'match false { true => 1, _ => 0 }'

  # Float patterns
  'match 1.5f { 1.5f => 1, _ => 0 }'
  'match 2.0f { 1.5f => 1, _ => 0 }'

  # Double patterns
  'match 1.5 { 1.5 => 1, _ => 0 }'
  'match 2.0 { 1.5 => 1, _ => 0 }'

  # Nested patterns
  'match Some((1, 2)) { Some((a, b)) => a + b, _ => 0 }'
  'match (Some(10), None) { (Some(a), None) => a, _ => 0 }'

  # Wildcard in patterns
  'let (a, _, c) = (1, 2, 3); a + c'
  'let record { x: a, y: _ } = record { x: 10, y: 20 }; a'
)

echo "Testing interpreter vs WASM output..."
echo ""

for expr in "${test_cases[@]}"; do
  # Create test file
  echo "$expr" > "$TEMP_DIR/test.xsh"

  # Run interpreter and extract numeric value
  interp_output=$(moon run "$PROJECT_DIR/src/cmd/xsh/main.mbt" --target native -- run "$TEMP_DIR/test.xsh" 2>/dev/null | tail -1)
  # Extract value from "last: X" format
  interp_result=$(echo "$interp_output" | sed 's/last: //')

  # Compile and run WASM
  if moon run "$PROJECT_DIR/src/cmd/xsh/main.mbt" --target native -- compile --wasm "$TEMP_DIR/test.xsh" -o "$TEMP_DIR/test.wasm" 2>/dev/null; then
    # Run with --invoke to get return value, untag integer (divide by 4)
    wasm_tagged=$(WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke run "$TEMP_DIR/test.wasm" 2>/dev/null | grep -v "^warning")
    if [ -n "$wasm_tagged" ]; then
      # Untag: shift right 2 bits (divide by 4)
      wasm_result=$((wasm_tagged >> 2))
    else
      wasm_result="<no output>"
    fi
  else
    wasm_result="<compile error>"
  fi

  # Compare
  if [ "$interp_result" = "$wasm_result" ]; then
    echo "PASS: $expr => $interp_result"
    passed=$((passed + 1))
  else
    echo "FAIL: $expr"
    echo "  Interpreter: $interp_result"
    echo "  WASM:        $wasm_result (tagged: $wasm_tagged)"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Summary: $passed passed, $failed failed"

if [ $failed -gt 0 ]; then
  exit 1
fi
