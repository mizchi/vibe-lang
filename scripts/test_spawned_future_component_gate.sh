#!/usr/bin/env bash
# Spawned-future async component regression gate (#1230 M1b-3c-1b).
#
# Verifies comp_emit_component_wasm_async_spawned_future
# (lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe):
# the fixed-shape "self-contained future via a spawned writer subtask"
# component -- a byte-exact port of
# tools/wasip3_component_probe/spawned_future/component.wat -- compiles,
# validates, and actually runs correctly under a genuinely-blocking host
# import (not just a trivially-ready one).
#
# Unlike scripts/test_async_component_gate.sh (which drives its components
# via bare `wasmtime --invoke`, sufficient for the eager/always-ready cases
# it covers), a component that imports a func_wrap_concurrent host function
# needs to be driven via wasmtime's Store::run_concurrent +
# TypedFunc::call_concurrent APIs -- `wasmtime --invoke` deadlock-traps on
# it (tools/wasip3_component_probe/stackful/README.md bug #1). Neither
# runtime/viberun (no component-model/async wasmtime features at all) nor
# the CLI can drive this, so this gate reuses the probe's own dedicated
# Rust host binary (tools/wasip3_component_probe/spawned_future/host/) as
# its driver -- built on demand, requires a Rust toolchain + network access
# to crates.io (wasmtime 47, tokio) the first time.
#
# Env:
#   VIBE_SPAWNED_FUTURE_GATE_COMPILER  compiler wasm override (default:
#                                      newest _build generation stage2, else
#                                      seed -- NOTE: comp_emit_component_
#                                      wasm_async_spawned_future postdates
#                                      the committed seed as of #1230, so a
#                                      fresh generation build is required
#                                      until the next bootstrap bump)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1       missing cargo/wasm-tools = FAIL
#                                      instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_spawned_future_component}"
mkdir -p "$OUT_DIR"

PROBE_DIR="$PROJECT_ROOT/tools/wasip3_component_probe/spawned_future"
HOST_BIN="$PROBE_DIR/host/target/release/p3spawnedfuturehost"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost spawned-future component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "selfhost spawned-future component gate skipped: $what"
  exit 0
}

command -v cargo >/dev/null 2>&1 || require_or_skip "cargo not installed"
command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

if [ ! -x "$HOST_BIN" ]; then
  echo "[spawned-future-component-gate] building probe host driver (first run only)..."
  if ! (cd "$PROBE_DIR/host" && cargo build --release >/dev/null 2>&1); then
    require_or_skip "failed to build $PROBE_DIR/host (network access to crates.io required)"
  fi
fi
[ -x "$HOST_BIN" ] || require_or_skip "probe host driver did not build: $HOST_BIN"

COMPILER="${VIBE_SPAWNED_FUTURE_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[spawned-future-component-gate] compiler: $COMPILER"
echo "[spawned-future-component-gate] host driver: $HOST_BIN"

# Harness: calls the composer directly and dumps the resulting bytes --
# comp_emit_component_wasm_async_spawned_future takes no core-module input
# (it's a fully self-contained, fixed-shape component, unlike the
# trampolined_p1 family which wraps an arbitrary compiled `.vibe` entry),
# so this is a plain Fs::write_bytes dump, not an async `run` entry itself.
HARNESS="$OUT_DIR/dump.vibex"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_spawned_future
}

fn main() -> Unit with { Fs } {
  let bytes = comp_emit_component_wasm_async_spawned_future("run", 121)
  Fs::write_bytes("_build/bench/selfhost_spawned_future_component/generated.component.wasm", bytes)
}
EOF

HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"

VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null \
  || { echo "selfhost spawned-future component gate FAILED: harness did not compile: $(cat "$HARNESS_WASM.diag" 2>/dev/null)" >&2; exit 1; }

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null \
  || { echo "selfhost spawned-future component gate FAILED: harness did not run" >&2; exit 1; }

[ -f "$COMPONENT" ] || { echo "selfhost spawned-future component gate FAILED: harness did not produce $COMPONENT" >&2; exit 1; }

wasm-tools validate --features all "$COMPONENT" \
  || { echo "selfhost spawned-future component gate FAILED: generated component failed validation" >&2; exit 1; }

RESULT_LOG="$OUT_DIR/run.log"
if ! timeout 30 "$HOST_BIN" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "selfhost spawned-future component gate FAILED: host driver did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

if ! grep -q 'suspending for 300ms' "$RESULT_LOG"; then
  echo "selfhost spawned-future component gate FAILED: no evidence of a genuine (non-instant) suspend" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

if ! grep -q 'run() = 42 ' "$RESULT_LOG"; then
  echo "selfhost spawned-future component gate FAILED: expected result 42, got:" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

echo "[spawned-future-component-gate] generated component: 42 ok (genuine blocking wait confirmed)"
echo "selfhost spawned-future component gate passed"
