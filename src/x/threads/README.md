# x/threads (experimental)

`src/x/threads` is a minimal WASI Threads probe for wasmtime.

Included:

- `threads.mbt`
  - recommended flag helpers for `VIBE_WASMTIME_WASM_FLAGS` / `VIBE_WASMTIME_WASI_FLAGS`
  - embedded probe WAT source (`probe_wat()`)
- `wasi_threads_probe.wat`
  - imports:
    - `env::memory` (shared memory)
    - `wasi::thread-spawn`
  - exports:
    - `_start`
    - `wasi_thread_start`
- `run_probe.sh`
  - local runner for this directory (`wasm-tools parse` + `scripts/wasmtime_run.sh`)

Run:

```bash
# run from repo root
just wasi-threads-probe

# or run directly
src/x/threads/run_probe.sh
```

Runtime requirements:

- `-S threads=y`
- `-W shared-memory=y`
- `-W threads=y`
