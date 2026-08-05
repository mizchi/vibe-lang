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
  local src="$1" out="$2"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
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
compile_fixture "$SRC" "$COMPONENT"

# Must be a COMPONENT (layer 1 header), not a bare core module.
if ! od -A n -t x1 -N 8 "$COMPONENT" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
  echo "named hostfutures component gate FAILED: output is not a component (wrap did not trigger)" >&2
  exit 1
fi

wasm-tools validate --features all "$COMPONENT" \
  || { echo "named hostfutures component gate FAILED: component failed validation" >&2; exit 1; }

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
echo "[named-hostfutures-component-gate] concurrent path: 42 in ${ELAPSED_MS}ms (>= ${MIN_MS}, < ${MAX_MS}: both futures in flight)"

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

echo "named hostfutures component gate OK"
