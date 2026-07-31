#!/usr/bin/env bash
# Interleaved-tasks probe gate (#1230 M1b-3c-1c).
#
# Locks in the M1b-3c-1c finding: two logical guest computations interleave
# at their await points on ONE stackful fiber, dispatched by completion
# order, using NO canon built-in beyond what M1b-3c-1b already proved -- no
# second stack, no context.get/set, no waitable-set.poll.
#
# Unlike the spawned-future and concurrent-awaits gates, this one drives the
# hand-authored probe WAT directly rather than a compiler-emitted component:
# the finding is about what the ABI permits, and the emitter for this shape
# is deliberately left to the follow-up (see docs/spec/wasi-p3-async.md
# §3.11). What it therefore protects is (a) the ABI behavior itself against
# a wasmtime bump, and (b) viberun's `get-after` host import, which nothing
# else exercises.
#
# The probe:
#     task A   await get-after(300) -> await get-after(300) -> log 1
#     task B   await get-after(100)                         -> log 2
# both started before either is waited on, result = log[0]*10 + log[1].
#
#     21 in ~600ms   B's continuation ran while A was still mid-sequence,
#                    and the total is A's own two awaits -- B overlapped.
#     12 in ~700ms   A ran to completion first: serial.
#
# serial_control.wat is the same component with A awaited to completion
# before B starts. It is run too, and must produce exactly the OTHER answer
# -- otherwise the assertions above are not discriminating and this gate is
# decorative.
#
# The probe's delays are baked into the committed WAT (they are part of the
# artifact), so viberun exposes VIBE_ASYNC_DELAY_SCALE_PCT to scale every
# host suspend by a percentage. Ratios are preserved, so completion order --
# the thing being asserted -- is unaffected. Used below to make the warmups
# nearly free; raise it above 100 if a loaded machine ever narrows the
# margin between the two measurements.
#
# Env:
#   VIBE_INTERLEAVED_GATE_RUNNER    viberun binary override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1    missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/interleaved_tasks_probe}"
mkdir -p "$OUT_DIR"

PROBE_DIR="$PROJECT_ROOT/tools/wasip3_component_probe/interleaved_tasks"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "interleaved-tasks probe gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "interleaved-tasks probe gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_INTERLEAVED_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the other component gates (Cargo.lock
# included -- wasmtime/tokio ARE the behavior under test, so a stale binary
# is a false pass rather than a crash).
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[interleaved-tasks-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[interleaved-tasks-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"
echo "[interleaved-tasks-gate] runner: $RUNNER"

# Runs $1.wat, echoes "<result> <elapsed_ms>".
run_probe() {
  local wat="$1" name="$2"
  local wasm="$OUT_DIR/$name.wasm"
  wasm-tools parse "$wat" -o "$wasm" \
    || { echo "interleaved-tasks probe gate FAILED: $name did not assemble" >&2; exit 1; }
  wasm-tools validate --features all "$wasm" \
    || { echo "interleaved-tasks probe gate FAILED: $name did not validate" >&2; exit 1; }
  # Warmup: first execution pays wasmtime JIT (~200ms observed), which would
  # blur the ~100ms gap between the interleaved and serial timings. Run it at
  # 2% of the probe's delays -- the JIT work is identical, but the warmup
  # stops costing as much as the measurement it exists to protect (it ran the
  # full ~1.3s of sleeps before). Ratios are preserved, so the guest still
  # takes exactly the same path; and the floor keeps every call blocking,
  # which the probe's own `unreachable` guards require.
  VIBE_ASYNC_DELAY_SCALE_PCT=2 timeout 60 "$RUNNER" "$wasm" >/dev/null 2>&1 \
    || { echo "interleaved-tasks probe gate FAILED: $name warmup did not exit 0" >&2; exit 1; }
  local log="$OUT_DIR/$name.log" start_ns elapsed
  start_ns=$(date +%s%N)
  timeout 60 "$RUNNER" "$wasm" >"$log" 2>&1 \
    || { echo "interleaved-tasks probe gate FAILED: $name did not exit 0" >&2; cat "$log" >&2; exit 1; }
  elapsed=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  echo "$(cat "$log") $elapsed"
}

read -r INTER_RESULT INTER_MS <<<"$(run_probe "$PROBE_DIR/component.wat" interleaved)"
read -r SERIAL_RESULT SERIAL_MS <<<"$(run_probe "$PROBE_DIR/serial_control.wat" serial_control)"

if [ "$INTER_RESULT" != "21" ]; then
  echo "interleaved-tasks probe gate FAILED: expected 21 (log = B then A, i.e. task B's continuation ran while task A was still mid-sequence), got $INTER_RESULT" >&2
  exit 1
fi
if [ "$SERIAL_RESULT" != "12" ]; then
  echo "interleaved-tasks probe gate FAILED: the serial control returned $SERIAL_RESULT, not 12 -- the log encoding no longer distinguishes the two orders, so the assertion above proves nothing" >&2
  exit 1
fi

# Timing: interleaved must cost about A alone (2x300ms); serial must cost
# A plus B (700ms). Assert the ORDER of the two measurements rather than
# absolute bounds, so a uniformly slow machine cannot flake this -- what
# matters is that overlapping is measurably cheaper than not.
if [ "$INTER_MS" -ge "$SERIAL_MS" ]; then
  echo "interleaved-tasks probe gate FAILED: interleaved took ${INTER_MS}ms but serial took ${SERIAL_MS}ms -- overlapping the two tasks saved nothing, so they did not actually overlap" >&2
  exit 1
fi
# ...and the saving should be roughly task B's 100ms, not noise.
SAVED=$(( SERIAL_MS - INTER_MS ))
if [ "$SAVED" -lt 50 ]; then
  echo "interleaved-tasks probe gate FAILED: interleaving saved only ${SAVED}ms (expected ~100ms, task B's whole duration) -- too close to call it overlap" >&2
  exit 1
fi

echo "[interleaved-tasks-gate] interleaved: 21 in ${INTER_MS}ms (B's continuation ran mid-A)"
echo "[interleaved-tasks-gate] serial control: 12 in ${SERIAL_MS}ms (assertions discriminate; overlap saved ${SAVED}ms)"
echo "interleaved-tasks probe gate passed"
