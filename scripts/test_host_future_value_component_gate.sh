#!/usr/bin/env bash
# Host-future-value async component regression gate (ADR-0089 Decision 2 /
# step 4, #1218).
#
# Verifies comp_emit_component_wasm_host_future_value
# (lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe):
# the fixed-shape component that reads a HOST-SUPPLIED `future<u32>` --
# a byte-exact port of tools/wasip3_component_probe/host_future_value/
# component.wat. Unlike the self-contained future-value shape (where the
# guest authors both ends and the write eagerly satisfies its own pending
# read), the write end here lives in the HOST: runtime/viberun's
# `get-future` import returns a wasmtime `FutureReader::new` whose producer
# resolves only after a genuine tokio timer suspend. The guest's path is:
#
#   [async-lower]get-future (eager RETURNED, handle in results buffer)
#   -> async future.read -> BLOCKED
#   -> waitable.join / waitable-set.wait  (the task REALLY suspends here)
#   -> FUTURE_READ completion event -> 42
#
# This is the `waitable-set.wait` backend of ADR-0089 Decision 1's
# three-backend split, measured end-to-end: the wall-clock assertion below
# is the point -- a result of 42 alone would also be produced by a
# never-suspending implementation, while >= ~delay proves park-and-wake.
#
# The emitted guest reports broken assumptions through task.return with
# distinctive values instead of trapping (5000+code = get-future did not
# complete eagerly, 1000+x = future.read did not block, 3000+ev = wrong
# wait event), so a failure prints WHICH canonical-ABI assumption broke.
#
# A component importing a func_wrap_concurrent host function cannot be
# driven by bare `wasmtime --invoke` (it deadlock-traps; see
# tools/wasip3_component_probe/stackful/README.md bug #1), so this gate
# drives it through viberun like the spawned-future gate does.
#
# Env:
#   VIBE_HOST_FUTURE_GATE_COMPILER  compiler wasm override (default: newest
#                                   _build generation stage2, else seed --
#                                   NOTE: comp_emit_component_wasm_host_
#                                   future_value postdates the committed
#                                   seed, so a fresh generation build is
#                                   required until the next bootstrap bump)
#   VIBE_HOST_FUTURE_GATE_RUNNER    viberun binary override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1    missing cargo/wasm-tools/viberun = FAIL
#                                   instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_host_future_value_component}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost host-future-value component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "selfhost host-future-value component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_HOST_FUTURE_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the spawned-future gate: an explicit
# override is trusted as-is; the default in-tree binary is rebuilt when
# missing or older than any viberun build input (Cargo.lock included -- a
# lock-only bump changes the wasmtime/tokio behavior this gate validates).
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[host-future-value-component-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[host-future-value-component-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_HOST_FUTURE_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[host-future-value-component-gate] compiler: $COMPILER"
echo "[host-future-value-component-gate] runner: $RUNNER"

# Harness: calls the composer directly and dumps the resulting bytes (fixed
# shape, no core-module input to prepare).
HARNESS="$OUT_DIR/dump.vibex"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_host_future_value
}

fn main() -> Unit with Exception + Fs {
  let bytes = comp_emit_component_wasm_host_future_value("run", 121)
  Fs::write_bytes("_build/bench/selfhost_host_future_value_component/generated.component.wasm", bytes)
}
EOF

HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"

VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null \
  || { echo "selfhost host-future-value component gate FAILED: harness did not compile: $(cat "$HARNESS_WASM.diag" 2>/dev/null)" >&2; exit 1; }

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null \
  || { echo "selfhost host-future-value component gate FAILED: harness did not run" >&2; exit 1; }

[ -f "$COMPONENT" ] || { echo "selfhost host-future-value component gate FAILED: harness did not produce $COMPONENT" >&2; exit 1; }

wasm-tools validate --features all "$COMPONENT" \
  || { echo "selfhost host-future-value component gate FAILED: generated component failed validation" >&2; exit 1; }

# --- blocked path: the producer genuinely suspends ---------------------------
# The wall-clock assertion is the whole point of this gate: 42 alone would
# also come from a never-suspending run, while >= ~delay proves the guest
# parked in waitable-set.wait and was woken by the host completion.
RESULT_LOG="$OUT_DIR/run.blocked.log"
BLOCKED_DELAY_MS=300
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_GET_DELAY_MS="$BLOCKED_DELAY_MS" timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "selfhost host-future-value component gate FAILED: viberun did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))

GOT="$(cat "$RESULT_LOG")"
if [ "$GOT" != "42" ]; then
  echo "selfhost host-future-value component gate FAILED: expected 42, got: $GOT" >&2
  case "$GOT" in
    50*) echo "  (diagnostic band 5000+code: [async-lower]get-future did not complete eagerly)" >&2 ;;
    10*) echo "  (diagnostic band 1000+x: async future.read did NOT return BLOCKED)" >&2 ;;
    30*) echo "  (diagnostic band 3000+ev: waitable-set.wait delivered event code ev instead of FUTURE_READ=4)" >&2 ;;
  esac
  exit 1
fi

MIN_MS=$(( BLOCKED_DELAY_MS * 8 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "selfhost host-future-value component gate FAILED: returned in ${ELAPSED_MS}ms with a ${BLOCKED_DELAY_MS}ms producer delay -- the guest cannot have genuinely suspended in waitable-set.wait" >&2
  exit 1
fi
echo "[host-future-value-component-gate] blocked path: 42 in ${ELAPSED_MS}ms (genuine waitable park/wake confirmed)"

# --- probe parity: the hand-authored WAT runs the same way -------------------
PROBE_WAT="$PROJECT_ROOT/tools/wasip3_component_probe/host_future_value/component.wat"
PROBE_WASM="$OUT_DIR/probe.component.wasm"
wasm-tools parse "$PROBE_WAT" -o "$PROBE_WASM" \
  || { echo "selfhost host-future-value component gate FAILED: probe WAT did not parse" >&2; exit 1; }
PROBE_LOG="$OUT_DIR/run.probe.log"
if ! VIBE_ASYNC_GET_DELAY_MS=50 timeout 60 "$RUNNER" "$PROBE_WASM" >"$PROBE_LOG" 2>&1; then
  echo "selfhost host-future-value component gate FAILED: probe component did not run" >&2
  cat "$PROBE_LOG" >&2
  exit 1
fi
[ "$(cat "$PROBE_LOG")" = "42" ] \
  || { echo "selfhost host-future-value component gate FAILED: probe expected 42, got: $(cat "$PROBE_LOG")" >&2; exit 1; }

echo "selfhost host-future-value component gate OK"
