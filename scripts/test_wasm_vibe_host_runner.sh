#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/test/wasm_vibe_host_runner"
VIBE_EXE="${PROJECT_ROOT}/_build/native/release/build/cmd/vibe/vibe.exe"
RUNNER="${PROJECT_ROOT}/scripts/run_wasm_vibe_host_runner.sh"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.vibe "$OUT_DIR"/*.wasm "$OUT_DIR"/input.txt

compile_and_run() {
  local name="$1"
  local source="$2"
  local invoke_name="$3"
  shift 3
  local src_path="$OUT_DIR/${name}.vibe"
  local wasm_path="$OUT_DIR/${name}.wasm"
  printf '%s\n' "$source" >"$src_path"
  "$VIBE_EXE" compile --wasm --force-cabi-realloc "$src_path" -o "$wasm_path" >/dev/null
  bash "$RUNNER" --invoke "$invoke_name" "$wasm_path" "$@" | grep -E '^-?[0-9]+$' | tail -n 1
}

env_result="$(
  FOO=abc compile_and_run env_get \
    'export let probe = () -> Int with { Env } { String::length(Env::get("FOO")) }' \
    probe
)"
if [ "$env_result" != "3" ]; then
  echo "env_get failed: expected 3, got '$env_result'" >&2
  exit 1
fi

args_result="$(
  compile_and_run args_get \
    'export let probe = () -> Int with { Env } { if Env::args_len() > 0 { String::length(Env::args_get(0)) } else { 0 } }' \
    probe \
    abc
)"
if [ "$args_result" != "3" ]; then
  echo "args_get failed: expected 3, got '$args_result'" >&2
  exit 1
fi

printf 'hello' >"$OUT_DIR/input.txt"
fs_result="$(
  cd "$OUT_DIR"
  compile_and_run fs_read \
    'export let probe = () -> Int with { Error, Fs } { String::length(Fs::read_file("input.txt")) }' \
    probe
)"
if [ "$fs_result" != "5" ]; then
  echo "fs_read_file failed: expected 5, got '$fs_result'" >&2
  exit 1
fi

echo "wasm vibe host runner test passed"
