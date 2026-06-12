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
  local output
  local raw_result
  printf '%s\n' "$source" >"$src_path"
  "$VIBE_EXE" compile --wasm --force-cabi-realloc "$src_path" -o "$wasm_path" >/dev/null
  output="$(bash "$RUNNER" --invoke "$invoke_name" "$wasm_path" "$@")"
  raw_result="$(printf '%s\n' "$output" | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
  if [ -z "$raw_result" ]; then
    raw_result="$(printf '%s' "$output" | sed -n 's/.*[^0-9-]\(-\{0,1\}[0-9][0-9]*\)$/\1/p')"
  fi
  if [ -z "$raw_result" ]; then
    echo "no numeric result in output: $output" >&2
    return 1
  fi
  if [ $((raw_result % 4)) -eq 0 ]; then
    echo $((raw_result / 4))
  else
    echo "$raw_result"
  fi
}

write_raw_abi_probe_wasm() {
  node - "$OUT_DIR/raw_abi_probe.wasm" <<'NODE'
const fs = require("node:fs");

function uleb(value) {
  const out = [];
  let n = value >>> 0;
  do {
    let byte = n & 0x7f;
    n >>>= 7;
    if (n !== 0) byte |= 0x80;
    out.push(byte);
  } while (n !== 0);
  return out;
}

function str(value) {
  const bytes = Buffer.from(value, "utf8");
  return [...uleb(bytes.length), ...bytes];
}

function section(id, content) {
  return [id, ...uleb(content.length), ...content];
}

const customPayload = Buffer.from("version=1\nhost_import_abi=raw\n", "utf8");
const body = [
  0x00,
  0x42, 0x03,
  0x10, 0x00,
  0xa7,
  0xac,
  0x0b,
];
const data = Buffer.from("FOO", "utf8");
const bytes = [
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  ...section(0, [...str("vibe.abi"), ...customPayload]),
  ...section(1, [
    ...uleb(2),
    0x60, ...uleb(1), 0x7e, ...uleb(1), 0x7e,
    0x60, ...uleb(0), ...uleb(1), 0x7e,
  ]),
  ...section(2, [
    ...uleb(1),
    ...str("vibe"),
    ...str("env-get"),
    0x00, ...uleb(0),
  ]),
  ...section(3, [...uleb(1), ...uleb(1)]),
  ...section(5, [...uleb(1), 0x00, ...uleb(1)]),
  ...section(7, [
    ...uleb(2),
    ...str("memory"), 0x02, ...uleb(0),
    ...str("probe"), 0x00, ...uleb(1),
  ]),
  ...section(10, [...uleb(1), ...uleb(body.length), ...body]),
  ...section(11, [
    ...uleb(1),
    0x00,
    0x41, 0x00, 0x0b,
    ...uleb(data.length),
    ...data,
  ]),
];

fs.writeFileSync(process.argv[2], Buffer.from(bytes));
NODE
}

write_cli_main_status_wasm() {
  node - "$OUT_DIR/cli_main_status.wasm" <<'NODE'
const fs = require("node:fs");

function uleb(value) {
  const out = [];
  let n = value >>> 0;
  do {
    let byte = n & 0x7f;
    n >>>= 7;
    if (n !== 0) byte |= 0x80;
    out.push(byte);
  } while (n !== 0);
  return out;
}

function str(value) {
  const bytes = Buffer.from(value, "utf8");
  return [...uleb(bytes.length), ...bytes];
}

function section(id, content) {
  return [id, ...uleb(content.length), ...content];
}

const customPayload = Buffer.from("version=1\nhost_import_abi=raw\n", "utf8");
const body = [0x00, 0x42, 0x04, 0x0b];
const bytes = [
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  ...section(0, [...str("vibe.abi"), ...customPayload]),
  ...section(1, [
    ...uleb(1),
    0x60, ...uleb(0), ...uleb(1), 0x7e,
  ]),
  ...section(3, [...uleb(1), ...uleb(0)]),
  ...section(7, [
    ...uleb(1),
    ...str("cli_main"), 0x00, ...uleb(0),
  ]),
  ...section(10, [...uleb(1), ...uleb(body.length), ...body]),
];

fs.writeFileSync(process.argv[2], Buffer.from(bytes));
NODE
}

write_raw_abi_probe_wasm
raw_abi_result="$(
  FOO=abc bash "$RUNNER" --invoke probe "$OUT_DIR/raw_abi_probe.wasm" | grep -E '^-?[0-9]+$' | tail -n 1
)"
if [ "$raw_abi_result" != "3" ]; then
  echo "raw ABI custom section failed: expected 3, got '$raw_abi_result'" >&2
  exit 1
fi

tagged_override_result="$(
  FOO=abc VIBE_SELFHOST_IMPORT_ABI=tagged bash "$RUNNER" --invoke probe "$OUT_DIR/raw_abi_probe.wasm" | grep -E '^-?[0-9]+$' | tail -n 1
)"
if [ "$tagged_override_result" = "3" ]; then
  echo "raw ABI custom section should not override explicit tagged env" >&2
  exit 1
fi

write_cli_main_status_wasm
set +e
cli_main_status_output="$(bash "$RUNNER" --invoke cli_main "$OUT_DIR/cli_main_status.wasm" 2>&1)"
cli_main_status=$?
set -e
if [ "$cli_main_status" -ne 1 ]; then
  echo "cli_main exit status failed: expected 1, got $cli_main_status output='$cli_main_status_output'" >&2
  exit 1
fi

env_result="$(
  FOO=abc compile_and_run env_get \
    'export let probe = () -> Int with { Env } { String::length(Env::get("FOO")) }' \
    probe
)"
if [ "$env_result" != "3" ]; then
  echo "env_get failed: expected 3, got '$env_result'" >&2
  exit 1
fi

heap_bump_env_result="$(
  FOO=abc VIBE_WASM_HOST_ALLOC_MODE=heap-bump compile_and_run env_get_heap_bump \
    'export let probe = () -> Int with { Env } { String::length(Env::get("FOO")) }' \
    probe
)"
if [ "$heap_bump_env_result" != "3" ]; then
  echo "heap-bump env_get failed: expected 3, got '$heap_bump_env_result'" >&2
  exit 1
fi

arena_env_result="$(
  FOO=abc VIBE_WASM_HOST_ALLOC_MODE=arena compile_and_run env_get_arena \
    'export let probe = () -> Int with { Env } { String::length(Env::get("FOO")) }' \
    probe
)"
if [ "$arena_env_result" != "3" ]; then
  echo "arena env_get failed: expected 3, got '$arena_env_result'" >&2
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

closure_env_result="$(
  FOO=abc compile_and_run closure_env \
    'let suffix = "x"

export let probe = () -> Int with { Env } {
  String::length(String::concat(suffix, Env::get("FOO")))
}' \
    probe
)"
if [ "$closure_env_result" != "4" ]; then
  echo "closure_env failed: expected 4, got '$closure_env_result'" >&2
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

preview2_stdout_result="$(
  cd "$OUT_DIR"
  compile_and_run preview2_stdout \
    'export let _start = () -> Int with { Error, Fs, Stdout } {
  let s = Fs::read_file("input.txt")
  Stdout::write_stream(s)
  String::length(s)
}' \
    _start
)"
if [ "$preview2_stdout_result" != "5" ]; then
  echo "preview2 stdout/fs failed: expected 5, got '$preview2_stdout_result'" >&2
  exit 1
fi

run_skip_init_result="$(
  cd "$OUT_DIR"
  VIBE_SKIP_RUN_INIT=1 compile_and_run fs_read_skip_init \
    'export let probe = () -> Int with { Error, Fs } { String::length(Fs::read_file("input.txt")) }' \
    probe
)"
if [ "$run_skip_init_result" != "5" ]; then
  echo "skip run init failed: expected 5, got '$run_skip_init_result'" >&2
  exit 1
fi

echo "wasm vibe host runner test passed"
