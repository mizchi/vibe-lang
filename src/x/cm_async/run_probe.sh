#!/usr/bin/env bash
set -euo pipefail

# CM async probe: verifies that concurrency-support + component-model-async
# flags are accepted and a component runs correctly on the current platform.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WAT_PATH="$SCRIPT_DIR/cm_async_probe.wat"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_cm_async_probe.XXXXXX")"
WASM_PATH="$TMP_DIR/cm_async_probe.wasm"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required. install: cargo install wasm-tools" >&2
  exit 1
fi

WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh")"

echo "[cm-async-probe] wasmtime: $($WASMTIME_BIN --version)"
echo "[cm-async-probe] platform: $(uname -ms)"

# Parse WAT -> WASM
wasm-tools parse "$WAT_PATH" -o "$WASM_PATH"
wasm-tools validate --features all "$WASM_PATH"
echo "[cm-async-probe] component validated OK"

# Flag combinations to test
declare -a TESTS=(
  "concurrency-support=y"
  "concurrency-support=y component-model-async=y"
  "concurrency-support=y component-model-async=y component-model-async-builtins=y"
  "concurrency-support=y component-model-async=y component-model-threading=y"
  "concurrency-support=y component-model-async=y component-model-error-context=y"
  "concurrency-support=y component-model-async=y component-model-async-stackful=y"
)

PASS=0
FAIL=0

for flags in "${TESTS[@]}"; do
  WASM_ARGS=()
  for flag in $flags; do
    WASM_ARGS+=("-W" "$flag")
  done

  result=$("$WASMTIME_BIN" run "${WASM_ARGS[@]}" --invoke "run()" "$WASM_PATH" 2>&1) || true

  if [ "$result" = "42" ]; then
    echo "[cm-async-probe] PASS: -W $flags"
    PASS=$((PASS + 1))
  else
    echo "[cm-async-probe] FAIL: -W $flags"
    echo "  output: $result"
    FAIL=$((FAIL + 1))
  fi
done

# Also test that stack-switching reports its known limitation
stack_result=$("$WASMTIME_BIN" run -W stack-switching=y --invoke "run()" "$WASM_PATH" 2>&1) || true
if echo "$stack_result" | grep -q "not supported"; then
  echo "[cm-async-probe] INFO: stack-switching not supported (expected on non-x86_64)"
elif [ "$stack_result" = "42" ]; then
  echo "[cm-async-probe] INFO: stack-switching supported on this platform"
fi

# Also test known-invalid combination
invalid_result=$("$WASMTIME_BIN" run \
  -W component-model-async=y -W concurrency-support=n \
  --invoke "run()" "$WASM_PATH" 2>&1) || true
if echo "$invalid_result" | grep -q "concurrency support must be enabled"; then
  echo "[cm-async-probe] PASS: invalid combo correctly rejected"
  PASS=$((PASS + 1))
else
  echo "[cm-async-probe] FAIL: invalid combo not rejected"
  echo "  output: $invalid_result"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "[cm-async-probe] results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
