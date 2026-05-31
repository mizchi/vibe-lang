# x/threads (experimental)

`src/x/threads` is a minimal threads probe area for wasmtime.
It contains WASI Threads, shared-everything-threads, and Component Model
threading probes for the local Wasmtime experiment.

Included:

- `threads.mbt`
  - recommended flag helpers for `VIBE_WASMTIME_WASM_FLAGS` / `VIBE_WASMTIME_WASI_FLAGS`
  - embedded probe WAT source (`probe_wat()`)
  - shared-everything flag helpers and i31 WAST source
  - Component Model threading flag helpers and WAST source
- `wasi_threads_probe.wat`
  - imports:
    - `env::memory` (shared memory)
    - `wasi::thread-spawn`
  - exports:
    - `_start`
    - `wasi_thread_start`
- `shared_everything_i31_probe.wast`
  - validates `ref.i31_shared`, `(shared i31)`, and `(shared any)`
- `component_model_threading_probe.wast`
  - validates Wasmtime's current `canon thread.new-indirect` Component Model path
- `run_probe.sh`
  - local runner for this directory (`wasm-tools parse` + `scripts/wasmtime_run.sh`)
- `run_shared_everything_probe.sh`
  - local runner for the shared-everything WAST probe
- `run_component_model_threading_probe.sh`
  - local runner for the Component Model threading WAST probe

Run WASI threads:

```bash
# run from repo root
pkf run experimental_wasi_threads_probe

# or run directly
src/x/threads/run_probe.sh
```

Run shared-everything i31:

```bash
# run from repo root
pkf run experimental_shared_everything_threads_probe

# or run directly
src/x/threads/run_shared_everything_probe.sh
```

Run Component Model threading:

```bash
# run from repo root
pkf run experimental_component_model_threading_probe

# or run directly
src/x/threads/run_component_model_threading_probe.sh
```

The shared-everything and Component Model threading runners automatically use
`../wasmtime/target/debug/wasmtime` when it exists, which matches the local
patched Wasmtime checkout layout.

WASI threads runtime requirements:

- `-S threads=y`
- `-W shared-memory=y`
- `-W threads=y`

shared-everything i31 runtime requirements:

- `-W gc=y`
- `-W function-references=y`
- `-W shared-everything-threads=y`

Component Model threading runtime requirements:

- `-W component-model=y`
- `-W component-model-async=y`
- `-W component-model-threading=y`
