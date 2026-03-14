#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="${VIBE_BIN:-$ROOT_DIR/_build/native/release/build/cmd/vibe/vibe.exe}"
WASMTIME_BIN="${WASMTIME_BIN:-$("$ROOT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$ROOT_DIR/scripts/wasmtime_run.sh"
BENCH_BIN="$ROOT_DIR/tools/wasmtime_bench/target/release/wasmtime_bench"
OUT_DIR="$ROOT_DIR/_build/bench/wasmtime-overhead"
SRC_PATH="${1:-$OUT_DIR/min_run.vibe}"
WASM_PATH="$OUT_DIR/$(basename "${SRC_PATH%.vibe}").wasm"
COUNT="${VIBE_WASMTIME_BENCH_COUNT:-100000}"
WARMUP="${VIBE_WASMTIME_BENCH_WARMUP:-1000}"
RUNS="${VIBE_WASMTIME_BENCH_RUNS:-10}"

mkdir -p "$OUT_DIR"

if [ ! -x "$CLI_BIN" ]; then
  echo "missing vibe binary: $CLI_BIN" >&2
  echo "build with: moon build --target native --release src/cmd/vibe" >&2
  exit 1
fi

if [ ! -f "$SRC_PATH" ]; then
  cat >"$SRC_PATH" <<'EOF'
0
EOF
fi

cargo build --release --manifest-path "$ROOT_DIR/tools/wasmtime_bench/Cargo.toml" >/dev/null

"$CLI_BIN" compile --wasm -o "$WASM_PATH" "$SRC_PATH" >/dev/null

echo "[wasmtime-cli one-shot]"
if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 3 --runs "$RUNS" \
    "WASMTIME_BIN=\"$WASMTIME_BIN\" \"$WASMTIME_RUN\" --invoke run \"$WASM_PATH\" >/dev/null"
else
  /usr/bin/time -p env WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke run "$WASM_PATH" >/dev/null
fi

echo
echo "[wasmtime resident phases]"
"$BENCH_BIN" "$WASM_PATH" --n "$COUNT" --warmup "$WARMUP"
