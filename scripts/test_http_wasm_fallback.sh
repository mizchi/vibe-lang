#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_wasm_fallback.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native --release src/cmd/vibe --warn-list '-29' >/dev/null
fi

if [ ! -x "$WASMTIME_RUN" ]; then
  echo "wasmtime runner not found: $WASMTIME_RUN" >&2
  exit 1
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools not found in PATH" >&2
  exit 1
fi

passed=0
failed=0

run_case() {
  local name="$1"
  local expr="$2"
  local expected="$3"
  local file="$TMP_DIR/${name}.vibe"
  local wasm="$TMP_DIR/${name}.wasm"
  cat > "$file" <<VIBE
let main = () -> Int with { Error, Net } {
  handle {
    $expr
    0
  } {
    Error(_) => $expected
  }
}

main()
VIBE

  if ! "$VIBE_BIN" compile --wasm --debug-errors "$file" -o "$wasm" >/dev/null 2>&1; then
    echo "FAIL: $name (wasm compile failed)"
    failed=$((failed + 1))
    return
  fi

  if ! wasm-tools validate --features all "$wasm" >/dev/null 2>&1; then
    echo "FAIL: $name (wasm validate failed)"
    failed=$((failed + 1))
    return
  fi

  local wasm_tagged
  wasm_tagged="$(VIBE_WASMTIME_WASM_FLAGS='exceptions=y' "$WASMTIME_RUN" --invoke run "$wasm" 2>/dev/null | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
  if [ -z "$wasm_tagged" ]; then
    echo "FAIL: $name (wasmtime output missing)"
    failed=$((failed + 1))
    return
  fi

  local wasm_result
  wasm_result=$((wasm_tagged >> 2))
  if [ "$wasm_result" = "$expected" ]; then
    echo "PASS: $name => $wasm_result"
    passed=$((passed + 1))
  else
    echo "FAIL: $name (expected=$expected, got=$wasm_result tagged=$wasm_tagged)"
    failed=$((failed + 1))
  fi
}

run_case "http_request_throw_is_catchable" "let _ = http_request(\"GET\", \"https://example.com\", \"\", \"\")" "11"
run_case "http_listen_throw_is_catchable" "let _ = http_listen(8080)" "12"
run_case "http_respond_throw_is_catchable" "http_respond(0, 200, \"\", \"\")" "13"

echo "Summary: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
