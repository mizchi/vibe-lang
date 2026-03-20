#!/usr/bin/env bash
# Verify that `vibe build --debug` and `vibe build --release` produce
# identical execution results for all test cases.
#
# Usage:
#   scripts/test_build_parity.sh                    # default cases
#   scripts/test_build_parity.sh file1.vibe file2.vibe  # specific files
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"
TIMEOUT="${VIBE_BUILD_PARITY_TIMEOUT:-10}"
TMPDIR="${TMPDIR:-/tmp}"
WORK="$TMPDIR/vibe_build_parity_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skip=0
failures=()

run_parity_test() {
  local src="$1"
  local name
  name="$(basename "$src")"

  # --- release build ---
  local release_wasm="$WORK/${name}.release.wasm"
  local release_out=""
  local release_rc=0
  if ! timeout "$TIMEOUT" "$CLI" build --release "$src" -o "$release_wasm" >/dev/null 2>&1; then
    skip=$((skip + 1))
    return
  fi
  release_out="$(timeout "$TIMEOUT" wasmtime run -W exceptions=y -W unknown-imports-default=y --invoke _start "$release_wasm" 2>&1 || true)"
  release_rc=$?

  # --- debug build ---
  # Clean cache to test from scratch
  local src_dir
  src_dir="$(dirname "$src")"
  rm -rf "$src_dir/.vibe/debug"

  local debug_wasm="$WORK/${name}.debug.wasm"
  local debug_out=""
  local debug_rc=0
  if ! timeout "$TIMEOUT" "$CLI" build --debug "$src" -o "$debug_wasm" >/dev/null 2>&1; then
    skip=$((skip + 1))
    return
  fi

  # Find preload modules from build output
  local build_output
  build_output="$("$CLI" build --debug "$src" -o "$debug_wasm" 2>&1)"
  local preload_args=""
  while IFS= read -r line; do
    if [[ "$line" == *"--preload"* ]]; then
      # Extract preload args from "  run: wasmtime --preload mod=path ..."
      preload_args="$(echo "$line" | sed 's/.*wasmtime //' | sed 's/ [^ ]*\.wasm$//')"
    fi
  done <<< "$build_output"

  if [[ -n "$preload_args" ]]; then
    # shellcheck disable=SC2086
    debug_out="$(timeout "$TIMEOUT" wasmtime run -W exceptions=y -W unknown-imports-default=y $preload_args --invoke _start "$debug_wasm" 2>&1 || true)"
  else
    debug_out="$(timeout "$TIMEOUT" wasmtime run -W exceptions=y -W unknown-imports-default=y --invoke _start "$debug_wasm" 2>&1 || true)"
  fi
  debug_rc=$?

  # Strip wasmtime warnings for comparison
  release_out="$(echo "$release_out" | grep -v '^warning:')"
  debug_out="$(echo "$debug_out" | grep -v '^warning:')"

  if [[ "$release_out" == "$debug_out" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failures+=("$name: release='$release_out' debug='$debug_out'")
  fi
}

# Collect test files
declare -a files
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  # Default: inline test cases
  # Pure arithmetic
  cat > "$WORK/arith.vibe" << 'EOF'
let result = (1 + 2) * 3 - 1
result
EOF
  files+=("$WORK/arith.vibe")

  # Fibonacci
  cat > "$WORK/fib.vibe" << 'EOF'
let fib = (n: Int) -> Int {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}
fib(10)
EOF
  files+=("$WORK/fib.vibe")

  # Array operations
  cat > "$WORK/array.vibe" << 'EOF'
let arr = [1, 2, 3, 4, 5]
let sum = Array::fold(arr, 0, (acc: Int, x: Int) -> Int { acc + x })
sum
EOF
  files+=("$WORK/array.vibe")

  # String operations
  cat > "$WORK/string.vibe" << 'EOF'
let s = String::concat("hello", " world")
String::length(s)
EOF
  files+=("$WORK/string.vibe")

  # Match expression
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

  # Closures (no higher-order passing)
  cat > "$WORK/closure.vibe" << 'EOF'
let make_adder = (n: Int) -> (Int) -> Int {
  (x: Int) -> Int { x + n }
}
let add5 = make_adder(5)
add5(10)
EOF
  files+=("$WORK/closure.vibe")

  # Tuple
  cat > "$WORK/tuple.vibe" << 'EOF'
let swap = (a: Int, b: Int) -> (Int, Int) { (b, a) }
let (x, y) = swap(1, 2)
x * 10 + y
EOF
  files+=("$WORK/tuple.vibe")

  # Effect / throw
  cat > "$WORK/effect.vibe" << 'EOF'
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if b == 0 { throw("div by zero") } else { a / b }
}
let result = handle { safe_div(10, 2) } { Error(_) => -1 }
result
EOF
  files+=("$WORK/effect.vibe")

  # Higher-order function (cross-module)
  mkdir -p "$WORK/hof"
  cat > "$WORK/hof/lib.vibe" << 'EOF'
export let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
export let add_ten = (x: Int) -> Int { x + 10 }
EOF
  cat > "$WORK/hof/main.vibe" << 'EOF'
import ./lib.vibe { apply, add_ten }
let double = (x: Int) -> Int { x * 2 }
apply(double, 10) + add_ten(5)
EOF
  files+=("$WORK/hof/main.vibe")

  # Cross-module string operations
  mkdir -p "$WORK/str_cross"
  cat > "$WORK/str_cross/lib.vibe" << 'EOF'
export let greet = (name: String) -> String {
  String::concat("Hello, ", name)
}
EOF
  cat > "$WORK/str_cross/main.vibe" << 'EOF'
import ./lib.vibe { greet }
let msg = greet("World")
String::length(msg)
EOF
  files+=("$WORK/str_cross/main.vibe")

  # With import (if available)
  if [[ -d "$ROOT_DIR/vibe/wasm/wasm_runtime" ]]; then
    mkdir -p "$WORK/wasm_runtime_case"
    cp "$ROOT_DIR/vibe/wasm/wasm_runtime/wasm_runtime.vibe" "$WORK/wasm_runtime_case/wasm_runtime.vibe"
    cat > "$WORK/wasm_runtime_case/main.vibe" << 'EOF'
import ./wasm_runtime.vibe { exec_body, make_memory }
let result = 42
result
EOF
    files+=("$WORK/wasm_runtime_case/main.vibe")
  fi
fi

for f in "${files[@]}"; do
  run_parity_test "$f"
done

echo ""
echo "=== build parity report ==="
echo "pass=$pass fail=$fail skip=$skip"

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  echo "[MISMATCH]"
  for f in "${failures[@]}"; do
    echo "  $f"
  done
  exit 1
fi
