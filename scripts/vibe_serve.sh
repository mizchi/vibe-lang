#!/usr/bin/env bash
set -euo pipefail

# vibe serve — compile a vibe HTTP handler and serve it via wasmtime.
#
# Usage:
#   vibe-serve.sh [options] <handler.vibe>
#
# Options:
#   --port <port>     Listen port (default: 8080)
#   --addr <addr>     Listen address (default: 127.0.0.1)
#   --adapter <path>  Pre-built P3 adapter (skips adapter build)
#   --no-validate     Skip wasm-tools validate
#   -o <path>         Save composed component to path (default: temp file)
#
# The vibe source must export a handler function:
#   export let handler: (String, String) -> Int = (method, url) -> { ... }
#
# Or with string result:
#   export let handler: (String, String) -> String = (method, url) -> { ... }
#
# Requires: wasmtime (with P3 support), wasm-tools

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${VIBE_HTTP_P3_CACHE:-$PROJECT_ROOT/_build/http_adapter}"

# Defaults
PORT=8080
ADDR="127.0.0.1"
ADAPTER=""
OUTPUT=""
VALIDATE=1
INPUT=""

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --port)    PORT="$2"; shift 2 ;;
    --addr)    ADDR="$2"; shift 2 ;;
    --adapter) ADAPTER="$2"; shift 2 ;;
    --no-validate) VALIDATE=0; shift ;;
    -o)        OUTPUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: vibe serve [options] <handler.vibe>"
      echo ""
      echo "Options:"
      echo "  --port <port>     Listen port (default: 8080)"
      echo "  --addr <addr>     Listen address (default: 127.0.0.1)"
      echo "  --adapter <path>  Pre-built P3 adapter"
      echo "  --no-validate     Skip wasm-tools validate"
      echo "  -o <path>         Save composed component"
      echo ""
      echo "Handler must export:"
      echo '  export let handler: (String, String) -> Int = (method, url) -> { 200 }'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      echo "run with --help for usage" >&2
      exit 1
      ;;
    *)
      INPUT="$1"; shift
      ;;
  esac
done

if [ -z "$INPUT" ]; then
  echo "error: no input file specified" >&2
  echo "usage: vibe serve [options] <handler.vibe>" >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "error: file not found: $INPUT" >&2
  exit 1
fi

# --- Locate tools ---

# wasmtime
WASMTIME_BIN=""
if WASMTIME_BIN="$("$SCRIPT_DIR/wasmtime_bin.sh" 2>/dev/null)"; then
  : # found
else
  echo "error: wasmtime not found" >&2
  echo "install: curl https://wasmtime.dev/install.sh -sSf | bash" >&2
  exit 1
fi

# Check wasmtime P3 support
if ! "$WASMTIME_BIN" serve --help 2>&1 | grep -qi "p3\|preview3\|Sp3"; then
  WASMTIME_VERSION=$("$WASMTIME_BIN" --version 2>/dev/null || echo "unknown")
  echo "warning: wasmtime ($WASMTIME_VERSION) may not support WASI P3" >&2
  echo "warning: P3 requires wasmtime v42+ with -Sp3 flag" >&2
  echo "warning: attempting serve anyway..." >&2
fi

# vibe CLI
VIBE="${VIBE:-}"
if [ -z "$VIBE" ]; then
  if [ -x "$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe" ]; then
    VIBE="$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe"
  elif command -v moon >/dev/null 2>&1; then
    VIBE="moon run --target native $PROJECT_ROOT/src/cmd/vibe --"
  else
    echo "error: vibe CLI not found" >&2
    echo "build with: moon build --target native --release src/cmd/vibe" >&2
    exit 1
  fi
fi

# --- Build adapter if needed ---

mkdir -p "$CACHE_DIR"

if [ -z "$ADAPTER" ]; then
  ADAPTER="$CACHE_DIR/vibe_http_p3_combined_adapter.component.wasm"
fi

if [ ! -f "$ADAPTER" ]; then
  echo "[serve] building P3 adapter (first time, may take a minute)..."
  if [ -x "$SCRIPT_DIR/build_wasi_http_p3_combined_adapter.sh" ]; then
    "$SCRIPT_DIR/build_wasi_http_p3_combined_adapter.sh" "$ADAPTER" 2>&1 | tail -1
  else
    echo "error: adapter build script not found and no pre-built adapter" >&2
    echo "provide one with --adapter <path>" >&2
    exit 1
  fi
fi

# --- Compile and compose ---

TEMP_COMPONENT=""
COMPONENT=""

if [ -n "$OUTPUT" ]; then
  COMPONENT="$OUTPUT"
else
  TEMP_COMPONENT="$(mktemp /tmp/vibe_serve_XXXXXX.component.wasm)"
  COMPONENT="$TEMP_COMPONENT"
fi

TEMP_PLUG="$(mktemp /tmp/vibe_serve_plug_XXXXXX.wasm)"

cleanup() {
  if [ -n "$TEMP_COMPONENT" ] && [ -f "$TEMP_COMPONENT" ]; then
    rm -f "$TEMP_COMPONENT"
  fi
  rm -f "$TEMP_PLUG"
}
trap cleanup EXIT

if ! command -v wac >/dev/null 2>&1; then
  echo "error: wac not found" >&2
  echo "install: cargo install wac-cli" >&2
  exit 1
fi

# Compile the handler to a sync component, then compose with the adapter via
# wac. See issue #267: the built-in `vibe compile --compose-p3` mode uses the
# mwac plug_components routine which does not forward component type
# definitions referenced by the socket's imports and produces an invalid
# component for non-trivial adapters.
echo "[serve] compiling $INPUT..."
$VIBE compile --component-string-lift "$INPUT" -o "$TEMP_PLUG" 2>/dev/null
wac plug --plug "$TEMP_PLUG" -o "$COMPONENT" "$ADAPTER"

if [ "$VALIDATE" = "1" ] && command -v wasm-tools >/dev/null 2>&1; then
  if ! wasm-tools validate --features all "$COMPONENT" 2>/dev/null; then
    echo "warning: component validation failed (continuing anyway)" >&2
  fi
fi

# --- Serve ---

LISTEN="${ADDR}:${PORT}"
echo "[serve] starting HTTP server on http://${LISTEN}"
echo "[serve] press Ctrl+C to stop"
echo ""

exec "$WASMTIME_BIN" serve \
  -Sp3 \
  -W component-model-async=y \
  -W component-model-async-builtins=y \
  --addr "$LISTEN" \
  "$COMPONENT"
