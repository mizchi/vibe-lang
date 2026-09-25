#!/usr/bin/env bash
set -euo pipefail

# #1540 scope 4: does `vibe serve` hand the REQUEST BODY to the handler as a
# stream it reads itself?
#
# This is the end of the issue. The sibling gates each proved one piece --
# test_serve_async_lift_gate.sh that a handler component can be async-lifted
# and still serve, test_http_body_read_probe_gate.sh that an emitted guest can
# drive `stream.read` to end of stream -- and this one is the join, through the
# CLI's own serve path rather than a hand-assembled emitter call:
#
#   handler.vibe (body: HostStream, with Async)
#     -> validate_serve_handler accepts the shape
#     -> serve_handler_takes_body_stream picks the lane
#     -> comp_emit_component_wasm_stream_handler
#     -> wac plug with an adapter whose `handler` import takes stream<u8>
#     -> wasmtime serve; curl asserts what came back
#
# The assertions are about BYTES, not about "it answered 200":
#
#   echo        a 300+ byte body comes back byte-for-byte, compared with
#               `cmp` on files. Substring or shell-string comparison is not
#               enough -- command substitution drops NUL bytes and trailing
#               newlines, so a body one byte too long can compare EQUAL
#               (the same trap #1860's review found in the probe gate).
#   empty       a zero-length body ends the stream immediately: the reader
#               must see end-of-stream on its FIRST read, not hang.
#   isolation   two requests in flight at once each get their own body back.
#   parking     a CHUNKED upload, delivered a byte at a time, so `stream.read`
#               returns BLOCKED and the adapter's park branch actually runs.
#               Every buffered case above completes eagerly and never enters it.
#   parity      the same body under request strings of EVERY length mod 8.
#               This is the one that looks pointless and is not: the lifted
#               method/url/headers pass through the trampoline's `cabi_realloc`,
#               which writes back MAIN's `__heap_ptr`, and vibe tags pointers in
#               their low bits. An allocator that left that pointer odd
#               corrupted the handler's first heap object -- so the lane worked
#               or trapped depending on how long the URL was (#1924). A gate
#               that only ever sends one URL cannot see that at all.
#
# Skips cleanly when cargo / wasm-tools / wac / wasmtime / curl are missing,
# and fails instead under VIBE_P3_GATE_REQUIRE_TOOLS=1, matching the other P3
# gates.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/serve_body_stream/run-$$"
SERVE_LOG="$OUT_DIR/serve.log"
PORT=$((24000 + ($$ % 16000)))
ADDR="${VIBE_SERVE_BODY_GATE_ADDR:-127.0.0.1:$PORT}"

if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[serve-body] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[serve-body] SKIP: $1 not found"; exit 0
}
for c in cargo wasm-tools wac curl cmp; do
  command -v "$c" >/dev/null 2>&1 || missing_tool "$c"
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  missing_tool "wasmtime"
fi

CLI_WASM="${VIBE_SERVE_CLI_WASM:-${VIBE_ASYNC_GATE_COMPILER:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  missing_tool "a stage2 compiler"
fi

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[serve-body] selfhost cli: $CLI_WASM"

ADAPTER="$OUT_DIR/adapter.component.wasm"
echo "[serve-body] build the adapter with a stream<u8> body import"
VIBE_HTTP_ADAPTER_BODY_STREAM=1 bash "$SCRIPT_DIR/build_wasi_http_p3_full_adapter.sh" "$ADAPTER" >/dev/null
ADAPTER_WIT="$(wasm-tools component wit "$ADAPTER")"
case "$ADAPTER_WIT" in
  *'import handler: async func(method: string, url: string, headers: string, body: stream<u8>)'*) ;;
  *)
    echo "[serve-body] FAILED: the adapter's handler import does not take a stream<u8> body" >&2
    printf '%s\n' "$ADAPTER_WIT" | head -12 >&2
    exit 1 ;;
esac
echo "[serve-body] adapter: handler(.., body: stream<u8>) as an async func"

# The handler echoes the body back a byte at a time. Nothing here says "read
# the whole body first" -- `host_stream_next` is the only way in, and it
# suspends, which is exactly what this lane exists to make possible.
HANDLER_SRC="$OUT_DIR/echo_handler.vibe"
cat >"$HANDLER_SRC" <<'HEOF'
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let mut out = ""
  let mut go = true
  while go {
    let b = host_stream_next(body)
    if b < 0 {
      go = false
    } else {
      out = String::concat(out, String::from_char_code(b))
    }
  }
  "200\n\n\{out}"
}
HEOF

# Adapter selection is signature-driven, not use-driven. An unused body must
# still publish the plain-i64 core ABI required by the stream composer.
UNUSED_BODY_SRC="$OUT_DIR/unused_body_handler.vibe"
cat >"$UNUSED_BODY_SRC" <<'HEOF'
export let helper = () -> Unit with Async {
  ()
}

export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  "204\n\n"
}
HEOF
UNUSED_BODY_COMPONENT="$OUT_DIR/unused_body.component.wasm"
rm -f "$UNUSED_BODY_COMPONENT" "$UNUSED_BODY_COMPONENT.diag"
env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${UNUSED_BODY_SRC#"$PROJECT_ROOT"/}" "${UNUSED_BODY_COMPONENT#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
if [ ! -s "$UNUSED_BODY_COMPONENT" ]; then
  echo "[serve-body] FAILED: a signature-selected stream handler with an unused body did not componentize" >&2
  cat "$UNUSED_BODY_COMPONENT.diag" >&2 2>/dev/null || true
  exit 1
fi
wasm-tools validate --features all "$UNUSED_BODY_COMPONENT" >/dev/null
UNUSED_BODY_WIT="$(wasm-tools component wit "$UNUSED_BODY_COMPONENT")"
case "$UNUSED_BODY_WIT" in
  *'export handler: async func('*'stream<u8>'*) ;;
  *)
    echo "[serve-body] FAILED: the unused-body handler did not select the stream composer" >&2
    printf '%s\n' "$UNUSED_BODY_WIT" | head -20 >&2
    exit 1 ;;
esac
echo "[serve-body] an unused HostStream body still selects and satisfies the stream composer"

# A HostStream-typed export is not by itself a serve boundary. Keep ordinary
# no-entry/library cores byte-neutral unless the named validated handler above
# selects the stream composer.
ORDINARY_STREAM_SRC="$OUT_DIR/ordinary_stream_export.vibe"
cat >"$ORDINARY_STREAM_SRC" <<'HEOF'
export let consume = (body: HostStream) -> Int with Async {
  host_stream_next(body)
}
HEOF
ORDINARY_STREAM_CORE="$OUT_DIR/ordinary_stream_export.wasm"
rm -f "$ORDINARY_STREAM_CORE" "$ORDINARY_STREAM_CORE.diag"
env VIBE_RC=0 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${ORDINARY_STREAM_SRC#"$PROJECT_ROOT"/}" "${ORDINARY_STREAM_CORE#"$PROJECT_ROOT"/}" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$ORDINARY_STREAM_CORE" ]; then
  echo "[serve-body] FAILED: the ordinary HostStream export did not compile" >&2
  cat "$ORDINARY_STREAM_CORE.diag" >&2 2>/dev/null || true
  exit 1
fi
if LC_ALL=C grep -a -q 'vibe.tagmode' "$ORDINARY_STREAM_CORE"; then
  echo "[serve-body] FAILED: an ordinary HostStream export received serve-only tagmode metadata" >&2
  exit 1
fi
echo "[serve-body] ordinary HostStream exports remain free of serve-only metadata"

# Componentize a handler through the CLI's own serve path, compose it, and
# start serving it. Sets ADDR/SERVE_PID for the checks that follow.
serve_handler() {
  local tag="$1" src="$2"
  local component="$OUT_DIR/$tag.component.wasm"
  local composed="$OUT_DIR/$tag.serve.wasm"
  SERVE_LOG="$OUT_DIR/$tag.serve.log"
  rm -f "$component" "$component.diag"
  env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
    "${src#"$PROJECT_ROOT"/}" "${component#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
  if [ ! -s "$component" ]; then
    echo "[serve-body] FAILED: the serve path produced no component for $tag" >&2
    cat "$component.diag" >&2 2>/dev/null || true
    exit 1
  fi
  wasm-tools validate --features all "$component" >/dev/null

  # The lane is identified by the exported functype, not by "it built": a
  # `stream<u8>` param and an async lift are what separate this from the String
  # handler the same CLI emits for a `body: String` signature. Checked on a
  # captured string rather than piped into `grep -q` -- grep exits on its first
  # match and `set -o pipefail` would report the SIGPIPE as a failed assertion.
  local wit
  wit="$(wasm-tools component wit "$component")"
  case "$wit" in
    *'export handler: async func('*'stream<u8>'*) ;;
    *)
      echo "[serve-body] FAILED: $tag does not export an async handler taking stream<u8>" >&2
      printf '%s\n' "$wit" | head -20 >&2
      exit 1 ;;
  esac

  wac plug --plug "$component" "$ADAPTER" -o "$composed"
  wasm-tools validate --features all "$composed" >/dev/null

  ADDR="${ADDR%:*}:$((${ADDR##*:} + 1))"
  "$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$composed" >"$SERVE_LOG" 2>&1 &
  SERVE_PID=$!
  local ready=0 _i
  for _i in $(seq 1 40); do
    if ! kill -0 "$SERVE_PID" 2>/dev/null; then
      echo "[serve-body] FAILED: wasmtime exited before accepting requests ($tag)" >&2
      cat "$SERVE_LOG" >&2 || true
      exit 1
    fi
    if curl -s -m 1 -o /dev/null "http://$ADDR/" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.25
  done
  if [ "$ready" != "1" ]; then
    echo "[serve-body] FAILED: wasmtime did not become ready at $ADDR ($tag)" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
}

stop_server() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    SERVE_PID=""
  fi
}

serve_handler echo "$HANDLER_SRC"
echo "[serve-body] echo handler: async func(.., body: stream<u8>) -> string, composed and serving"

# The adapter answers "STATUS\n<headers>\n\n<body>" and falls back to the whole
# remainder when there is no header block, so the wire body is a leading "\n"
# followed by what the handler echoed. Building the expected file the same way
# keeps this a BYTE comparison of the echoed payload rather than a substring
# test that would accept a truncated or duplicated body.
post_and_compare() {
  local what="$1" payload_file="$2"
  local want="$OUT_DIR/want-$what.bin" got="$OUT_DIR/got-$what.bin" code
  { printf '\n'; cat "$payload_file"; } >"$want"
  code="$(curl -sS --max-time 20 -o "$got" -w '%{http_code}' -X POST \
    --data-binary "@$payload_file" -H 'content-type: application/octet-stream' \
    "http://$ADDR/echo" 2>&1 || true)"
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "[serve-body] FAILED: wasmtime exited while serving the $what request" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  if [ "$code" != "200" ]; then
    echo "[serve-body] FAILED: $what returned '$code' (want 200)" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  if ! cmp -s "$want" "$got"; then
    echo "[serve-body] FAILED: $what did not echo its body byte-for-byte" >&2
    echo "  want $(wc -c <"$want") bytes, got $(wc -c <"$got") bytes" >&2
    cmp "$want" "$got" >&2 || true
    exit 1
  fi
}

printf 'abc' >"$OUT_DIR/small.bin"
post_and_compare small "$OUT_DIR/small.bin"
echo "[serve-body] a 3-byte body echoes byte-for-byte"

# Longer than any single read and long enough to span whatever chunking the
# host producer chooses: the reader must keep parking and resuming until the
# end, not stop at the first completion.
python3 - "$OUT_DIR/large.bin" <<'PY'
import sys
# Every byte value the handler can echo through String::from_char_code, so a
# lane that mangled the high half would not be hidden by an all-ASCII body.
data = bytes(range(32, 127)) * 4 + b"-tail"
open(sys.argv[1], "wb").write(data)
PY
post_and_compare large "$OUT_DIR/large.bin"
echo "[serve-body] a $(wc -c <"$OUT_DIR/large.bin")-byte body echoes byte-for-byte"

: >"$OUT_DIR/empty.bin"
post_and_compare empty "$OUT_DIR/empty.bin"
echo "[serve-body] an empty body ends the stream on the first read"

# Concurrency, buffered. This proves the per-request handle plumbing keeps two
# in-flight requests apart; it does NOT prove the adapter's per-handle bands,
# because buffered reads complete eagerly and the two requests are never parked
# at the same time. The version of this check that DOES exercise that -- two
# slow chunked uploads -- is blocked on #1924.
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >"$OUT_DIR/conc-a.bin"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >"$OUT_DIR/conc-b.bin"
conc_pids=()
for n in a b; do
  { printf '\n'; cat "$OUT_DIR/conc-$n.bin"; } >"$OUT_DIR/want-conc-$n.bin"
  curl -sS --max-time 20 -o "$OUT_DIR/got-conc-$n.bin" -X POST \
    --data-binary "@$OUT_DIR/conc-$n.bin" "http://$ADDR/echo" &
  conc_pids+=("$!")
done
# Wait on the CURLS by pid, never a bare `wait`: wasmtime is a background child
# of this script too, so `wait` with no argument would block until the server
# exits -- which it never does on its own.
for pid in "${conc_pids[@]}"; do
  wait "$pid" || true
done
for n in a b; do
  if ! cmp -s "$OUT_DIR/want-conc-$n.bin" "$OUT_DIR/got-conc-$n.bin"; then
    echo "[serve-body] FAILED: concurrent request $n did not get its own body back" >&2
    cmp "$OUT_DIR/want-conc-$n.bin" "$OUT_DIR/got-conc-$n.bin" >&2 || true
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
done
echo "[serve-body] two concurrent buffered requests each echo their own body"

# The parking path. Buffered uploads complete every read eagerly, so nothing
# above ever reaches the adapter's BLOCKED branch; a chunked upload fed a byte
# at a time does. `-T -` rather than `--data-binary @-`: curl reads a
# `--data-binary` body to the end before sending it, to compute Content-Length,
# which buffers away the very thing under test.
slow_feed() {
  local text="$1" i=0
  while [ "$i" -lt "${#text}" ]; do
    printf '%s' "${text:$i:1}"
    i=$((i + 1))
    sleep 0.05
  done
}
SLOW_BODY="0123456789"
printf '\n%s' "$SLOW_BODY" >"$OUT_DIR/want-slow.bin"
slow_feed "$SLOW_BODY" | curl -sS --max-time 60 -o "$OUT_DIR/got-slow.bin" -X POST -T - \
  "http://$ADDR/echo" || true
if ! cmp -s "$OUT_DIR/want-slow.bin" "$OUT_DIR/got-slow.bin"; then
  echo "[serve-body] FAILED: a chunked body whose reads park did not echo byte-for-byte" >&2
  cmp "$OUT_DIR/want-slow.bin" "$OUT_DIR/got-slow.bin" >&2 || true
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
echo "[serve-body] a chunked body whose reads park echoes byte-for-byte"

# Request-string length parity: ONE string varies, by ONE byte per iteration.
#
# That is the whole design of this loop, and it is easy to get wrong. Padding
# the URL and a header together advances the total by two each time, which
# holds the parity FIXED and turns a sweep that looks like it covers eight
# residues into one that covers four of the same parity -- it would pass, or
# fail, uniformly against the pre-#1924 allocator instead of showing both.
# Only the URL grows here, one byte at a time, so the lifted-string total takes
# every residue mod 8 of what `cabi_realloc` leaves in `__heap_ptr`.
for pad in 0 1 2 3 4 5 6 7; do
  path="echo"
  [ "$pad" = "0" ] || path="echo$(printf 'a%.0s' $(seq 1 "$pad"))"
  code="$(curl -sS --max-time 20 -o "$OUT_DIR/got-pad$pad.bin" -w '%{http_code}' -X POST \
    --data-binary 'abc' "http://$ADDR/$path" 2>&1 || true)"
  if [ "$code" != "200" ]; then
    echo "[serve-body] FAILED: url pad $pad returned '$code' (want 200) -- request-string length must not change the answer (#1924)" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  if ! cmp -s "$OUT_DIR/want-small.bin" "$OUT_DIR/got-pad$pad.bin"; then
    echo "[serve-body] FAILED: url pad $pad did not echo its body byte-for-byte (#1924)" >&2
    cmp "$OUT_DIR/want-small.bin" "$OUT_DIR/got-pad$pad.bin" >&2 || true
    exit 1
  fi
done
echo "[serve-body] the answer is the same for request strings of every length mod 8"

stop_server

# The other half of the adapter's surface, checked where it can be checked:
# COMPOSITION. `host_stream_close` lowers to a `vibe.host_stream_close` core
# import, and a core instance cannot be given fewer bindings than it imports --
# so before the adapter exported both halves, a handler that stops reading
# early could not be composed at all. Both are checked: the core really does
# import the close half, and the handler then serves and answers with exactly
# the bytes it chose to read.
CLOSE_SRC="$OUT_DIR/close_handler.vibe"
cat >"$CLOSE_SRC" <<'HEOF'
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let mut out = ""
  let mut n = 0
  while n < 4 {
    let b = host_stream_next(body)
    if b < 0 {
      n = 4
    } else {
      out = String::concat(out, String::from_char_code(b))
      n = n + 1
    }
  }
  host_stream_close(body)
  "200\n\n\{out}"
}
HEOF
CLOSE_COMPONENT="$OUT_DIR/close.component.wasm"
rm -f "$CLOSE_COMPONENT" "$CLOSE_COMPONENT.diag"
env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${CLOSE_SRC#"$PROJECT_ROOT"/}" "${CLOSE_COMPONENT#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
if [ ! -s "$CLOSE_COMPONENT" ]; then
  echo "[serve-body] FAILED: an early-closing handler did not componentize" >&2
  cat "$CLOSE_COMPONENT.diag" >&2 2>/dev/null || true
  exit 1
fi
CLOSE_CORE_WIT="$(wasm-tools print "$CLOSE_COMPONENT")"
case "$CLOSE_CORE_WIT" in
  *'(import "vibe" "host_stream_close"'*) ;;
  *)
    echo "[serve-body] FAILED: the early-closing handler's core does not import vibe.host_stream_close" >&2
    exit 1 ;;
esac
serve_handler close "$CLOSE_SRC"
printf '\nabcd' >"$OUT_DIR/want-close.bin"
close_code="$(curl -sS --max-time 20 -o "$OUT_DIR/got-close.bin" -w '%{http_code}' -X POST \
  --data-binary 'abcdefghij' "http://$ADDR/echo" || true)"
if [ "$close_code" != "200" ]; then
  echo "[serve-body] FAILED: the early-closing handler returned '$close_code' (want 200)" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
if ! cmp -s "$OUT_DIR/want-close.bin" "$OUT_DIR/got-close.bin"; then
  echo "[serve-body] FAILED: the early-closing handler did not answer with its first 4 bytes" >&2
  cmp "$OUT_DIR/want-close.bin" "$OUT_DIR/got-close.bin" >&2 || true
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
stop_server
echo "[serve-body] a handler that reads 4 bytes and closes the body composes, serves, and answers abcd"

# #2066 the `wasi:http/service` world: a handler that is also a CLIENT. It
# awaits two responses from a `from_wit` binding, so the serve path composes
# the run lane's response imports under the stream lane's handler export. A
# provider built by scripts/build_http_client_provider.sh implements that
# binding's interface over `wasi:http/client`; plugged in, the component
# exports `handler` and imports `wasi:http/client`, and `wasmtime serve`
# supplies the client. The upstream delays `/slow/<x>` by one second and
# answers `<x>`, so the two fetches in flight together take about one second.
SVC_SRC="$PROJECT_ROOT/fixtures/serve_service_world/handler.vibe"
SVC_COMPONENT="$OUT_DIR/service.component.wasm"
rm -f "$SVC_COMPONENT" "$SVC_COMPONENT.diag"
env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${SVC_SRC#"$PROJECT_ROOT"/}" "${SVC_COMPONENT#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
if [ ! -s "$SVC_COMPONENT" ]; then
  echo "[serve-body] FAILED: the service handler did not componentize" >&2
  cat "$SVC_COMPONENT.diag" >&2 2>/dev/null || true
  exit 1
fi
wasm-tools validate --features all "$SVC_COMPONENT" >/dev/null
SVC_WIT="$(wasm-tools component wit "$SVC_COMPONENT")"
case "$SVC_WIT" in
  *'import example:http-lite/client@1.0.0;'*'export handler: async func('*'stream<u8>'*) ;;
  *)
    echo "[serve-body] FAILED: the service handler must import the client interface and export the stream handler" >&2
    printf '%s\n' "$SVC_WIT" | head -20 >&2
    exit 1 ;;
esac
echo "[serve-body] service handler: imports example:http-lite/client, exports handler(.., body: stream<u8>)"

PROVIDER="$OUT_DIR/client_provider.component.wasm"
bash "$SCRIPT_DIR/build_http_client_provider.sh" "$PROVIDER" >/dev/null
SVC_CLIENT="$OUT_DIR/service_client.wasm"
wac plug --plug "$PROVIDER" "$SVC_COMPONENT" -o "$SVC_CLIENT"
wasm-tools validate --features all "$SVC_CLIENT" >/dev/null
SVC_CLIENT_WIT="$(wasm-tools component wit "$SVC_CLIENT")"
case "$SVC_CLIENT_WIT" in
  *'example:http-lite'*)
    echo "[serve-body] FAILED: the provider left the client interface unsatisfied" >&2
    exit 1 ;;
  *'import wasi:http/client@0.3.0;'*'export handler: async func('*) ;;
  *)
    echo "[serve-body] FAILED: the composed service does not import wasi:http/client and export handler" >&2
    printf '%s\n' "$SVC_CLIENT_WIT" | head -20 >&2
    exit 1 ;;
esac
echo "[serve-body] provider plugged: the service imports wasi:http/client and exports handler"
SVC_SERVED="$OUT_DIR/service.serve.wasm"
wac plug --plug "$SVC_CLIENT" "$ADAPTER" -o "$SVC_SERVED"
wasm-tools validate --features all "$SVC_SERVED" >/dev/null

UPSTREAM_PID=""
python3 - <<'PYEOF' &
import http.server, time
class Slow(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow/"):
            time.sleep(1)
            body = self.path[len("/slow/"):].encode()
            self.send_response(200)
        else:
            body = b"missing"
            self.send_response(404)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18767), Slow).serve_forever()
PYEOF
UPSTREAM_PID=$!
stop_upstream() {
  if [ -n "$UPSTREAM_PID" ]; then
    kill "$UPSTREAM_PID" 2>/dev/null || true
    wait "$UPSTREAM_PID" 2>/dev/null || true
    UPSTREAM_PID=""
  fi
}
trap 'stop_upstream; cleanup' EXIT
wait_port() {
  python3 - "$1" "$2" <<'PYEOF'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 20
while time.time() < deadline:
    try:
        socket.create_connection((host, port), timeout=1).close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.1)
raise SystemExit(1)
PYEOF
}
wait_port 127.0.0.1 18767 || { echo "[serve-body] FAILED: the upstream on 127.0.0.1:18767 did not come up" >&2; exit 1; }
ADDR="${ADDR%:*}:$((${ADDR##*:} + 1))"
SERVE_LOG="$OUT_DIR/service.serve.log"
"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$SVC_SERVED" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
wait_port "${ADDR%:*}" "${ADDR##*:}" || { echo "[serve-body] FAILED: wasmtime did not listen at $ADDR (service)" >&2; cat "$SERVE_LOG" >&2 || true; exit 1; }
printf '\n200:left|200:right|xyz' >"$OUT_DIR/want-service.bin"
SVC_T0=$(date +%s%N)
svc_code="$(curl -sS --noproxy '*' --max-time 20 -o "$OUT_DIR/got-service.bin" -w '%{http_code}' -X POST \
  --data-binary 'xyz' "http://$ADDR/svc" || true)"
SVC_MS=$(( ($(date +%s%N) - SVC_T0) / 1000000 ))
stop_server
stop_upstream
if [ "$svc_code" != "200" ]; then
  echo "[serve-body] FAILED: the service handler returned '$svc_code' (want 200)" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
if ! cmp -s "$OUT_DIR/want-service.bin" "$OUT_DIR/got-service.bin"; then
  echo "[serve-body] FAILED: the service handler did not answer both upstream responses and its own body" >&2
  cmp "$OUT_DIR/want-service.bin" "$OUT_DIR/got-service.bin" >&2 || true
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
if [ "$SVC_MS" -ge 1900 ]; then
  echo "[serve-body] FAILED: two 1s upstream fetches took ${SVC_MS}ms -- they ran one after the other" >&2
  exit 1
fi
echo "[serve-body] service world: two upstream fetches in flight answer 200:left|200:right|xyz in ${SVC_MS}ms"

# #2066 the `wasi:http/middleware` world: the same composition with the
# provider's `handler` mode, whose `fetch` hands the request to an IMPORTED
# `wasi:http/handler`. The middleware then imports and exports `handler`, and
# plugging a backend -- an ordinary `vibe serve` String handler composed with
# the sync adapter -- into that import gives a chain `wasmtime serve` runs.
for mw_part in middleware backend; do
  mw_src="$PROJECT_ROOT/fixtures/serve_middleware_world/$mw_part.vibe"
  mw_out="$OUT_DIR/mw_$mw_part.component.wasm"
  rm -f "$mw_out" "$mw_out.diag"
  env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
    "${mw_src#"$PROJECT_ROOT"/}" "${mw_out#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
  if [ ! -s "$mw_out" ]; then
    echo "[serve-body] FAILED: fixtures/serve_middleware_world/$mw_part.vibe did not componentize" >&2
    cat "$mw_out.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
SYNC_ADAPTER="$OUT_DIR/adapter_sync.component.wasm"
bash "$SCRIPT_DIR/build_wasi_http_p3_full_adapter.sh" "$SYNC_ADAPTER" >/dev/null
MW_PROVIDER="$OUT_DIR/handler_provider.component.wasm"
bash "$SCRIPT_DIR/build_http_client_provider.sh" "$MW_PROVIDER" handler >/dev/null
wac plug --plug "$MW_PROVIDER" "$OUT_DIR/mw_middleware.component.wasm" -o "$OUT_DIR/mw_client.wasm"
wac plug --plug "$OUT_DIR/mw_client.wasm" "$ADAPTER" -o "$OUT_DIR/mw.serve.wasm"
wasm-tools validate --features all "$OUT_DIR/mw.serve.wasm" >/dev/null
MW_WIT="$(wasm-tools component wit "$OUT_DIR/mw.serve.wasm")"
case "$MW_WIT" in
  *'import wasi:http/handler@0.3.0;'*'export wasi:http/handler@0.3.0;'*) ;;
  *)
    echo "[serve-body] FAILED: the middleware does not import and export wasi:http/handler" >&2
    printf '%s\n' "$MW_WIT" | head -20 >&2
    exit 1 ;;
esac
echo "[serve-body] middleware world: the composed middleware imports and exports wasi:http/handler"
wac plug --plug "$OUT_DIR/mw_backend.component.wasm" "$SYNC_ADAPTER" -o "$OUT_DIR/backend.serve.wasm"
wac plug --plug "$OUT_DIR/backend.serve.wasm" "$OUT_DIR/mw.serve.wasm" -o "$OUT_DIR/chain.serve.wasm"
wasm-tools validate --features all "$OUT_DIR/chain.serve.wasm" >/dev/null
ADDR="${ADDR%:*}:$((${ADDR##*:} + 1))"
SERVE_LOG="$OUT_DIR/chain.serve.log"
"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$OUT_DIR/chain.serve.wasm" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
wait_port "${ADDR%:*}" "${ADDR##*:}" || { echo "[serve-body] FAILED: wasmtime did not listen at $ADDR (middleware chain)" >&2; cat "$SERVE_LOG" >&2 || true; exit 1; }
# The sync adapter's body begins after the status line's own newline, so the
# backend's answer arrives as "\nbackend saw ..." inside the middleware's body.
printf '\nmiddleware(200): \nbackend saw GET /items?id=7' >"$OUT_DIR/want-chain.bin"
chain_code="$(curl -sS --noproxy '*' --max-time 20 -o "$OUT_DIR/got-chain.bin" -w '%{http_code}' -X POST \
  --data-binary 'xyz' "http://$ADDR/items?id=7" || true)"
stop_server
if [ "$chain_code" != "200" ]; then
  echo "[serve-body] FAILED: the middleware chain returned '$chain_code' (want 200)" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
if ! cmp -s "$OUT_DIR/want-chain.bin" "$OUT_DIR/got-chain.bin"; then
  echo "[serve-body] FAILED: the middleware chain did not wrap the backend's answer" >&2
  cmp "$OUT_DIR/want-chain.bin" "$OUT_DIR/got-chain.bin" >&2 || true
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
echo "[serve-body] middleware chain: the request reached the backend through the imported handler"

# The service composer needs a provider behind every host future it imports,
# and only a WIT response has one under `wasmtime serve`. A runner-private
# root future is refused by name rather than composed into a component no
# host can instantiate.
ROOT_SRC="$OUT_DIR/root_future_handler.vibe"
cat >"$ROOT_SRC" <<'HEOF'
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let v = await(host_future_named("x"))
  "200\n\n\{v}"
}
HEOF
ROOT_COMPONENT="$OUT_DIR/root_future.component.wasm"
rm -f "$ROOT_COMPONENT" "$ROOT_COMPONENT.diag"
env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${ROOT_SRC#"$PROJECT_ROOT"/}" "${ROOT_COMPONENT#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
if [ -s "$ROOT_COMPONENT" ]; then
  echo "[serve-body] FAILED: a serve handler awaiting a runner-private root future composed" >&2
  exit 1
fi
grep -qF "must await a WIT response" "$ROOT_COMPONENT.diag" 2>/dev/null || {
  echo "[serve-body] FAILED: the root-future handler gave an unexpected diagnostic: $(cat "$ROOT_COMPONENT.diag" 2>/dev/null)" >&2
  exit 1
}
echo "[serve-body] a serve handler awaiting a runner-private root future: refused"

echo "[serve-body] PASS: vibe serve hands the request body to the handler as a stream (#1540)"
