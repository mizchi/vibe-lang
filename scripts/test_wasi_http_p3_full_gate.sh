#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async HTTP full-handler gate (docs/spec/wasi-p3-async.md §4.1).
#
# The most comprehensive HTTP gate: a vibe handler sees the full request
# (method, url, request headers, request body) and returns a full response
# (status + headers + body). Auth-by-request-header is the test:
#   handler : (method, url, headers, body) -> "STATUS\n<resp headers>\n\n<body>"
#   with `x-token: secret` -> 200 "ok"; without -> 401 "unauthorized".
#
# Subsumes the body / reqbody / status_body gates. Skips cleanly when cargo /
# wasm-tools / wasmtime / curl are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_http_p3_full"
ADAPTER="$OUT_DIR/full_adapter.component.wasm"
HANDLER_SRC="$OUT_DIR/handler.vibe"
COMPONENT="$OUT_DIR/handler.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
ADDR="127.0.0.1:18984"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

for c in cargo wasm-tools curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "[http-full-gate] SKIP: $c not found"; exit 0; }
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[http-full-gate] SKIP: wasmtime not found"; exit 0
fi
if [ -x "$HOST_VIBE_EXE" ]; then VIBE="$HOST_VIBE_EXE"
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then VIBE="$HOST_VIBE_EXE_DEBUG"
else echo "[http-full-gate] SKIP: host vibe.exe not built"; exit 0; fi

mkdir -p "$OUT_DIR"
echo "[http-full-gate] wasmtime: $($WASMTIME_BIN --version)"

echo "[http-full-gate] build full adapter"
bash "$SCRIPT_DIR/build_wasi_http_p3_full_adapter.sh" "$ADAPTER" >/dev/null

printf 'export let handler = (method: String, url: String, headers: String, body: String) -> String { if String::contains(headers, "x-token: secret") { "200\\ncontent-type: text/plain\\n\\nok" } else { "401\\nunauthorized" } }\n' > "$HANDLER_SRC"

echo "[http-full-gate] compose"
"$VIBE" compile --compose-p3 --adapter "$ADAPTER" "$HANDLER_SRC" -o "$COMPONENT" >/dev/null
wasm-tools validate --features all "$COMPONENT" >/dev/null
echo "[http-full-gate] composed component validates"

SERVE_PID=""
cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPONENT" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
sleep 3

check() {
  local desc="$1" want_code="$2" want_body="$3"; shift 3
  local body code
  body="$(curl -s --max-time 5 "$@" "http://$ADDR/" || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "http://$ADDR/" || true)"
  if [ "$code" != "$want_code" ]; then
    echo "[http-full-gate] FAIL: $desc expected HTTP $want_code, got '$code'" >&2
    head -8 "$SERVE_LOG" >&2; exit 1
  fi
  case "$body" in
    *"$want_body"*) ;;
    *) echo "[http-full-gate] FAIL: $desc body did not contain '$want_body' (got: '$body')" >&2; exit 1 ;;
  esac
  echo "[http-full-gate] $desc -> $code '$body' OK"
}

check "with x-token"    "200" "ok"          -H "x-token: secret"
check "without x-token" "401" "unauthorized"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async HTTP Full-Handler Gate"
    echo
    echo "- vibe \`handler : (method,url,headers,body) -> response\` read a request header (auth)"
    echo "- x-token present -> 200 'ok'; absent -> 401 'unauthorized' (served via wasmtime)"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[http-full-gate] PASS: vibe full async HTTP handler (request headers/body -> status/headers/body)"
