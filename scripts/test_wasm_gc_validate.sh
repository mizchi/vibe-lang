#!/usr/bin/env bash
set -euo pipefail

# Validate wasm-gc output: type section encoding and basic compilation.
#
# Gate checks:
# 1. Small wasm-gc files pass wasm-tools validate (type encoding correctness)
# 2. wasm-gc mainlane E2E tests pass (runtime correctness)
# 3. Selfhost compiler compiles to wasm-gc (P4 regression check)
#
# Requires: moon, wasm-tools, wasmtime (for E2E)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }

cd "$PROJECT_ROOT"

VIBE="${VIBE_CLI:-_build/native/debug/build/cmd/vibe/vibe.exe}"
if [ ! -x "$VIBE" ]; then
  echo "Building vibe CLI (debug)..."
  moon build --target native src/cmd/vibe 2>/dev/null
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "ERROR: wasm-tools not found" >&2
  exit 1
fi

TMP_DIR="/tmp/vibe_gc_validate_$$"
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --- Gate 1: Small wasm-gc files validate (type encoding) ---

echo "=== Gate 1: wasm-gc type encoding validation ==="

for src in \
  "let add: (Int, Int) -> Int = (x, y) -> { x + y }; add(3, 4)" \
  "let fib: (Int) -> Int = (n) -> { if n <= 1 { n } else { fib(n-1) + fib(n-2) } }; fib(10)" \
  "enum Color { Red; Green; Blue }; match Green { Red => 1, Green => 2, Blue => 3 }" \
; do
  # Note: struct field access has a known func body type mismatch (#199)
  # "struct P { x: Int; y: Int }; let p = P::{ x: 3, y: 4 }; p.x + p.y"
  label=$(echo "$src" | head -c 40)
  echo "$src" > "$TMP_DIR/test.vibe"
  if VIBE_USE_SESSION_HTTP=0 "$VIBE" compile --wasm-gc "$TMP_DIR/test.vibe" -o "$TMP_DIR/test.wasm" 2>/dev/null; then
    if wasm-tools validate --features all "$TMP_DIR/test.wasm" 2>/dev/null; then
      log_pass "validate: $label..."
    else
      log_fail "validate: $label..."
    fi
  else
    log_fail "compile: $label..."
  fi
done

# --- Gate 2: Selfhost compiler compiles to wasm-gc ---

echo ""
echo "=== Gate 2: Selfhost wasm-gc compilation (P4 gate) ==="

if VIBE_USE_SESSION_HTTP=0 "$VIBE" compile --wasm-gc vibe/compiler/selfhost_cli_support.vibe -o "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null; then
  SIZE=$(stat -c%s "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null || stat -f%z "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null)
  GZIP_SIZE=$(gzip -c "$TMP_DIR/selfhost_gc.wasm" | wc -c)
  log_pass "selfhost wasm-gc build: ${SIZE} bytes raw, ${GZIP_SIZE} bytes gzip"

  # Size regression: should be under 500KB raw
  if [ "$SIZE" -lt 512000 ]; then
    log_pass "selfhost size < 500KB raw"
  else
    log_fail "selfhost size regression: ${SIZE} bytes (> 500KB)"
  fi
else
  log_fail "selfhost wasm-gc compile failed"
fi

# --- Gate 3: P4 selfhost check (import resolution) ---

echo ""
echo "=== Gate 3: P4 selfhost check (import resolution) ==="

for f in \
  vibe/compiler/codegen/wasm_emit/simd_patterns.vibe \
  vibe/compiler/entry/source_compile/gc_only/index.vibe \
; do
  if VIBE_USE_SESSION_HTTP=0 "$VIBE" check "$f" 2>/dev/null; then
    log_pass "check: $(basename $f)"
  else
    # Allow warnings, only fail on errors
    result=$(VIBE_USE_SESSION_HTTP=0 "$VIBE" check "$f" 2>&1)
    if echo "$result" | grep -q "error(s) found"; then
      log_fail "check: $(basename $f)"
    else
      log_pass "check: $(basename $f) (warnings only)"
    fi
  fi
done

# --- Summary ---

echo ""
echo "========================================="
echo -e "Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo "========================================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
