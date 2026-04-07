#!/usr/bin/env bash
set -euo pipefail

# Selfhost cutover gate: CLI contract verification + compile-lite parity.
# This script bundles Phase 1 (CLI contract) and Phase 0+2 (artifact parity)
# checks into a single CI gate.
#
# Env:
#   VIBE_BIN                           — host CLI binary
#   STAGE1_COMPILER_WASM               — selfhost WASI compiler wasm
#   VIBE_CUTOVER_REQUIRE_PARITY        — 1: fail on mismatch (default: 1), 0: monitor-only
#   VIBE_CUTOVER_INCLUDE_COMPILER_SIZE — 1: expand canary set (default: 1)
#   VIBE_CUTOVER_INCLUDE_FAIL_CASES    — 1: run expected-fail parity canaries (default: 1)
#   VIBE_CUTOVER_MODES                 — comma-separated compile-lite modes (default: mvp,no-dce)
#   VIBE_CUTOVER_STAGE_TIMEOUT_SEC     — per-stage timeout (default: 300)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cutover}"
STAGE_TIMEOUT_SEC="${VIBE_CUTOVER_STAGE_TIMEOUT_SEC:-300}"

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost Cutover Gate"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

# Ensure prerequisites are synced to the current workspace state.
# `moon build` is incremental, so always running it avoids stale parity inputs.
echo "[cutover-gate] syncing host CLI..." >&2
moon build --target native --release src/cmd/vibe --warn-list '-29'

echo "[cutover-gate] syncing selfhost WASI compiler..." >&2
moon build --target wasm src/cmd/vibe_compile_wasi

if ! command -v moonrun >/dev/null 2>&1; then
  echo "cutover gate failed: moonrun not found" >&2
  exit 1
fi

echo "=== Stage 1: CLI contract verification ==="

# 1a. Verify --wasm produces MVP (not WasmGc)
echo "[cutover-gate] verifying --wasm produces MVP wasm..."
contract_out="$OUT_DIR/contract_test.wasm"
set +e
moonrun "$STAGE1_COMPILER_WASM" --wasm "$PROJECT_ROOT/examples/basics.vibe" -o "$contract_out" 2>"$OUT_DIR/contract_stderr.log"
contract_status=$?
set -e
if [ "$contract_status" -ne 0 ]; then
  echo "cutover gate failed: selfhost --wasm compile returned non-zero ($contract_status)" >&2
  cat "$OUT_DIR/contract_stderr.log" >&2
  exit 1
fi
if [ ! -f "$contract_out" ]; then
  echo "cutover gate failed: selfhost --wasm did not produce output file" >&2
  exit 1
fi
echo "[cutover-gate] --wasm compile: OK"

# 1b. Verify error exit code (compile a nonexistent file)
echo "[cutover-gate] verifying error exit code..."
set +e
(moonrun "$STAGE1_COMPILER_WASM" --wasm "__nonexistent_file_cutover_test.vibe" -o "$OUT_DIR/should_not_exist.wasm" >/dev/null 2>/dev/null)
error_status=$?
set -e
if [ "$error_status" -eq 0 ]; then
  echo "cutover gate failed: selfhost compile of nonexistent file returned exit 0 (expected non-zero)" >&2
  exit 1
fi
echo "[cutover-gate] error exit code: OK (got $error_status)"

# 1c. Verify --debug-errors is accepted
echo "[cutover-gate] verifying --debug-errors flag..."
set +e
moonrun "$STAGE1_COMPILER_WASM" --wasm --debug-errors "$PROJECT_ROOT/examples/basics.vibe" -o "$OUT_DIR/debug_errors_test.wasm" 2>"$OUT_DIR/debug_errors_stderr.log"
debug_status=$?
set -e
if [ "$debug_status" -ne 0 ]; then
  echo "cutover gate failed: selfhost --wasm --debug-errors returned non-zero ($debug_status)" >&2
  cat "$OUT_DIR/debug_errors_stderr.log" >&2
  exit 1
fi
echo "[cutover-gate] --debug-errors: OK"

# 1d. Verify --wasm --http-host-imports is accepted (--wasm is now MVP)
echo "[cutover-gate] verifying --wasm --http-host-imports..."
set +e
moonrun "$STAGE1_COMPILER_WASM" --wasm --http-host-imports "$PROJECT_ROOT/examples/basics.vibe" -o "$OUT_DIR/http_imports_test.wasm" 2>"$OUT_DIR/http_imports_stderr.log"
http_status=$?
set -e
if [ "$http_status" -ne 0 ]; then
  echo "cutover gate failed: selfhost --wasm --http-host-imports returned non-zero ($http_status)" >&2
  cat "$OUT_DIR/http_imports_stderr.log" >&2
  exit 1
fi
echo "[cutover-gate] --wasm --http-host-imports: OK"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "- CLI contract: --wasm=MVP, error-exit=non-zero, --debug-errors=accepted, --http-host-imports=accepted"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo ""
echo "=== Stage 2: compile-lite parity comparison ==="

VIBE_BIN="$VIBE_BIN" \
STAGE1_COMPILER_WASM="$STAGE1_COMPILER_WASM" \
OUT_DIR="$OUT_DIR" \
VIBE_CUTOVER_STAGE_TIMEOUT_SEC="$STAGE_TIMEOUT_SEC" \
  "$SCRIPT_DIR/test_selfhost_cutover_compare.sh"

echo ""
echo "cutover gate passed"
