#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_bootstrap}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native --release src/cmd/vibe --warn-list '-29' >/dev/null
fi

mkdir -p "$OUT_DIR"

echo "[bootstrap] compiled selfhost test suite"
VIBE_TEST_BACKEND=compiled "$VIBE_BIN" test "$PROJECT_ROOT"/vibe/compiler/*_test.vibe

echo "[bootstrap] selfhost __to_string source path check"
if rg -n "double_to_string_compiler" \
  "$PROJECT_ROOT/vibe/compiler/values.vibe" \
  "$PROJECT_ROOT/vibe/compiler/token.vibe" \
  "$PROJECT_ROOT/vibe/compiler/printer.vibe" >/dev/null; then
  echo "bootstrap gate failed: selfhost compiler still depends on double_to_string_compiler" >&2
  exit 1
fi

echo "[bootstrap] compiled __to_string(Double/Float) probe"
TOSTRING_PROBE="$OUT_DIR/selfhost_tostring_probe.vibe"
cat >"$TOSTRING_PROBE" <<'EOF'
test "__to_string number parity" {
  assert(string_equals(__to_string(1.5), "1.5"))
  assert(string_equals(__to_string(2.0), "2"))
  assert(string_equals(__to_string(1.5f), "1.5"))
}
EOF
VIBE_TEST_BACKEND=compiled "$VIBE_BIN" test "$TOSTRING_PROBE"

echo "[bootstrap] selfhost probe smoke (vibe integration test index 44)"
moon test -p tests -f vibe_integration_test.mbt --target js --warn-list '-29' --index 44

echo "[bootstrap] deterministic compile check for $ENTRY_PATH"
WASM_A="$OUT_DIR/index_a.wasm"
WASM_B="$OUT_DIR/index_b.wasm"
"$VIBE_BIN" compile --wasm "$ENTRY_PATH" -o "$WASM_A"
"$VIBE_BIN" compile --wasm "$ENTRY_PATH" -o "$WASM_B"

if command -v wasm-tools >/dev/null 2>&1; then
  wasm-tools validate --features all "$WASM_A"
  wasm-tools validate --features all "$WASM_B"
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_A="$(shasum -a 256 "$WASM_A" | awk '{print $1}')"
HASH_B="$(shasum -a 256 "$WASM_B" | awk '{print $1}')"
if [ "$HASH_A" != "$HASH_B" ]; then
  echo "bootstrap gate failed: wasm hash mismatch" >&2
  echo "  first : $HASH_A" >&2
  echo "  second: $HASH_B" >&2
  exit 1
fi

echo "bootstrap gate passed: hash=$HASH_A"
