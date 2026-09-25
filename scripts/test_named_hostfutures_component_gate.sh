#!/usr/bin/env bash
# ADR-0089 (c) (#1218): NAMED host futures, end to end.
#
# The generalization of test_hostfuture_source_component_gate.sh's single
# anonymous `get-future`: a `.vibe` program
#
#   let run: () -> Int with Async = () -> {
#     let a = host_future_named("price")
#     let b = host_future_named("qty")
#     await(a) + await(b)
#   }
#
# compiles to a core module importing `vibe.host_future_get$price` and
# `vibe.host_future_get$qty`, which the composer turns into TWO component
# imports `price: func() -> future<u32>` / `qty: func() -> future<u32>`.
# viberun links both from VIBE_ASYNC_FUTURES.
#
# What each assertion proves:
#   imports  both names are real component imports (and the anonymous
#            `get-future` is NOT there -- the program never asked for one)
#   value    40 + 2 = 42 came back, so each await settled on ITS OWN future:
#            the two handles cannot have been confused for one another.
#   overlap  both futures are created BEFORE the first await, and the
#            adapter STARTS each read at creation time, so their producers
#            run concurrently. With delays P (price) and Q = 2P/3 (qty), the
#            wall clock must be >= 0.8 x P (the task really parked) and
#            < 1.4 x P (the two waits OVERLAPPED -- back-to-back waits would
#            take P + Q = 1.67 x P). A non-parking run would take ~0.
#   latch    (#2832) awaiting the SAME future twice returns the settled value
#            without a second host read. The value cannot tell the two worlds
#            apart -- the host would hand back the same number -- so the wall
#            clock does it: one read costs LONG, two cost 2 x LONG.
#   control  a single-name program imports only that name -- the per-name
#            wiring must not drag the whole name set into every component.
#
# Env:
#   VIBE_NAMED_HOSTFUTURES_GATE_COMPILER  compiler wasm override (default:
#                                         newest _build generation stage2,
#                                         else seed -- NOTE the lowering
#                                         postdates the committed seed, so a
#                                         fresh generation build is required
#                                         until the next bootstrap bump)
#   VIBE_NAMED_HOSTFUTURES_GATE_RUNNER    viberun binary override
#   VIBE_NAMED_HOSTFUTURES_GATE_DELAY_MS  the LONG (price) delay, default 300;
#                                         qty uses two thirds of it. Raise it
#                                         on a slow machine.
#   VIBE_P3_GATE_REQUIRE_TOOLS=1          missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_named_hostfutures_component}"
mkdir -p "$OUT_DIR"

LONG_MS="${VIBE_NAMED_HOSTFUTURES_GATE_DELAY_MS:-300}"
# Two thirds of the long delay: sequential would be ~1.67x LONG, overlapped
# ~1x LONG, so the [0.8x, 1.4x] window below separates them with room to
# spare on a loaded machine (measured overlapped: 320ms at LONG=300).
SHORT_MS=$(( LONG_MS * 2 / 3 ))

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "named hostfutures component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "named hostfutures component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_NAMED_HOSTFUTURES_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the other p3 gates: an explicit
# override is trusted as-is; the default in-tree binary is rebuilt when
# missing or older than any viberun build input.
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[named-hostfutures-component-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[named-hostfutures-component-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_NAMED_HOSTFUTURES_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[named-hostfutures-component-gate] compiler: $COMPILER"
echo "[named-hostfutures-component-gate] runner: $RUNNER"

compile_fixture() {
  local src="$1" out="$2" rc_mode="${3:-1}"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw VIBE_RC="$rc_mode" \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$src" "$out" run >/dev/null \
    || { echo "named hostfutures component gate FAILED: $src did not compile: $(cat "$out.diag" 2>/dev/null)" >&2; exit 1; }
  [ -s "$out" ] || { echo "named hostfutures component gate FAILED: no output for $src" >&2; exit 1; }
}

# --- the two-name fixture ----------------------------------------------------
# Both futures are created BEFORE the first await: that is what puts the two
# host producers in flight at the same time, which the wall-clock bound below
# measures.
SRC="$OUT_DIR/named_await.vibe"
cat >"$SRC" <<'EOF'
let run: () -> Int with Async = () -> {
  let a = host_future_named("price")
  let b = host_future_named("qty")
  await(a) + await(b)
}
EOF

COMPONENT="$OUT_DIR/named_await.component.wasm"
compile_fixture "$SRC" "$COMPONENT" 1
RC0_COMPONENT="$OUT_DIR/named_await.rc0.component.wasm"
compile_fixture "$SRC" "$RC0_COMPONENT" 0

# Must be a COMPONENT (layer 1 header), not a bare core module.
if ! od -A n -t x1 -N 8 "$COMPONENT" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
  echo "named hostfutures component gate FAILED: output is not a component (wrap did not trigger)" >&2
  exit 1
fi

wasm-tools validate --features all "$COMPONENT" \
  || { echo "named hostfutures component gate FAILED: component failed validation" >&2; exit 1; }
wasm-tools validate --features all "$RC0_COMPONENT" \
  || { echo "named hostfutures component gate FAILED: RC=0 component failed validation" >&2; exit 1; }

WIT="$OUT_DIR/named_await.wit"
wasm-tools component wit "$COMPONENT" >"$WIT" 2>/dev/null \
  || { echo "named hostfutures component gate FAILED: could not print the component's WIT" >&2; exit 1; }
for want in "price" "qty"; do
  grep -Eq "^[[:space:]]*import ${want}:" "$WIT" \
    || { echo "named hostfutures component gate FAILED: no '${want}' import in the component's WIT:" >&2; cat "$WIT" >&2; exit 1; }
done
if grep -Eq "^[[:space:]]*import get-future:" "$WIT"; then
  echo "named hostfutures component gate FAILED: the anonymous 'get-future' import leaked into a named-only program" >&2
  cat "$WIT" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] imports: price + qty, no anonymous get-future"

# --- warmup (JIT) then the timed run -----------------------------------------
FUTURES="price=40:$LONG_MS,qty=2:$SHORT_MS"
WARM_LOG="$OUT_DIR/run.warmup.log"
if ! VIBE_ASYNC_FUTURES="price=40:1,qty=2:1" timeout 60 "$RUNNER" "$COMPONENT" >"$WARM_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: warmup run did not exit 0" >&2
  cat "$WARM_LOG" >&2
  exit 1
fi
[ "$(cat "$WARM_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: warmup expected 42, got: $(cat "$WARM_LOG")" >&2; exit 1; }
RC0_WARM_LOG="$OUT_DIR/run.rc0.warmup.log"
if ! VIBE_ASYNC_FUTURES="price=40:1,qty=2:1" timeout 60 "$RUNNER" "$RC0_COMPONENT" >"$RC0_WARM_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: RC=0 warmup run did not exit 0" >&2
  cat "$RC0_WARM_LOG" >&2
  exit 1
fi
[ "$(cat "$RC0_WARM_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: RC=0 warmup expected 42, got: $(cat "$RC0_WARM_LOG")" >&2; exit 1; }

RESULT_LOG="$OUT_DIR/run.blocked.log"
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="$FUTURES" timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: viberun did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))

GOT="$(cat "$RESULT_LOG")"
[ "$GOT" = "42" ] \
  || { echo "named hostfutures component gate FAILED: expected 42 (40 from price + 2 from qty), got: $GOT" >&2; exit 1; }
RC0_RESULT_LOG="$OUT_DIR/run.rc0.blocked.log"
if ! VIBE_ASYNC_FUTURES="$FUTURES" timeout 60 "$RUNNER" "$RC0_COMPONENT" >"$RC0_RESULT_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: RC=0 blocked run did not exit 0" >&2
  cat "$RC0_RESULT_LOG" >&2
  exit 1
fi
[ "$(cat "$RC0_RESULT_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: RC=0 blocked run expected 42, got: $(cat "$RC0_RESULT_LOG")" >&2; exit 1; }

MIN_MS=$(( LONG_MS * 8 / 10 ))
MAX_MS=$(( LONG_MS * 14 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "named hostfutures component gate FAILED: returned in ${ELAPSED_MS}ms with a ${LONG_MS}ms producer delay -- the task cannot have genuinely parked" >&2
  exit 1
fi
if [ "$ELAPSED_MS" -ge "$MAX_MS" ]; then
  echo "named hostfutures component gate FAILED: took ${ELAPSED_MS}ms, at or beyond the ${MAX_MS}ms overlap bound -- sequential waits would take ${LONG_MS} + ${SHORT_MS}ms, so the two host futures did not overlap" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] concurrent path: RC=1/0 both returned 42; RC=1 took ${ELAPSED_MS}ms (>= ${MIN_MS}, < ${MAX_MS}: both futures in flight)"

# --- regression: the call NESTED in a record literal (#1337 Codex P2) ---------
# The name collector must be TOTAL over expression containers: compile_call
# lowers a nested `host_future_named` to its raw getter regardless of where it
# sits, so a container the collector skips reserves no import and the program
# fails to compile ("undefined variable (local): vibe_hf_get_raw$price").
# The record literal sits in a row-free NAMED fn rather than on the handled
# spine: ADR-0076's migration eligibility independently rejects a container
# literal there, and that (clearly diagnosed) rejection is a separate concern.
NEST_SRC="$OUT_DIR/nested_named_await.vibe"
cat >"$NEST_SRC" <<'EOF'
fn make_cell() -> Future[Int] {
  let r = record {
    p: host_future_named("price")
  }
  r.p
}

let run: () -> Int with Async = () -> {
  await(make_cell())
}
EOF
NEST_OUT="$OUT_DIR/nested_named_await.component.wasm"
compile_fixture "$NEST_SRC" "$NEST_OUT"
NEST_LOG="$OUT_DIR/nested.log"
if ! VIBE_ASYNC_FUTURES="price=40:1" timeout 60 "$RUNNER" "$NEST_OUT" >"$NEST_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: record-nested run did not exit 0" >&2
  cat "$NEST_LOG" >&2
  exit 1
fi
[ "$(cat "$NEST_LOG")" = "40" ] \
  || { echo "named hostfutures component gate FAILED: record-nested expected 40, got: $(cat "$NEST_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] record-nested call: 40 (collector is total over containers)"

# --- regression: a SHADOWED builtin reserves nothing (#1337 Codex P2) ---------
# A local named `host_future_named` makes the call an ordinary closure call
# that compile_call does not lower, so collecting its argument would demand a
# `price` import the program never uses.
SHADOW_SRC="$OUT_DIR/shadowed_named.vibe"
cat >"$SHADOW_SRC" <<'EOF'
let run: () -> Int = () -> {
  let host_future_named = (s: String) -> Int {
    41
  }
  host_future_named("price") + 1
}
EOF
SHADOW_OUT="$OUT_DIR/shadowed_named.wasm"
compile_fixture "$SHADOW_SRC" "$SHADOW_OUT"
if grep -q "host_future_get\$price" "$SHADOW_OUT"; then
  echo "named hostfutures component gate FAILED: a SHADOWED host_future_named still reserved the 'price' import" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] shadowed builtin: no 'price' import reserved"
# The response builtin is shadow-aware on its own name too (Codex on #3059):
# a program's own top-level `host_response_named`, called with a WIT address,
# reserves no response import, while its `host_future_named` call still does.
RSHADOW_SRC="$OUT_DIR/shadowed_response.vibe"
cat >"$RSHADOW_SRC" <<'EOF'
fn host_response_named(s: String) -> Int {
  String::length(s)
}

let run: () -> Int with Async = () -> {
  host_response_named("example:p/api#fetch") + await(host_future_named("price"))
}
EOF
RSHADOW_OUT="$OUT_DIR/shadowed_response.wasm"
compile_fixture "$RSHADOW_SRC" "$RSHADOW_OUT"
if grep -q "wit_response_get" "$RSHADOW_OUT"; then
  echo "named hostfutures component gate FAILED: a program's own host_response_named reserved a response import" >&2
  exit 1
fi
grep -q "host_future_get\$price" "$RSHADOW_OUT" \
  || { echo "named hostfutures component gate FAILED: shadowing host_response_named dropped the host_future_named import" >&2; exit 1; }
echo "[named-hostfutures-component-gate] shadowed response builtin: no response import, 'price' still reserved"

# --- #2832: awaiting the SAME host future twice ------------------------------
# The future-side analogue of the stream lifecycle the hoststreams gate pins
# (its partial-consume fixture closes twice and reads after close). Nothing
# awaited one host future twice, so the latch that makes the second await
# cheap was documented and never run.
#
# The mechanism: `__aw_settle` (lowering/effects/await/await.vibe) writes the
# resumed value into the cell's payload word and then sets the state word to
# `0`, so `__aw_poll`'s `while 0 < state` loop does not run a second time and
# the second `await` reads the cached payload. It must NOT go back to the
# host: `host_future_wait` only settles, and a second `future.read` on a
# future that already has one pending is a canonical-ABI error.
#
# `a * 2 + b` with price = 14 is 42. The VALUE cannot separate a cached read
# from a correct re-read (the host would hand back the same 14), so it is here
# only to catch a second await that settles to garbage -- a payload word left
# holding the handle, or a zero. **The wall clock is the load-bearing
# assertion**: one host read costs LONG_MS, two cost 2 x LONG_MS, and the same
# [0.8x, 1.4x] window the overlap check uses separates them. Measured at
# LONG_MS=300 on this tree: 318ms for the double await, 619ms for the
# two-name sequential shape that really does read twice.
DOUBLE_SRC="$OUT_DIR/double_await.vibe"
cat >"$DOUBLE_SRC" <<'EOF'
let run: () -> Int with Async = () -> {
  let f = host_future_named("price")
  let a = await(f)
  let b = await(f)
  a * 2 + b
}
EOF
DOUBLE_OUT="$OUT_DIR/double_await.component.wasm"
compile_fixture "$DOUBLE_SRC" "$DOUBLE_OUT"

DOUBLE_WARM_LOG="$OUT_DIR/run.double.warmup.log"
if ! VIBE_ASYNC_FUTURES="price=14:1" timeout 60 "$RUNNER" "$DOUBLE_OUT" >"$DOUBLE_WARM_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: double-await warmup did not exit 0 (a second future.read on the same future is a canonical-ABI error)" >&2
  cat "$DOUBLE_WARM_LOG" >&2
  exit 1
fi
[ "$(cat "$DOUBLE_WARM_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: double-await warmup expected 42 (14 * 2 + 14), got: $(cat "$DOUBLE_WARM_LOG")" >&2; exit 1; }

DOUBLE_LOG="$OUT_DIR/run.double.log"
DOUBLE_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="price=14:$LONG_MS" timeout 60 "$RUNNER" "$DOUBLE_OUT" >"$DOUBLE_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: double-await run did not exit 0 (a second future.read on the same future is a canonical-ABI error)" >&2
  cat "$DOUBLE_LOG" >&2
  exit 1
fi
DOUBLE_ELAPSED_MS=$(( ( $(date +%s%N) - DOUBLE_START_NS ) / 1000000 ))
DOUBLE_GOT="$(cat "$DOUBLE_LOG")"
[ "$DOUBLE_GOT" = "42" ] \
  || { echo "named hostfutures component gate FAILED: double-await expected 42 (14 * 2 + 14), got: $DOUBLE_GOT" >&2; exit 1; }
if [ "$DOUBLE_ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "named hostfutures component gate FAILED: double-await returned in ${DOUBLE_ELAPSED_MS}ms with a ${LONG_MS}ms producer delay -- the first await cannot have genuinely parked" >&2
  exit 1
fi
if [ "$DOUBLE_ELAPSED_MS" -ge "$MAX_MS" ]; then
  echo "named hostfutures component gate FAILED: double-await took ${DOUBLE_ELAPSED_MS}ms, at or beyond the ${MAX_MS}ms bound -- the settled cell did not latch, so the second await went back to the host for a second ${LONG_MS}ms read" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] double await: 42 in ${DOUBLE_ELAPSED_MS}ms (>= ${MIN_MS}, < ${MAX_MS}: exactly ONE host read -- the settled cell latched)"

# The window above only means something if the two-read world actually lands
# outside it, so the gate measures that world too rather than asserting it.
# Same program with the second future created AFTER the first await settles --
# the reads cannot overlap, so this is what "the second await went back to the
# host" costs. It must sit at or beyond MAX_MS; a loaded machine only pushes
# it further out, so this control cannot go flaky in the direction that would
# matter. (Creating both futures up front instead would OVERLAP the reads and
# land back inside the window -- which is what the overlap check above
# measures, and why this control is written sequentially.)
SEQ_SRC="$OUT_DIR/sequential_two_reads.vibe"
cat >"$SEQ_SRC" <<'EOF'
let run: () -> Int with Async = () -> {
  let f = host_future_named("price")
  let a = await(f)
  let g = host_future_named("qty")
  let b = await(g)
  a * 2 + b
}
EOF
SEQ_OUT="$OUT_DIR/sequential_two_reads.component.wasm"
compile_fixture "$SEQ_SRC" "$SEQ_OUT"
SEQ_LOG="$OUT_DIR/run.sequential.log"
SEQ_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="price=14:$LONG_MS,qty=14:$LONG_MS" timeout 60 "$RUNNER" "$SEQ_OUT" >"$SEQ_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: sequential two-read control did not exit 0" >&2
  cat "$SEQ_LOG" >&2
  exit 1
fi
SEQ_ELAPSED_MS=$(( ( $(date +%s%N) - SEQ_START_NS ) / 1000000 ))
[ "$(cat "$SEQ_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: sequential two-read control expected 42, got: $(cat "$SEQ_LOG")" >&2; exit 1; }
if [ "$SEQ_ELAPSED_MS" -lt "$MAX_MS" ]; then
  echo "named hostfutures component gate FAILED: two SEQUENTIAL host reads took ${SEQ_ELAPSED_MS}ms, inside the ${MAX_MS}ms bound the double-await check uses -- that check can no longer tell one host read from two, so its pass above proves nothing" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] two-read control: ${SEQ_ELAPSED_MS}ms (>= ${MAX_MS}: the window above really does separate one host read from two)"

# --- control: one name imports only that name --------------------------------
CTRL_SRC="$OUT_DIR/single_named_await.vibe"
cat >"$CTRL_SRC" <<'EOF'
let run: () -> Int with Async = () -> {
  await(host_future_named("price"))
}
EOF
CTRL_OUT="$OUT_DIR/single_named_await.component.wasm"
compile_fixture "$CTRL_SRC" "$CTRL_OUT"
CTRL_WIT="$OUT_DIR/single_named_await.wit"
wasm-tools component wit "$CTRL_OUT" >"$CTRL_WIT" 2>/dev/null \
  || { echo "named hostfutures component gate FAILED: could not print the control component's WIT" >&2; exit 1; }
grep -Eq "^[[:space:]]*import price:" "$CTRL_WIT" \
  || { echo "named hostfutures component gate FAILED: control component has no 'price' import" >&2; cat "$CTRL_WIT" >&2; exit 1; }
if grep -Eq "^[[:space:]]*import qty:" "$CTRL_WIT"; then
  echo "named hostfutures component gate FAILED: control component imports 'qty' -- names leaked across programs" >&2
  cat "$CTRL_WIT" >&2
  exit 1
fi
CTRL_LOG="$OUT_DIR/single.log"
if ! VIBE_ASYNC_FUTURES="price=41:1" timeout 60 "$RUNNER" "$CTRL_OUT" >"$CTRL_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: control run did not exit 0" >&2
  cat "$CTRL_LOG" >&2
  exit 1
fi
[ "$(cat "$CTRL_LOG")" = "41" ] \
  || { echo "named hostfutures component gate FAILED: control expected 41, got: $(cat "$CTRL_LOG")" >&2; exit 1; }

# --- spawned tasks awaiting host futures interleave (#1537) ------------------
# fixtures/async_spawn_host_futures/main.vibe: task a awaits `slow` (300ms);
# task b awaits `fast` (150ms) and only then requests a second `fast`. The
# group waits on every pending handle at once and resumes whichever lands, so
# b completes both reads inside a's 300ms. Waiting in park order would start
# b's second read only after a's future landed (~450ms), so the 400ms upper
# bound is what separates the two.
SPAWN_OUT="$OUT_DIR/spawn_host_futures.component.wasm"
rm -f "$SPAWN_OUT" "$SPAWN_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/main.vibe "$SPAWN_OUT" run >/dev/null 2>&1 || true
[ -s "$SPAWN_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/main.vibe did not compile: $(cat "$SPAWN_OUT.diag" 2>/dev/null)" >&2; exit 1; }
SPAWN_LOG="$OUT_DIR/spawn_host_futures.log"
SPAWN_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="slow=40:300,fast=1:150" timeout 60 "$RUNNER" "$SPAWN_OUT" >"$SPAWN_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: spawned-task run did not exit 0" >&2
  cat "$SPAWN_LOG" >&2
  exit 1
fi
SPAWN_ELAPSED_MS=$(( ( $(date +%s%N) - SPAWN_START_NS ) / 1000000 ))
[ "$(cat "$SPAWN_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: spawned tasks expected 42 (40 + 1 + 1), got: $(cat "$SPAWN_LOG")" >&2; exit 1; }
if [ "$SPAWN_ELAPSED_MS" -ge 400 ]; then
  echo "named hostfutures component gate FAILED: spawned tasks took ${SPAWN_ELAPSED_MS}ms -- b's second read waited for a's future instead of interleaving" >&2
  exit 1
fi
if [ "$SPAWN_ELAPSED_MS" -lt 240 ]; then
  echo "named hostfutures component gate FAILED: spawned tasks took ${SPAWN_ELAPSED_MS}ms, under the 300ms future -- the tasks did not park" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] spawned tasks: 42 in ${SPAWN_ELAPSED_MS}ms (< 400: interleaved, not park order)"
# Two tasks awaiting ONE future: both resume with its value (41 = 20 + 21).
SHARED_OUT="$OUT_DIR/spawn_shared_future.component.wasm"
rm -f "$SHARED_OUT" "$SHARED_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/shared.vibe "$SHARED_OUT" run >/dev/null 2>&1 || true
[ -s "$SHARED_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/shared.vibe did not compile: $(cat "$SHARED_OUT.diag" 2>/dev/null)" >&2; exit 1; }
SHARED_LOG="$OUT_DIR/spawn_shared_future.log"
if ! VIBE_ASYNC_FUTURES="slow=20:200" timeout 60 "$RUNNER" "$SHARED_OUT" >"$SHARED_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: shared-future run did not exit 0" >&2
  cat "$SHARED_LOG" >&2
  exit 1
fi
[ "$(cat "$SHARED_LOG")" = "41" ] \
  || { echo "named hostfutures component gate FAILED: two tasks awaiting one future expected 41, got: $(cat "$SHARED_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] shared future: 41 (every task parked on the handle resumed with its value)"
# A task cancelled while parked on a future nobody else awaits releases it.
CANCEL_OUT="$OUT_DIR/spawn_cancelled_waiter.component.wasm"
rm -f "$CANCEL_OUT" "$CANCEL_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/cancelled.vibe "$CANCEL_OUT" run >/dev/null 2>&1 || true
[ -s "$CANCEL_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/cancelled.vibe did not compile: $(cat "$CANCEL_OUT.diag" 2>/dev/null)" >&2; exit 1; }
CANCEL_LOG="$OUT_DIR/spawn_cancelled_waiter.log"
if ! VIBE_ASYNC_FUTURES="slow=40:300,fast=1:100" timeout 60 "$RUNNER" "$CANCEL_OUT" >"$CANCEL_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: cancelled-waiter run did not exit 0" >&2
  cat "$CANCEL_LOG" >&2
  exit 1
fi
[ "$(cat "$CANCEL_LOG")" = "40" ] \
  || { echo "named hostfutures component gate FAILED: cancelled waiter expected 40, got: $(cat "$CANCEL_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] cancelled waiter: 40 (its future's read was cancelled and released)"
# 1100 park-and-cancel rounds, past the adapter's 1023-handle ceiling: each
# cancelled future's handle must be released for the live read to succeed.
MANY_OUT="$OUT_DIR/spawn_cancel_many.component.wasm"
rm -f "$MANY_OUT" "$MANY_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/cancel_many.vibe "$MANY_OUT" run >/dev/null 2>&1 || true
[ -s "$MANY_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/cancel_many.vibe did not compile: $(cat "$MANY_OUT.diag" 2>/dev/null)" >&2; exit 1; }
wasm-tools print "$MANY_OUT" >"$MANY_OUT.wat" 2>/dev/null || true
grep -q 'canon future.cancel-read' "$MANY_OUT.wat" \
  || { echo "named hostfutures component gate FAILED: cancel_many composed without future.cancel-read" >&2; exit 1; }
MANY_LOG="$OUT_DIR/spawn_cancel_many.log"
if ! VIBE_ASYNC_FUTURES="slow=40:300,fast=1:100" timeout 60 "$RUNNER" "$MANY_OUT" >"$MANY_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: cancel_many run did not exit 0 (a cancelled future kept its handle?)" >&2
  cat "$MANY_LOG" >&2
  exit 1
fi
[ "$(cat "$MANY_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: cancel_many expected 42, got: $(cat "$MANY_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] cancel_many: 42 (1100 cancelled futures released, past the 1023-handle ceiling)"
# A sleeping task and host waiters share one wait (the earliest sleeper's
# timer is in the same waitable set). Both orders are pinned: a long sleep
# beside a short host chain (sleep-first would take ~400ms), and a short
# sleep before more host work beside a long future (host-first would take
# ~400ms). Each runs in ~300ms.
for timer_case in "sleep_and_host:42" "sleep_short:41"; do
  tc_name="${timer_case%%:*}"
  tc_want="${timer_case##*:}"
  TC_OUT="$OUT_DIR/spawn_${tc_name}.component.wasm"
  rm -f "$TC_OUT" "$TC_OUT.diag"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "fixtures/async_spawn_host_futures/${tc_name}.vibe" "$TC_OUT" run >/dev/null 2>&1 || true
  [ -s "$TC_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/${tc_name}.vibe did not compile: $(cat "$TC_OUT.diag" 2>/dev/null)" >&2; exit 1; }
  TC_LOG="$OUT_DIR/spawn_${tc_name}.log"
  TC_START_NS=$(date +%s%N)
  if ! VIBE_ASYNC_FUTURES="slow=40:300,fast=1:100" timeout 60 "$RUNNER" "$TC_OUT" >"$TC_LOG" 2>&1; then
    echo "named hostfutures component gate FAILED: ${tc_name} did not exit 0" >&2
    cat "$TC_LOG" >&2
    exit 1
  fi
  TC_ELAPSED_MS=$(( ( $(date +%s%N) - TC_START_NS ) / 1000000 ))
  [ "$(cat "$TC_LOG")" = "$tc_want" ] \
    || { echo "named hostfutures component gate FAILED: ${tc_name} expected ${tc_want}, got: $(cat "$TC_LOG")" >&2; exit 1; }
  if [ "$TC_ELAPSED_MS" -ge 370 ] || [ "$TC_ELAPSED_MS" -lt 240 ]; then
    echo "named hostfutures component gate FAILED: ${tc_name} took ${TC_ELAPSED_MS}ms (want ~300ms: the sleeper's timer and the host waits in one set)" >&2
    exit 1
  fi
  echo "[named-hostfutures-component-gate] ${tc_name}: ${tc_want} in ${TC_ELAPSED_MS}ms (timer and host waits together)"
done

# A sleep that begins after the shared timer was armed keeps its whole debt:
# the 1000ms timer fires after `b`'s 900ms future and its 500ms sleep began,
# and only `a` is debited, so the run takes >= 1400ms (debiting every sleeper
# ended `b`'s sleep at ~1000ms).
SAH_OUT="$OUT_DIR/spawn_sleep_after_host.component.wasm"
rm -f "$SAH_OUT" "$SAH_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/sleep_after_host.vibe "$SAH_OUT" run >/dev/null 2>&1 || true
[ -s "$SAH_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/sleep_after_host.vibe did not compile: $(cat "$SAH_OUT.diag" 2>/dev/null)" >&2; exit 1; }
SAH_LOG="$OUT_DIR/spawn_sleep_after_host.log"
SAH_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="slow=40:900" timeout 60 "$RUNNER" "$SAH_OUT" >"$SAH_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: sleep_after_host did not exit 0" >&2
  cat "$SAH_LOG" >&2
  exit 1
fi
SAH_ELAPSED_MS=$(( ( $(date +%s%N) - SAH_START_NS ) / 1000000 ))
[ "$(cat "$SAH_LOG")" = "41" ] \
  || { echo "named hostfutures component gate FAILED: sleep_after_host expected 41, got: $(cat "$SAH_LOG")" >&2; exit 1; }
if [ "$SAH_ELAPSED_MS" -lt 1400 ] || [ "$SAH_ELAPSED_MS" -ge 1900 ]; then
  echo "named hostfutures component gate FAILED: sleep_after_host took ${SAH_ELAPSED_MS}ms (want >= 1400: a sleep begun after the timer was armed is not debited by it)" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] sleep_after_host: 41 in ${SAH_ELAPSED_MS}ms (a later sleep keeps its debt)"

# A task group nested in another group's task shares the waitable set: it
# must leave the enclosing group's landed future and fired timer for their
# owner. The old scheduler took `c`'s future and trapped.
NG_OUT="$OUT_DIR/spawn_nested_groups.component.wasm"
rm -f "$NG_OUT" "$NG_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/nested_groups.vibe "$NG_OUT" run >/dev/null 2>&1 || true
[ -s "$NG_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/nested_groups.vibe did not compile: $(cat "$NG_OUT.diag" 2>/dev/null)" >&2; exit 1; }
NG_LOG="$OUT_DIR/spawn_nested_groups.log"
NG_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="fast=1:100,mid=2:200,slow=40:300" timeout 60 "$RUNNER" "$NG_OUT" >"$NG_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: nested_groups did not exit 0" >&2
  cat "$NG_LOG" >&2
  exit 1
fi
NG_ELAPSED_MS=$(( ( $(date +%s%N) - NG_START_NS ) / 1000000 ))
[ "$(cat "$NG_LOG")" = "43" ] \
  || { echo "named hostfutures component gate FAILED: nested_groups expected 43, got: $(cat "$NG_LOG")" >&2; exit 1; }
if [ "$NG_ELAPSED_MS" -lt 350 ] || [ "$NG_ELAPSED_MS" -ge 600 ]; then
  echo "named hostfutures component gate FAILED: nested_groups took ${NG_ELAPSED_MS}ms (want ~400ms: the outer timer paid once, not again after the nested group consumed it)" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] nested_groups: 43 in ${NG_ELAPSED_MS}ms (the nested group left the outer group's events for it)"

# A nested group arms its own timer after the outer timer fired during its
# wait; its sleeper sleeps its full 200ms (~550ms total), not ended by the
# outer entry left in the mailbox.
NTR_OUT="$OUT_DIR/spawn_nested_timer_reuse.component.wasm"
rm -f "$NTR_OUT" "$NTR_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/nested_timer_reuse.vibe "$NTR_OUT" run >/dev/null 2>&1 || true
[ -s "$NTR_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/nested_timer_reuse.vibe did not compile: $(cat "$NTR_OUT.diag" 2>/dev/null)" >&2; exit 1; }
NTR_LOG="$OUT_DIR/spawn_nested_timer_reuse.log"
NTR_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="fast=1:100,mid=2:250,slow=40:300" timeout 60 "$RUNNER" "$NTR_OUT" >"$NTR_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: nested_timer_reuse did not exit 0" >&2
  cat "$NTR_LOG" >&2
  exit 1
fi
NTR_ELAPSED_MS=$(( ( $(date +%s%N) - NTR_START_NS ) / 1000000 ))
[ "$(cat "$NTR_LOG")" = "43" ] \
  || { echo "named hostfutures component gate FAILED: nested_timer_reuse expected 43, got: $(cat "$NTR_LOG")" >&2; exit 1; }
if [ "$NTR_ELAPSED_MS" -lt 500 ] || [ "$NTR_ELAPSED_MS" -ge 800 ]; then
  echo "named hostfutures component gate FAILED: nested_timer_reuse took ${NTR_ELAPSED_MS}ms (want ~550ms: the nested sleeper keeps its whole debt)" >&2
  exit 1
fi
echo "[named-hostfutures-component-gate] nested_timer_reuse: 43 in ${NTR_ELAPSED_MS}ms (the nested timer is its own, not the outer one left in the mailbox)"

# An enclosing task and a nested group's task await the SAME host future: the
# nested group takes the value, and the enclosing task must still resume with
# it (the old scheduler left it arming a released handle, which trapped).
NS_OUT="$OUT_DIR/spawn_nested_shared.component.wasm"
rm -f "$NS_OUT" "$NS_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/nested_shared.vibe "$NS_OUT" run >/dev/null 2>&1 || true
[ -s "$NS_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/nested_shared.vibe did not compile: $(cat "$NS_OUT.diag" 2>/dev/null)" >&2; exit 1; }
NS_LOG="$OUT_DIR/spawn_nested_shared.log"
if ! VIBE_ASYNC_FUTURES="fast=1:100,slow=20:300" timeout 60 "$RUNNER" "$NS_OUT" >"$NS_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: nested_shared did not exit 0" >&2
  cat "$NS_LOG" >&2
  exit 1
fi
[ "$(cat "$NS_LOG")" = "41" ] \
  || { echo "named hostfutures component gate FAILED: nested_shared expected 41, got: $(cat "$NS_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] nested_shared: 41 (the enclosing waiter resumed with the value the nested group took)"

# nested_shared_reuse: after the nested group takes the shared future (and
# releases its handle), its task obtains ANOTHER host future, which the
# runtime hands the released handle. The mailbox is keyed by waiter, so that
# future is awaited for real: 20 + (20 + 5) = 45. Keyed by handle it answered
# 60 -- the stale shared value, silently (Codex on #3091).
NR_OUT="$OUT_DIR/spawn_nested_shared_reuse.component.wasm"
rm -f "$NR_OUT" "$NR_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/nested_shared_reuse.vibe "$NR_OUT" run >/dev/null 2>&1 || true
[ -s "$NR_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/nested_shared_reuse.vibe did not compile: $(cat "$NR_OUT.diag" 2>/dev/null)" >&2; exit 1; }
NR_LOG="$OUT_DIR/spawn_nested_shared_reuse.log"
if ! VIBE_ASYNC_FUTURES="fast=1:100,slow=20:300,other=5:100" timeout 60 "$RUNNER" "$NR_OUT" >"$NR_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: nested_shared_reuse did not exit 0" >&2
  cat "$NR_LOG" >&2
  exit 1
fi
[ "$(cat "$NR_LOG")" = "45" ] \
  || { echo "named hostfutures component gate FAILED: nested_shared_reuse expected 45, got: $(cat "$NR_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] nested_shared_reuse: 45 (a future on a reused handle was awaited, not answered from the mailbox)"

# join_parked: TaskHandle::join on a task parked on a host future, with no
# pump_all first. It trapped as a deadlock; join now pumps the group itself.
# The 5s sleeper beside it is cancelled after the join, so the run ends with
# the 100ms future.
JP_OUT="$OUT_DIR/spawn_join_parked.component.wasm"
rm -f "$JP_OUT" "$JP_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/join_parked.vibe "$JP_OUT" run >/dev/null 2>&1 || true
[ -s "$JP_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/join_parked.vibe did not compile: $(cat "$JP_OUT.diag" 2>/dev/null)" >&2; exit 1; }
JP_LOG="$OUT_DIR/spawn_join_parked.log"
JP_START=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="fast=7:100" timeout 60 "$RUNNER" "$JP_OUT" >"$JP_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: join_parked did not exit 0" >&2
  cat "$JP_LOG" >&2
  exit 1
fi
JP_MS=$(( ( $(date +%s%N) - JP_START ) / 1000000 ))
[ "$(cat "$JP_LOG")" = "7" ] \
  || { echo "named hostfutures component gate FAILED: join_parked expected 7, got: $(cat "$JP_LOG")" >&2; exit 1; }
[ "$JP_MS" -lt 2000 ] \
  || { echo "named hostfutures component gate FAILED: join_parked took ${JP_MS}ms -- the cancelled 5s sleeper held the run" >&2; exit 1; }
echo "[named-hostfutures-component-gate] join_parked: 7 in ${JP_MS}ms (join pumped the parked task)"

# catch_in_entry: an Async entry that spawns suspendable tasks catches
# exceptions around code that cannot suspend (one passes a local into a
# String parameter). Such an entry's boundary is suspend-class, and it used to
# refuse every nested handle. 40 + 1 + 1 = 42.
CI_OUT="$OUT_DIR/spawn_catch_in_entry.component.wasm"
rm -f "$CI_OUT" "$CI_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/catch_in_entry.vibe "$CI_OUT" run >/dev/null 2>&1 || true
[ -s "$CI_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/catch_in_entry.vibe did not compile: $(cat "$CI_OUT.diag" 2>/dev/null)" >&2; exit 1; }
CI_LOG="$OUT_DIR/spawn_catch_in_entry.log"
if ! VIBE_ASYNC_FUTURES="fast=1:100" timeout 60 "$RUNNER" "$CI_OUT" >"$CI_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: catch_in_entry did not exit 0" >&2
  cat "$CI_LOG" >&2
  exit 1
fi
[ "$(cat "$CI_LOG")" = "42" ] \
  || { echo "named hostfutures component gate FAILED: catch_in_entry expected 42, got: $(cat "$CI_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] catch_in_entry: 42 (a handle beside spawned tasks in an Async entry)"

# catch_async_body_refused: the same handle around a callee whose row carries
# Async stays refused -- the suspend split does not cut through a handle.
CR_OUT="$OUT_DIR/spawn_catch_async_body_refused.component.wasm"
rm -f "$CR_OUT" "$CR_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/catch_async_body_refused.vibe "$CR_OUT" run >/dev/null 2>&1 || true
if [ -s "$CR_OUT" ]; then
  echo "named hostfutures component gate FAILED: catch_async_body_refused compiled -- a handle around an Async callee must be refused" >&2
  exit 1
fi
grep -qF "cannot see through" "$CR_OUT.diag" 2>/dev/null \
  || { echo "named hostfutures component gate FAILED: catch_async_body_refused gave an unexpected diagnostic: $(cat "$CR_OUT.diag" 2>/dev/null)" >&2; exit 1; }
echo "[named-hostfutures-component-gate] catch_async_body_refused: refused (the handled body reaches Async)"

# timer_release_many: 1100 groups each close with their timer still armed
# (the 10s sleeper it covered was cancelled); each cancels the timer's
# subtask. Past the 1024-handle band, so keeping them trapped a later arm.
TR_OUT="$OUT_DIR/spawn_timer_release_many.component.wasm"
rm -f "$TR_OUT" "$TR_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" fixtures/async_spawn_host_futures/timer_release_many.vibe "$TR_OUT" run >/dev/null 2>&1 || true
[ -s "$TR_OUT" ] || { echo "named hostfutures component gate FAILED: fixtures/async_spawn_host_futures/timer_release_many.vibe did not compile: $(cat "$TR_OUT.diag" 2>/dev/null)" >&2; exit 1; }
TR_LOG="$OUT_DIR/spawn_timer_release_many.log"
if ! VIBE_ASYNC_FUTURES="fast=1:1" timeout 120 "$RUNNER" "$TR_OUT" >"$TR_LOG" 2>&1; then
  echo "named hostfutures component gate FAILED: timer_release_many did not exit 0" >&2
  cat "$TR_LOG" >&2
  exit 1
fi
[ "$(cat "$TR_LOG")" = "1100" ] \
  || { echo "named hostfutures component gate FAILED: timer_release_many expected 1100, got: $(cat "$TR_LOG")" >&2; exit 1; }
echo "[named-hostfutures-component-gate] timer_release_many: 1100 (each closing group cancelled its pending timer)"

echo "named hostfutures component gate OK"
