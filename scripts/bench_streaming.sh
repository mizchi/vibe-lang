#!/usr/bin/env bash
set -euo pipefail

# Streaming / ByteStream micro-benchmark (docs/spec/wasi-p3-async.md §M2c).
#
# The streaming builtins (String::to_bytes / Stream::map / Stream::filter /
# Stream::to_string / `for await`) live only in the selfhost compiler, so the
# host `vibe bench` path cannot compile them. Instead we:
#
#   1. build a stage1 selfhost compiler core wasm (stage0 = MoonBit host),
#   2. for each op, generate a `run : () -> Int` that applies the op ITER times
#      over a SIZE-byte ByteStream and returns a checksum (defeats DCE),
#   3. compile each program via stage1 to a core wasm module,
#   4. time the wasmtime run (hyperfine if available, else /usr/bin/time).
#
# Env knobs: BENCH_SIZE_CHUNKS (32-byte chunks, default 128 => 4096 B),
# BENCH_ITERS (pipeline repetitions per run, default 200), BENCH_RUNS (timed
# runs without hyperfine, default 10), BENCH_OPS (space-separated subset).
# Skips cleanly when wasmtime / node / wasm host runner are unavailable.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/_build/bench/streaming"
ENTRY_PATH="$PROJECT_ROOT/vibe/compiler/index.vibe"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_ASYNC_STAGE_TIMEOUT_SEC:-600}"
SIZE_CHUNKS="${BENCH_SIZE_CHUNKS:-128}"
ITERS="${BENCH_ITERS:-200}"
RUNS="${BENCH_RUNS:-10}"
OPS="${BENCH_OPS:-to_bytes map filter to_string for_await pipeline}"

HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

run_with_timeout() {
  local t="$1"; shift
  if [ "$t" -le 0 ]; then "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"; return $?; fi
  "$@"
}

# --- preconditions ---
if ! command -v node >/dev/null 2>&1; then echo "[bench-stream] SKIP: node not found"; exit 0; fi
if [ ! -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]; then
  echo "[bench-stream] SKIP: wasm host runner not found"; exit 0
fi
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[bench-stream] SKIP: wasmtime not found"; exit 0
fi
echo "[bench-stream] wasmtime: $($WASMTIME_BIN --version)"
echo "[bench-stream] config: size=$((SIZE_CHUNKS*32))B iters=$ITERS runs=$RUNS"

WASM_RUN_FLAGS=(-W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

if [ -x "$HOST_VIBE_EXE" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE_DEBUG" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

mkdir -p "$OUT_DIR"

echo "[bench-stream] stage0 -> stage1 selfhost compiler core wasm"
run_with_timeout "$STAGE_TIMEOUT_SEC" "${HOST_COMPILE[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM" >/dev/null

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"
compile_via_stage1() {
  local in="$1" out="$2"
  run_with_timeout "$STAGE_TIMEOUT_SEC" \
    env VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke selfbuild_cli_args_entry "$STAGE1_CORE_WASM" \
        "${in#$PROJECT_ROOT/}" "${out#$PROJECT_ROOT/}" run >/dev/null
}

# Emit the body of `run` for a given op. `make_input` builds the SIZE-byte
# string once; the ITER loop applies the op and folds a checksum into `acc`.
emit_program() {
  local op="$1" file="$2"
  {
    printf 'let make_input: (Int) -> String = (chunks) -> {\n'
    printf '  let mut s = ""\n'
    printf '  let mut i = 0\n'
    printf '  while i < chunks {\n'
    printf '    s = String::concat(s, "abcdefghijklmnopqrstuvwxyzABCDEF")\n'
    printf '    i = i + 1\n'
    printf '  }\n'
    printf '  s\n'
    printf '}\n'
    printf 'let run: () -> Int = () -> {\n'
    printf '  let input = make_input(%s)\n' "$SIZE_CHUNKS"
    printf '  let mut acc = 0\n'
    printf '  let mut it = 0\n'
    printf '  while it < %s {\n' "$ITERS"
    case "$op" in
      to_bytes)
        printf '    let bs = String::to_bytes(input)\n'
        printf '    acc = acc + Array::length(bs)\n' ;;
      map)
        printf '    let bs = String::to_bytes(input)\n'
        printf '    let m = Stream::map(bs, (b) -> { b + 1 })\n'
        printf '    acc = acc + Array::length(m)\n' ;;
      filter)
        printf '    let bs = String::to_bytes(input)\n'
        printf '    let f = Stream::filter(bs, (b) -> { b > 96 })\n'
        printf '    acc = acc + Array::length(f)\n' ;;
      to_string)
        printf '    let bs = String::to_bytes(input)\n'
        printf '    let s = Stream::to_string(bs)\n'
        printf '    acc = acc + String::length(s)\n' ;;
      for_await)
        printf '    let bytes = String::to_bytes(input)\n'
        printf '    let len = Array::length(bytes)\n'
        printf '    let mut i = 0\n'
        printf '    let next = () -> {\n'
        printf '      if i < len {\n'
        printf '        let b = Array::get(bytes, i)\n'
        printf '        i = i + 1\n'
        printf '        Some(b)\n'
        printf '      } else {\n'
        printf '        None\n'
        printf '      }\n'
        printf '    }\n'
        printf '    let mut total = 0\n'
        printf '    for await b in next {\n'
        printf '      total = total + b\n'
        printf '    }\n'
        printf '    acc = acc + total\n' ;;
      pipeline)
        printf '    let bs = String::to_bytes(input)\n'
        printf '    let m = Stream::map(bs, (b) -> { b + 1 })\n'
        printf '    let f = Stream::filter(m, (b) -> { b > 96 })\n'
        printf '    let s = Stream::to_string(f)\n'
        printf '    acc = acc + String::length(s)\n' ;;
      *) echo "[bench-stream] unknown op: $op" >&2; exit 1 ;;
    esac
    printf '    it = it + 1\n'
    printf '  }\n'
    printf '  acc\n'
    printf '}\n'
  } > "$file"
}

time_run() {
  local out="$1"
  if command -v hyperfine >/dev/null 2>&1; then
    hyperfine --warmup 2 --runs "$RUNS" -N \
      "\"$WASMTIME_BIN\" run ${WASM_RUN_FLAGS[*]} --invoke _start \"$out\"" 2>/dev/null \
      | sed -n 's/^  Time (mean.*:  *\(.*\)/    \1/p'
  else
    local best="" t
    local tmp; tmp="$(mktemp)"
    for _ in $(seq 1 "$RUNS"); do
      /usr/bin/env bash -c "TIMEFORMAT='%R'; time \"$WASMTIME_BIN\" run ${WASM_RUN_FLAGS[*]} --invoke _start \"$out\" >/dev/null" 2>"$tmp"
      t="$(tr -d ' \n' < "$tmp")"
      if [ -z "$best" ] || awk "BEGIN{exit !($t < $best)}"; then best="$t"; fi
    done
    rm -f "$tmp"
    printf '    min %ss over %s runs\n' "$best" "$RUNS"
  fi
}

for op in $OPS; do
  prog="$OUT_DIR/${op}_input.vibe"
  wasm="$OUT_DIR/${op}.wasm"
  emit_program "$op" "$prog"
  compile_via_stage1 "$prog" "$wasm"
  result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke _start "$wasm" 2>&1 | grep -E '^-?[0-9]+$' | tail -n1 || true)"
  echo "[bench-stream] $op (checksum=$result):"
  time_run "$wasm"
done

echo "[bench-stream] done"
