#!/usr/bin/env bash
set -euo pipefail

# #1540 scope 4: can a `vibe serve` handler component be ASYNC-LIFTED and still
# serve real HTTP?
#
# The existing serve lane (test_wasi_http_p3_full_gate.sh) lifts the handler
# SYNC. That works only for a handler that never suspends -- and everything
# #1540 is heading for (reading the request body) suspends. Async lifting is
# what makes suspension expressible, and it moves the result off the core
# function's return path onto `task.return`.
#
# This gate holds the async lane to the sync lane's own bar, on the same
# handler fixture: 200 with a body when the request carries `x-token: secret`,
# 401 without. Same handler, same answers, different lift.
#
# What it exercises:
#   comp_generate_string_trampoline_packed_async   task.return instead of a
#                                                  retptr, no return area
#   comp_emit_component_wasm_string_handler_async  async functype + async lift
#                                                  over the REAL compiled core
#   build_wasi_http_p3_full_adapter.sh             VIBE_HTTP_ADAPTER_ASYNC_HANDLER=1
#
# That last one is not optional and not cosmetic: `canon lift ... async`
# validates only against an async functype, and the functype in question is the
# one the ADAPTER declares. A sync import makes an async-lifted handler
# unpluggable (tools/wasip3_component_probe/http_body_read/README.md).
#
# Skips cleanly when cargo / wasm-tools / wac / wasmtime / curl are missing, and
# fails instead under VIBE_P3_GATE_REQUIRE_TOOLS=1, matching the other P3 gates.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/serve_async_lift/run-$$"
SERVE_LOG="$OUT_DIR/serve.log"
HANDLER_SRC="fixtures/serve_handler_smoke.vibe"
PORT=$((20000 + ($$ % 20000)))
ADDR="${VIBE_SERVE_ASYNC_GATE_ADDR:-127.0.0.1:$PORT}"

if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[serve-async] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[serve-async] SKIP: $1 not found"; exit 0
}
for c in cargo wasm-tools wac curl; do
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
  # A missing compiler is treated like a missing tool rather than a silent
  # pass: this gate has nothing to assert without one.
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

echo "[serve-async] selfhost cli: $CLI_WASM"

ADAPTER="$OUT_DIR/adapter.component.wasm"
echo "[serve-async] build the full adapter with an ASYNC handler import"
VIBE_HTTP_ADAPTER_ASYNC_HANDLER=1 bash "$SCRIPT_DIR/build_wasi_http_p3_full_adapter.sh" "$ADAPTER" >/dev/null
ADAPTER_WIT="$(wasm-tools component wit "$ADAPTER")"
case "$ADAPTER_WIT" in
  *'import handler: async func('*) ;;
  *)
    echo "[serve-async] FAILED: VIBE_HTTP_ADAPTER_ASYNC_HANDLER=1 did not produce an async handler import" >&2
    printf '%s\n' "$ADAPTER_WIT" | head -12 >&2
    exit 1 ;;
esac
echo "[serve-async] adapter imports handler as an async func"

REL_OUT="${OUT_DIR#"$PROJECT_ROOT"/}"
cat >"$OUT_DIR/emit.vibe" <<EMITEOF
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_string_handler_async,
  compile_file_wasi_only
}

fn main() -> Int with Fs + Exception {
  let core = compile_file_wasi_only("$HANDLER_SRC", "__no_entry__")
  let comp = comp_emit_component_wasm_string_handler_async(core, "handler", "handler", [
    "method",
    "url",
    "headers",
    "body"
  ])
  Fs::write_bytes("$REL_OUT/handler.component.wasm", comp)
  Bytes::length(comp)
}
EMITEOF
echo "[serve-async] componentize the handler through the async lane"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$CLI_WASM" "$OUT_DIR/emit.vibe" "$OUT_DIR/emit.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$OUT_DIR/emit.wasm" ]; then
  echo "[serve-async] FAILED: the componentizer program did not compile" >&2
  cat "$OUT_DIR/emit.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_PREOPEN_DIR="$PROJECT_ROOT" bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" \
  --invoke main "$OUT_DIR/emit.wasm" >/dev/null 2>&1 || true
COMPONENT="$OUT_DIR/handler.component.wasm"
if [ ! -s "$COMPONENT" ]; then
  echo "[serve-async] FAILED: the async lane produced no component" >&2
  exit 1
fi
wasm-tools validate --features all "$COMPONENT" >/dev/null

# The option set is the async_string_lift probe's, on a REAL compiled core:
# task.return carries memory + encoding and never realloc, the lift carries all
# four. Checked on a captured string, never piped into `grep -q` -- grep exits
# on its first match and `set -o pipefail` would report the SIGPIPE as a failed
# assertion.
COMPONENT_DUMP="$(wasm-tools dump "$COMPONENT" 2>/dev/null || true)"
case "$COMPONENT_DUMP" in
  *'TaskReturn { result: Some(Primitive(String)), options: [Memory(0), UTF8] }'*) ;;
  *)
    echo "[serve-async] FAILED: task.return's option set is not [Memory(0), UTF8]" >&2
    exit 1 ;;
esac
case "$COMPONENT_DUMP" in
  *'options: [Async, Memory(0), Realloc(3), UTF8]'*) ;;
  *)
    echo "[serve-async] FAILED: the handler is not lifted with [Async, Memory(0), Realloc(3), UTF8]" >&2
    exit 1 ;;
esac
case "$COMPONENT_DUMP" in
  *'ComponentFuncType { async_: true, params: [("method", Primitive(String))'*) ;;
  *)
    echo "[serve-async] FAILED: the exported handler's functype is not async" >&2
    exit 1 ;;
esac
echo "[serve-async] handler component: async functype, async lift, string task.return"

COMPOSED="$OUT_DIR/handler.serve.wasm"
wac plug --plug "$COMPONENT" "$ADAPTER" -o "$COMPOSED"
wasm-tools validate --features all "$COMPOSED" >/dev/null
echo "[serve-async] composed with the async adapter"

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPOSED" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
ready=0
for _ in $(seq 1 40); do
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "[serve-async] FAILED: wasmtime exited before accepting requests" >&2
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
  echo "[serve-async] FAILED: wasmtime did not become ready at $ADDR" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

# Both arms of the fixture's own contract. Asserting only the 200 would accept
# a handler whose branch collapsed -- the 401 is what says the request actually
# reached the vibe code and was decided there.
check_request() {
  local what="$1" want_code="$2" want_body="$3"
  shift 3
  local file="$OUT_DIR/response-$what.txt" code
  code="$(curl -sS --max-time 10 -o "$file" -w '%{http_code}' "$@" "http://$ADDR/hello" 2>&1 || true)"
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "[serve-async] FAILED: wasmtime exited while serving the $what request" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  if [ "$code" != "$want_code" ]; then
    echo "[serve-async] FAILED: $what returned '$code' (want $want_code)" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  # Containment, not equality, and for one specific reason: the adapter splits
  # the handler's "STATUS\n<headers>\n\n<body>" answer with `split_once("\n\n")`
  # and falls back to the WHOLE remainder when there is no header block, so the
  # header-less 401 arm comes back as "\nunauthorized". That is the adapter's
  # behaviour in both lanes, not something this lift changed -- the sibling
  # sync gate asserts containment for the same reason.
  local body
  body="$(cat "$file" 2>/dev/null || true)"
  case "$body" in
    *"$want_body"*) ;;
    *)
      echo "[serve-async] FAILED: $what body was '$body' (want it to contain '$want_body')" >&2
      exit 1 ;;
  esac
}

check_request "with-token" 200 "ok:GET:/hello" -H 'x-token: secret'
check_request "without-token" 401 "unauthorized"
echo "[serve-async] with x-token -> 200 ok:GET:/hello; without -> 401 unauthorized"

kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

echo "[serve-async] PASS: a serve handler component can be async-lifted and still serve (#1540)"
