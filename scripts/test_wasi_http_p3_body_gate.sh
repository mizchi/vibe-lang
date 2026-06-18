#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async HTTP body gate (docs/spec/wasi-p3-async.md §4.1).
#
# Proves a vibe HTTP handler controls the response body end-to-end on wasmtime 45:
#   build body adapter -> compose a String-returning handler -> wasmtime serve ->
#   curl returns the handler's body with HTTP 200.
#
# Skips cleanly when cargo / wasm-tools / wasmtime / curl / node are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_http_p3_body"
ADAPTER="$OUT_DIR/body_adapter.component.wasm"
HANDLER_SRC="$OUT_DIR/handler.vibe"
COMPONENT="$OUT_DIR/handler.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
ADDR="127.0.0.1:18981"
EXPECT="hello from vibe gate"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

for c in cargo wasm-tools curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "[http-body-gate] SKIP: $c not found"; exit 0; }
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[http-body-gate] SKIP: wasmtime not found"; exit 0
fi
if [ -x "$HOST_VIBE_EXE" ]; then VIBE="$HOST_VIBE_EXE"
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then VIBE="$HOST_VIBE_EXE_DEBUG"
else echo "[http-body-gate] SKIP: host vibe.exe not built"; exit 0; fi

mkdir -p "$OUT_DIR"
echo "[http-body-gate] wasmtime: $($WASMTIME_BIN --version)"

echo "[http-body-gate] build body adapter"
bash "$SCRIPT_DIR/build_wasi_http_p3_body_adapter.sh" "$ADAPTER" >/dev/null

printf 'export let handler = (method: String, url: String) -> String { "%s" }\n' "$EXPECT" > "$HANDLER_SRC"

echo "[http-body-gate] compose"
"$VIBE" compile --compose-p3 --adapter "$ADAPTER" "$HANDLER_SRC" -o "$COMPONENT" >/dev/null
wasm-tools validate --features all "$COMPONENT" >/dev/null
echo "[http-body-gate] composed component validates"

SERVE_PID=""
cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPONENT" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
sleep 3

body="$(curl -s --max-time 5 "http://$ADDR/gate" || true)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ADDR/gate" || true)"

if [ "$code" != "200" ]; then
  echo "[http-body-gate] FAIL: expected HTTP 200, got '$code'" >&2
  echo "--- serve log ---" >&2; head -8 "$SERVE_LOG" >&2
  exit 1
fi
case "$body" in
  *"$EXPECT"*) ;;
  *) echo "[http-body-gate] FAIL: body did not contain '$EXPECT' (got: '$body')" >&2; exit 1 ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async HTTP Body Gate"
    echo
    echo "- a vibe \`handler : (String, String) -> String\` controlled the response body"
    echo "- served via wasmtime, curl returned HTTP 200 with the handler's body"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[http-body-gate] PASS: vibe handler body served over HTTP (200, body matched)"
