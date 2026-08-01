#!/usr/bin/env bash
# ADR-0089 step 4 (#1218): REAL-source host-future await gate.
#
# The step-4 wiring end-to-end: a `.vibe` program
#
#   let run: () -> Int with { Async } = () -> {
#     let f = host_future_get()
#     await(f)
#   }
#
# compiled by the selfhost compiler (single-source path, entry name "run")
# is AUTO-wrapped into the adapter-backed async component
# (comp_emit_component_wasm_async_hostfuture -- the wrap keys on the core's
# vibe.host_future_get import), imports `get-future: func() -> future<u32>`
# from the host, and must return 42 under runtime/viberun.
#
# What each assertion proves:
#   value    42 came through the whole lowering chain: host_future_get ->
#            [state=2, handle] cell -> __aw_poll's waitable payload
#            (Suspend(handle + 2)) -> entry boundary __entry_settle ->
#            vibe.host_future_wait -> adapter future.read/waitable-set.wait
#            -> tagged value back into the cell.
#   timing   with the host producer suspending DELAY ms, wall clock
#            >= 0.8 x DELAY proves the task genuinely parked in
#            waitable-set.wait and was woken by the FUTURE_READ completion
#            (an always-ready or busy-polling run returns in single-digit
#            ms). A 1ms warmup run precedes the timed run so wasmtime JIT
#            compilation does not eat the margin.
#   control  the same entry shape WITHOUT host_future_get keeps the plain
#            self-contained trampolined-p1 wrap (no `get-future` import) --
#            the step-4 routing must not leak into ordinary async entries.
#
# Env:
#   VIBE_HOSTFUTURE_SOURCE_GATE_COMPILER  compiler wasm override (default:
#                                         newest _build generation stage2,
#                                         else seed -- NOTE the lowering
#                                         postdates the committed seed, so a
#                                         fresh generation build is required
#                                         until the next bootstrap bump)
#   VIBE_HOSTFUTURE_SOURCE_GATE_RUNNER    viberun binary override
#   VIBE_HOSTFUTURE_SOURCE_GATE_DELAY_MS  producer delay (default 300; raise
#                                         on a slow machine)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1          missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_hostfuture_source_component}"
mkdir -p "$OUT_DIR"

DELAY_MS="${VIBE_HOSTFUTURE_SOURCE_GATE_DELAY_MS:-300}"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "hostfuture source component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "hostfuture source component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_HOSTFUTURE_SOURCE_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the host-future-value gate: an
# explicit override is trusted as-is; the default in-tree binary is rebuilt
# when missing or older than any viberun build input.
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[hostfuture-source-component-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[hostfuture-source-component-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_HOSTFUTURE_SOURCE_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[hostfuture-source-component-gate] compiler: $COMPILER"
echo "[hostfuture-source-component-gate] runner: $RUNNER"

# --- compile the real-source fixture (single-source path, entry "run") -------
SRC="$OUT_DIR/hostfuture_await.vibe"
cat >"$SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  let f = host_future_get()
  await(f)
}
EOF

COMPONENT="$OUT_DIR/hostfuture_await.component.wasm"
rm -f "$COMPONENT" "$COMPONENT.diag"
# NO VIBE_FS_COMPILE: the single-source path is where the async entry
# detection + component wrap live (same lane as test_async_component_gate.sh).
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$SRC" "$COMPONENT" run >/dev/null \
  || { echo "hostfuture source component gate FAILED: fixture did not compile: $(cat "$COMPONENT.diag" 2>/dev/null)" >&2; exit 1; }
[ -s "$COMPONENT" ] || { echo "hostfuture source component gate FAILED: no output produced" >&2; exit 1; }

# Must be a COMPONENT (layer 1 header), not a bare core module: the wrap
# routing is part of what this gate pins.
if ! od -A n -t x1 -N 8 "$COMPONENT" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
  echo "hostfuture source component gate FAILED: output is not a component (wrap did not trigger)" >&2
  exit 1
fi

wasm-tools validate --features all "$COMPONENT" \
  || { echo "hostfuture source component gate FAILED: component failed validation" >&2; exit 1; }

# --- warmup (JIT) then the timed blocked run ---------------------------------
WARM_LOG="$OUT_DIR/run.warmup.log"
if ! VIBE_ASYNC_GET_DELAY_MS=1 timeout 60 "$RUNNER" "$COMPONENT" >"$WARM_LOG" 2>&1; then
  echo "hostfuture source component gate FAILED: warmup run did not exit 0" >&2
  cat "$WARM_LOG" >&2
  exit 1
fi
[ "$(cat "$WARM_LOG")" = "42" ] \
  || { echo "hostfuture source component gate FAILED: warmup expected 42, got: $(cat "$WARM_LOG")" >&2; exit 1; }

RESULT_LOG="$OUT_DIR/run.blocked.log"
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_GET_DELAY_MS="$DELAY_MS" timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "hostfuture source component gate FAILED: viberun did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))

GOT="$(cat "$RESULT_LOG")"
[ "$GOT" = "42" ] \
  || { echo "hostfuture source component gate FAILED: expected 42, got: $GOT" >&2; exit 1; }

MIN_MS=$(( DELAY_MS * 8 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "hostfuture source component gate FAILED: returned in ${ELAPSED_MS}ms with a ${DELAY_MS}ms producer delay -- the task cannot have genuinely parked in waitable-set.wait" >&2
  exit 1
fi
echo "[hostfuture-source-component-gate] blocked path: 42 in ${ELAPSED_MS}ms (real-source await through waitable-set.wait confirmed)"

# --- control: an ordinary async entry keeps the p1 wrap ----------------------
CTRL_SRC="$OUT_DIR/ready_await.vibe"
cat >"$CTRL_SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  await(Future::ready(42))
}
EOF
CTRL_OUT="$OUT_DIR/ready_await.component.wasm"
rm -f "$CTRL_OUT" "$CTRL_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$CTRL_SRC" "$CTRL_OUT" run >/dev/null \
  || { echo "hostfuture source component gate FAILED: control fixture did not compile: $(cat "$CTRL_OUT.diag" 2>/dev/null)" >&2; exit 1; }
if grep -q "get-future" "$CTRL_OUT"; then
  echo "hostfuture source component gate FAILED: control component imports get-future -- the host-future routing leaked into an ordinary async entry" >&2
  exit 1
fi

echo "hostfuture source component gate OK"
