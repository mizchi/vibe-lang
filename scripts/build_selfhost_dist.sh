#!/usr/bin/env bash
# Build distributable selfhost compiler WASM.
#
# Pipeline:
#   1. MoonBit host compiles selfhost_cli_core_entry.vibe → stage1.wasm (host-compiled)
#   2. (optional) wasm-opt -O3 on stage1 → stage1_opt.wasm
#   3. Validates output: compiles a sample program and runs it (answer=42)
#
# Outputs:
#   _build/dist/selfhost_compiler.wasm       — distributable compiler
#   _build/dist/selfhost_compiler_raw.wasm   — pre-optimization copy
#
# Env:
#   VIBE_DIST_SKIP_OPT=1   — skip wasm-opt step
#   VIBE_DIST_OPT_LEVEL    — wasm-opt level (default: -O3)
#   VIBE_DIST_ENTRY_PATH   — entry file (default: selfhost_cli_core_entry.vibe)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/_build/dist"
ENTRY_PATH="${VIBE_DIST_ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_core_entry.vibe}"
OPT_LEVEL="${VIBE_DIST_OPT_LEVEL:--O3}"
SKIP_OPT="${VIBE_DIST_SKIP_OPT:-0}"

HOST_VIBE_EXE_RELEASE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

mkdir -p "$DIST_DIR"

RAW_WASM="$DIST_DIR/selfhost_compiler_raw.wasm"
DIST_WASM="$DIST_DIR/selfhost_compiler.wasm"

# --- Step 1: Host compile ---
if [ -x "$HOST_VIBE_EXE_RELEASE" ]; then
  HOST_CMD=("$HOST_VIBE_EXE_RELEASE" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then
  HOST_CMD=("$HOST_VIBE_EXE_DEBUG" compile --wasm --force-cabi-realloc)
else
  echo "[dist] building host CLI..." >&2
  (cd "$PROJECT_ROOT" && moon build --target native --release src/cmd/vibe --warn-list '-1-7-24-29' >/dev/null)
  HOST_CMD=("$HOST_VIBE_EXE_RELEASE" compile --wasm --force-cabi-realloc)
fi

echo "[dist] stage1: host compile $ENTRY_PATH"
"${HOST_CMD[@]}" "$ENTRY_PATH" -o "$RAW_WASM"

raw_size=$(wc -c < "$RAW_WASM")
echo "[dist] stage1: $raw_size bytes ($(echo "scale=0; $raw_size / 1024" | bc) KB)"

# --- Step 2: wasm-opt ---
if [ "$SKIP_OPT" = "1" ]; then
  cp "$RAW_WASM" "$DIST_WASM"
  echo "[dist] wasm-opt: skipped"
elif command -v wasm-opt >/dev/null 2>&1; then
  echo "[dist] wasm-opt $OPT_LEVEL"
  wasm-opt "$OPT_LEVEL" \
    --enable-bulk-memory \
    --enable-multivalue \
    --enable-exception-handling \
    "$RAW_WASM" -o "$DIST_WASM"
  opt_size=$(wc -c < "$DIST_WASM")
  echo "[dist] optimized: $opt_size bytes ($(echo "scale=0; $opt_size / 1024" | bc) KB, -$(echo "scale=0; ($raw_size - $opt_size) * 100 / $raw_size" | bc)%)"
else
  echo "[dist] wasm-opt not found, using raw output" >&2
  cp "$RAW_WASM" "$DIST_WASM"
fi

# --- Step 3: Validate ---
echo "[dist] validating..."

SAMPLE_DIR="$DIST_DIR/validate"
mkdir -p "$SAMPLE_DIR"
cat > "$SAMPLE_DIR/sample.vibe" <<'VIBE'
let answer = () -> Int { 40 + 2 }
VIBE

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    "$DIST_WASM" \
    "${SAMPLE_DIR#$PROJECT_ROOT/}/sample.vibe" \
    "${SAMPLE_DIR#$PROJECT_ROOT/}/sample.wasm" \
    "answer" >/dev/null 2>&1

if [ ! -f "$SAMPLE_DIR/sample.wasm" ]; then
  echo "[dist] FAIL: sample wasm not produced" >&2
  exit 1
fi

sample_magic="$(od -An -t x1 -N 4 "$SAMPLE_DIR/sample.wasm" | tr -d ' \n')"
if [ "$sample_magic" != "0061736d" ]; then
  echo "[dist] FAIL: sample artifact is not valid wasm" >&2
  exit 1
fi

# Run sample: try --invoke _start first, then _start (for GC WASM)
sample_result="$(VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start "$SAMPLE_DIR/sample.wasm" 2>/dev/null | grep -E '^-?[0-9]+$' | tail -n 1 || true)"

if [ -z "$sample_result" ]; then
  # GC codegen outputs _start instead of run
  sample_result="$("$PROJECT_ROOT/scripts/wasmtime_run.sh" \
    -W gc "$SAMPLE_DIR/sample.wasm" 2>/dev/null | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
fi

if [ "$sample_result" != "42" ]; then
  echo "[dist] FAIL: sample returned '$sample_result' (expected 42)" >&2
  exit 1
fi

final_size=$(wc -c < "$DIST_WASM")
echo "[dist] OK: $DIST_WASM ($final_size bytes, $(echo "scale=0; $final_size / 1024" | bc) KB)"
