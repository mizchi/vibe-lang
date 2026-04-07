#!/usr/bin/env bash
# Test that `vibe build --debug` produces valid wasm for the selfhost compiler.
# Also verifies the cached (second) build path works.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"

TMPDIR="${TMPDIR:-/tmp}"
WORK="$TMPDIR/vibe_linked_debug_test_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
STRING_CASE_DIR="$WORK/string_case"
STRING_LIB_WASM="$STRING_CASE_DIR/.vibe/debug/main/lib.wasm"
STRING_RELEASE_WASM="$STRING_CASE_DIR/main.release.wasm"
PRELUDE_CASE_DIR="$WORK/prelude_case"
PRELUDE_LIB_WASM="$PRELUDE_CASE_DIR/.vibe/debug/main/prelude_core.wasm"
PRELUDE_RELEASE_WASM="$PRELUDE_CASE_DIR/main.release.wasm"
MIXED_HOF_CASE_DIR="$WORK/mixed_hof_case"
MIXED_HOF_RELEASE_WASM="$MIXED_HOF_CASE_DIR/main.release.wasm"

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
LIB_COUNT=$(find "$CACHE_DIR" -name "*.wasm" 2>/dev/null | wc -l | tr -d ' ')
echo "  library modules: $LIB_COUNT"

# WASI import check
WASI_MODULES=0
for f in $(find "$CACHE_DIR" -name "*.wasm" 2>/dev/null); do
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

echo "  [5/7] cross-module string concat..."
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
STRING_PRELOAD_ARGS=()
for f in $(find "$STRING_CASE_DIR/.vibe/debug/main/" -name "*.wasm" 2>/dev/null); do
  if ! [ -f "$f" ]; then
    continue
  fi
  mod="$(basename "$f" .wasm)"
  STRING_PRELOAD_ARGS+=(--preload "$mod=$f")
done
STRING_EXPECTED="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run --invoke _start "$STRING_RELEASE_WASM" \
  2>&1 || true)"
STRING_RESULT="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run "${STRING_PRELOAD_ARGS[@]}" \
  --invoke _start "$STRING_CASE_DIR/main.wasm" 2>&1 || true)"
if ! [ "$STRING_RESULT" = "$STRING_EXPECTED" ]; then
  echo "FAIL: cross-module string concat returned unexpected result"
  echo "expected:"
  echo "$STRING_EXPECTED"
  echo "actual:"
  echo "$STRING_RESULT"
  exit 1
fi

# Prelude core scalar helpers should compile into a synthetic library module.
mkdir -p "$PRELUDE_CASE_DIR"
cat >"$PRELUDE_CASE_DIR/main.vibe" <<'EOF'
option_is_none(None)
EOF

echo "  [6/7] prelude core synthetic library..."
if ! timeout 30 "$CLI" build --debug "$PRELUDE_CASE_DIR/main.vibe" \
  -o "$PRELUDE_CASE_DIR/main.wasm" >/dev/null 2>&1; then
  echo "FAIL: prelude core linked debug build failed"
  exit 1
fi
if ! timeout 30 "$CLI" build --debug "$PRELUDE_CASE_DIR/main.vibe" \
  -o "$PRELUDE_CASE_DIR/main.cached.wasm" >/dev/null 2>&1; then
  echo "FAIL: cached prelude core linked debug build failed"
  exit 1
fi
if ! timeout 30 "$CLI" build --release "$PRELUDE_CASE_DIR/main.vibe" \
  -o "$PRELUDE_RELEASE_WASM" >/dev/null 2>&1; then
  echo "FAIL: prelude core release build failed"
  exit 1
fi
if ! [ -f "$PRELUDE_LIB_WASM" ]; then
  echo "FAIL: prelude core library wasm missing"
  exit 1
fi
PRELUDE_PRELOAD_ARGS=()
for f in $(find "$PRELUDE_CASE_DIR/.vibe/debug/main/" -name "*.wasm" 2>/dev/null); do
  if ! [ -f "$f" ]; then
    continue
  fi
  mod="$(basename "$f" .wasm)"
  PRELUDE_PRELOAD_ARGS+=(--preload "$mod=$f")
done
PRELUDE_EXPECTED="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run --invoke _start "$PRELUDE_RELEASE_WASM" \
  2>&1 || true)"
PRELUDE_RESULT="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run "${PRELUDE_PRELOAD_ARGS[@]}" \
  --invoke _start "$PRELUDE_CASE_DIR/main.wasm" 2>&1 || true)"
if ! [ "$PRELUDE_RESULT" = "$PRELUDE_EXPECTED" ]; then
  echo "FAIL: prelude core linked debug run returned unexpected result"
  echo "expected:"
  echo "$PRELUDE_EXPECTED"
  echo "actual:"
  echo "$PRELUDE_RESULT"
  exit 1
fi

# Mixed HOF deps should inline only HOF exports and keep scalar exports linked.
mkdir -p "$MIXED_HOF_CASE_DIR"
cat >"$MIXED_HOF_CASE_DIR/lib.vibe" <<'EOF'
export let add1 = (x : Int) -> Int { x + 1 }
export let apply_twice = (f : (Int) -> Int, x : Int) -> Int {
  f(f(x))
}
EOF
cat >"$MIXED_HOF_CASE_DIR/main.vibe" <<'EOF'
import ./lib.vibe { add1, apply_twice }
apply_twice(add1, 40)
EOF

echo "  [7/7] mixed HOF selective inline..."
if ! timeout 30 "$CLI" build --debug "$MIXED_HOF_CASE_DIR/main.vibe" \
  -o "$MIXED_HOF_CASE_DIR/main.wasm" >/dev/null 2>&1; then
  echo "FAIL: mixed HOF linked debug build failed"
  exit 1
fi
if ! timeout 30 "$CLI" build --debug "$MIXED_HOF_CASE_DIR/main.vibe" \
  -o "$MIXED_HOF_CASE_DIR/main.cached.wasm" >/dev/null 2>&1; then
  echo "FAIL: cached mixed HOF linked debug build failed"
  exit 1
fi
if ! timeout 30 "$CLI" build --release "$MIXED_HOF_CASE_DIR/main.vibe" \
  -o "$MIXED_HOF_RELEASE_WASM" >/dev/null 2>&1; then
  echo "FAIL: mixed HOF release build failed"
  exit 1
fi
MIXED_HOF_PRELOAD_ARGS=()
for f in $(find "$MIXED_HOF_CASE_DIR/.vibe/debug/main/" -name "*.wasm" 2>/dev/null); do
  if ! [ -f "$f" ]; then
    continue
  fi
  mod="$(basename "$f" .wasm)"
  MIXED_HOF_PRELOAD_ARGS+=(--preload "$mod=$f")
done
MIXED_HOF_EXPECTED="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run --invoke _start "$MIXED_HOF_RELEASE_WASM" \
  2>&1 || true)"
MIXED_HOF_RESULT="$(env VIBE_WASMTIME_WASM_FLAGS='exceptions=y' \
  "$ROOT_DIR/scripts/wasmtime_run.sh" run "${MIXED_HOF_PRELOAD_ARGS[@]}" \
  --invoke _start "$MIXED_HOF_CASE_DIR/main.wasm" 2>&1 || true)"
if ! [ "$MIXED_HOF_RESULT" = "$MIXED_HOF_EXPECTED" ]; then
  echo "FAIL: mixed HOF linked debug run returned unexpected result"
  echo "expected:"
  echo "$MIXED_HOF_EXPECTED"
  echo "actual:"
  echo "$MIXED_HOF_RESULT"
  exit 1
fi
