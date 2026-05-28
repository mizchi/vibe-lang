#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "=== HTTP P3 handler gate ==="
PASS=0
FAIL=0
TMP_FILES=()

cleanup() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

strip_fixture_data() {
  local src="$1"
  local dst
  dst="$(mktemp "${TMPDIR:-/tmp}/p3_handler_XXXXXX")"
  sed '/^__DATA__$/,$d' "$src" >"$dst"
  TMP_FILES+=("$dst")
  echo "$dst"
}

HANDLER_SRC="$(strip_fixture_data fixtures/http_p3_handler_string.vibe)"

# --- Sub-gate 1: Component string lift validation ---
echo "--- 1. Component string lift (handler pattern) ---"

COMPONENT="dist/http_p3_handler_string.component.wasm"
moon run --target native src/cmd/vibe -- compile --component-string-lift "$HANDLER_SRC" -o "$COMPONENT" 2>/dev/null

if [ ! -f "$COMPONENT" ]; then
  echo "FAIL: component not generated"
  FAIL=$((FAIL + 1))
else
  # Validate component
  if wasm-tools validate --features all "$COMPONENT" 2>/dev/null; then
    echo "PASS: component validates"
    PASS=$((PASS + 1))
  else
    echo "FAIL: component validation failed"
    FAIL=$((FAIL + 1))
  fi

  # Check component header
  MAGIC=$(xxd -l4 -p "$COMPONENT")
  if [ "$MAGIC" = "0061736d" ]; then
    echo "PASS: component magic bytes"
    PASS=$((PASS + 1))
  else
    echo "FAIL: bad magic: $MAGIC"
    FAIL=$((FAIL + 1))
  fi

  # Check version byte (0x0d = component)
  VERSION=$(xxd -s4 -l1 -p "$COMPONENT")
  if [ "$VERSION" = "0d" ]; then
    echo "PASS: component version 0x0d"
    PASS=$((PASS + 1))
  else
    echo "FAIL: bad version: $VERSION"
    FAIL=$((FAIL + 1))
  fi

  # Check handler export exists in binary
  if strings "$COMPONENT" | grep -q "handler"; then
    echo "PASS: handler export found"
    PASS=$((PASS + 1))
  else
    echo "FAIL: handler export not found"
    FAIL=$((FAIL + 1))
  fi
fi

# --- Sub-gate 2: Incompatible server builtins rejection ---
echo ""
echo "--- 2. Incompatible server builtins rejection ---"

REJECT_SRC=$(mktemp "${TMPDIR:-/tmp}/p3_reject_XXXXXX")
cat > "$REJECT_SRC" <<'EOF'
export let handler = (method: String, url: String) -> Int with {Net} {
  let listener = http_listen(8080)
  let _ = http_accept(listener)
  200
}
handler("GET", "/")
EOF

if moon run --target native src/cmd/vibe -- compile --component-string-lift "$REJECT_SRC" 2>/dev/null; then
  echo "FAIL: should have rejected incompatible builtins"
  FAIL=$((FAIL + 1))
else
  echo "PASS: incompatible builtins rejected"
  PASS=$((PASS + 1))
fi
rm -f "$REJECT_SRC"

# --- Sub-gate 3: Core wasm exports for P3 ---
echo ""
echo "--- 3. Core wasm exports (handler + cabi_realloc + memory) ---"

CORE_WASM="dist/http_p3_handler_string.wasm"
moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc "$HANDLER_SRC" -o "$CORE_WASM" 2>/dev/null

EXPORTS=$(wasm-tools dump "$CORE_WASM" 2>/dev/null | grep 'export Export' || true)

for name in handler cabi_realloc memory; do
  if echo "$EXPORTS" | grep -q "name: \"$name\""; then
    echo "PASS: export '$name' found"
    PASS=$((PASS + 1))
  else
    echo "FAIL: export '$name' missing"
    FAIL=$((FAIL + 1))
  fi
done

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
echo "=== HTTP P3 handler gate: $PASS/$TOTAL passed ==="

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
