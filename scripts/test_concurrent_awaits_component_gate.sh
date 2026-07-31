#!/usr/bin/env bash
# Concurrent-awaits async component gate (#1230 M1b-3c-3).
#
# Verifies comp_emit_component_wasm_async_concurrent_awaits
# (lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe):
# the fixed-shape "two host operations genuinely in flight at once"
# component -- a byte-level port of
# tools/wasip3_component_probe/concurrent_awaits/component.wat -- compiles,
# validates, and actually runs CONCURRENTLY rather than serially.
#
# Two independent assertions, because either alone is weak:
#
#   value    `run` returns 84 (= 42 + 42). Each call writes its own result
#            slot, so a component that completed only one call, or read one
#            slot twice, returns 42 and fails. This is what proves both
#            awaits really resolved.
#
#   timing   with a host suspending $DELAY ms per call, concurrent execution
#            takes ~DELAY and serial ~2*DELAY. Asserted two-sided:
#              >= 0.8*DELAY  it genuinely suspended (an always-ready host
#                            would return in single-digit ms)
#              <  1.6*DELAY  it was NOT serial (that lands at ~2.0*DELAY)
#            This is the assertion that actually tests concurrency; the
#            value check passes just as happily on a serial implementation.
#
# A warmup run precedes the timed run: the first execution in a fresh
# process pays wasmtime JIT compilation (~200ms observed), which would eat
# most of the headroom between the concurrent and serial bounds.
#
# NOTE this gate is about concurrent HOST operations awaited by ONE guest
# computation -- not M1b-3c-1c's interleaving spawn (two concurrent GUEST
# computations), which needs machinery this shape does not have and remains
# open. See docs/spec/wasi-p3-async.md §3.10.
#
# Env:
#   VIBE_CONCURRENT_AWAITS_GATE_COMPILER  compiler wasm override (default:
#                                         newest _build generation stage2,
#                                         else seed -- NOTE the emitter
#                                         postdates the committed seed, so a
#                                         fresh generation build is required
#                                         until the next bootstrap bump)
#   VIBE_CONCURRENT_AWAITS_GATE_RUNNER    viberun binary override
#   VIBE_CONCURRENT_AWAITS_GATE_DELAY_MS  per-call host suspend (default 300;
#                                         raise on a slow machine -- a larger
#                                         delay shrinks the relative weight
#                                         of fixed overhead)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1          missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_concurrent_awaits_component}"
mkdir -p "$OUT_DIR"

DELAY_MS="${VIBE_CONCURRENT_AWAITS_GATE_DELAY_MS:-300}"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost concurrent-awaits component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "selfhost concurrent-awaits component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_CONCURRENT_AWAITS_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the spawned-future gate: an explicit
# override is trusted as-is, the in-tree default is rebuilt when missing or
# older than any build input (Cargo.lock included -- wasmtime/tokio ARE the
# async behavior under test, so a stale binary is a false pass, not a crash).
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[concurrent-awaits-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[concurrent-awaits-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_CONCURRENT_AWAITS_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[concurrent-awaits-gate] compiler: $COMPILER"
echo "[concurrent-awaits-gate] runner: $RUNNER"

# Harness: the composer takes no core-module input (it is a fully
# self-contained fixed-shape component), so this is a plain Fs::write_bytes
# dump, not an async `run` entry itself.
HARNESS="$OUT_DIR/dump.vibex"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_concurrent_awaits
}

fn main() -> Unit with { Error, Fs } {
  let bytes = comp_emit_component_wasm_async_concurrent_awaits("run", 121)
  Fs::write_bytes("_build/bench/selfhost_concurrent_awaits_component/generated.component.wasm", bytes)
}
EOF

HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"

VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null \
  || { echo "selfhost concurrent-awaits component gate FAILED: harness did not compile: $(cat "$HARNESS_WASM.diag" 2>/dev/null)" >&2; exit 1; }

VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null \
  || { echo "selfhost concurrent-awaits component gate FAILED: harness did not run" >&2; exit 1; }

[ -f "$COMPONENT" ] || { echo "selfhost concurrent-awaits component gate FAILED: harness did not produce $COMPONENT" >&2; exit 1; }

wasm-tools validate --features all "$COMPONENT" \
  || { echo "selfhost concurrent-awaits component gate FAILED: generated component failed validation" >&2; exit 1; }

# --- warmup (unmeasured): pay JIT compilation before the timed run ----------
# Delay 0 keeps this cheap, and here it is also the eager path, which this
# component must handle anyway (asserted for real further down).
VIBE_ASYNC_GET_DELAY_MS=0 timeout 60 "$RUNNER" "$COMPONENT" >/dev/null 2>&1 \
  || { echo "selfhost concurrent-awaits component gate FAILED: warmup run did not exit 0" >&2; exit 1; }

# --- timed run: both calls suspend --------------------------------------------
RESULT_LOG="$OUT_DIR/run.concurrent.log"
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_GET_DELAY_MS="$DELAY_MS" timeout 120 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "selfhost concurrent-awaits component gate FAILED: viberun did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))

if [ "$(cat "$RESULT_LOG")" != "84" ]; then
  echo "selfhost concurrent-awaits component gate FAILED: expected 84 (= 42 + 42, both awaits resolved into their own result slots), got:" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi

MIN_MS=$(( DELAY_MS * 8 / 10 ))
MAX_MS=$(( DELAY_MS * 16 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "selfhost concurrent-awaits component gate FAILED: returned in ${ELAPSED_MS}ms with a ${DELAY_MS}ms host delay -- the guest cannot have genuinely suspended" >&2
  exit 1
fi
if [ "$ELAPSED_MS" -ge "$MAX_MS" ]; then
  echo "selfhost concurrent-awaits component gate FAILED: took ${ELAPSED_MS}ms for two ${DELAY_MS}ms host calls (>= ${MAX_MS}ms) -- that is serial, not concurrent; the two async-lowered calls must both be issued BEFORE either is waited on" >&2
  exit 1
fi
echo "[concurrent-awaits-gate] concurrent: 84 in ${ELAPSED_MS}ms for 2x${DELAY_MS}ms host calls (serial would be ~$(( DELAY_MS * 2 ))ms)"

# --- eager path: neither call suspends ----------------------------------------
# Same regression guard the spawned-future gate carries: an async-lowered
# call that completes eagerly creates no subtask, so nothing may be dropped.
EAGER_LOG="$OUT_DIR/run.eager.log"
if ! VIBE_ASYNC_GET_DELAY_MS=0 timeout 60 "$RUNNER" "$COMPONENT" >"$EAGER_LOG" 2>&1; then
  echo "selfhost concurrent-awaits component gate FAILED: viberun did not exit 0 with a non-suspending host import (eager path)" >&2
  cat "$EAGER_LOG" >&2
  exit 1
fi
if [ "$(cat "$EAGER_LOG")" != "84" ]; then
  echo "selfhost concurrent-awaits component gate FAILED: expected 84 (eager path), got:" >&2
  cat "$EAGER_LOG" >&2
  exit 1
fi
echo "[concurrent-awaits-gate] eager path: 84 (no subtask created, none dropped)"

echo "selfhost concurrent-awaits component gate passed"
