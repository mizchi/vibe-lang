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

PORT="${VIBE_HTTP_ECHO_PORT:-$((18280 + $(printf '%s' "$ROOT_DIR" | cksum | cut -d' ' -f1) % 1000))}"
export VIBE_HTTP_ECHO_PORT="$PORT"
python3 tests/http_echo_server.py "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "bench-http: echo server failed to start on 127.0.0.1:$PORT" >&2
  exit 1
fi

ITERS="${VIBE_BENCH_HTTP_N:-50}"
WARMUP="${VIBE_BENCH_HTTP_WARMUP:-5}"
echo "bench-http: local echo server: 127.0.0.1:$PORT"
echo "bench-http: compiled client benchmarks (iters=$ITERS, warmup=$WARMUP)"
"$VIBE" bench "$ROOT_DIR/bench/http_bench.vibe" --iters "$ITERS" --warmup "$WARMUP"
