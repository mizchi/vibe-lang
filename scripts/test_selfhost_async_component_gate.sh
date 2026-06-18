#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async component gate (docs/spec/wasi-p3-async.md, M1b/M1b-2).
#
# Codifies the end-to-end async vertical: a freshly built stage1 selfhost
# compiler compiles an async entry (`run : () -> Int with { Async }`) into an
# async-lifted WASM component, which wasmtime 45 then runs to a known result.
#
#   stage0 (MoonBit host) compiles vibe/compiler/index.vibe -> index_stage1.wasm
#   stage1 compiles the async input via selfbuild_cli_args_entry -> out.wasm
#   out.wasm must be a COMPONENT (magic 0d 00 01 00), validate, and return 42
#
# Also asserts the non-async control (`run : () -> Int`) stays a plain core
# module — i.e. the async wrapping does not leak into ordinary builds.
#
# Skips cleanly when wasmtime / wasm-tools / node are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_async_component"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_ASYNC_STAGE_TIMEOUT_SEC:-600}"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
ASYNC_INPUT="$OUT_DIR/async_input.vibe"
ASYNC_OUTPUT="$OUT_DIR/async_output.wasm"
TASK_INPUT="$OUT_DIR/task_input.vibe"
TASK_OUTPUT="$OUT_DIR/task_output.wasm"
STREAM_INPUT="$OUT_DIR/stream_input.vibe"
STREAM_OUTPUT="$OUT_DIR/stream_output.wasm"
OPTION_INPUT="$OUT_DIR/option_input.vibe"
OPTION_OUTPUT="$OUT_DIR/option_output.wasm"
BYTES_INPUT="$OUT_DIR/bytes_input.vibe"
BYTES_OUTPUT="$OUT_DIR/bytes_output.wasm"
STR_INPUT="$OUT_DIR/str_input.vibe"
STR_OUTPUT="$OUT_DIR/str_output.wasm"
ITER_INPUT="$OUT_DIR/iter_input.vibe"
ITER_OUTPUT="$OUT_DIR/iter_output.wasm"
PLAIN_INPUT="$OUT_DIR/plain_input.vibe"
PLAIN_OUTPUT="$OUT_DIR/plain_output.wasm"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"
EXPECTED="42"

WASM_RUN_FLAGS=(-W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

run_with_timeout() {
  local t="$1"; shift
  if [ "$t" -le 0 ]; then "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"; return $?; fi
  "$@"
}

magic8() { od -An -t x1 -N 8 "$1" | tr -d ' \n'; }

# --- preconditions (skip if tooling missing) ---
if ! command -v node >/dev/null 2>&1; then
  echo "[async-gate] SKIP: node not found"; exit 0
fi
if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "[async-gate] SKIP: wasm-tools not found"; exit 0
fi
if [ ! -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]; then
  echo "[async-gate] SKIP: wasm host runner not found"; exit 0
fi
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[async-gate] SKIP: wasmtime not found"; exit 0
fi
echo "[async-gate] wasmtime: $($WASMTIME_BIN --version)"

if [ -x "$HOST_VIBE_EXE" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE_DEBUG" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

mkdir -p "$OUT_DIR"
rm -f "$STAGE1_CORE_WASM" "$ASYNC_OUTPUT" "$TASK_OUTPUT" "$STREAM_OUTPUT" "$OPTION_OUTPUT" "$BYTES_OUTPUT" "$STR_OUTPUT" "$ITER_OUTPUT" "$PLAIN_OUTPUT"

echo "[async-gate] stage0 -> stage1 selfhost compiler core wasm"
run_with_timeout "$STAGE_TIMEOUT_SEC" "${HOST_COMPILE[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM"
if [ "$(magic8 "$STAGE1_CORE_WASM")" != "0061736d01000000" ]; then
  echo "[async-gate] FAIL: stage1 is not a core module" >&2; exit 1
fi

printf 'let run: () -> Int with { Async } = () -> { await(Future::ready(%s)) }\n' "$EXPECTED" > "$ASYNC_INPUT"
# Structured concurrency (docs/spec §2.5): spawn a thunk, join it, race against
# a cancelled task. Synchronous eager model must still resolve to EXPECTED.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let t = Task::spawn(() -> { %s })\n' "$EXPECTED"
  printf '  let other = Task::spawn(() -> { 0 })\n'
  printf '  let _ = Task::cancel(other)\n'
  printf '  Task::race(Task::spawn(() -> { Task::join(t) }), other)\n'
  printf '}\n'
} > "$TASK_INPUT"
# Stream[T] async iterator (docs/spec §2.4): empty/once/map/filter/fold over the
# eager Array-backed model must resolve to EXPECTED.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let base = await(Stream::fold(Stream::empty(), 21, (acc, x) -> { acc }))\n'
  printf '  let mapped = Stream::map(Stream::once(base), (x) -> { x + x })\n'
  printf '  let kept = Stream::filter(mapped, (x) -> { x > 0 })\n'
  printf '  await(Stream::fold(kept, 0, (acc, x) -> { acc + x }))\n'
  printf '}\n'
} > "$STREAM_INPUT"
# Option construction (docs/spec §2.4/§2.5): Stream::next (Some + None paths) and
# Task::timeout both build real Option ctors. Must resolve to EXPECTED.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let none_case = match await(Stream::next(Stream::empty())) {\n'
  printf '    Some(x) => 0,\n'
  printf '    None => 21\n'
  printf '  }\n'
  printf '  let some_case = match await(Stream::next(Stream::once(none_case))) {\n'
  printf '    Some(x) => x + x,\n'
  printf '    None => 0\n'
  printf '  }\n'
  printf '  match Task::timeout(1000, () -> { some_case }) {\n'
  printf '    Some(x) => x,\n'
  printf '    None => 0\n'
  printf '  }\n'
  printf '}\n'
} > "$OPTION_INPUT"
# HTTP body as ByteStream (docs/spec §2.4/§4.1): consume a "body" string as a
# Stream[Int] of bytes and process it with the Stream combinators. ")" = byte 41;
# map(+1) -> 42; filter(>0) keeps it; fold(sum) -> 42.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let body = ")"\n'
  printf '  let bytes = String::to_bytes(body)\n'
  printf '  let shifted = Stream::map(bytes, (b) -> { b + 1 })\n'
  printf '  let kept = Stream::filter(shifted, (b) -> { b > 0 })\n'
  printf '  await(Stream::fold(kept, 0, (acc, b) -> { acc + b }))\n'
  printf '}\n'
} > "$BYTES_INPUT"
# Response body production (docs/spec §M2c-2): transform a body ByteStream and
# collect it back to a String via Stream::to_string, then re-read it. ")" -> +1
# -> "*"; to_string round-trips; fold(sum) of "*" bytes -> 42.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let shifted = Stream::map(String::to_bytes(")"), (b) -> { b + 1 })\n'
  printf '  let echoed = Stream::to_string(shifted)\n'
  printf '  await(Stream::fold(String::to_bytes(echoed), 0, (acc, b) -> { acc + b }))\n'
  printf '}\n'
} > "$STR_INPUT"
# Async-iterator surface (docs/spec §M2c-3): `for await x in stream { ... }`
# consumes a ByteStream element-by-element. Sum the bytes of "ABC" (65+66+67 =
# 198), minus 156 -> 42.
{
  printf 'let run: () -> Int with { Async } = () -> {\n'
  printf '  let mut total = 0\n'
  printf '  for await b in String::to_bytes("ABC") {\n'
  printf '    total = total + b\n'
  printf '  }\n'
  printf '  total - 156\n'
  printf '}\n'
} > "$ITER_INPUT"
printf 'let run: () -> Int = () -> { %s }\n' "$EXPECTED" > "$PLAIN_INPUT"

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"
compile_via_stage1() {
  local in="$1" out="$2"
  run_with_timeout "$STAGE_TIMEOUT_SEC" \
    env VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke selfbuild_cli_args_entry "$STAGE1_CORE_WASM" \
        "${in#$PROJECT_ROOT/}" "${out#$PROJECT_ROOT/}" run >/dev/null
}

echo "[async-gate] stage1 compiles async entry"
compile_via_stage1 "$ASYNC_INPUT" "$ASYNC_OUTPUT"
echo "[async-gate] stage1 compiles structured-concurrency (Task) entry"
compile_via_stage1 "$TASK_INPUT" "$TASK_OUTPUT"
echo "[async-gate] stage1 compiles Stream[T] async-iterator entry"
compile_via_stage1 "$STREAM_INPUT" "$STREAM_OUTPUT"
echo "[async-gate] stage1 compiles Option-construction (Stream::next / Task::timeout) entry"
compile_via_stage1 "$OPTION_INPUT" "$OPTION_OUTPUT"
echo "[async-gate] stage1 compiles HTTP-body-as-ByteStream (String::to_bytes) entry"
compile_via_stage1 "$BYTES_INPUT" "$BYTES_OUTPUT"
echo "[async-gate] stage1 compiles ByteStream-to-String (Stream::to_string) entry"
compile_via_stage1 "$STR_INPUT" "$STR_OUTPUT"
echo "[async-gate] stage1 compiles for-await async-iterator entry"
compile_via_stage1 "$ITER_INPUT" "$ITER_OUTPUT"
echo "[async-gate] stage1 compiles non-async control entry"
compile_via_stage1 "$PLAIN_INPUT" "$PLAIN_OUTPUT"
unset VIBE_PREOPEN_DIR

# async output must be a component
if [ "$(magic8 "$ASYNC_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: async output is not a component (magic=$(magic8 "$ASYNC_OUTPUT"))" >&2; exit 1
fi
echo "[async-gate] async output is a component"

# non-async control must stay a plain core module (no async leakage)
if [ "$(magic8 "$PLAIN_OUTPUT")" != "0061736d01000000" ]; then
  echo "[async-gate] FAIL: non-async output is not a plain core module (magic=$(magic8 "$PLAIN_OUTPUT"))" >&2; exit 1
fi
echo "[async-gate] non-async control is a plain core module (no regression)"

wasm-tools validate --features all "$ASYNC_OUTPUT" >/dev/null
echo "[async-gate] async component validates"

# Task entry must also be an async-lifted component (it carries the Async effect)
if [ "$(magic8 "$TASK_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: task output is not a component (magic=$(magic8 "$TASK_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$TASK_OUTPUT" >/dev/null
echo "[async-gate] structured-concurrency (Task) component validates"

result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$ASYNC_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: async component returned '$result' (expected $EXPECTED)" >&2; exit 1
fi

task_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$TASK_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$task_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: Task component returned '$task_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] structured-concurrency (Task) component runs -> $task_result"

if [ "$(magic8 "$STREAM_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: stream output is not a component (magic=$(magic8 "$STREAM_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$STREAM_OUTPUT" >/dev/null
echo "[async-gate] Stream[T] async-iterator component validates"
stream_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$STREAM_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$stream_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: Stream component returned '$stream_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] Stream[T] async-iterator component runs -> $stream_result"

if [ "$(magic8 "$OPTION_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: option output is not a component (magic=$(magic8 "$OPTION_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$OPTION_OUTPUT" >/dev/null
echo "[async-gate] Option-construction component validates"
option_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$OPTION_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$option_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: Option component returned '$option_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] Option-construction (Stream::next / Task::timeout) component runs -> $option_result"

if [ "$(magic8 "$BYTES_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: bytes output is not a component (magic=$(magic8 "$BYTES_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$BYTES_OUTPUT" >/dev/null
echo "[async-gate] HTTP-body-as-ByteStream component validates"
bytes_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$BYTES_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$bytes_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: ByteStream component returned '$bytes_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] HTTP-body-as-ByteStream (String::to_bytes) component runs -> $bytes_result"

if [ "$(magic8 "$STR_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: str output is not a component (magic=$(magic8 "$STR_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$STR_OUTPUT" >/dev/null
echo "[async-gate] ByteStream-to-String component validates"
str_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$STR_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$str_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: to_string component returned '$str_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] ByteStream-to-String (Stream::to_string) component runs -> $str_result"

if [ "$(magic8 "$ITER_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: iter output is not a component (magic=$(magic8 "$ITER_OUTPUT"))" >&2; exit 1
fi
wasm-tools validate --features all "$ITER_OUTPUT" >/dev/null
echo "[async-gate] for-await async-iterator component validates"
iter_result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$ITER_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$iter_result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: for-await component returned '$iter_result' (expected $EXPECTED)" >&2; exit 1
fi
echo "[async-gate] for-await async-iterator (for await x in stream) component runs -> $iter_result"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async Component Gate"
    echo
    echo "- stage1 selfhost compiler compiled \`run : () -> Int with { Async }\` to an async-lifted component"
    echo "- component validated and ran on wasmtime, returning \`$EXPECTED\`"
    echo "- non-async control stayed a plain core module (no regression)"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[async-gate] PASS: selfhost async component runs on wasmtime ($result)"
