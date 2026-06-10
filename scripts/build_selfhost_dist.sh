#!/usr/bin/env bash
# Build distributable selfhost compiler WASM.
#
# Pipeline:
#   1. MoonBit host compiles vibe/cli/selfhost_entry.vibe → stage1.wasm (host-compiled)
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
#   VIBE_DIST_ENTRY_PATH   — entry file (default: vibe/cli/selfhost_entry.vibe)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/_build/dist"
ENTRY_PATH="${VIBE_DIST_ENTRY_PATH:-$PROJECT_ROOT/vibe/cli/selfhost_entry.vibe}"
OPT_LEVEL="${VIBE_DIST_OPT_LEVEL:--O3}"
SKIP_OPT="${VIBE_DIST_SKIP_OPT:-0}"

EXPLICIT_VIBE_BIN="${VIBE_BIN:-${VIBE_CLI:-}}"

mkdir -p "$DIST_DIR"

RAW_WASM="$DIST_DIR/selfhost_compiler_raw.wasm"
DIST_WASM="$DIST_DIR/selfhost_compiler.wasm"

resolve_host_cmd() {
  if [ -n "$EXPLICIT_VIBE_BIN" ]; then
    if [ ! -x "$EXPLICIT_VIBE_BIN" ]; then
      echo "[dist] VIBE_BIN/VIBE_CLI is not executable: $EXPLICIT_VIBE_BIN" >&2
      exit 1
    fi
    HOST_CMD=("$EXPLICIT_VIBE_BIN" compile --wasm --force-cabi-realloc)
    return
  fi

  local candidate
  for candidate in \
    "$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe" \
    "$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe" \
    "$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe" \
    "$PROJECT_ROOT/target/native/debug/build/cmd/vibe/vibe.exe" \
  ; do
    if [ -x "$candidate" ]; then
      HOST_CMD=("$candidate" compile --wasm --force-cabi-realloc)
      return
    fi
  done

  echo "[dist] building host CLI..." >&2
  VIBE_CLI_RELEASE=1 source "$SCRIPT_DIR/ensure_native_cli.sh"
  HOST_CMD=("$VIBE_CLI_BIN" compile --wasm --force-cabi-realloc)
}

# --- Step 1: Host compile ---
resolve_host_cmd

echo "[dist] stage1: host compile $ENTRY_PATH"
"${HOST_CMD[@]}" "$ENTRY_PATH" -o "$RAW_WASM"

raw_size=$(wc -c < "$RAW_WASM")
echo "[dist] stage1: $raw_size bytes ($(echo "scale=0; $raw_size / 1024" | bc) KB)"

if command -v wasm-tools >/dev/null 2>&1; then
  if ! wasm-tools validate --features exceptions "$RAW_WASM" >/dev/null; then
    echo "[dist] FAIL: raw selfhost compiler wasm failed validation" >&2
    exit 1
  fi
fi

# --- Step 2: wasm-opt ---
if [ "$SKIP_OPT" = "1" ]; then
  cp "$RAW_WASM" "$DIST_WASM"
  echo "[dist] wasm-opt: skipped"
elif command -v wasm-opt >/dev/null 2>&1; then
  echo "[dist] wasm-opt $OPT_LEVEL"
  if wasm-opt "$OPT_LEVEL" \
    --enable-bulk-memory \
    --enable-multivalue \
    --enable-exception-handling \
    "$RAW_WASM" -o "$DIST_WASM"; then
    opt_size=$(wc -c < "$DIST_WASM")
    echo "[dist] optimized: $opt_size bytes ($(echo "scale=0; $opt_size / 1024" | bc) KB, -$(echo "scale=0; ($raw_size - $opt_size) * 100 / $raw_size" | bc)%)"
  else
    echo "[dist] wasm-opt failed, using raw output" >&2
    cp "$RAW_WASM" "$DIST_WASM"
  fi
else
  echo "[dist] wasm-opt not found, using raw output" >&2
  cp "$RAW_WASM" "$DIST_WASM"
fi

if command -v wasm-tools >/dev/null 2>&1; then
  if ! wasm-tools validate --features exceptions "$DIST_WASM" >/dev/null; then
    echo "[dist] FAIL: distributable selfhost compiler wasm failed validation" >&2
    exit 1
  fi
fi

# --- Step 3: Validate ---
echo "[dist] validating..."

SAMPLE_DIR="$DIST_DIR/validate"
mkdir -p "$SAMPLE_DIR"
cat > "$SAMPLE_DIR/sample.vibe" <<'VIBE'
export let answer = () -> Int { 40 + 2 }
VIBE

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main \
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
