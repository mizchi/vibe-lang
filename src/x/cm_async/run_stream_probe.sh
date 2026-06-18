#!/usr/bin/env bash
set -euo pipefail

# M2c-3 stream.read feasibility probe (docs/spec/wasi-p3-async.md §3.x).
# Verifies that the WASI 0.3 stream<u8> canonical built-ins parse, validate, and
# EXECUTE on wasmtime 45 under the `-W component-model-more-async-builtins=y`
# flag set. cm_stream_read_probe.wat's `run` calls `stream.new` and returns 42
# iff it yields a non-zero packed handle pair (proving the lowering runs).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WAT_PATH="$SCRIPT_DIR/cm_stream_read_probe.wat"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_cm_stream_probe.XXXXXX")"
WASM_PATH="$TMP_DIR/cm_stream_read_probe.wasm"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "[cm-stream-probe] SKIP: wasm-tools not found"; exit 0
fi
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[cm-stream-probe] SKIP: wasmtime not found"; exit 0
fi

echo "[cm-stream-probe] wasmtime: $($WASMTIME_BIN --version)"
echo "[cm-stream-probe] platform: $(uname -ms)"

wasm-tools parse "$WAT_PATH" -o "$WASM_PATH"
wasm-tools validate --features all "$WASM_PATH"
echo "[cm-stream-probe] stream<u8> canon component validated OK"

FLAGS=(-W concurrency-support=y -W component-model-async=y \
  -W component-model-async-stackful=y -W component-model-more-async-builtins=y)

result="$("$WASMTIME_BIN" run "${FLAGS[@]}" --invoke "run()" "$WASM_PATH" 2>&1 | tail -n1 || true)"
if [ "$result" = "42" ]; then
  echo "[cm-stream-probe] PASS: stream.new executes on wasmtime ($result)"
else
  echo "[cm-stream-probe] FAIL: expected 42, got '$result'" >&2
  exit 1
fi

# Note: `stream.new` (this probe) runs under the base flags alone. It is
# `stream.read` / `stream.write` that require `component-model-more-async-builtins`
# (a module containing them fails to parse on wasmtime 45 without it); see the
# round-trip blueprint in cm_stream_read_probe.wat.
neg="$("$WASMTIME_BIN" run -W concurrency-support=y -W component-model-async=y \
  -W component-model-async-stackful=y --invoke "run()" "$WASM_PATH" 2>&1 | tail -n1 || true)"
echo "[cm-stream-probe] INFO: stream.new under base flags (no more-async-builtins): '$neg'"

echo "[cm-stream-probe] done"
