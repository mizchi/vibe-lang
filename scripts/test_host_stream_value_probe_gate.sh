#!/usr/bin/env bash
# ADR-0089 Decision 3 (#1218): host-supplied `stream<u8>` PROBE gate.
#
# Pins the one runtime fact the Decision 3 emitter cannot be written without:
# how wasmtime reports END OF STREAM to a guest reading a host-supplied
# `stream<u8>` one byte at a time.
#
# tools/wasip3_component_probe/host_stream_value/component.wat imports
# `body: func() -> stream<u8>` (served by runtime/viberun's VIBE_ASYNC_STREAMS,
# backed by wasmtime's own Vec<u8> StreamProducer), reads single bytes until
# the stream ends, and returns their sum -- but ONLY if the terminating read
# reports the measured encoding (amount 0, code 1 = CLOSED). Any other
# terminal status returns 7000 + status instead, so a wasmtime bump that
# changes the encoding fails here rather than silently producing a reader
# that never terminates.
#
# Expected: 42 = 10 + 15 + 17.
#
# Env:
#   VIBE_HOST_STREAM_PROBE_RUNNER   viberun binary override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1    missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/host_stream_value_probe}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "host stream value probe gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "host stream value probe gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_HOST_STREAM_PROBE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the other p3 gates.
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[host-stream-value-probe-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[host-stream-value-probe-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

WAT="$PROJECT_ROOT/tools/wasip3_component_probe/host_stream_value/component.wat"
COMPONENT="$OUT_DIR/host_stream_value.wasm"
wasm-tools parse "$WAT" -o "$COMPONENT" \
  || { echo "host stream value probe gate FAILED: probe did not assemble" >&2; exit 1; }
wasm-tools validate --features all "$COMPONENT" \
  || { echo "host stream value probe gate FAILED: probe failed validation" >&2; exit 1; }

LOG="$OUT_DIR/run.log"
if ! VIBE_ASYNC_STREAMS="body=10|15|17" timeout 60 "$RUNNER" "$COMPONENT" >"$LOG" 2>&1; then
  echo "host stream value probe gate FAILED: viberun did not exit 0" >&2
  cat "$LOG" >&2
  exit 1
fi
GOT="$(cat "$LOG")"
if [ "$GOT" != "42" ]; then
  echo "host stream value probe gate FAILED: expected 42, got: $GOT" >&2
  echo "  (7000 + status = a zero-transfer read whose code is not the measured CLOSED code 1;" >&2
  echo "   6000 + n = the end was never recognised; see the probe's header for the full band map)" >&2
  exit 1
fi

echo "[host-stream-value-probe-gate] 42: bytes delivered one at a time, end-of-stream = amount 0 / code 1"
echo "host stream value probe gate OK"
