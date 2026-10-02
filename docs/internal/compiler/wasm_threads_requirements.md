# wasm + threads: runtime requirements

The repository's Wasmtime is **47.0.2** (`scripts/install_wasmtime_release.sh`,
flake.nix, CI). This note records which thread-related Wasmtime surfaces vibe
can rely on there, and what was measured to decide it.

The public concurrency model is ADR-0068's shared-nothing structured
concurrency ([concurrency.md](../design/concurrency.md)). Threads are one
possible lowering of it, not a semantics of their own.

## Supported: core wasm atomics + shared memory

`-W threads=y` / `-W shared-memory=y` enable the wasm threads proposal (atomics
and shared memory). This is a wasm proposal flag, unrelated to the removed WASI
Threads (`-S threads`, below), and it is not deprecated. What a core wasm module
that uses atomics needs, measured on a minimal WAT module (`memory shared` +
`i32.atomic.store/load`):

| flags | result |
|---|---|
| (default) | `shared memory support is disabled for this engine -- see Config::shared_memory` |
| `-W shared-memory=y` | runs |
| `-W shared-memory=y -W threads=n` | `threads must be enabled for shared memories` |

So a module using atomics needs at least `-W shared-memory=y`, and passing
`-W threads=y` explicitly is the safe spelling. Through vibe's wrappers
(`scripts/wasmtime_run.sh`), `VIBE_WASMTIME_WASM_FLAGS` takes whitespace-separated
`-W` values:

```bash
VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'   # → -W threads=y -W shared-memory=y
```

The repository's active gates (`scripts/run_cli_preview2_component.sh`,
`scripts/test_cli_preview2_package.sh` and others) use only these `-W` flags.

## Removed: WASI Threads (`-S threads=y`)

`-S threads=y` (WASI Threads, the `wasm32-wasip1-threads` target) was removed in
Wasmtime 47.0.0 (#486). On 47.0.2:

```text
Error: the `-Sthreads` flag is no longer supported
```

No script in the repository passes `-S threads`; do not reintroduce it. A thread
probe, if one is wanted again, is a shared-everything probe (below) kept
separate from the backend-neutral conformance tests.

References:

- https://github.com/bytecodealliance/wasmtime/releases/tag/v45.0.0
- https://docs.wasmtime.dev/stability-wasm-proposals.html

## Component Model concurrency flags

Core wasm threads do not need `concurrency-support`. The Component Model's async
lowering does: the component gates pass
`-W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y`
(for example `scripts/test_serve_body_stream_gate.sh` and
`scripts/test_future_value_component_gate.sh`).

## Not available: shared-everything-threads

The successor proposal on the wasm side is **shared-everything-threads**
(`thread.spawn-ref` / `thread.spawn-indirect` / `thread.available-parallelism`
and shared composite types). It is not part of vibe's public API: in ADR-0068 it
is one interchangeable lowering of the task/channel semantics, to be built only
once Wasmtime implements the proposal. #488 (closed) carried the experiment; its
boundary and the conditions for promoting a shared-everything lowering to a
production candidate are the "#488" section of
[concurrency.md](../design/concurrency.md). No issue tracks re-evaluation; file
one when an upstream Wasmtime release implements the proposal.

Probe on the release binary `wasmtime 47.0.2 (90fed3c6a 2026-07-21)`, x86_64
Linux (2026-07-24):

- The `-W shared-everything-threads[=y|n]` **flag exists and is accepted**
  (a trivial module runs with it).
- It is a **stub that does not reach validation**: a module containing
  `(type (shared (func)))` is rejected with
  `shared composite types require the shared-everything-threads proposal`
  under `-W shared-everything-threads=y`, under `-W all-proposals=y`, and with
  `function-references=y gc=y threads=y shared-memory=y` added. The CLI flag is
  not wired into the validator's feature set.
- **The bundled WAT parser does not know the proposal's text syntax**: shared
  globals (`(global (shared (mut i32)) ...)`), shared tables,
  `ref.i31 (shared)`, and `thread.spawn_ref` / `thread.spawn_indirect` /
  `thread.available_parallelism` (and the alternative names `thread.spawn` /
  `thread.hw_concurrency`) are all parse errors.
- Upstream documentation (stability-wasm-proposals) lists the proposal as
  **Unimplemented**; the tracking issue is bytecodealliance/wasmtime#9466.
- The baseline is unchanged: shared memory + atomics under
  `-W threads=y -W shared-memory=y` works on 47.0.2.

Conclusion: **on 47.0.2, shared-everything-threads cannot be enabled.** The
0.2.0 concurrency work proceeds on ADR-0068's shared-nothing semantics
(cooperative, Worker and WASI backends).

- proposal: https://github.com/WebAssembly/shared-everything-threads
- upstream tracking: https://github.com/bytecodealliance/wasmtime/issues/9466
