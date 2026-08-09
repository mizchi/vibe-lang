#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
if [ ! -x "$RT" ] || [ -n "$(find runtime/viberun/src -name '*.rs' -newer "$RT" 2>/dev/null | head -1)" ]; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "bench-http: no CLI wasm built" >&2; exit 1; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
bash scripts/install.sh --cli-wasm "$cli" >/dev/null
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "bench-http: launcher not installed" >&2; exit 1; }

REQUESTED_PORT="${VIBE_HTTP_ECHO_PORT:-0}"
SERVER_LOG="$WORK/http_echo.log"
python3 tests/http_echo_server.py "$REQUESTED_PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  PORT="$(sed -n 's/^HTTP echo server listening on 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$SERVER_LOG" | head -1)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "bench-http: echo server failed to start (requested port $REQUESTED_PORT)" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
fi
export VIBE_HTTP_ECHO_PORT="$PORT"

ITERS="${VIBE_BENCH_HTTP_N:-50}"
WARMUP="${VIBE_BENCH_HTTP_WARMUP:-5}"
echo "bench-http: local echo server: 127.0.0.1:$PORT"
echo "bench-http: compiled client benchmarks (iters=$ITERS, warmup=$WARMUP)"
"$VIBE" bench "$ROOT_DIR/bench/http_bench.vibe" --iters "$ITERS" --warmup "$WARMUP"
