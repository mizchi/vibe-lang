#!/usr/bin/env bash
set -euo pipefail

# Selfhost cutover gate: CLI contract verification + compile-lite parity.
# This script bundles Phase 1 (CLI contract) and Phase 0+2 (artifact parity)
# checks into a single CI gate.
#
# Env:
#   VIBE_BIN                           — host CLI binary
#   STAGE1_COMPILER_WASM               — selfhost WASI compiler wasm
#   VIBE_CUTOVER_COMPILER_KIND         — cli-core|moonbit (default: cli-core)
#   VIBE_CUTOVER_REQUIRE_PARITY        — 1: fail on mismatch (default: 1), 0: monitor-only
#   VIBE_CUTOVER_INCLUDE_COMPILER_SIZE — 1: expand canary set (default: moonbit=1, cli-core=0)
#   VIBE_CUTOVER_INCLUDE_FAIL_CASES    — 1: run expected-fail parity canaries (default: moonbit=1, cli-core=0)
#   VIBE_CUTOVER_MODES                 — comma-separated compile-lite modes (default: mvp,no-dce)
#   VIBE_CUTOVER_STAGE_TIMEOUT_SEC     — per-stage timeout (default: 300)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cutover}"
SELFHOST_COMPILER_KIND="${VIBE_CUTOVER_COMPILER_KIND:-cli-core}"
case "$SELFHOST_COMPILER_KIND" in
  cli-core|moonbit) ;;
  *) echo "cutover gate failed: VIBE_CUTOVER_COMPILER_KIND must be cli-core|moonbit" >&2; exit 1 ;;
esac
if [ -z "${STAGE1_COMPILER_WASM:-}" ]; then
  if [ "$SELFHOST_COMPILER_KIND" = "cli-core" ]; then
    STAGE1_COMPILER_WASM="$OUT_DIR/selfhost_compiler.wasm"
  else
    STAGE1_COMPILER_WASM="$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
  fi
fi
STAGE_TIMEOUT_SEC="${VIBE_CUTOVER_STAGE_TIMEOUT_SEC:-300}"
RUNNER="$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh"

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

if [ "$SELFHOST_COMPILER_KIND" = "cli-core" ]; then
  echo "[cutover-gate] resolving selfhost cli-core compiler..." >&2
  STAGE1_COMPILER_WASM="$(VIBE_SELFHOST_CLI_CORE_OUT_DIR="$OUT_DIR" \
    ENTRY_PATH="$PROJECT_ROOT/vibe/cli/selfhost_entry.vibe" \
    STAGE1_CORE_WASM="$STAGE1_COMPILER_WASM" \
    bash "$PROJECT_ROOT/scripts/build_selfhost_cli_core.sh")"
else
  echo "[cutover-gate] syncing selfhost WASI compiler..." >&2
  moon build --target wasm src/cmd/vibe_compile_wasi

  if ! command -v moonrun >/dev/null 2>&1; then
    echo "cutover gate failed: moonrun not found" >&2
    exit 1
  fi
fi

echo "=== Stage 1: CLI contract verification ==="

run_selfhost_compiler() {
  if [ "$SELFHOST_COMPILER_KIND" = "cli-core" ]; then
    bash "$RUNNER" --invoke cli_main "$STAGE1_COMPILER_WASM" compile "$@"
  else
    moonrun "$STAGE1_COMPILER_WASM" "$@"
  fi
}

# 1a. Verify --wasm produces MVP (not WasmGc)
echo "[cutover-gate] verifying --wasm produces MVP wasm..."
contract_out="$OUT_DIR/contract_test.wasm"
set +e
run_selfhost_compiler --wasm "$PROJECT_ROOT/examples/basics.vibe" -o "$contract_out" 2>"$OUT_DIR/contract_stderr.log"
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
(run_selfhost_compiler --wasm "__nonexistent_file_cutover_test.vibe" -o "$OUT_DIR/should_not_exist.wasm" >/dev/null 2>/dev/null)
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
run_selfhost_compiler --wasm --debug-errors "$PROJECT_ROOT/examples/basics.vibe" -o "$OUT_DIR/debug_errors_test.wasm" 2>"$OUT_DIR/debug_errors_stderr.log"
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
run_selfhost_compiler --wasm --http-host-imports "$PROJECT_ROOT/examples/basics.vibe" -o "$OUT_DIR/http_imports_test.wasm" 2>"$OUT_DIR/http_imports_stderr.log"
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
VIBE_CUTOVER_COMPILER_KIND="$SELFHOST_COMPILER_KIND" \
OUT_DIR="$OUT_DIR" \
VIBE_CUTOVER_STAGE_TIMEOUT_SEC="$STAGE_TIMEOUT_SEC" \
  "$SCRIPT_DIR/test_selfhost_cutover_compare.sh"

echo ""
echo "cutover gate passed"
