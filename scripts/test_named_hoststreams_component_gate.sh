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

# --- the `for` surface (#1341) ------------------------------------------------
# ADR-0089 D3's first connection item: `for b in <host stream>` instead of the
# hand-written read loop above. Before this the host stream shared the static
# type `Stream[Int]` with the EAGER array-backed stream, so `for` took the
# array path and silently iterated the 2-word `[state, handle]` cell -- a
# plausible small number (measured: 4), never a diagnostic. The host stream now
# has its own nominal type and the desugar builds the loop on host_stream_next,
# so this must produce the same 42 as the while loop and go through the same
# imports.
FOR_SRC="$OUT_DIR/stream_for.vibe"
cat >"$FOR_SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  let mut sum = 0
  for b in host_stream_named("body") {
    sum = sum + b
  }
  sum
}
EOF
FOR_COMPONENT="$OUT_DIR/stream_for.component.wasm"
compile_fixture "$FOR_SRC" "$FOR_COMPONENT"
check_component_header "$FOR_COMPONENT"
FOR_LOG="$OUT_DIR/run.for.log"
if ! VIBE_ASYNC_STREAMS="body=10|15|17" timeout 60 "$RUNNER" "$FOR_COMPONENT" >"$FOR_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: the `for` form did not exit 0" >&2
  cat "$FOR_LOG" >&2
  exit 1
fi
FOR_GOT="$(cat "$FOR_LOG")"
[ "$FOR_GOT" = "42" ] \
  || { echo "named hoststreams component gate FAILED: for-over-host-stream expected 42, got: $FOR_GOT" >&2; exit 1; }

# The row requirement is the other half: each read parks, so a `for` over a
# host stream outside an { Async } context must be REJECTED, not silently
# compiled. (Before the nominal type it was accepted and iterated the cell.)
FOR_NEG="$OUT_DIR/stream_for_norow.vibe"
cat >"$FOR_NEG" <<'EOF'
let drain = (s: HostStream) -> Int {
  let mut sum = 0
  for b in s {
    sum = sum + b
  }
  sum
}

let run: () -> Int with { Async } = () -> {
  drain(host_stream_named("body"))
}
EOF
FOR_NEG_OUT="$OUT_DIR/stream_for_norow.wasm"
rm -f "$FOR_NEG_OUT" "$FOR_NEG_OUT.diag"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$FOR_NEG" "$FOR_NEG_OUT" run >/dev/null 2>&1 || true
if [ -s "$FOR_NEG_OUT" ]; then
  echo "named hoststreams component gate FAILED: a for-over-host-stream without { Async } compiled (#1341)" >&2
  exit 1
fi
echo "[named-hoststreams-component-gate] for path: 42 (same bytes as the while loop; an Async-free row is rejected)"

# --- delayed lane: reads genuinely PARK + the INLINE terminal shape ----------
# The buffered Vec producer above hands every byte to the pipe on its first
# poll, so no read ever blocks and the end arrives as a separate zero-amount
# CLOSED read. With a per-byte delay (`@delay_ms`, viberun's delayed
# producer) every read comes back BLOCKED first -- exercising the
# park/unjoin/drop sequence ("resource has children" if the unjoin is lost)
# -- and the final byte arrives WITH the CLOSED code (the inline terminal
# shape), exercising the adapter's closed latch (a raw re-read after that
# notification traps host-side). 42 + a wall clock of at least
# 0.8 * 3 * DELAY_MS pins both.
DELAY_MS="${VIBE_NAMED_HOSTSTREAMS_GATE_DELAY_MS:-60}"
DELAYED_LOG="$OUT_DIR/run.stream.delayed.log"
START_NS=$(date +%s%N)
if ! VIBE_ASYNC_STREAMS="body=10|15|17@${DELAY_MS}" timeout 60 "$RUNNER" "$COMPONENT" >"$DELAYED_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: delayed run did not exit 0 (park/unjoin or inline-close path)" >&2
  cat "$DELAYED_LOG" >&2
  exit 1
fi
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))
[ "$(cat "$DELAYED_LOG")" = "42" ] \
  || { echo "named hoststreams component gate FAILED: delayed run expected 42, got: $(cat "$DELAYED_LOG")" >&2; exit 1; }
MIN_MS=$(( 3 * DELAY_MS * 8 / 10 ))
if [ "$ELAPSED_MS" -lt "$MIN_MS" ]; then
  echo "named hoststreams component gate FAILED: returned in ${ELAPSED_MS}ms with a ${DELAY_MS}ms per-byte delay -- the reads cannot have genuinely parked" >&2
  exit 1
fi
echo "[named-hoststreams-component-gate] delayed path: 42 in ${ELAPSED_MS}ms (>= ${MIN_MS}: reads parked; inline close latched)"

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

# --- the record-nested creation fixture (Codex P2 on #1339) ------------------
# The creation call sits inside a struct literal: the import collector must
# traverse ERecord (and friends) or the lowered `vibe_hs_get_raw$body` call
# has no reserved import and compilation fails with a missing call target.
NESTED_SRC="$OUT_DIR/nested.vibe"
cat >"$NESTED_SRC" <<'EOF'
struct Holder { s: HostStream }

let run: () -> Int with { Async } = () -> {
  let h = Holder::{ s: host_stream_named("body") }
  let a = host_stream_next(h.s)
  let b = host_stream_next(h.s)
  a + b
}
EOF

NESTED="$OUT_DIR/nested.component.wasm"
compile_fixture "$NESTED_SRC" "$NESTED"
check_component_header "$NESTED"

NESTED_LOG="$OUT_DIR/run.nested.log"
if ! VIBE_ASYNC_STREAMS="body=21|21" timeout 60 "$RUNNER" "$NESTED" >"$NESTED_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: record-nested run did not exit 0" >&2
  cat "$NESTED_LOG" >&2
  exit 1
fi
NESTED_GOT="$(cat "$NESTED_LOG")"
[ "$NESTED_GOT" = "42" ] \
  || { echo "named hoststreams component gate FAILED: record-nested expected 42 (21 + 21), got: $NESTED_GOT" >&2; exit 1; }
echo "[named-hoststreams-component-gate] record-nested path: 42 (collector traverses struct literals)"

# --- the partial-consume + explicit close fixture (D3 follow-up) -------------
# The limitation recorded at the end of spec 3.18: the read half drops the
# readable end only at end of stream, so a guest that stops early pinned its
# handle for the instance's whole lifetime. `host_stream_close` is the
# explicit drop.
#
# The fixture reads TWO of five bytes, closes, and then deliberately does two
# more things that must be no-ops rather than traps:
#   - a second close (the cell's state word gates the drop, so the adapter is
#     called exactly once -- a double stream.drop-readable traps host-side)
#   - a read after close (the closed cell latches -1 without performing, the
#     same latch end-of-stream uses)
# 42 = 20 + 22 with the remaining 3 bytes (90|91|92) never read: if the close
# had instead drained or the post-close read had returned a real byte, the
# sum would not be 42.
CLOSE_SRC="$OUT_DIR/stream_close.vibe"
cat >"$CLOSE_SRC" <<'EOF'
let run: () -> Int with { Async } = () -> {
  let s = host_stream_named("body")
  let a = host_stream_next(s)
  let b = host_stream_next(s)
  host_stream_close(s)
  host_stream_close(s)
  let after = host_stream_next(s)
  a + b + (after + 1)
}
EOF

CLOSE_COMPONENT="$OUT_DIR/stream_close.component.wasm"
compile_fixture "$CLOSE_SRC" "$CLOSE_COMPONENT"
check_component_header "$CLOSE_COMPONENT"

CLOSE_LOG="$OUT_DIR/run.close.log"
if ! VIBE_ASYNC_STREAMS="body=20|22|90|91|92" timeout 60 "$RUNNER" "$CLOSE_COMPONENT" >"$CLOSE_LOG" 2>&1; then
  echo "named hoststreams component gate FAILED: partial-consume close run did not exit 0 (a double drop-readable traps host-side)" >&2
  cat "$CLOSE_LOG" >&2
  exit 1
fi
CLOSE_GOT="$(cat "$CLOSE_LOG")"
[ "$CLOSE_GOT" = "42" ]   || { echo "named hoststreams component gate FAILED: partial-consume close expected 42 (20 + 22, tail unread, post-close read -1), got: $CLOSE_GOT" >&2; exit 1; }
echo "[named-hoststreams-component-gate] close path: 42 (partial consume released the readable end; re-close and post-close read are no-ops)"

# A draining program must NOT pay for the close half: no import, no adapter
# func. This is the byte-compat claim that lets the surface land without
# touching every already-pinned stream composition.
# NOTE the materialized .wat: `wasm-tools print ... | grep -q` looks right and
# is a trap under `set -o pipefail` -- grep -q exits at the first match, the
# writer takes SIGPIPE, and the PIPELINE reports failure, so BOTH polarities
# of this check read as "no match found" (measured: it hid a real gating bug
# AND then misreported which side failed). Print once to a file, then grep.
DRAIN_WAT="$OUT_DIR/stream_sum.wat"
CLOSE_WAT="$OUT_DIR/stream_close.wat"
wasm-tools print "$COMPONENT" >"$DRAIN_WAT" 2>/dev/null || { echo "named hoststreams component gate FAILED: could not print the drain-only component" >&2; exit 1; }
wasm-tools print "$CLOSE_COMPONENT" >"$CLOSE_WAT" 2>/dev/null || { echo "named hoststreams component gate FAILED: could not print the closing component" >&2; exit 1; }
if grep -q 'host_stream_close' "$DRAIN_WAT"; then
  echo "named hoststreams component gate FAILED: the drain-only component reserved a host_stream_close import (the close half must be gated on use)" >&2
  exit 1
fi
# Two sites, not one: the GUEST's `(import "vibe" "host_stream_close" ...)`
# and the ADAPTER's `(export "host_stream_close" ...)`. Checking only the
# import would pass even if the adapter never grew the drop func -- and the
# guest-side cell bookkeeping alone reproduces the 42 above, so the run
# result cannot distinguish those two worlds on its own.
CLOSE_SITES="$(grep -c 'host_stream_close' "$CLOSE_WAT" || true)"
[ "${CLOSE_SITES:-0}" -ge 2 ] \
  || { echo "named hoststreams component gate FAILED: expected the closing component to both import and export host_stream_close, found $CLOSE_SITES site(s)" >&2; exit 1; }
echo "[named-hoststreams-component-gate] close half is gated on use (absent from the drain-only component, guest import + adapter export present in the closing one)"

echo "named hoststreams component gate OK"
