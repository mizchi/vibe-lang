#!/usr/bin/env bash
# ADR-0089 Decision 3 (#1218): NAMED host streams, end to end.
#
# The stream sibling of test_named_hostfutures_component_gate.sh: a `.vibe`
# program
#
#   let run: () -> Int with { Async } = () -> {
#     let s = host_stream_named("body")
#     let mut sum = 0
#     let mut b = host_stream_next(s)
#     while 0 <= b {
#       sum = sum + b
#       b = host_stream_next(s)
#     }
#     sum
#   }
#
# compiles to a core module importing `vibe.host_stream_get$body` +
# `vibe.host_stream_read`, which the composer turns into a component import
# `body: func() -> stream<u8>`. viberun links it from VIBE_ASYNC_STREAMS
# (wasmtime's own Vec<u8> StreamProducer).
#
# What each lane proves:
#   stream   the sum of every delivered byte comes back (42 = 10+15+17) AND
#            the loop terminated -- so each read transferred exactly one
#            byte, the end of stream was recognized (the measured
#            amount-0/code-1 status -> -1, spec 3.17), and reads genuinely
#            parked and resumed through waitable-set.wait (the Vec producer
#            only runs once a read is pending, so the first read of each
#            byte BLOCKS).
#   wit      `body` is a real `stream<u8>` component import and the future
#            machinery did not leak in (no `get-future`).
#   mixed    one named future + one named stream in the same program share
#            the composition: 42 = 30 (price future) + 5 + 7 (body bytes),
#            with both imports in the WIT.
#
# Env:
#   VIBE_NAMED_HOSTSTREAMS_GATE_COMPILER  compiler wasm override (default:
#                                         newest _build generation stage2,
#                                         else seed -- NOTE the lowering
#                                         postdates the committed seed, so a
#                                         fresh generation build is required
#                                         until the next bootstrap bump)
#   VIBE_NAMED_HOSTSTREAMS_GATE_RUNNER    viberun binary override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1          missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_named_hoststreams_component}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "named hoststreams component gate FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "named hoststreams component gate skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"

DEFAULT_RUNNER="$PROJECT_ROOT/runtime/viberun/target/release/viberun"
RUNNER="${VIBE_NAMED_HOSTSTREAMS_GATE_RUNNER:-$DEFAULT_RUNNER}"
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
    echo "[named-hoststreams-component-gate] viberun is older than its build inputs; rebuilding..."
  fi
  if [ "$needs_build" = "1" ]; then
    command -v cargo >/dev/null 2>&1 || require_or_skip "viberun needs a (re)build and cargo is not installed"
    echo "[named-hoststreams-component-gate] building viberun..."
    if ! (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1); then
      require_or_skip "failed to build runtime/viberun"
    fi
  fi
fi
[ -x "$RUNNER" ] || require_or_skip "viberun not available: $RUNNER"

COMPILER="${VIBE_NAMED_HOSTSTREAMS_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[named-hoststreams-component-gate] compiler: $COMPILER"
echo "[named-hoststreams-component-gate] runner: $RUNNER"

compile_fixture() {
  local src="$1" out="$2"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$src" "$out" run >/dev/null \
    || { echo "named hoststreams component gate FAILED: $src did not compile: $(cat "$out.diag" 2>/dev/null)" >&2; exit 1; }
  [ -s "$out" ] || { echo "named hoststreams component gate FAILED: no output for $src" >&2; exit 1; }
}

check_component_header() {
  local file="$1"
  if ! od -A n -t x1 -N 8 "$file" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
    echo "named hoststreams component gate FAILED: $file is not a component (wrap did not trigger)" >&2
    exit 1
  fi
  wasm-tools validate --features all "$file" \
    || { echo "named hoststreams component gate FAILED: $file failed validation" >&2; exit 1; }
}

# --- the stream fixture ------------------------------------------------------
# A while loop that consumes the stream to its end: the shape a real body
# reader has, and the shape that exercises the ADR-0076 loop widening around
# a suspending call.
SRC="$OUT_DIR/stream_sum.vibe"
cat >"$SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  let s = host_stream_named("body")
  let mut sum = 0
  let mut b = host_stream_next(s)
  while 0 <= b {
    sum = sum + b
    b = host_stream_next(s)
  }
  sum
}
EOF

COMPONENT="$OUT_DIR/stream_sum.component.wasm"
compile_fixture "$SRC" "$COMPONENT"
check_component_header "$COMPONENT"

WIT="$OUT_DIR/stream_sum.wit"
wasm-tools component wit "$COMPONENT" >"$WIT" 2>/dev/null \
  || { echo "named hoststreams component gate FAILED: could not print the component's WIT" >&2; exit 1; }
grep -Eq "^[[:space:]]*import body: async func\(\) -> stream<u8>;" "$WIT" \
  || { echo "named hoststreams component gate FAILED: no 'body: ... stream<u8>' import in the component's WIT:" >&2; cat "$WIT" >&2; exit 1; }
if grep -Eq "^[[:space:]]*import get-future:" "$WIT"; then
  echo "named hoststreams component gate FAILED: the anonymous 'get-future' import leaked into a stream-only program" >&2
  cat "$WIT" >&2
  exit 1
fi
echo "[named-hoststreams-component-gate] wit: body is a stream<u8> import, no future machinery"

RESULT_LOG="$OUT_DIR/run.stream.log"
if ! VIBE_ASYNC_STREAMS="body=10|15|17" timeout 60 "$RUNNER" "$COMPONENT" >"$RESULT_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: viberun did not exit 0" >&2
  cat "$RESULT_LOG" >&2
  exit 1
fi
GOT="$(cat "$RESULT_LOG")"
[ "$GOT" = "42" ] \
  || { echo "named hoststreams component gate FAILED: expected 42 (10+15+17 to end of stream), got: $GOT" >&2; exit 1; }
echo "[named-hoststreams-component-gate] stream path: 42 (all bytes delivered, end of stream recognized)"

# --- the mixed future + stream fixture ---------------------------------------
MIXED_SRC="$OUT_DIR/mixed.vibe"
cat >"$MIXED_SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  let f = host_future_named("price")
  let s = host_stream_named("body")
  let a = host_stream_next(s)
  let b = host_stream_next(s)
  await(f) + a + b
}
EOF

MIXED="$OUT_DIR/mixed.component.wasm"
compile_fixture "$MIXED_SRC" "$MIXED"
check_component_header "$MIXED"

MIXED_WIT="$OUT_DIR/mixed.wit"
wasm-tools component wit "$MIXED" >"$MIXED_WIT" 2>/dev/null \
  || { echo "named hoststreams component gate FAILED: could not print the mixed component's WIT" >&2; exit 1; }
grep -Eq "^[[:space:]]*import price: async func\(\) -> future<u32>;" "$MIXED_WIT" \
  || { echo "named hoststreams component gate FAILED: no 'price' future import in the mixed WIT:" >&2; cat "$MIXED_WIT" >&2; exit 1; }
grep -Eq "^[[:space:]]*import body: async func\(\) -> stream<u8>;" "$MIXED_WIT" \
  || { echo "named hoststreams component gate FAILED: no 'body' stream import in the mixed WIT:" >&2; cat "$MIXED_WIT" >&2; exit 1; }

MIXED_LOG="$OUT_DIR/run.mixed.log"
if ! VIBE_ASYNC_FUTURES="price=30:50" VIBE_ASYNC_STREAMS="body=5|7" \
     timeout 60 "$RUNNER" "$MIXED" >"$MIXED_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: mixed run did not exit 0" >&2
  cat "$MIXED_LOG" >&2
  exit 1
fi
MIXED_GOT="$(cat "$MIXED_LOG")"
[ "$MIXED_GOT" = "42" ] \
  || { echo "named hoststreams component gate FAILED: mixed expected 42 (30 + 5 + 7), got: $MIXED_GOT" >&2; exit 1; }
echo "[named-hoststreams-component-gate] mixed path: 42 (future + stream share one composition)"

echo "named hoststreams component gate OK"
