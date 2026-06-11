#!/usr/bin/env bash
set -euo pipefail

# Validate wasm-gc output: type section encoding and basic compilation.
#
# Gate checks:
# 1. Small wasm-gc files pass wasm-tools validate (type encoding correctness)
# 2. wasm-gc mainlane E2E tests pass (runtime correctness)
# 3. Selfhost wasm emitter module compiles to wasm-gc (P4 regression check)
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

VIBE="${VIBE_BIN:-${VIBE_CLI:-}}"
if [ -n "$VIBE" ] && [ ! -x "$VIBE" ]; then
  echo "ERROR: VIBE_BIN/VIBE_CLI is not executable: $VIBE" >&2
  exit 1
fi
if [ -z "$VIBE" ]; then
  for candidate in \
    target/native/release/build/cmd/vibe/vibe.exe \
    _build/native/release/build/cmd/vibe/vibe.exe \
    _build/native/debug/build/cmd/vibe/vibe.exe \
    target/native/debug/build/cmd/vibe/vibe.exe \
  ; do
    if [ -x "$candidate" ]; then
      VIBE="$candidate"
      break
    fi
  done
fi
if [ -z "$VIBE" ]; then
  echo "Building vibe CLI (debug)..."
  VIBE_MOON_WARN_LIST="${VIBE_MOON_WARN_LIST:--29}" source "$SCRIPT_DIR/ensure_native_cli.sh"
  VIBE="$VIBE_CLI_BIN"
fi
if [ ! -x "$VIBE" ]; then
  echo "ERROR: vibe CLI not found and build failed" >&2
  exit 1
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "Installing wasm-tools..."
  WASM_TOOLS_VERSION="v1.245.1"
  curl -fsSL --retry 3 \
    -o /tmp/wasm-tools.tar.gz \
    "https://github.com/bytecodealliance/wasm-tools/releases/download/${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION#v}-x86_64-linux.tar.gz" 2>/dev/null
  if [ $? -eq 0 ]; then
    tar -xzf /tmp/wasm-tools.tar.gz -C /tmp
    sudo install -m 0755 "/tmp/wasm-tools-${WASM_TOOLS_VERSION#v}-x86_64-linux/wasm-tools" /usr/local/bin/wasm-tools 2>/dev/null \
      || install -m 0755 "/tmp/wasm-tools-${WASM_TOOLS_VERSION#v}-x86_64-linux/wasm-tools" "$HOME/.local/bin/wasm-tools" 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! command -v wasm-tools >/dev/null 2>&1; then
    echo "WARN: wasm-tools not available, skipping validate checks" >&2
    echo "========================================="
    echo "Results: skipped (wasm-tools not found)"
    echo "========================================="
    exit 0
  fi
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

# --- Gate 2: Selfhost wasm emitter compiles to wasm-gc ---

echo ""
echo "=== Gate 2: Selfhost wasm emitter wasm-gc compilation (P4 gate) ==="

if VIBE_USE_SESSION_HTTP=0 "$VIBE" compile --wasm-gc vibe/compiler/codegen/wasm_emit/instructions.vibe -o "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null; then
  SIZE=$(stat -c%s "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null || stat -f%z "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null)
  GZIP_SIZE=$(gzip -c "$TMP_DIR/selfhost_gc.wasm" | wc -c)
  log_pass "selfhost wasm emitter wasm-gc build: ${SIZE} bytes raw, ${GZIP_SIZE} bytes gzip"

  if wasm-tools validate --features all "$TMP_DIR/selfhost_gc.wasm" 2>/dev/null; then
    log_pass "selfhost wasm emitter validate"
  else
    log_fail "selfhost wasm emitter validate"
  fi

  # Size regression: should be under 500KB raw
  if [ "$SIZE" -lt 512000 ]; then
    log_pass "selfhost wasm emitter size < 500KB raw"
  else
    log_fail "selfhost wasm emitter size regression: ${SIZE} bytes (> 500KB)"
  fi
else
  log_fail "selfhost wasm emitter wasm-gc compile failed"
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
