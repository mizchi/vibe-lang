#!/usr/bin/env bash
# #1342: `sleep` INSIDE an async component, end to end.
#
# Until this landed, an `() -> Int with Async` entry that called `sleep` had no
# working route at all. The self-contained wrap it fell into instantiates the
# compiled core with a preview1 stub and nothing else, so the emitted component
# was missing the `vibe` instance its own core imported -- and the compiler
# wrote that file and exited 0. `wasm-tools validate` said:
#
#   error: missing module instantiation argument named `vibe`
#
# Now `vibe.sleep` keys the adapter-backed composition (the one host futures and
# host streams already ride): the component imports `sleep-for: async func(ms:
# u32) -> u32`, and the adapter's `sleep` func async-lowers that call and parks
# on the resulting SUBTASK in `waitable-set.wait`.
#
# What each assertion proves:
#   validate  the composition is instantiable at all -- the regression that
#             motivated this lane was an artifact that was not
#   import     `sleep-for` is a real component import, so the delay comes from
#             a host timer rather than a guest spin loop
#   value      42 came back, so the program resumed AFTER the sleep with its
#              state intact
#   suspend    wall clock >= 0.8 x D: the task really waited
#   overlap    the mixed lane is the load-bearing one. A host future with delay
#              D is created BEFORE a sleep of D, then awaited after it. If the
#              sleep genuinely parks the task, the future's producer runs
#              during it and the whole program takes ~D. If the sleep blocked
#              instead, nothing else could progress and it would take ~2D.
#              That is the difference between an async component and a
#              component that merely compiles.
#   rc0        the same program under the plain-i64 value convention: the ms
#              argument crosses the adapter boundary, so it has to be decoded
#              per the core's declared convention (ADR-0106), not guessed.
#   reject     an async entry whose core imports something NOTHING in the
#              composition provides must fail with that import named, instead
#              of producing an invalid component with a zero exit status.
#
# Env:
#   VIBE_ASYNC_SLEEP_GATE_COMPILER  compiler wasm override (default: newest
#                                   _build generation stage2, else seed -- the
#                                   lowering postdates the committed seed, so a
#                                   fresh generation build is required until the
#                                   next bootstrap bump)
#   VIBE_ASYNC_SLEEP_GATE_RUNNER    viberun binary override
#   VIBE_ASYNC_SLEEP_GATE_DELAY_MS  the sleep/future delay D, default 300
#   VIBE_P3_GATE_REQUIRE_TOOLS=1    missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_async_sleep_component}"
mkdir -p "$OUT_DIR"

DELAY_MS="${VIBE_ASYNC_SLEEP_GATE_DELAY_MS:-300}"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "async sleep component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "async sleep component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_ASYNC_SLEEP_GATE_RUNNER:-$DEFAULT_RUNNER}"
# Same rebuild-when-stale convention as the other p3 gates: an explicit
# override is trusted as-is; the default in-tree binary is rebuilt when missing
# or older than any viberun build input.
if [ "$RUNNER" = "$DEFAULT_RUNNER" ]; then
  needs_build=0
  if [ ! -x "$RUNNER" ]; then
    needs_build=1
  elif find "$PROJECT_ROOT/runtime/viberun/src" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.toml" \
        "$PROJECT_ROOT/runtime/viberun/Cargo.lock" \
        -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
    echo "[async-sleep-component-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[async-sleep-component-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_ASYNC_SLEEP_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[async-sleep-component-gate] compiler: $COMPILER"
echo "[async-sleep-component-gate] runner: $RUNNER"

compile_fixture() {
  local src="$1" out="$2" rc_mode="${3:-1}"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw VIBE_RC="$rc_mode" \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$src" "$out" run >/dev/null \
    || { echo "async sleep component gate FAILED: $src did not compile: $(cat "$out.diag" 2>/dev/null)" >&2; exit 1; }
  [ -s "$out" ] || { echo "async sleep component gate FAILED: no output for $src" >&2; exit 1; }
}

assert_component() {
  local what="$1" comp="$2"
  od -A n -t x1 -N 8 "$comp" | tr -d ' \n' | grep -q '^0061736d0d000100$' \
    || { echo "async sleep component gate FAILED: $what is not a component (wrap did not trigger)" >&2; exit 1; }
  wasm-tools validate --features all "$comp" \
    || { echo "async sleep component gate FAILED: $what failed validation" >&2; exit 1; }
}

elapsed_ms() {
  echo $(( ( $2 - $1 ) / 1000000 ))
}

# --- lane 1: sleep only ------------------------------------------------------
SRC="$OUT_DIR/sleep_only.vibe"
cat >"$SRC" <<EOF
let run: () -> Int with Async = () -> {
  sleep($DELAY_MS)
  42
}
EOF

COMPONENT="$OUT_DIR/sleep_only.component.wasm"
compile_fixture "$SRC" "$COMPONENT" 1
assert_component "the sleep-only component" "$COMPONENT"

WIT="$OUT_DIR/sleep_only.wit"
wasm-tools component wit "$COMPONENT" >"$WIT" 2>/dev/null \
  || { echo "async sleep component gate FAILED: could not print the component's WIT" >&2; exit 1; }
grep -Eq "^[[:space:]]*import sleep-for:" "$WIT" \
  || { echo "async sleep component gate FAILED: no 'sleep-for' import in the component's WIT:" >&2; cat "$WIT" >&2; exit 1; }
echo "[async-sleep-component-gate] imports: sleep-for"

# Warm the JIT with a near-zero delay first, so the timed run below measures the
# sleep rather than compilation.
WARM_LOG="$OUT_DIR/sleep_only.warmup.log"
if ! VIBE_ASYNC_DELAY_SCALE_PCT=1 timeout 60 "$RUNNER" "$COMPONENT" >"$WARM_LOG" 2>&1; then
  echo "async sleep component gate FAILED: warmup run did not exit 0" >&2
  cat "$WARM_LOG" >&2
  exit 1
fi
[ "$(cat "$WARM_LOG")" = "42" ] \
  || { echo "async sleep component gate FAILED: warmup expected 42, got: $(cat "$WARM_LOG")" >&2; exit 1; }

RESULT_LOG="$OUT_DIR/sleep_only.log"
START_NS=$(date +%s%N)
if ! timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "async sleep component gate FAILED: run did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
END_NS=$(date +%s%N)
[ "$(cat "$RESULT_LOG")" = "42" ] \
  || { echo "async sleep component gate FAILED: expected 42, got: $(cat "$RESULT_LOG")" >&2; exit 1; }
ELAPSED=$(elapsed_ms "$START_NS" "$END_NS")
MIN_MS=$(( DELAY_MS * 8 / 10 ))
if [ "$ELAPSED" -lt "$MIN_MS" ]; then
  echo "async sleep component gate FAILED: ${ELAPSED}ms < ${MIN_MS}ms -- the task did not actually wait for the host timer" >&2
  exit 1
fi
echo "[async-sleep-component-gate] sleep-only: 42 in ${ELAPSED}ms (delay ${DELAY_MS}ms)"

# --- lane 2: sleep under the plain-i64 value convention ----------------------
RC0_COMPONENT="$OUT_DIR/sleep_only.rc0.component.wasm"
compile_fixture "$SRC" "$RC0_COMPONENT" 0
assert_component "the RC=0 sleep-only component" "$RC0_COMPONENT"
RC0_LOG="$OUT_DIR/sleep_only.rc0.log"
RC0_START_NS=$(date +%s%N)
if ! timeout 60 "$RUNNER" "$RC0_COMPONENT" >"$RC0_LOG" 2>&1; then
  echo "async sleep component gate FAILED: RC=0 run did not exit 0" >&2
  cat "$RC0_LOG" >&2
  exit 1
fi
RC0_END_NS=$(date +%s%N)
[ "$(cat "$RC0_LOG")" = "42" ] \
  || { echo "async sleep component gate FAILED: RC=0 expected 42, got: $(cat "$RC0_LOG")" >&2; exit 1; }
RC0_ELAPSED=$(elapsed_ms "$RC0_START_NS" "$RC0_END_NS")
# The ms argument crosses the adapter boundary. A convention mismatch would not
# fail loudly -- it would sleep for half (or twice) the requested time and still
# print 42, so the DURATION is the only thing that can catch it.
RC0_MAX_MS=$(( DELAY_MS * 16 / 10 ))
if [ "$RC0_ELAPSED" -lt "$MIN_MS" ] || [ "$RC0_ELAPSED" -gt "$RC0_MAX_MS" ]; then
  echo "async sleep component gate FAILED: RC=0 slept ${RC0_ELAPSED}ms, expected ${MIN_MS}..${RC0_MAX_MS}ms -- the ms argument was decoded in the wrong value convention" >&2
  exit 1
fi
echo "[async-sleep-component-gate] rc0: 42 in ${RC0_ELAPSED}ms"

# --- lane 3: sleep MIXED with a host future ----------------------------------
# The future is created (and its read issued) BEFORE the sleep, and awaited
# after it. Overlapped: ~D. Serialized by a blocking sleep: ~2D.
MIXED_SRC="$OUT_DIR/sleep_mixed.vibe"
cat >"$MIXED_SRC" <<EOF
let run: () -> Int with Async = () -> {
  let a = host_future_named("price")
  sleep($DELAY_MS)
  await(a) + 2
}
EOF
MIXED_COMPONENT="$OUT_DIR/sleep_mixed.component.wasm"
compile_fixture "$MIXED_SRC" "$MIXED_COMPONENT" 1
assert_component "the mixed sleep+future component" "$MIXED_COMPONENT"

MIXED_WIT="$OUT_DIR/sleep_mixed.wit"
wasm-tools component wit "$MIXED_COMPONENT" >"$MIXED_WIT" 2>/dev/null \
  || { echo "async sleep component gate FAILED: could not print the mixed component's WIT" >&2; exit 1; }
for want in "price" "sleep-for"; do
  grep -Eq "^[[:space:]]*import ${want}:" "$MIXED_WIT" \
    || { echo "async sleep component gate FAILED: no '${want}' import in the mixed component's WIT:" >&2; cat "$MIXED_WIT" >&2; exit 1; }
done

MIXED_WARM="$OUT_DIR/sleep_mixed.warmup.log"
if ! VIBE_ASYNC_FUTURES="price=40:$DELAY_MS" VIBE_ASYNC_DELAY_SCALE_PCT=1 \
     timeout 60 "$RUNNER" "$MIXED_COMPONENT" >"$MIXED_WARM" 2>&1; then
  echo "async sleep component gate FAILED: mixed warmup did not exit 0" >&2
  cat "$MIXED_WARM" >&2
  exit 1
fi
[ "$(cat "$MIXED_WARM")" = "42" ] \
  || { echo "async sleep component gate FAILED: mixed warmup expected 42, got: $(cat "$MIXED_WARM")" >&2; exit 1; }

MIXED_LOG="$OUT_DIR/sleep_mixed.log"
MIXED_START_NS=$(date +%s%N)
if ! VIBE_ASYNC_FUTURES="price=40:$DELAY_MS" timeout 60 "$RUNNER" "$MIXED_COMPONENT" >"$MIXED_LOG" 2>&1; then
  echo "async sleep component gate FAILED: mixed run did not exit 0" >&2
  cat "$MIXED_LOG" >&2
  exit 1
fi
MIXED_END_NS=$(date +%s%N)
[ "$(cat "$MIXED_LOG")" = "42" ] \
  || { echo "async sleep component gate FAILED: mixed expected 42, got: $(cat "$MIXED_LOG")" >&2; exit 1; }
MIXED_ELAPSED=$(elapsed_ms "$MIXED_START_NS" "$MIXED_END_NS")
MIXED_MAX_MS=$(( DELAY_MS * 16 / 10 ))
if [ "$MIXED_ELAPSED" -lt "$MIN_MS" ]; then
  echo "async sleep component gate FAILED: mixed took ${MIXED_ELAPSED}ms < ${MIN_MS}ms -- neither wait happened" >&2
  exit 1
fi
if [ "$MIXED_ELAPSED" -gt "$MIXED_MAX_MS" ]; then
  echo "async sleep component gate FAILED: mixed took ${MIXED_ELAPSED}ms > ${MIXED_MAX_MS}ms -- the sleep BLOCKED the host future's producer instead of parking the task" >&2
  exit 1
fi
echo "[async-sleep-component-gate] mixed: 42 in ${MIXED_ELAPSED}ms (sleep and future overlapped; serialized would be ~$(( DELAY_MS * 2 ))ms)"

# --- lane 4: an unsatisfiable host import must be NAMED, not emitted ---------
REJECT_SRC="$OUT_DIR/unsatisfiable.vibe"
# `Stdin::read_char` is a host import with no provider inside a component. Its
# capability label rides the entry row alongside Async, so this is still an
# async component entry -- it routes to the wrap, it just cannot be satisfied.
cat >"$REJECT_SRC" <<'EOF'
let run: () -> Int with Async + Stdin::read_char = () -> {
  let _ = Stdin::read_char()
  42
}
EOF
REJECT_OUT="$OUT_DIR/unsatisfiable.component.wasm"
rm -f "$REJECT_OUT" "$REJECT_OUT.diag"
if VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw VIBE_RC=1 \
   bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
   "$COMPILER" "$REJECT_SRC" "$REJECT_OUT" run >/dev/null 2>&1; then
  echo "async sleep component gate FAILED: an async entry with an unprovided host import compiled -- and the artifact it wrote is not instantiable:" >&2
  wasm-tools validate --features all "$REJECT_OUT" >&2 || true
  exit 1
fi
REJECT_DIAG="$(cat "$REJECT_OUT.diag" 2>/dev/null || true)"
echo "$REJECT_DIAG" | grep -q "stdin_read_char" \
  || { echo "async sleep component gate FAILED: the rejection does not name the offending import: $REJECT_DIAG" >&2; exit 1; }
[ ! -s "$REJECT_OUT" ] \
  || { echo "async sleep component gate FAILED: a rejected compile still left an artifact behind" >&2; exit 1; }
echo "[async-sleep-component-gate] reject: $REJECT_DIAG"

echo "async sleep component gate OK"
