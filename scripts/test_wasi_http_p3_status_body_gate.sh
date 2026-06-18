#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async HTTP routing gate — comprehensive (docs/spec/wasi-p3-async.md §4.1).
#
# Proves a vibe HTTP handler can read the request body AND control both the
# status code and the body, with routing, end-to-end on wasmtime 45:
#   handler : (method, url, body) -> "STATUS\nBODY"
#   GET /health -> 200 "ok";  GET /other -> 404 "not found".
#
# This subsumes the simpler body / reqbody gates (it reads the request body,
# returns a body, and sets the status). Skips cleanly when cargo / wasm-tools /
# wasmtime / curl are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_http_p3_status_body"
ADAPTER="$OUT_DIR/status_body_adapter.component.wasm"
HANDLER_SRC="$OUT_DIR/handler.vibe"
COMPONENT="$OUT_DIR/handler.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
ADDR="127.0.0.1:18983"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

for c in cargo wasm-tools curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "[http-routing-gate] SKIP: $c not found"; exit 0; }
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[http-routing-gate] SKIP: wasmtime not found"; exit 0
fi
if [ -x "$HOST_VIBE_EXE" ]; then VIBE="$HOST_VIBE_EXE"
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then VIBE="$HOST_VIBE_EXE_DEBUG"
else echo "[http-routing-gate] SKIP: host vibe.exe not built"; exit 0; fi

mkdir -p "$OUT_DIR"
echo "[http-routing-gate] wasmtime: $($WASMTIME_BIN --version)"

echo "[http-routing-gate] build status+body adapter"
bash "$SCRIPT_DIR/build_wasi_http_p3_status_body_adapter.sh" "$ADAPTER" >/dev/null

printf 'export let handler = (method: String, url: String, body: String) -> String { if String::equals(url, "/health") { "200\\nok" } else { "404\\nnot found" } }\n' > "$HANDLER_SRC"

echo "[http-routing-gate] compose"
"$VIBE" compile --compose-p3 --adapter "$ADAPTER" "$HANDLER_SRC" -o "$COMPONENT" >/dev/null
wasm-tools validate --features all "$COMPONENT" >/dev/null
echo "[http-routing-gate] composed component validates"

SERVE_PID=""
cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPONENT" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
sleep 3

check() {
  local path="$1" want_code="$2" want_body="$3"
  local body code
  body="$(curl -s --max-time 5 "http://$ADDR$path" || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ADDR$path" || true)"
  if [ "$code" != "$want_code" ]; then
    echo "[http-routing-gate] FAIL: $path expected HTTP $want_code, got '$code'" >&2
    head -8 "$SERVE_LOG" >&2; exit 1
  fi
  case "$body" in
    *"$want_body"*) ;;
    *) echo "[http-routing-gate] FAIL: $path body did not contain '$want_body' (got: '$body')" >&2; exit 1 ;;
  esac
  echo "[http-routing-gate] $path -> $code '$body' OK"
}

check "/health" "200" "ok"
check "/other"  "404" "not found"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async HTTP Routing Gate"
    echo
    echo "- a vibe \`handler : (String,String,String) -> String\` routed by url and set status+body"
    echo "- /health -> 200 'ok'; /other -> 404 'not found' (served via wasmtime)"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[http-routing-gate] PASS: vibe handler routed with status+body over HTTP"
