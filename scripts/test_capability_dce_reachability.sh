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
let run: () -> Int with Async = () -> { 42 }
VIBE
cat >"$out_dir/live_stream.vibe" <<'VIBE'
fn read_stream() -> Int with Async {
  host_stream_next(host_stream_named("left"))
}
let run: () -> Int with Async = () -> { read_stream() }
VIBE
cat >"$out_dir/live_future.vibe" <<'VIBE'
fn read_future() -> Int with Async {
  await(host_future_named("price"))
}
let run: () -> Int with Async = () -> { read_future() }
VIBE

for case_name in dead live_stream live_future; do
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
  wasm-tools print "$out" >"$out_dir/$case_name.wat"
done

if rg -q '\(import "vibe" "(host_stream|host_future)' "$out_dir/dead.wat"; then
  echo "[capability-dce] FAIL: unreachable helpers retained host imports" >&2
  rg '\(import "vibe" "(host_stream|host_future)' "$out_dir/dead.wat" >&2
  exit 1
fi
if ! rg -q '\(import "vibe" "host_stream_get\$left"' "$out_dir/live_stream.wat" ||
   ! rg -q '\(import "vibe" "host_stream_read"' "$out_dir/live_stream.wat"; then
  echo "[capability-dce] FAIL: reachable stream read lost its host imports" >&2
  exit 1
fi
if ! rg -q '\(import "vibe" "host_future_get\$price"' "$out_dir/live_future.wat" ||
   ! rg -q '\(import "vibe" "host_future_wait"' "$out_dir/live_future.wat"; then
  echo "[capability-dce] FAIL: reachable future await lost its host imports" >&2
  exit 1
fi
echo "[capability-dce] reachable imports kept; dead imports removed"
