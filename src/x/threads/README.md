# x/threads (experimental)

`src/x/threads` is a minimal threads probe area for wasmtime.
It contains WASI Threads, shared-everything-threads, and Component Model
threading probes for the local Wasmtime experiment.

Included:

- `threads.mbt`
  - backend contract helpers (`ThreadBackend`, `ThreadSpawnSemantics`)
  - recommended flag helpers for `VIBE_WASMTIME_WASM_FLAGS` / `VIBE_WASMTIME_WASI_FLAGS`
  - embedded probe WAT source (`probe_wat()`)
  - shared-everything flag helpers and i31 WAST source
  - Component Model threading flag helpers and WAST source
  - ComponentModelUnsafeOsThreads slot ABI and generated WAST sources
- `src/cmd/thread_probe_codegen`
  - emits generated ComponentModelUnsafeOsThreads WAST probes from `threads.mbt`
  - renders slot layout placeholders from `ComponentThreadSlotAbi`
- `THREADING_CONTRACT.md`
  - stable semantic contract between vibe and the local Wasmtime fork
- `wasi_threads_probe.wat`
  - imports:
    - `env::memory` (shared memory)
    - `wasi::thread-spawn`
  - exports:
    - `_start`
    - `wasi_thread_start`
- `wasi_threads_speedup_bench.wat`
  - exports:
    - `serial`
    - `parallel`
    - `_start` checksum validation
    - `wasi_thread_start`
- `shared_everything_i31_probe.wast`
  - validates `ref.i31_shared`, `(shared i31)`, and `(shared any)`
- `component_model_threading_probe.wast`
  - validates Wasmtime's current `canon thread.new-indirect` Component Model path
- `component_model_unsafe_os_threads_trampoline_status_probe.wast`
  - reference fixture for the generated trampoline status probe
  - validates the fork-local `canon thread.spawn-indirect` OS-thread path used
    by `ComponentModelUnsafeOsThreads`
  - intentionally drops the canonical spawn return index
  - publishes Vibe-level completion/status through trampoline-owned shared
    memory plus wait/notify
- generated `vibe-abi` probe
  - validates the consolidated Vibe slot ABI used by the unsafe backend
  - covers normal completion, failed-as-value, in-flight cooperative
    cancellation, and parent aggregation
- generated `channel-abi` probe
  - validates the fixed-capacity shared channel ABI for the unsafe backend
  - exercises atomic lock, bounded send failure, ring wraparound, recv-empty,
    and send/recv notify epochs
- generated `channel-spawn-abi` probe
  - connects `thread.spawn-indirect` worker trampolines to the shared channel ABI
  - validates that parent-side join/status still flows through Vibe slots while
    worker payload transfer flows through the shared channel
- `component_model_unsafe_os_threads_vibe_abi_speedup_*.wast`
  - reference fixtures for the generated ABI-shaped speedup probes
  - validates that the same Vibe slot ABI can produce a serial/parallel
    checksum match and local wall-clock speedup
- `run_probe.sh`
  - local runner for this directory (`wasm-tools parse` + `scripts/wasmtime_run.sh`)
- `run_speedup_probe.sh`
  - local runner for serial vs parallel speedup verification (`hyperfine`)
- `run_shared_everything_probe.sh`
  - local runner for the shared-everything WAST probe
- `run_component_model_threading_probe.sh`
  - local runner for the Component Model threading WAST probe
- `run_component_model_unsafe_os_threads_probe.sh`
  - local runner for the generated ComponentModelUnsafeOsThreads consolidated
    Vibe slot ABI, channel ABI, and channel-spawn ABI WAST probes
- `run_component_model_unsafe_os_threads_speedup_probe.sh`
  - local runner for the generated ComponentModelUnsafeOsThreads ABI-shaped
    speedup probe

Generate ComponentModelUnsafeOsThreads probes directly:

```bash
moon run --target native src/cmd/thread_probe_codegen -- trampoline-status
moon run --target native src/cmd/thread_probe_codegen -- vibe-abi
moon run --target native src/cmd/thread_probe_codegen -- channel-abi
moon run --target native src/cmd/thread_probe_codegen -- channel-spawn-abi
moon run --target native src/cmd/thread_probe_codegen -- speedup-serial
moon run --target native src/cmd/thread_probe_codegen -- speedup-parallel
```

The unsafe OS-thread runners generate temporary WAST files with this command
before invoking Wasmtime. The checked-in `.wast` files are reference fixtures,
not the runner source of truth.

The generated WAST must not hard-code the Vibe slot/channel layout independently
of `component_thread_slot_abi()` and `shared_thread_channel_abi()`.
`moon test src/x/threads` checks the public base values and verifies that
rendered probes do not leave unresolved `@VIBE_*` placeholders.

Run WASI threads:

```bash
# run from repo root
pkf run experimental_wasi_threads_probe

# or run directly
src/x/threads/run_probe.sh
```

Run WASI threads speedup verification:

```bash
# run from repo root
pkf run experimental_wasi_threads_speedup_probe

# or run directly
src/x/threads/run_speedup_probe.sh
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

Run ComponentModelUnsafeOsThreads consolidated Vibe ABI:

```bash
# run from repo root
pkf run experimental_component_model_unsafe_os_threads_probe

# or run directly
src/x/threads/run_component_model_unsafe_os_threads_probe.sh
```

Run ComponentModelUnsafeOsThreads ABI-shaped speedup:

```bash
# run from repo root
pkf run experimental_component_model_unsafe_os_threads_speedup_probe

# or run directly
src/x/threads/run_component_model_unsafe_os_threads_speedup_probe.sh
```

The thread runners default to `VIBE_USE_WASMTIME_PREBUILT=1`, so they use the
project-local fork prebuilt unless `WASMTIME_BIN` is set explicitly. Package the
local sibling fork build and install it before running these probes:

```bash
pkf run package-wasmtime-prebuilt
pkf run install-wasmtime-prebuilt
```

Detailed setup and update procedure:

- [docs/wasmtime-prebuilt-setup.md](../../../docs/wasmtime-prebuilt-setup.md)

`deps/wasmtime` remains available as a source-build fallback with
`VIBE_USE_WASMTIME_SUBMODULE=1`.

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

ComponentModelUnsafeOsThreads Vibe ABI probe requirements:

- `WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=1` for the local fork
- `-W threads=y`
- `-W component-model=y`
- `-W component-model-async=y`
- `-W component-model-threading=y`
- `-W gc=y`
- `-W function-references=y`
- `-W shared-everything-threads=y`

ComponentModelUnsafeOsThreads speedup probe requirements:

- same flags as the Vibe ABI probe
- `hyperfine`
- `node`

Backend semantic contract:

- `LinearLocal` is the default `--unstable-threads` backend today. It keeps
  `Threads::channel_*` and `Threads::spawn/wait` executable inside one Wasm
  instance, with immediate-complete local task handles and no parallelism.
- The selected backend ID is carried into codegen options so
  `Threads::runtime_hints()` can report backend-specific Wasmtime flags even
  before non-`linear-local` spawn lowering is connected.
- `Threads::probe_wat` and `Threads::runtime_hints` are metadata-only compiled
  constants and may be used with a non-`linear-local` backend. Stateful
  `Threads::channel_*` and `Threads::spawn/wait` lowering still requires
  `linear-local`.
- `ThreadCompiledStatefulLowering` is the single source of truth for what the
  normal Vibe compiler can lower today. It currently exposes
  `LinearLocalStateful` only; Component Model thread backends remain
  `NoCompiledStateful` even when their probe WASTs are executable.
- `ComponentModelCooperative` covers current `thread.new-indirect` and any
  fork-local `thread.spawn-indirect` implementation that only fuses
  new-and-resume on the cooperative scheduler.
- `ComponentModelUnsafeOsThreads` is the current fork-local diagnostic backend.
  It can claim local preemptive speedup only behind
  `WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=1`. Its Vibe-level
  join/completion must come from a generated trampoline using shared state plus
  wait/notify, not from the canonical spawn return index.
- `ComponentModelShared` is reserved for a future proposal-complete
  shared-everything backend.
- `WasiThreads` remains a speedup baseline, not the final Component Model
  backend.
