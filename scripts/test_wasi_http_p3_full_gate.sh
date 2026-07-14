#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async HTTP full-handler gate (docs/spec/wasi-p3-async.md §4.1),
# selfhost edition (#537 — the legacy `vibe.exe compile --compose-p3` host
# path was retired with the MoonBit host).
#
# Pipeline under test (the same one `runtime/vibe serve` drives):
#   1. selfhost CLI (VIBE_SERVE_COMPONENT=1) componentizes the vibe handler:
#      handler.vibe -> handler.component.wasm exporting
#        handler: func(method, url, headers, body: string) -> string
#      (packed-string trampoline, comp_emit_component_wasm_string_handler)
#   2. build_wasi_http_p3_full_adapter.sh builds the Rust wasi-http P3 adapter
#      component (imports that handler func, exports wasi:http/handler).
#   3. `wac plug` plugs the handler component into the adapter.
#   4. `wasmtime serve` serves it; curl asserts auth-by-request-header:
#      with `x-token: secret` -> 200 "ok:GET:/"; without -> 401 "unauthorized".
#
# Skips cleanly when cargo / wasm-tools / wac / wasmtime / curl or a selfhost
# compiler wasm are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_http_p3_full"
ADAPTER="$OUT_DIR/full_adapter.component.wasm"
HANDLER_SRC="$PROJECT_ROOT/fixtures/serve_handler_smoke.vibe"
COMPONENT="$OUT_DIR/handler.component.wasm"
COMPOSED="$OUT_DIR/handler.serve.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
ADDR="127.0.0.1:18984"

# Flag override for the wasmtime 46 re-probe (#821): on 46+ component-model
# async is default-on, so the RC flag set can be replaced/trimmed via env.
if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

# VIBE_P3_GATE_REQUIRE_TOOLS=1 (#821 guarantee mode): a missing tool is a
# FAILURE, not a skip — CI must not go green without actually verifying.
missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[http-full-gate] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[http-full-gate] SKIP: $1 not found"; exit 0
}
for c in cargo wasm-tools wac curl; do
  command -v "$c" >/dev/null 2>&1 || missing_tool "$c"
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  missing_tool "wasmtime"
fi

# Selfhost compiler wasm: explicit override, else the newest generation build.
CLI_WASM="${VIBE_SERVE_CLI_WASM:-}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[http-full-gate] FAILED: no selfhost compiler wasm (required mode; run scripts/selfhost_generations.sh build, or set VIBE_SERVE_CLI_WASM)" >&2
    exit 1
  fi
  echo "[http-full-gate] SKIP: no selfhost compiler wasm (run scripts/selfhost_generations.sh build, or set VIBE_SERVE_CLI_WASM)"
  exit 0
fi

mkdir -p "$OUT_DIR"
echo "[http-full-gate] wasmtime: $($WASMTIME_BIN --version)"
echo "[http-full-gate] selfhost cli: $CLI_WASM"

echo "[http-full-gate] build full adapter"
bash "$SCRIPT_DIR/build_wasi_http_p3_full_adapter.sh" "$ADAPTER" >/dev/null

echo "[http-full-gate] componentize handler (selfhost VIBE_SERVE_COMPONENT)"
rm -f "$COMPONENT" "$COMPONENT.diag"
env VIBE_SERVE_COMPONENT=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI_WASM" \
  "${HANDLER_SRC#"$PROJECT_ROOT"/}" "${COMPONENT#"$PROJECT_ROOT"/}" main >/dev/null 2>&1 || true
if [ ! -s "$COMPONENT" ]; then
  echo "[http-full-gate] FAIL: handler componentization produced nothing" >&2
  cat "$COMPONENT.diag" 2>/dev/null >&2 || true
  exit 1
fi
wasm-tools validate --features all "$COMPONENT" >/dev/null
echo "[http-full-gate] handler component validates"

echo "[http-full-gate] compose (wac plug)"
wac plug --plug "$COMPONENT" "$ADAPTER" -o "$COMPOSED"
wasm-tools validate --features all "$COMPOSED" >/dev/null
echo "[http-full-gate] composed component validates"

SERVE_PID=""
cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPOSED" >"$SERVE_LOG" 2>&1 &
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
  echo "[http-full-gate] $desc -> $code OK"
}

check "with x-token"    "200" "ok:GET:/"     -H "x-token: secret"
check "without x-token" "401" "unauthorized"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async HTTP Full-Handler Gate (selfhost, #537)"
    echo
    echo "- selfhost componentize -> wac plug -> wasmtime serve -> curl"
    echo "- x-token present -> 200 'ok:GET:/'; absent -> 401 'unauthorized'"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[http-full-gate] PASS: vibe full async HTTP handler (selfhost serve pipeline)"
