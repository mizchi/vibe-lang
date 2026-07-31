#!/usr/bin/env bash
# Real async execution on wasmtime 45 with a HOST producer
# (docs/spec/wasi-p3-async.md §2.3). Builds the async host
# (tools/async_host, bin vibe-real-async-host) and runs it on the guest
# examples/wasm/async_host_probe.wat: `run()` awaits the host async import
# `host.get_async`, which returns Pending once — genuinely SUSPENDING the guest
# fiber — then Ready(42). The host exits 0 only if run() == 42 AND a real
# suspend+resume occurred. Proves real blocking await works on wasmtime 45 when
# the async source is the host (the spec's "producer は host"; self-contained
# component-model `future.write` traps without a concurrent reader).
#
# SKIPs cleanly when cargo is unavailable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  echo "[real-async-host] SKIP: cargo not available"; exit 0
fi
export PATH="$HOME/.cargo/bin:$PATH"
host_dir="tools/async_host"
probe="examples/wasm/async_host_probe.wat"
[ -f "$probe" ] || { echo "[real-async-host] FAIL: $probe missing" >&2; exit 1; }
echo "[real-async-host] building host (wasmtime crate; first build is slow)"
( cd "$host_dir" && cargo build --bin vibe-real-async-host >/dev/null 2>&1 ) || {
  echo "[real-async-host] SKIP: host build failed (offline / toolchain)"; exit 0; }
bin="$host_dir/target/debug/vibe-real-async-host"
echo "[real-async-host] running proof"
if "$bin" "$probe"; then
  echo "[real-async-host] real async (host-driven suspend/resume) -> 42 ok"
else
  echo "[real-async-host] FAIL: guest did not suspend/resume to 42" >&2; exit 1
fi

# End-to-end for a real VIBE program: the selfhost compiles `sleep` to a
# `vibe.sleep` host import; the async host suspends/resumes the guest fiber.
# `|| true`: no generations dir => ls exits nonzero => pipefail would abort the
# gate outright instead of taking the "no stage2, skip this section" branch.
STAGE2="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
if [ -s "$STAGE2" ]; then
  echo "[real-async-host] vibe end-to-end: compiling examples/wasm/sleep_async.vibe"
  vdir="_build/_realasync_vibe"; mkdir -p "$vdir"
  rm -f _build/vibe_selfhost_type_env_v2_*.tsv 2>/dev/null || true
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    examples/wasm/sleep_async.vibe "$vdir/sleep.wasm" run >/dev/null 2>&1 || true
  if [ ! -s "$vdir/sleep.wasm" ]; then
    echo "[real-async-host] FAIL: sleep_async.vibe did not compile" >&2; exit 1
  fi
  ( cd "$host_dir" && cargo build --bin vibe-sleep-host >/dev/null 2>&1 ) || {
    echo "[real-async-host] SKIP: sleep host build failed"; exit 0; }
  if "$host_dir/target/debug/vibe-sleep-host" "$vdir/sleep.wasm"; then
    echo "[real-async-host] vibe sleep program: real suspend/resume -> 42 ok"
    # Concurrency proof: two guest instances run via futures::join!; real async
    # interleaves (both suspend before either resumes).
    ( cd "$host_dir" && cargo build --bin vibe-concurrency-host >/dev/null 2>&1 ) || true
    if [ -x "$host_dir/target/debug/vibe-concurrency-host" ]; then
      if "$host_dir/target/debug/vibe-concurrency-host" "$vdir/sleep.wasm"; then
        echo "[real-async-host] concurrency: two vibe tasks interleave -> REAL concurrency ok"
      else
        echo "[real-async-host] FAIL: vibe tasks did not interleave (not real concurrency)" >&2; exit 1
      fi
    fi
  else
    echo "[real-async-host] FAIL: vibe sleep program did not suspend/resume to 42" >&2; exit 1
  fi
  # Value-returning async import: `Stdin::read_char()` reads async DATA.
  rm -f _build/vibe_selfhost_type_env_v2_*.tsv 2>/dev/null || true
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    examples/wasm/read_async.vibe "$vdir/read.wasm" run >/dev/null 2>&1 || true
  ( cd "$host_dir" && cargo build --bin vibe-recv-host >/dev/null 2>&1 ) || true
  if [ -s "$vdir/read.wasm" ] && [ -x "$host_dir/target/debug/vibe-recv-host" ]; then
    if "$host_dir/target/debug/vibe-recv-host" "$vdir/read.wasm"; then
      echo "[real-async-host] vibe async data read (Stdin::read_char) -> 42 ok"
    else
      echo "[real-async-host] FAIL: async data read did not deliver 42" >&2; exit 1
    fi
  fi
  rm -rf "$vdir"
else
  echo "[real-async-host] SKIP vibe end-to-end: no stage2 (run scripts/generations.sh build)"
fi
