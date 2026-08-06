#!/usr/bin/env bash
# Stream-value async component regression gate (ADR-0089 step 2, #1218) --
# the stream twin of test_future_value_component_gate.sh.
#
# Verifies comp_emit_component_wasm_stream_value
# (lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe):
# the fixed-shape "self-contained stream<u8> round-trip" component --
# a byte-exact port of tools/wasip3_component_probe/stream_value/
# component.wat -- compiles, validates, and actually runs the literal
# `stream.*` canonical built-ins:
#
#   stream.new -> async stream.read (BLOCKED) -> waitable.join ->
#   async stream.write of the byte 42 (completes eagerly against the pending read)
#   -> waitable-set.wait (STREAM_READ event) -> 42
#
# The emitted guest reports broken assumptions through task.return with
# distinctive values instead of trapping (1000+x = read did not block,
# 2015 = write blocked, 3000+ev = wrong event code), so a failure here
# prints WHICH canonical-ABI assumption broke, not just "not 42".
#
# Unlike the spawned-future/concurrent-awaits gates this component has NO
# host import (the rendezvous is guest-internal), so it needs no viberun
# concurrent driver -- plain `wasmtime --invoke` works. It DOES need
# wasmtime's `-W component-model-more-async-builtins=y` (the stream/future
# canon family is still feature-gated in wasmtime 47, matching the M2c-3
# spike's finding on 45; the other async flags alone reject the component
# at instantiation).
#
# Env:
#   VIBE_STREAM_VALUE_GATE_COMPILER  compiler wasm override (default:
#                                    newest _build generation stage2, else
#                                    seed -- NOTE: comp_emit_component_wasm_
#                                    stream_value postdates the committed
#                                    seed as of #1218, so a fresh generation
#                                    build is required until the next
#                                    bootstrap bump)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1     missing wasmtime/wasm-tools = FAIL
#                                    instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_stream_value_component}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost stream-value component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "selfhost stream-value component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"
command -v wasmtime >/dev/null 2>&1 || require_or_skip "wasmtime not installed"

COMPILER="${VIBE_STREAM_VALUE_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[stream-value-component-gate] compiler: $COMPILER"

# Harness: calls the composer directly and dumps the resulting bytes (the
# component is fully self-contained and fixed-shape; there is no core-module
# input to prepare).
HARNESS="$OUT_DIR/dump.vibex"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_stream_value
}

fn main() -> Unit with Exception + Fs {
  let bytes = comp_emit_component_wasm_stream_value("run", 121)
  Fs::write_bytes("_build/bench/selfhost_stream_value_component/generated.component.wasm", bytes)
}
EOF

HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"

VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null \
  || { echo "selfhost stream-value component gate FAILED: harness did not compile: $(cat "$HARNESS_WASM.diag" 2>/dev/null)" >&2; exit 1; }

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null \
  || { echo "selfhost stream-value component gate FAILED: harness did not run" >&2; exit 1; }

[ -f "$COMPONENT" ] || { echo "selfhost stream-value component gate FAILED: harness did not produce $COMPONENT" >&2; exit 1; }

wasm-tools validate --features all "$COMPONENT" \
  || { echo "selfhost stream-value component gate FAILED: generated component failed validation" >&2; exit 1; }

RESULT_LOG="$OUT_DIR/run.log"
if ! timeout 60 wasmtime run \
    -W exceptions=y -W concurrency-support=y \
    -W component-model-async=y -W component-model-async-stackful=y \
    -W component-model-more-async-builtins=y \
    --invoke 'run()' "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "selfhost stream-value component gate FAILED: wasmtime did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

GOT="$(cat "$RESULT_LOG")"
if [ "$GOT" != "42" ]; then
  echo "selfhost stream-value component gate FAILED: expected 42, got: $GOT" >&2
  case "$GOT" in
    10*) echo "  (diagnostic band 1000+x: async stream.read did NOT return BLOCKED)" >&2 ;;
    2015) echo "  (diagnostic 2015: async stream.write returned BLOCKED against a pending read)" >&2 ;;
    30*) echo "  (diagnostic band 3000+ev: waitable-set.wait delivered event code ev instead of STREAM_READ=2)" >&2 ;;
  esac
  exit 1
fi

echo "[stream-value-component-gate] stream.new/read/write/drop round-trip: 42 (BLOCKED read -> eager write -> STREAM_READ event)"
echo "selfhost stream-value component gate passed"
