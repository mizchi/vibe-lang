#!/usr/bin/env bash
# #2064: emit the complete synthetic-core composition for the first
# WIT-derived async import and validate that it owns a versioned interface
# import instead of a runner-private root function import.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/_build/wit_async_import_component_gate"
mkdir -p "$OUT"

cat >"$OUT/emit_test.vibe" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_wit_future_fixture,
  comp_emit_wit_async_future_import_surface,
  comp_emit_wit_outbound_http_dual_fetch_surface,
  comp_emit_wit_http_error_code_type_surface,
  comp_emit_wit_http_client_send_surface,
  comp_wit_outbound_http_response_descriptor
}

fn write_hex(bytes: Bytes, path: String) -> Unit with Fs {
  let out = StringBuilder::new()
  let mut i = 0
  while i < Bytes::length(bytes) {
    let byte = Bytes::get(bytes, i)
    let hi = (byte >> 4)&15
    let lo = byte&15
    StringBuilder::push(out, String::from_char_code(if hi < 10 { 48 + hi } else { 87 + hi }))
    StringBuilder::push(out, String::from_char_code(if lo < 10 { 48 + lo } else { 87 + lo }))
    i = i + 1
  }
  Fs::write_file(path, StringBuilder::freeze(out))
}

test "emit composed fixture" {
  write_hex(
    comp_emit_component_wasm_async_wit_future_fixture(),
    "_build/wit_async_import_component_gate/component.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "example:prices/api@1.0.0",
      "get-price-record",
      "future<record{amount:s64,currency:string}>"
    ),
    "_build/wit_async_import_component_gate/record.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "example:prices/api@1.0.0",
      "get-price-band",
      "future<enum{cheap,expensive}>"
    ),
    "_build/wit_async_import_component_gate/enum.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "wasi:http/outgoing-handler@0.3.0",
      "handle",
      comp_wit_outbound_http_response_descriptor()
    ),
    "_build/wit_async_import_component_gate/http-response.hex"
  )
  write_hex(
    comp_emit_wit_outbound_http_dual_fetch_surface(),
    "_build/wit_async_import_component_gate/http-dual.hex"
  )
  write_hex(
    comp_emit_wit_http_error_code_type_surface(),
    "_build/wit_async_import_component_gate/http-error-code.hex"
  )
  write_hex(
    comp_emit_wit_http_client_send_surface(),
    "_build/wit_async_import_component_gate/http-client.hex"
  )
}
EOF

bash scripts/vibe_test.sh "$OUT/emit_test.vibe"
rm -f "$OUT/component.wasm" "$OUT/record.wasm" "$OUT/enum.wasm" "$OUT/http-response.wasm" "$OUT/http-dual.wasm" "$OUT/http-error-code.wasm" "$OUT/http-client.wasm"
xxd -r -p "$OUT/component.hex" "$OUT/component.wasm"
wasm-tools validate --features all "$OUT/component.wasm"
wasm-tools print "$OUT/component.wasm" >"$OUT/component.wat"
xxd -r -p "$OUT/record.hex" "$OUT/record.wasm"
xxd -r -p "$OUT/enum.hex" "$OUT/enum.wasm"
xxd -r -p "$OUT/http-response.hex" "$OUT/http-response.wasm"
xxd -r -p "$OUT/http-dual.hex" "$OUT/http-dual.wasm"
xxd -r -p "$OUT/http-error-code.hex" "$OUT/http-error-code.wasm"
xxd -r -p "$OUT/http-client.hex" "$OUT/http-client.wasm"
wasm-tools validate --features all "$OUT/record.wasm"
wasm-tools validate --features all "$OUT/enum.wasm"
wasm-tools validate --features all "$OUT/http-response.wasm"
wasm-tools validate --features all "$OUT/http-dual.wasm"
wasm-tools validate --features all "$OUT/http-error-code.wasm"
wasm-tools validate --features all "$OUT/http-client.wasm"
wasm-tools print "$OUT/record.wasm" >"$OUT/record.wat"
wasm-tools print "$OUT/enum.wasm" >"$OUT/enum.wat"
wasm-tools print "$OUT/http-response.wasm" >"$OUT/http-response.wat"
wasm-tools print "$OUT/http-dual.wasm" >"$OUT/http-dual.wat"
wasm-tools print "$OUT/http-error-code.wasm" >"$OUT/http-error-code.wat"
wasm-tools print "$OUT/http-client.wasm" >"$OUT/http-client.wat"
grep -Fq '(import "example:prices/api@1.0.0" (instance' "$OUT/component.wat"
grep -Fq '(export (;0;) "get-price" (func' "$OUT/component.wat"
grep -Fq '(export (;1;) "get-tax" (func' "$OUT/component.wat"
grep -Fq '(import "example:inventory/api@2.1.0" (instance' "$OUT/component.wat"
grep -Fq '"get-stock" (func' "$OUT/component.wat"
[ "$(grep -Fc '(import "example:prices/api@1.0.0" (instance' "$OUT/component.wat")" = 1 ]
if grep -Fq '(import "get-price" (func' "$OUT/component.wat"; then
  echo "WIT async import gate FAILED: get-price remained a root function import" >&2
  exit 1
fi
grep -Fq '(record (field "amount" s64) (field "currency" string))' "$OUT/record.wat"
grep -Fq '(future 0)' "$OUT/record.wat"
grep -Fq '(enum "cheap" "expensive")' "$OUT/enum.wat"
grep -Fq '(future 0)' "$OUT/enum.wat"
grep -Fq '(import "wasi:http/types@0.3.0" (instance' "$OUT/http-response.wat"
grep -Fq '(import "wasi:http/outgoing-handler@0.3.0" (instance' "$OUT/http-response.wat"
grep -Fq '(stream u8)' "$OUT/http-response.wat"
grep -Fq '(record (field "status" s32) (field "headers" string) (field "body" 0))' "$OUT/http-response.wat"
grep -Fq '(record (field "method" string) (field "url" string) (field "headers" string) (field "body" 0))' "$OUT/http-dual.wat"
grep -Fq '(record (field "status" s32) (field "headers" string) (field "body" 0))' "$OUT/http-dual.wat"
[ "$(grep -Fc '(func async (param "request" 0) (result 2))' "$OUT/http-dual.wat")" = 2 ]
grep -Fq '(export (;0;) "fetch-left" (func' "$OUT/http-dual.wat"
grep -Fq '(export (;1;) "fetch-right" (func' "$OUT/http-dual.wat"
grep -Fq '(case "DNS-error" 3)' "$OUT/http-error-code.wat"
grep -Fq '(case "TLS-alert-received" 6)' "$OUT/http-error-code.wat"
grep -Fq '(case "internal-error" 0)' "$OUT/http-error-code.wat"
grep -Fq '"error-code" (type (eq 12))' "$OUT/http-error-code.wat"
grep -Fq '"request" (type (sub resource))' "$OUT/http-client.wat"
grep -Fq '"response" (type (sub resource))' "$OUT/http-client.wat"
grep -Fq '(type (;3;) (own 1))' "$OUT/http-client.wat"
grep -Fq '(type (;4;) (result 3 (error 2)))' "$OUT/http-client.wat"
grep -Fq '(type (;5;) (own 0))' "$OUT/http-client.wat"
grep -Fq '(func async (param "request" 5) (result 4))' "$OUT/http-client.wat"

# --- a REAL program on the same route (#2064) -------------------------------
# Everything above composes a hand-built core. Here the import set comes from
# WIT text: fixtures/wit_future_import/prices_bindings.vibe is the
# `from_wit_future_imports` derivation of prices.wit (from_wit_test.vibe pins
# that), and main.vibe awaits both bindings. linked_compile must emit the
# `wit_future_get$` metadata imports and the composer must import both
# functions from ONE versioned `example:prices/api@1.0.0` instance.
#
# The checkout's compiler, not the seed: the route is new, and a seed that
# predates it would refuse the address (`invalid import name`) -- which is
# the answer about a different compiler, not a pass or fail about this one.
COMPILER="${VIBE_WIT_ASYNC_IMPORT_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
fi
if [ ! -f "$COMPILER" ]; then
  echo "WIT async import gate FAILED: no stage2 compiler (set VIBE_WIT_ASYNC_IMPORT_GATE_COMPILER or run pkf run generation)" >&2
  exit 1
fi
PROG_DIR="$OUT/program"
rm -rf "$PROG_DIR"
mkdir -p "$PROG_DIR"
cp fixtures/wit_future_import/main.vibe fixtures/wit_future_import/prices_bindings.vibe "$PROG_DIR/"
# The program imports its bindings, so it compiles on the FS lane, which
# composes the host-future adapter itself when a `run` entry's core imports a
# host future (`maybe_wrap_stdin_provider_core`), as the single-file lane does.
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$PROG_DIR/main.vibe" "$PROG_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$PROG_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_future_import/main.vibe did not compile" >&2
  cat "$PROG_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! od -A n -t x1 -N 8 "$PROG_DIR/main.wasm" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
  echo "WIT async import gate FAILED: the file lane left a core module, not a component" >&2
  exit 1
fi
# The embedded core must carry the WIT-addressed metadata imports and no root ones.
for want in 'wit_future_get$example:prices/api@1.0.0#get-price' 'wit_future_get$example:prices/api@1.0.0#get-tax'; do
  grep -aFq "$want" "$PROG_DIR/main.wasm" || {
    echo "WIT async import gate FAILED: the core lacks the metadata import $want" >&2
    exit 1
  }
done
if grep -aFq 'host_future_get$' "$PROG_DIR/main.wasm"; then
  echo "WIT async import gate FAILED: a WIT-addressed future was emitted as a root host_future_get import" >&2
  exit 1
fi
wasm-tools validate --features all "$PROG_DIR/main.wasm"
wasm-tools print "$PROG_DIR/main.wasm" >"$PROG_DIR/main.wat"
[ "$(grep -Fc '(import "example:prices/api@1.0.0" (instance' "$PROG_DIR/main.wat")" = 1 ] || {
  echo "WIT async import gate FAILED: the program does not import exactly one example:prices/api@1.0.0 instance" >&2
  exit 1
}
grep -Fq '"get-price" (func' "$PROG_DIR/main.wat"
grep -Fq '"get-tax" (func' "$PROG_DIR/main.wat"
# #3131: the import is the WIT as written. `async func() -> s64` is a subtask
# whose result is the value; `-> future<s64>` would be a different function
# type, and a provider implementing prices.wit would not plug in.
PROG_WIT="$(wasm-tools component wit "$PROG_DIR/main.wasm")"
case "$PROG_WIT" in
  *'future<'*)
    echo "WIT async import gate FAILED: a WIT async import was composed with a future result, not as the WIT declares it" >&2
    printf '%s\n' "$PROG_WIT" >&2
    exit 1 ;;
  *'get-price: async func() -> s64;'*'get-tax: async func() -> s64;'*) ;;
  *)
    echo "WIT async import gate FAILED: get-price / get-tax are not imported as async func() -> s64" >&2
    printf '%s\n' "$PROG_WIT" >&2
    exit 1 ;;
esac
if grep -Eq '\(import "(get-price|get-tax)" \(func' "$PROG_DIR/main.wat"; then
  echo "WIT async import gate FAILED: a WIT-addressed future became a root function import" >&2
  exit 1
fi
# --- and EXECUTED (#2064) -----------------------------------------------------
# viberun links a WIT-addressed VIBE_ASYNC_FUTURES entry inside its versioned
# interface instance as `async func() -> s64`. Both producers wait LONG_MS; awaited
# concurrently the run takes about LONG_MS, sequentially about twice that, so
# the wall clock is what shows the two imports were in flight together.
RUNNER="${VIBE_WIT_ASYNC_IMPORT_GATE_RUNNER:-$ROOT/runtime/viberun/target/release/viberun}"
if [ "$RUNNER" = "$ROOT/runtime/viberun/target/release/viberun" ]; then
  if [ ! -x "$RUNNER" ] || find "$ROOT/runtime/viberun/src" "$ROOT/runtime/viberun/Cargo.toml" \
      "$ROOT/runtime/viberun/Cargo.lock" -newer "$RUNNER" -print -quit 2>/dev/null | grep -q .; then
    (cd "$ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1) || {
      echo "WIT async import gate FAILED: could not build runtime/viberun" >&2
      exit 1
    }
  fi
fi
LONG_MS=300
IFACE='example:prices/api@1.0.0'
START_NS=$(date +%s%N)
GOT="$(VIBE_ASYNC_FUTURES="$IFACE#get-price=40:$LONG_MS,$IFACE#get-tax=2:$LONG_MS" run_bounded 60 "$RUNNER" "$PROG_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0: $GOT" >&2
  exit 1
}
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))
[ "$GOT" = "42" ] || {
  echo "WIT async import gate FAILED: expected 42 (40 from get-price + 2 from get-tax), got: $GOT" >&2
  exit 1
}
if [ "$ELAPSED_MS" -ge $(( LONG_MS * 3 / 2 )) ]; then
  echo "WIT async import gate FAILED: ${ELAPSED_MS}ms for two ${LONG_MS}ms futures -- they were not in flight together" >&2
  exit 1
fi
if [ "$ELAPSED_MS" -lt $(( LONG_MS * 4 / 5 )) ]; then
  echo "WIT async import gate FAILED: ${ELAPSED_MS}ms is shorter than one ${LONG_MS}ms future -- the task did not park" >&2
  exit 1
fi
echo "[wit-async-import] executed: 42 in ${ELAPSED_MS}ms (two ${LONG_MS}ms futures)"

# --- WIT futures awaited from SPAWNED tasks (#1537) -------------------------
# fixtures/wit_future_import/spawn_main.vibe parks two TaskGroup tasks on the
# two WIT futures; the group waits on both at once. @vibe/concurrent imports
# `sleep`, so the root `sleep-for` import rides beside the interface instance
# (component func 0, the aliased functions after it).
SPAWN_DIR="$OUT/spawn"
rm -rf "$SPAWN_DIR"
mkdir -p "$SPAWN_DIR"
cp fixtures/wit_future_import/spawn_main.vibe fixtures/wit_future_import/prices_bindings.vibe "$SPAWN_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$SPAWN_DIR/spawn_main.vibe" "$SPAWN_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$SPAWN_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_future_import/spawn_main.vibe did not compile" >&2
  cat "$SPAWN_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
wasm-tools validate --features all "$SPAWN_DIR/main.wasm"
START_NS=$(date +%s%N)
GOT="$(VIBE_ASYNC_FUTURES="$IFACE#get-price=40:$LONG_MS,$IFACE#get-tax=2:$LONG_MS" run_bounded 60 "$RUNNER" "$SPAWN_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0 on the spawned-task program: $GOT" >&2
  exit 1
}
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))
[ "$GOT" = "42" ] || {
  echo "WIT async import gate FAILED: spawned tasks expected 42, got: $GOT" >&2
  exit 1
}
if [ "$ELAPSED_MS" -ge $(( LONG_MS * 3 / 2 )) ] || [ "$ELAPSED_MS" -lt $(( LONG_MS * 4 / 5 )) ]; then
  echo "WIT async import gate FAILED: spawned tasks took ${ELAPSED_MS}ms for two ${LONG_MS}ms futures (want one delay: in flight together, and parked)" >&2
  exit 1
fi
echo "[wit-async-import] spawned tasks: 42 in ${ELAPSED_MS}ms (two ${LONG_MS}ms WIT futures, tasks parked on both)"

# --- WIT RESPONSES: async func() -> record{status, body: stream<u8>} (#2066) -
# fixtures/wit_response_import/client_bindings.vibe is the derivation of
# client.wit (from_wit_test.vibe pins it). Each function returns the `types`
# interface's `response` record, so the core carries `wit_response_get$`
# metadata imports and the component imports the `types` instance (for the
# record) and the `client` instance (for the functions). The body is a
# host stream the guest reads byte by byte.
RESP_DIR="$OUT/response"
rm -rf "$RESP_DIR"
mkdir -p "$RESP_DIR"
cp fixtures/wit_response_import/main.vibe fixtures/wit_response_import/client_bindings.vibe "$RESP_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$RESP_DIR/main.vibe" "$RESP_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$RESP_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_response_import/main.vibe did not compile" >&2
  cat "$RESP_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
for want in 'wit_response_get$example:http-lite/client@1.0.0#fetch-a' 'wit_response_get$example:http-lite/client@1.0.0#fetch-b'; do
  grep -aFq "$want" "$RESP_DIR/main.wasm" || {
    echo "WIT async import gate FAILED: the core lacks the response metadata import $want" >&2
    exit 1
  }
done
wasm-tools validate --features all "$RESP_DIR/main.wasm"
wasm-tools print "$RESP_DIR/main.wasm" >"$RESP_DIR/main.wat"
for iface in 'example:http-lite/types@1.0.0' 'example:http-lite/client@1.0.0'; do
  [ "$(grep -Fc "(import \"$iface\" (instance" "$RESP_DIR/main.wat")" = 1 ] || {
    echo "WIT async import gate FAILED: the response program does not import exactly one $iface instance" >&2
    exit 1
  }
done
grep -Fq '(record (field "status" s32) (field "body"' "$RESP_DIR/main.wat" || {
  echo "WIT async import gate FAILED: the response record is not {status: s32, body: stream<u8>}" >&2
  exit 1
}
RESP_WIT="$(wasm-tools component wit "$RESP_DIR/main.wasm")"
case "$RESP_WIT" in
  *'future<'*)
    echo "WIT async import gate FAILED: a WIT response import was composed with a future result (#3131)" >&2
    printf '%s\n' "$RESP_WIT" >&2
    exit 1 ;;
  *'fetch-a: async func() -> response;'*'fetch-b: async func() -> response;'*) ;;
  *)
    echo "WIT async import gate FAILED: fetch-a / fetch-b are not imported as async func() -> response" >&2
    printf '%s\n' "$RESP_WIT" >&2
    exit 1 ;;
esac
# Both responses resolve after LONG_MS. 200 + 204 + (1+2+3) + (10+20) = 440:
# each status and every body byte reached the guest, and the wall clock shows
# the two requests were in flight together.
IFACE='example:http-lite/client@1.0.0'
START_NS=$(date +%s%N)
GOT="$(VIBE_ASYNC_RESPONSES="$IFACE#fetch-a=200:$LONG_MS:1|2|3,$IFACE#fetch-b=204:$LONG_MS:10|20" run_bounded 60 "$RUNNER" "$RESP_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0 on the response program: $GOT" >&2
  exit 1
}
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))
[ "$GOT" = "440" ] || {
  echo "WIT async import gate FAILED: expected 440 (statuses 200 + 204, body bytes 6 + 30), got: $GOT" >&2
  exit 1
}
if [ "$ELAPSED_MS" -ge $(( LONG_MS * 3 / 2 )) ]; then
  echo "WIT async import gate FAILED: ${ELAPSED_MS}ms for two ${LONG_MS}ms responses -- they were not in flight together" >&2
  exit 1
fi
if [ "$ELAPSED_MS" -lt $(( LONG_MS * 4 / 5 )) ]; then
  echo "WIT async import gate FAILED: ${ELAPSED_MS}ms is shorter than one ${LONG_MS}ms response -- the task did not park" >&2
  exit 1
fi
echo "[wit-async-import] responses executed: 440 in ${ELAPSED_MS}ms (two ${LONG_MS}ms responses, bodies streamed)"
# The runner registers an interface's scalar futures and its responses on ONE
# linker instance: a scalar future supplied on the same interface must not
# make the linker define the instance twice (Codex on #3059).
GOT="$(VIBE_ASYNC_FUTURES="$IFACE#extra=5:0" VIBE_ASYNC_RESPONSES="$IFACE#fetch-a=200:0:1|2|3,$IFACE#fetch-b=204:0:10|20" run_bounded 60 "$RUNNER" "$RESP_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun refused a scalar future and responses on one interface: $GOT" >&2
  exit 1
}
[ "$GOT" = "440" ] || {
  echo "WIT async import gate FAILED: shared-interface run expected 440, got: $GOT" >&2
  exit 1
}
echo "[wit-async-import] one interface carrying a scalar future and responses links once: 440"
# #2066 MIXED: fixtures/wit_response_mixed awaits a response AND a scalar
# `async func() -> s64` from ONE interface. The adapter decodes each call's
# result slot by its kind.
# Both land after LONG_MS: 200 + (1+2+3) + 5 = 211 in about LONG_MS.
MIX_DIR="$OUT/response_mixed"
rm -rf "$MIX_DIR"
mkdir -p "$MIX_DIR"
cp fixtures/wit_response_mixed/main.vibe fixtures/wit_response_mixed/client_bindings.vibe "$MIX_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$MIX_DIR/main.vibe" "$MIX_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$MIX_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_response_mixed/main.vibe did not compile" >&2
  cat "$MIX_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
wasm-tools validate --features all "$MIX_DIR/main.wasm"
START_NS=$(date +%s%N)
GOT="$(VIBE_ASYNC_RESPONSES="$IFACE#fetch-a=200:$LONG_MS:1|2|3" VIBE_ASYNC_FUTURES="$IFACE#pending-count=5:$LONG_MS" run_bounded 60 "$RUNNER" "$MIX_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0 on the mixed program: $GOT" >&2
  exit 1
}
ELAPSED_MS=$(( ( $(date +%s%N) - START_NS ) / 1000000 ))
[ "$GOT" = "211" ] || {
  echo "WIT async import gate FAILED: mixed expected 211 (status 200, body bytes 6, count 5), got: $GOT" >&2
  exit 1
}
if [ "$ELAPSED_MS" -ge $(( LONG_MS * 3 / 2 )) ]; then
  echo "WIT async import gate FAILED: ${ELAPSED_MS}ms for a ${LONG_MS}ms response beside a ${LONG_MS}ms future -- they were not in flight together" >&2
  exit 1
fi
echo "[wit-async-import] response + scalar future from one interface: 211 in ${ELAPSED_MS}ms"
# #2066 REQUEST PARAMETER: fixtures/wit_response_request imports
# `fetch: async func(url: string) -> response`. The guest pushes the URL's
# bytes into the adapter's argument buffer and the adapter lowers it as the
# string parameter; the runner's `echo` response streams the argument back as
# the body. 200 + ("abc" = 294) + ("d" = 100) = 594 -- the second request
# proves the buffer is reset between calls rather than appended to -- and a
# third, 70000 bytes of "a" (97 each), outgrows the buffer's first page, so
# the adapter must grow its memory: 594 + 6790000 = 6790594.
REQ_DIR="$OUT/response_request"
rm -rf "$REQ_DIR"
mkdir -p "$REQ_DIR"
cp fixtures/wit_response_request/main.vibe fixtures/wit_response_request/client_bindings.vibe "$REQ_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$REQ_DIR/main.vibe" "$REQ_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$REQ_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_response_request/main.vibe did not compile" >&2
  cat "$REQ_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
wasm-tools validate --features all "$REQ_DIR/main.wasm"
GOT="$(VIBE_ASYNC_RESPONSES="$IFACE#fetch=200:0:echo" run_bounded 60 "$RUNNER" "$REQ_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0 on the request-parameter program: $GOT" >&2
  exit 1
}
[ "$GOT" = "6790594" ] || {
  echo "WIT async import gate FAILED: request parameter expected 6790594 (status 200, echoed \"abc\" 294, \"d\" 100, 70000 x \"a\" 6790000), got: $GOT" >&2
  exit 1
}
echo "[wit-async-import] response taking a string parameter (up to 70000 bytes): 6790594"
# #2066 NAMED STREAMS beside WIT imports. A named host stream is a ROOT
# import, so it takes the component funcs before the WIT interface's aliased
# functions (after it, in spawn_main, comes `sleep-for`); the lowers keep the
# core order. Each program also drains the stream while its futures are in
# flight. Before the lowers were mapped per kind the composer refused them.
mix_stream_row() { # <fixture dir> <main> <bindings> <expected> <max_ms> <futures spec> <responses spec> <label>
  local dir="$OUT/stream_mix_$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "fixtures/$1/$2.vibe" "fixtures/$1/$3" "$dir/"
  VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$COMPILER" "$dir/$2.vibe" "$dir/main.wasm" run >/dev/null 2>&1 || true
  if [ ! -s "$dir/main.wasm" ]; then
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe did not compile" >&2
    cat "$dir/main.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  wasm-tools validate --features all "$dir/main.wasm"
  local start got elapsed
  start=$(date +%s%N)
  got="$(VIBE_ASYNC_FUTURES="$6" VIBE_ASYNC_RESPONSES="$7" VIBE_ASYNC_STREAMS="body=10|15|17@100" run_bounded 60 "$RUNNER" "$dir/main.wasm" 2>&1)" || {
    echo "WIT async import gate FAILED: viberun did not exit 0 on fixtures/$1/$2.vibe: $got" >&2
    exit 1
  }
  elapsed=$(( ( $(date +%s%N) - start ) / 1000000 ))
  [ "$got" = "$4" ] || {
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe expected $4, got: $got" >&2
    exit 1
  }
  if [ "$elapsed" -ge "$5" ]; then
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe took ${elapsed}ms (>= $5) -- the stream was not drained while the futures were in flight" >&2
    exit 1
  fi
  echo "[wit-async-import] $8: $got in ${elapsed}ms"
}
PRICES='example:prices/api@1.0.0'
mix_stream_row wit_future_import stream_main prices_bindings.vibe 84 450 \
  "$PRICES#get-price=40:$LONG_MS,$PRICES#get-tax=2:$LONG_MS" "" "WIT futures + named stream"
# spawn: one task awaits the two futures in turn (~2 x LONG_MS), the other
# drains the stream meanwhile, so the bound is the task's own two waits.
mix_stream_row wit_future_import stream_spawn_main prices_bindings.vibe 84 $(( LONG_MS * 2 + LONG_MS / 2 )) \
  "$PRICES#get-price=40:$LONG_MS,$PRICES#get-tax=2:$LONG_MS" "" "spawned WIT futures + named stream + sleep-for"
mix_stream_row wit_response_import stream_main client_bindings.vibe 248 450 \
  "" "$IFACE#fetch-a=200:$LONG_MS:1|2|3,$IFACE#fetch-b=0:0:" "WIT response + named stream"
# #2066: a response future captured by a spawned task is refused -- its body
# stream has one owner -- with the message naming the edit.
SHARE_DIR="$OUT/response_share_refused"
rm -rf "$SHARE_DIR"
mkdir -p "$SHARE_DIR"
cp fixtures/wit_response_import/share_refused.vibe fixtures/wit_response_import/client_bindings.vibe "$SHARE_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$SHARE_DIR/share_refused.vibe" "$SHARE_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ -s "$SHARE_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: a response future shared with a spawned task compiled -- its body stream would have two readers" >&2
  exit 1
fi
grep -qF "start the request inside the spawned task" "$SHARE_DIR/main.wasm.diag" 2>/dev/null || {
  echo "WIT async import gate FAILED: share_refused gave an unexpected diagnostic: $(cat "$SHARE_DIR/main.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
echo "[wit-async-import] a response future shared with a spawned task: refused"
# A closure bound to a name hides its captures from the check, so while a
# value owning a host stream is in scope, spawning a closure that is not
# written at the spawn is refused, naming the edit (Codex on #3091).
cp fixtures/wit_response_import/share_named_closure_refused.vibe "$SHARE_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$SHARE_DIR/share_named_closure_refused.vibe" "$SHARE_DIR/named.wasm" run >/dev/null 2>&1 || true
if [ -s "$SHARE_DIR/named.wasm" ]; then
  echo "WIT async import gate FAILED: a named closure awaiting a shared response future compiled" >&2
  exit 1
fi
grep -qF "pass the closure literal itself to the spawn" "$SHARE_DIR/named.wasm.diag" 2>/dev/null || {
  echo "WIT async import gate FAILED: share_named_closure_refused gave an unexpected diagnostic: $(cat "$SHARE_DIR/named.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
echo "[wit-async-import] a named closure spawned while a response future is in scope: refused"
# The same rule through containers: a future of `Option[Reply]` whose struct
# field is the response.
cp fixtures/wit_response_import/share_nested_refused.vibe "$SHARE_DIR/"
rm -f "$SHARE_DIR/nested.wasm" "$SHARE_DIR/nested.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$SHARE_DIR/share_nested_refused.vibe" "$SHARE_DIR/nested.wasm" run >/dev/null 2>&1 || true
if [ -s "$SHARE_DIR/nested.wasm" ]; then
  echo "WIT async import gate FAILED: a future of an Option/struct holding a response, shared with a spawned task, compiled" >&2
  exit 1
fi
grep -qF "start the request inside the spawned task" "$SHARE_DIR/nested.wasm.diag" 2>/dev/null || {
  echo "WIT async import gate FAILED: share_nested_refused gave an unexpected diagnostic: $(cat "$SHARE_DIR/nested.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
echo "[wit-async-import] a future of a response inside Option and a struct, shared: refused"
# #2066 REAL PROVIDER: fixtures/wit_response_request/http_main.vibe, the same
# `fetch(url)` binding answered by viberun's `http` mode, which performs an
# HTTP GET of the argument. A local file server stands in for the network:
# `abc` at /hello.txt, nothing at /missing (a 404 is a response, not an
# error). 200 + 294 + 404 = 898.
HTTP_DIR="$OUT/response_http"
rm -rf "$HTTP_DIR"
mkdir -p "$HTTP_DIR/srv"
printf 'abc' > "$HTTP_DIR/srv/hello.txt"
cp fixtures/wit_response_request/http_main.vibe fixtures/wit_response_request/client_bindings.vibe "$HTTP_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$HTTP_DIR/http_main.vibe" "$HTTP_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$HTTP_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_response_request/http_main.vibe did not compile" >&2
  cat "$HTTP_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
(cd "$HTTP_DIR/srv" && exec python3 -m http.server 18766 --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
python3 - <<'PYEOF' || { echo "WIT async import gate FAILED: the local file server on 127.0.0.1:18766 did not come up" >&2; exit 1; }
import socket, time
deadline = time.time() + 20
while time.time() < deadline:
    try:
        socket.create_connection(("127.0.0.1", 18766), timeout=1).close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.1)
raise SystemExit(1)
PYEOF
GOT="$(NO_PROXY='*' no_proxy='*' VIBE_ASYNC_RESPONSES="$IFACE#fetch=0:0:http" run_bounded 60 "$RUNNER" "$HTTP_DIR/main.wasm" 2>&1)" || {
  echo "WIT async import gate FAILED: viberun did not exit 0 on the real-provider program: $GOT" >&2
  exit 1
}
[ "$GOT" = "898" ] || {
  kill "$HTTP_PID" 2>/dev/null || true
  echo "WIT async import gate FAILED: real provider expected 898 (200 + \"abc\" 294 + 404), got: $GOT" >&2
  exit 1
}
echo "[wit-async-import] response from a real HTTP GET (200 + body, and a 404): 898"
# The provider buffers the body before the future lands, so the body is capped
# (VIBE_HTTP_BODY_LIMIT) and a larger one fails the future naming the limit --
# never a silent truncation.
GOT="$(NO_PROXY='*' no_proxy='*' VIBE_HTTP_BODY_LIMIT=2 VIBE_ASYNC_RESPONSES="$IFACE#fetch=0:0:http" run_bounded 60 "$RUNNER" "$HTTP_DIR/main.wasm" 2>&1)" && {
  kill "$HTTP_PID" 2>/dev/null || true
  echo "WIT async import gate FAILED: a body over VIBE_HTTP_BODY_LIMIT was accepted: $GOT" >&2
  exit 1
}
kill "$HTTP_PID" 2>/dev/null || true
case "$GOT" in
  *"the body is larger than 2 bytes"*) ;;
  *) echo "WIT async import gate FAILED: an over-limit body did not name the limit: $GOT" >&2; exit 1 ;;
esac
echo "[wit-async-import] a body over VIBE_HTTP_BODY_LIMIT fails the future naming the limit"
# A server that sends its headers and then stalls: the request is bounded
# (VIBE_HTTP_TIMEOUT_MS), so the runner exits instead of waiting on a blocking
# thread it cannot abort.
wait "$HTTP_PID" 2>/dev/null || true
python3 - <<'PYEOF' &
import socket, threading, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 18766))
s.listen(8)
def stall(c):
    c.recv(4096)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nab")
    time.sleep(60)
    c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=stall, args=(c,), daemon=True).start()
PYEOF
HTTP_PID=$!
python3 - <<'PYEOF' || { echo "WIT async import gate FAILED: the stalling server on 127.0.0.1:18766 did not come up" >&2; exit 1; }
import socket, time
deadline = time.time() + 20
while time.time() < deadline:
    try:
        socket.create_connection(("127.0.0.1", 18766), timeout=1).close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.1)
raise SystemExit(1)
PYEOF
STATUS=0
GOT="$(NO_PROXY='*' no_proxy='*' VIBE_HTTP_TIMEOUT_MS=800 VIBE_ASYNC_RESPONSES="$IFACE#fetch=0:0:http" run_bounded 20 "$RUNNER" "$HTTP_DIR/main.wasm" 2>&1)" || STATUS=$?
kill "$HTTP_PID" 2>/dev/null || true
case "$STATUS:$GOT" in
  124:*) echo "WIT async import gate FAILED: a stalled response held the runner past its bound" >&2; exit 1 ;;
  0:*) echo "WIT async import gate FAILED: a stalled response answered: $GOT" >&2; exit 1 ;;
  *"timed out"*) ;;
  *) echo "WIT async import gate FAILED: a stalled response failed without naming the timeout: $GOT" >&2; exit 1 ;;
esac
echo "[wit-async-import] a stalled server fails the future within VIBE_HTTP_TIMEOUT_MS"
# A WIT `string` argument must be UTF-8; a vibe String is bytes. The call
# fails closed with the canonical ABI's own message naming the byte offset.
UTF_DIR="$OUT/response_invalid_utf8"
rm -rf "$UTF_DIR"; mkdir -p "$UTF_DIR"
cp fixtures/wit_response_request/invalid_utf8_main.vibe fixtures/wit_response_request/client_bindings.vibe "$UTF_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$UTF_DIR/invalid_utf8_main.vibe" "$UTF_DIR/main.wasm" run >/dev/null 2>&1 || true
[ -s "$UTF_DIR/main.wasm" ] || {
  echo "WIT async import gate FAILED: invalid_utf8_main.vibe did not compile: $(cat "$UTF_DIR/main.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
GOT="$(VIBE_ASYNC_RESPONSES="example:http-lite/client@1.0.0#fetch=200:0:echo" run_bounded 60 "$RUNNER" "$UTF_DIR/main.wasm" 2>&1)" && {
  echo "WIT async import gate FAILED: a non-UTF-8 string argument was accepted: $GOT" >&2
  exit 1
}
case "$GOT" in
  *"invalid utf-8 sequence of 1 bytes from index 2"*) ;;
  *) echo "WIT async import gate FAILED: a non-UTF-8 argument did not fail naming the offset: $GOT" >&2; exit 1 ;;
esac
echo "[wit-async-import] a non-UTF-8 string argument fails closed at byte 2"
# #3131: cancelling a task parked on a WIT future cancels its SUBTASK and
# frees its result slot. 600 groups each cancel a pending call, past the
# adapter's 512 slots, so a leak traps a later call. Scalar first: each group
# joins a fast get-tax (2) and cancels a 10s get-price, 1200.
cancel_row() { # <fixture dir> <main> <bindings> <expected> <futures spec> <responses spec> <label>
  local dir="$OUT/cancel_$1_$2"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "fixtures/$1/$2.vibe" "fixtures/$1/$3" "$dir/"
  VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$COMPILER" "$dir/$2.vibe" "$dir/main.wasm" run >/dev/null 2>&1 || true
  [ -s "$dir/main.wasm" ] || {
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe did not compile: $(cat "$dir/main.wasm.diag" 2>/dev/null)" >&2
    exit 1
  }
  local got
  got="$(VIBE_ASYNC_FUTURES="$5" VIBE_ASYNC_RESPONSES="$6" run_bounded 120 "$RUNNER" "$dir/main.wasm" 2>&1)" || {
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe did not exit 0 ($7): $got" >&2
    exit 1
  }
  [ "$got" = "$4" ] || {
    echo "WIT async import gate FAILED: fixtures/$1/$2.vibe expected $4 ($7), got: $got" >&2
    exit 1
  }
  echo "[wit-async-import] $7: $got"
}
# A closure RETURNED by a function hides the response future from the spawn
# capture check, so two tasks can reach one body. The adapter's one-time claim
# must trap the second `HostResponse::body` (before the claim: 6006, the body
# read by both tasks).
CLAIM_DIR="$OUT/share_body_claim"
rm -rf "$CLAIM_DIR"; mkdir -p "$CLAIM_DIR"
cp fixtures/wit_response_import/share_body_claim_trap.vibe fixtures/wit_response_import/client_bindings.vibe "$CLAIM_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$CLAIM_DIR/share_body_claim_trap.vibe" "$CLAIM_DIR/main.wasm" run >/dev/null 2>&1 || true
[ -s "$CLAIM_DIR/main.wasm" ] || {
  echo "WIT async import gate FAILED: share_body_claim_trap did not compile: $(cat "$CLAIM_DIR/main.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
CLAIM_IFACE='example:http-lite/client@1.0.0'
if GOT="$(VIBE_ASYNC_RESPONSES="$CLAIM_IFACE#fetch-a=200:50:1|2|3,$CLAIM_IFACE#fetch-b=204:1:9" run_bounded 60 "$RUNNER" "$CLAIM_DIR/main.wasm" 2>&1)"; then
  echo "WIT async import gate FAILED: one response body read by two tasks exited 0 (answered $GOT); the second body claim must trap" >&2
  exit 1
fi
case "$GOT" in
  *unreachable*) ;;
  *)
    echo "WIT async import gate FAILED: share_body_claim_trap failed for another reason: $GOT" >&2
    exit 1
    ;;
esac
echo "[wit-async-import] a response body reached by two tasks through a returned closure: the second claim traps"
PIFACE='example:prices/api@1.0.0'
cancel_row wit_future_import cancel_many prices_bindings.vibe 1200 \
  "$PIFACE#get-price=40:10000,$PIFACE#get-tax=2:1" "" "600 cancelled get-price subtasks release their slots"
CIFACE='example:http-lite/client@1.0.0'
cancel_row wit_response_import cancel_many client_bindings.vibe 122400 \
  "" "$CIFACE#fetch-a=200:10000:1|2|3,$CIFACE#fetch-b=204:1:9" "600 cancelled pending responses release their slots"
cancel_row wit_response_import cancel_many client_bindings.vibe 122400 \
  "" "$CIFACE#fetch-a=200:0:1|2|3,$CIFACE#fetch-b=204:5:9" "600 groups whose responses land at once"
# A future whose read was cancelled, awaited again once its result slot is
# reused by a later call. It used to answer that call's value (2, for a price)
# with no error; the release now poisons the cell and the await traps (Codex
# on #3091).
STALE_DIR="$OUT/stale_after_cancel"
rm -rf "$STALE_DIR"; mkdir -p "$STALE_DIR"
cp fixtures/wit_future_import/stale_after_cancel.vibe fixtures/wit_future_import/prices_bindings.vibe "$STALE_DIR/"
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$STALE_DIR/stale_after_cancel.vibe" "$STALE_DIR/main.wasm" run >/dev/null 2>&1 || true
[ -s "$STALE_DIR/main.wasm" ] || {
  echo "WIT async import gate FAILED: stale_after_cancel did not compile: $(cat "$STALE_DIR/main.wasm.diag" 2>/dev/null)" >&2
  exit 1
}
if GOT="$(VIBE_ASYNC_FUTURES="$PIFACE#get-price=40:3000,$PIFACE#get-tax=2:1" run_bounded 60 "$RUNNER" "$STALE_DIR/main.wasm" 2>&1)"; then
  echo "WIT async import gate FAILED: awaiting a future whose read was cancelled exited 0 (answered $GOT)" >&2
  exit 1
fi
# The trap's message goes to stdout, which the runner does not flush on a
# trap (the body-claim row above has the same shape), so the row checks the
# trap and that the stale answer is gone.
case "$GOT" in
  *unreachable*) ;;
  *)
    echo "WIT async import gate FAILED: stale_after_cancel failed for another reason: $GOT" >&2
    exit 1
    ;;
esac
echo "[wit-async-import] a future whose read was cancelled, awaited after its slot was reused: traps"
echo "WIT async import component gate OK"
