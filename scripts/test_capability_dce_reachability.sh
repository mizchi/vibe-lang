#!/usr/bin/env bash
# #3193: host imports follow reachable definitions in the executable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
stage2_wasm="${VIBE_STAGE2_WASM:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
out_dir="$ROOT_DIR/_build/_gate_capability_dce"
rm -rf "$out_dir"
mkdir -p "$out_dir"
trap 'rm -rf "$out_dir"' EXIT

cat >"$out_dir/dead.vibe" <<'VIBE'
fn dead_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
fn dead_future() -> Int with Async {
  await(host_future_named("price"))
}
let unused_alias = dead_stream
let run: () -> Int with Async = () -> { 42 }
VIBE
cat >"$out_dir/live_stream.vibe" <<'VIBE'
fn read_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
let run: () -> Int with Async = () -> { read_stream() }
VIBE
cat >"$out_dir/dead_wat.vibe" <<'VIBE'
fn dead_wat_callee() -> Int = wasm"(i64.const 84)"
fn dead_wat() -> Int = wasm"(call $dead_wat_callee)"
let run: () -> Int = () -> { 42 }
VIBE
cat >"$out_dir/baseline.vibe" <<'VIBE'
let run: () -> Int = () -> { 42 }
VIBE
cat >"$out_dir/iterator_import.vibe" <<'VIBE'
import @vibe/builtin { trait Iterator }
fn dead_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
let run: () -> Int with Async = () -> { 42 }
VIBE
cat >"$out_dir/provider.vibe" <<'VIBE'
export fn answer() -> Int { 42 }
VIBE
cat >"$out_dir/facade.vibe" <<'VIBE'
export ./provider.vibe { answer as choose }
VIBE
cat >"$out_dir/reexport_chain.vibe" <<'VIBE'
import ./facade.vibe { choose }
fn dead_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
let run: () -> Int with Async = () -> { choose() }
VIBE
cat >"$out_dir/contract.vibe" <<'VIBE'
fn dead_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
fn checked(dead_stream: Int) -> Int where {
  requires: dead_stream > 0,
  ensures: result > 0,
} { dead_stream }
let run: () -> Int = () -> { checked(42) }
VIBE
cat >"$out_dir/dead_export.vibe" <<'VIBE'
export fn dead_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
let run: () -> Int with Async = () -> { 42 }
VIBE
cat >"$out_dir/live_wat.vibe" <<'VIBE'
fn helper() -> Int = wasm"(i64.const 84)"
fn middle() -> Int = wasm"(call $helper)"
fn via_wat() -> Int = wasm"(call $middle)"
let run: () -> Int = () -> { via_wat() }
VIBE
cat >"$out_dir/live_future.vibe" <<'VIBE'
fn read_future() -> Int with Async {
  await(host_future_named("price"))
}
let run: () -> Int with Async = () -> { read_future() }
VIBE

for case_name in dead dead_wat baseline iterator_import reexport_chain contract dead_export live_stream live_wat live_future; do
  out="$out_dir/$case_name.wasm"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$out_dir/$case_name.vibe" "$out" run >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[capability-dce] FAIL: $case_name did not compile" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# The generated flat-source lane serializes each source boundary as a reserved
# import. Compile it as trusted compiler output to exercise that carrier.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_EMIT_MERGED_SOURCE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$out_dir/reexport_chain.vibe" "$out_dir/flat_chain.vibe" run >/dev/null
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$out_dir/flat_chain.vibe" "$out_dir/flat_chain.wasm" run >/dev/null
if [ ! -s "$out_dir/flat_chain.wasm" ]; then
  echo "[capability-dce] FAIL: trusted flat re-export chain did not compile" >&2
  cat "$out_dir/flat_chain.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

node - "$out_dir" <<'NODE'
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const dir = process.argv[2];
function readLeb(bytes, position) {
  let value = 0;
  let shift = 0;
  let byte;
  do {
    byte = bytes[position.index++];
    value += (byte & 0x7f) * 2 ** shift;
    shift += 7;
  } while (byte & 0x80);
  return value;
}
function coreModules(bytes) {
  const version = bytes.readUInt32LE(4);
  if (version === 1) return [new WebAssembly.Module(bytes)];
  if (version !== 0x0001000d) throw new Error(`unexpected wasm version: ${version}`);
  const result = [];
  const position = { index: 8 };
  while (position.index < bytes.length) {
    const section = readLeb(bytes, position);
    const length = readLeb(bytes, position);
    const end = position.index + length;
    if (section === 1) result.push(new WebAssembly.Module(bytes.subarray(position.index, end)));
    position.index = end;
  }
  return result;
}
function definedFunctions(bytes) {
  const position = { index: 8 };
  while (position.index < bytes.length) {
    const section = readLeb(bytes, position);
    const length = readLeb(bytes, position);
    const end = position.index + length;
    if (section === 3) return readLeb(bytes, position);
    position.index = end;
  }
  return 0;
}
function imports(name) {
  return coreModules(readFileSync(join(dir, `${name}.wasm`)))
    .flatMap((module) => WebAssembly.Module.imports(module))
    .filter((entry) => entry.module === 'vibe')
    .map((entry) => entry.name);
}
if (definedFunctions(readFileSync(join(dir, 'dead_wat.wasm'))) !==
    definedFunctions(readFileSync(join(dir, 'baseline.wasm')))) {
  console.error('[capability-dce] FAIL: an unreachable WAT callee survived');
  process.exit(1);
}
for (const name of ['dead', 'dead_wat', 'iterator_import', 'reexport_chain', 'flat_chain', 'contract', 'dead_export']) {
  const leaked = imports(name).filter((entry) => entry.startsWith('host_stream') || entry.startsWith('host_future'));
  if (leaked.length > 0) {
    console.error(`[capability-dce] FAIL: ${name} retained ${leaked.join(', ')}`);
    process.exit(1);
  }
}
for (const [name, expected] of [
  ['live_stream', ['host_stream_get$left', 'host_stream_read']],
  ['live_future', ['host_future_get$price', 'host_future_wait']],
]) {
  const actual = imports(name);
  for (const entry of expected) {
    if (!actual.includes(entry)) {
      console.error(`[capability-dce] FAIL: ${name} lost ${entry}; found ${actual.join(', ')}`);
      process.exit(1);
    }
  }
}
NODE
wat_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke run "$out_dir/live_wat.wasm" 2>&1 | tail -1)"
if [ "$wat_result" != 42 ]; then
  echo "[capability-dce] FAIL: reachable inline WAT callee returned '$wat_result' (want 42)" >&2
  exit 1
fi
reexport_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke run "$out_dir/reexport_chain.wasm" 2>&1 | tail -1)"
if [ "$reexport_result" != 42 ]; then
  echo "[capability-dce] FAIL: reachable re-export returned '$reexport_result' (want 42)" >&2
  exit 1
fi
contract_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke run "$out_dir/contract.wasm" 2>&1 | tail -1)"
if [ "$contract_result" != 42 ]; then
  echo "[capability-dce] FAIL: reachable contract returned '$contract_result' (want 42)" >&2
  exit 1
fi
echo "[capability-dce] reachable imports kept; dead imports removed"
