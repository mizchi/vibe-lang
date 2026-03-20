#!/usr/bin/env bash
# Test that `vibe build --debug` produces valid wasm for the selfhost compiler.
# Also verifies the cached (second) build path works.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"

TMPDIR="${TMPDIR:-/tmp}"
WORK="$TMPDIR/vibe_linked_debug_test_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
STRING_CASE_DIR="$WORK/string_case"
STRING_LIB_WASM="$STRING_CASE_DIR/.vibe/debug/main/lib.wasm"
STRING_RELEASE_WASM="$STRING_CASE_DIR/main.release.wasm"

echo "=== linked debug build: selfhost compiler ==="

# Clean cache
CACHE_DIR="$ROOT_DIR/vibe/.vibe/debug/compiler_index"
rm -rf "$CACHE_DIR"

# First build (full: db load + library compilation)
echo "  [1/4] first build (no cache)..."
if ! timeout 120 "$CLI" build --debug "$ROOT_DIR/vibe/compiler/index.vibe" \
  -o "$WORK/debug1.wasm" >/dev/null 2>&1; then
  echo "FAIL: first debug build failed"
  exit 1
fi

# Validate wasm
echo "  [2/4] wasm validation..."
if ! wasm-tools validate "$WORK/debug1.wasm" 2>/dev/null; then
  echo "FAIL: debug build produced invalid wasm"
  exit 1
fi

# Second build (cached: fast path)
echo "  [3/4] second build (cached)..."
if ! timeout 30 "$CLI" build --debug "$ROOT_DIR/vibe/compiler/index.vibe" \
  -o "$WORK/debug2.wasm" >/dev/null 2>&1; then
  echo "FAIL: cached debug build failed"
  exit 1
fi

# Validate cached build
echo "  [4/4] cached wasm validation..."
if ! wasm-tools validate "$WORK/debug2.wasm" 2>/dev/null; then
  echo "FAIL: cached debug build produced invalid wasm"
  exit 1
fi

# Compare sizes (should be identical)
SIZE1=$(wc -c < "$WORK/debug1.wasm")
SIZE2=$(wc -c < "$WORK/debug2.wasm")
echo ""
echo "=== linked debug build: OK ==="
echo "  first build:  $SIZE1 bytes"
echo "  cached build: $SIZE2 bytes"
if [ "$SIZE1" -ne "$SIZE2" ]; then
  echo "  WARNING: sizes differ (expected identical)"
fi

# Library module count
LIB_COUNT=$(ls "$CACHE_DIR"/*.wasm 2>/dev/null | wc -l | tr -d ' ')
echo "  library modules: $LIB_COUNT"

# WASI import check
WASI_MODULES=0
for f in "$CACHE_DIR"/*.wasm; do
  count=$(wasm-tools print "$f" 2>/dev/null | grep -c "wasi:" || true)
  if [ "$count" -gt 0 ]; then
    WASI_MODULES=$((WASI_MODULES + 1))
  fi
done
echo "  WASI-dependent modules: $WASI_MODULES"

# Cross-module string concat should work via shared linked memory/heap state.
mkdir -p "$STRING_CASE_DIR"
cat >"$STRING_CASE_DIR/lib.vibe" <<'EOF'
export let helper = () -> String { "Hello" }
EOF
cat >"$STRING_CASE_DIR/main.vibe" <<'EOF'
import ./lib.vibe { helper }
String::length(String::concat(helper(), ", world"))
EOF

echo "  [5/5] cross-module string concat..."
if ! timeout 30 "$CLI" build --debug "$STRING_CASE_DIR/main.vibe" \
  -o "$STRING_CASE_DIR/main.wasm" >/dev/null 2>&1; then
  echo "FAIL: string linked debug build failed"
  exit 1
fi
if ! timeout 30 "$CLI" build --release "$STRING_CASE_DIR/main.vibe" \
  -o "$STRING_RELEASE_WASM" >/dev/null 2>&1; then
  echo "FAIL: string release build failed"
  exit 1
fi
if ! [ -f "$STRING_LIB_WASM" ]; then
  echo "FAIL: string linked debug library wasm missing"
  exit 1
fi
STRING_EXPECTED="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run --invoke _start "$STRING_RELEASE_WASM" \
  2>&1 || true)"
STRING_RESULT="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run --preload lib="$STRING_LIB_WASM" \
  --invoke _start "$STRING_CASE_DIR/main.wasm" 2>&1 || true)"
if ! [ "$STRING_RESULT" = "$STRING_EXPECTED" ]; then
  echo "FAIL: cross-module string concat returned unexpected result"
  echo "expected:"
  echo "$STRING_EXPECTED"
  echo "actual:"
  echo "$STRING_RESULT"
  exit 1
fi
