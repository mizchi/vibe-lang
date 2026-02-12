#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
OUT_DIR="$ROOT_DIR/target/bench"
SCRIPT_PATH="$OUT_DIR/bench_builder.vibe"
N="${VIBE_BUILDER_N:-200}"

mkdir -p "$OUT_DIR"
cat >"$SCRIPT_PATH" <<EOF_SCRIPT
let rec build = fn (n: Int, b: ArrayBuilder[Int]) -> ArrayBuilder[Int] {
  if eq(n, 0) {
    b
  } else {
    do {
      array_builder_push(b, n)
      build(sub(n, 1), b)
    }
  }
}

let result = do {
  let b = array_builder()
  let out = build($N, b)
  array_builder_freeze(out)
}
result
EOF_SCRIPT

moon build --target native --release src/cmd/vibe

RUN_CMD="$CLI_BIN run $SCRIPT_PATH >/dev/null"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 3 "$RUN_CMD"
else
  echo "hyperfine not found; using /usr/bin/time (10 runs)"
  for _ in $(seq 1 10); do
    /usr/bin/time -p $RUN_CMD
  done
fi
