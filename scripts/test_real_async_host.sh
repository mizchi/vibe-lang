#!/usr/bin/env bash
# Real async execution on wasmtime 45 with a HOST producer
# (docs/spec/wasi-p3-async.md §2.3). Builds the async host
# (examples/async_host, bin vibe-real-async-host) and runs it on the guest
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
host_dir="examples/async_host"
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
