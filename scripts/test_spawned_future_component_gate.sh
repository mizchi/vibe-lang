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
# it (tools/wasip3_component_probe/stackful/README.md bug #1).
#
# #1230 M1b-3c-2: that driver now lives in runtime/viberun itself
# (run_async_component), so this gate no longer shells out to the probe's
# dedicated Rust host binary and no longer needs a crates.io fetch at gate
# time -- it just needs viberun built, the same binary `vibe run` already
# uses. viberun sniffs the component header and routes to the async path
# automatically, so the invocation is a plain `viberun <component.wasm>`.
#
# Both host-side outcomes are covered, because they take DIFFERENT paths
# through the emitted guest code and only one of them was ever exercised
# before:
#   blocked  host import genuinely suspends (300ms) -> waitable-set.new /
#            waitable.join / wait-loop / subtask.drop
#   eager    host import resolves without suspending -> none of the above;
#            the packed result carries status RETURNED and NO subtask handle.
#            Dropping unconditionally here trapped with "unknown handle
#            index 0" until #1230 M1b-3c-2 guarded it -- a bug the probe's
#            own host could never surface, since it always slept.
#
# Env:
#   VIBE_SPAWNED_FUTURE_GATE_COMPILER  compiler wasm override (default:
#                                      newest _build generation stage2, else
#                                      seed -- NOTE: comp_emit_component_
#                                      wasm_async_spawned_future postdates
#                                      the committed seed as of #1230, so a
#                                      fresh generation build is required
#                                      until the next bootstrap bump)
#   VIBE_SPAWNED_FUTURE_GATE_RUNNER    viberun binary override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1       missing cargo/wasm-tools/viberun =
#                                      FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_spawned_future_component}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost spawned-future component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "selfhost spawned-future component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

RUNNER="${VIBE_SPAWNED_FUTURE_GATE_RUNNER:-$PROJECT_ROOT/runtime/viberun/target/release/viberun}"
if [ ! -x "$RUNNER" ]; then
  command -v cargo >/dev/null 2>&1 || require_or_skip "viberun not built and cargo not installed"
  echo "[spawned-future-component-gate] building viberun (first run only)..."
  if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
    require_or_skip "failed to build runtime/viberun"
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun did not build: $RUNNER"

COMPILER="${VIBE_SPAWNED_FUTURE_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[spawned-future-component-gate] compiler: $COMPILER"
echo "[spawned-future-component-gate] runner: $RUNNER"

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

fn main() -> Unit with { Error, Fs } {
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

# --- blocked path: the host import genuinely suspends ------------------------
# Asserting the elapsed wall-clock (not just the value) is the whole point:
# a trivially-ready import would return 42 too, while proving nothing about
# waitable-set.wait actually suspending and resuming the guest fiber.
RESULT_LOG="$OUT_DIR/run.blocked.log"
BLOCKED_DELAY_MS=300
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_GET_DELAY_MS="$BLOCKED_DELAY_MS" timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "selfhost spawned-future component gate FAILED: viberun did not exit 0 (blocked path)" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))

if [ "$(cat "$RESULT_LOG")" != "42" ]; then
  echo "selfhost spawned-future component gate FAILED: expected result 42 (blocked path), got:" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

# Allow a little slack under the nominal delay for timer granularity; the
# point is to exclude an instantaneous (never-suspended) resolution, which
# lands one to two orders of magnitude below this.
MIN_MS=$(( BLOCKED_DELAY_MS * 8 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "selfhost spawned-future component gate FAILED: returned in ${ELAPSED_MS}ms with a ${BLOCKED_DELAY_MS}ms host delay -- the guest cannot have genuinely suspended" >&2
  exit 1
fi
echo "[spawned-future-component-gate] blocked path: 42 in ${ELAPSED_MS}ms (genuine suspend/resume confirmed)"

# --- eager path: the host import resolves without suspending ------------------
# Regression guard for the #1230 M1b-3c-2 fix. Before it, this trapped with
# "unknown handle index 0": the epilogue dropped a subtask that a
# status-RETURNED-on-call result never creates.
EAGER_LOG="$OUT_DIR/run.eager.log"
if ! VIBE_ASYNC_GET_DELAY_MS=0 timeout 60 "$RUNNER" "$COMPONENT" >"$EAGER_LOG" 2>&1; then
  echo "selfhost spawned-future component gate FAILED: viberun did not exit 0 with a non-suspending host import (eager path -- the emitted epilogue must not drop a subtask that was never created)" >&2
  cat "$EAGER_LOG" >&2
  exit 1
fi
if [ "$(cat "$EAGER_LOG")" != "42" ]; then
  echo "selfhost spawned-future component gate FAILED: expected result 42 (eager path), got:" >&2
  cat "$EAGER_LOG" >&2
  exit 1
fi
echo "[spawned-future-component-gate] eager path: 42 (no subtask/waitable-set drop attempted)"

echo "selfhost spawned-future component gate passed"
