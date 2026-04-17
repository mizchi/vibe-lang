#!/bin/bash
# Test that vibe run and WASM compiled output produce the same results
# for pattern matching and other expressions.
# This verifies codegen correctness by comparing evaluation results.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEMP_DIR="/tmp/run_wasm_match"
WASMTIME_BIN="${WASMTIME_BIN:-$("$PROJECT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$PROJECT_DIR/scripts/wasmtime_run.sh"

# Clean stale temp dir to avoid carrying over generated test artifacts
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Use pre-built VIBE_BIN if set, otherwise fall back to moon run
if [ -n "${VIBE_BIN:-}" ] && [ -x "$VIBE_BIN" ]; then
  VIBE="$VIBE_BIN"
else
  VIBE="moon run $PROJECT_DIR/src/cmd/vibe/main.mbt --target native --"
fi

failed=0
passed=0
skipped=0
test_index=0

SHARD_INDEX="${SHARD_INDEX:-0}"
SHARD_TOTAL="${SHARD_TOTAL:-1}"

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

  # For-in with mutable accumulation (wrapped in function — top-level let mut is disallowed)
  'let f = () -> Int { let mut total = 0; for x in [1, 2, 3, 4, 5] { total = total + x }; total }; f()'
  'let f = () -> Int { let mut sum = 0; for x in [10, 20, 30] { sum = sum + x; x }; sum }; f()'

  # String builtins
  'String::length("hello")'
  'if String::contains("hello world", "world") { 1 } else { 0 }'
  'if String::contains("hello", "xyz") { 1 } else { 0 }'
  'if String::starts_with("hello", "hel") { 1 } else { 0 }'
  'if String::ends_with("hello", "llo") { 1 } else { 0 }'
  'String::index_of("hello world", "world")'
  'String::index_of("hello", "xyz")'
  'String::last_index_of("abcabc", "abc")'
  'String::char_code_at("A", 0)'
  'String::count("abcabc", "abc")'
  'String::count("aaaa", "aa")'
  'String::length(String::trim("  hi  "))'
  'String::length(String::trim_start("  hi  "))'
  'String::length(String::trim_end("  hi  "))'
  'String::length(String::concat("hello", " world"))'
  'String::length(String::substring("hello world", 0, 5))'
  'String::char_code_at(String::to_upper("abc"), 0)'
  'String::char_code_at(String::to_lower("ABC"), 0)'

  # String equality operator (==)
  'if "hello" == "hello" { 1 } else { 0 }'
  'if "hello" == "world" { 1 } else { 0 }'
  'if "" == "" { 1 } else { 0 }'

  # String split
  'Array::length(String::split("a,b,c", ","))'
  'Array::length(String::split("hello", ","))'
  'Array::length(String::split("a::b::c", "::"))'
  'Array::length(String::split("abc", ""))'

  # String replace
  'String::length(String::replace("hello world", "world", "vibe"))'
  'String::length(String::replace("aaa", "a", "bb"))'
  'String::length(String::replace_all("aaa", "a", "bb"))'
  'if String::replace("foo bar foo", "foo", "baz") == "baz bar foo" { 1 } else { 0 }'
  'if String::replace_all("foo bar foo", "foo", "baz") == "baz bar baz" { 1 } else { 0 }'

  # Break and continue (wrapped in function — top-level let mut is disallowed)
  'let f = () -> Int { let mut sum = 0; let mut i = 0; while i < 10 { i = i + 1; if i == 5 { break }; sum = sum + i }; sum }; f()'
  'let f = () -> Int { let mut sum = 0; let mut i = 0; while i < 10 { i = i + 1; if i % 2 == 0 { continue }; sum = sum + i }; sum }; f()'
  'let f = () -> Int { let mut sum = 0; let mut i = 0; while i < 100 { i = i + 1; if i % 3 == 0 { continue }; if i > 10 { break }; sum = sum + i }; sum }; f()'

  # Closures and higher-order functions
  'let f = (x: Int) -> Int { x * 2 }; f(5)'
  'let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }; apply((x: Int) -> Int { x + 1 }, 5)'
  'let make_adder = (n: Int) -> (Int) -> Int { (x: Int) -> Int { x + n } }; let add5 = make_adder(5); add5(10)'

  # Recursive functions
  'let rec fact = (n: Int) -> Int { if n <= 1 { 1 } else { n * fact(n - 1) } }; fact(5)'
  'let rec fib = (n: Int) -> Int { if n <= 1 { n } else { fib(n - 1) + fib(n - 2) } }; fib(10)'

  # Array operations
  'Array::length([1, 2, 3, 4, 5])'
  'let arr = [10, 20, 30]; arr[1]'
  'Array::length(Array::concat([1, 2], [3, 4]))'
  'Array::length(Array::slice([1, 2, 3, 4, 5], 1, 3))'

  # Pipe operator
  'let double = (x: Int) -> Int { x * 2 }; 5 |> double'
  'let inc = (x: Int) -> Int { x + 1 }; let double = (x: Int) -> Int { x * 2 }; 3 |> inc |> double'

  # Block expressions
  'let x = { let a = 10; let b = 20; a + b }; x'
  'let y = { let f = () -> Int { let mut sum = 0; for i in [1, 2, 3] { sum = sum + i }; sum }; f() }; y'

  # Complex combinations (wrapped in function — top-level let mut is disallowed)
  'let f = () -> Int { let arr = [1, 2, 3, 4, 5]; let mut sum = 0; for x in arr { if x % 2 == 1 { sum = sum + x * x } }; sum }; f()'
  'match (Some(10), Some(20)) { (Some(a), Some(b)) => a + b, _ => 0 }'
  'let rec sum_to = (n: Int) -> Int { if n <= 0 { 0 } else { n + sum_to(n - 1) } }; sum_to(10)'

  # Bitwise operations
  '7 & 3'
  '5 | 3'
  '6 ^ 3'
  '1 << 4'
  '32 >> 3'

  # Boolean operations
  'if true && true { 1 } else { 0 }'
  'if true && false { 1 } else { 0 }'
  'if false || true { 1 } else { 0 }'
  'if false || false { 1 } else { 0 }'

  # Chained function calls (currying)
  'let add = (x: Int) -> (Int) -> Int { (y: Int) -> Int { x + y } }; add(10)(5)'
  'let f = (a: Int) -> (Int) -> (Int) -> Int { (b: Int) -> (Int) -> Int { (c: Int) -> Int { a + b + c } } }; f(1)(2)(3)'
  'let add = (x: Int) -> (Int) -> Int { (y: Int) -> Int { x + y } }; add(10)(20) + add(3)(4)'

  # Nested closures with chained calls
  'let outer = (x: Int) -> (Int) -> Int { let y = x + 1; (z: Int) -> Int { y + z } }; outer(10)(5)'
  'let compose = (f: (Int) -> Int, g: (Int) -> Int) -> (Int) -> Int { (x: Int) -> Int { f(g(x)) } }; let add1 = (x: Int) -> Int { x + 1 }; let mul2 = (x: Int) -> Int { x * 2 }; compose(add1, mul2)(5)'

  # Double::to_int (replaces deprecated double_to_int + parse_double)
  'Double::to_int(3.14 * 100.0)'
  'Double::to_int(0.0)'
  'Double::to_int(-2.5 * 10.0)'
  'Double::to_int(1.5 + 2.5)'
  'Double::to_int(42.0)'
)

echo "Testing vibe run vs WASM output..."
echo ""

for expr in "${test_cases[@]}"; do
  if [ "$SHARD_TOTAL" -gt 1 ]; then
    if [ $((test_index % SHARD_TOTAL)) -ne "$SHARD_INDEX" ]; then
      test_index=$((test_index + 1))
      skipped=$((skipped + 1))
      continue
    fi
  fi
  test_index=$((test_index + 1))
  case_path="$TEMP_DIR/test_${test_index}.vibe"
  wasm_path="$TEMP_DIR/test_${test_index}.wasm"

  # Create test file
  echo "$expr" > "$case_path"

  # Get reference result via vibe run
  run_output=$($VIBE run "$case_path" 2>/dev/null | grep "^last: " | sed 's/last: //')
  run_result="$run_output"

  # Compile and run WASM with wasmtime directly.
  if $VIBE compile --wasm "$case_path" -o "$wasm_path" 2>/dev/null; then
    wasm_result=$(WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke _start "$wasm_path" 2>/dev/null | grep -v "^warning")
    if [ -z "$wasm_result" ]; then
      wasm_result="<no output>"
    fi
  else
    wasm_result="<compile error>"
  fi

  # Compare
  if [ "$run_result" = "$wasm_result" ]; then
    echo "PASS: $expr => $run_result"
    passed=$((passed + 1))
  else
    echo "FAIL: $expr"
    echo "  run:  $run_result"
    echo "  WASM: $wasm_result"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Summary: $passed passed, $failed failed, $skipped skipped"
if [ "$SHARD_TOTAL" -gt 1 ]; then
  echo "Shard: $((SHARD_INDEX + 1))/$SHARD_TOTAL"
fi

if [ $failed -gt 0 ]; then
  exit 1
fi
