# Vibe threading contract

This file defines the semantic contract that `vibe` expects from experimental
thread backends. Wasmtime fork work should implement toward this contract, not
toward backend-specific accidents.

## Stable backend names

The MoonBit API in `threads.mbt` exposes these backend identifiers:

| Backend | ID | Spawn semantics | Parallel speedup claim |
| --- | --- | --- | --- |
| `SerialOnly` | `serial` | `NoSpawn` | no |
| `WasiThreads` | `wasi-threads` | `PreemptiveParallel` | yes |
| `ComponentModelCooperative` | `component-cooperative` | `Cooperative` | no |
| `ComponentModelShared` | `component-shared` | `PreemptiveParallel` | yes |

## Semantic boundaries

`Cooperative` means a thread can make progress only through the Component Model
concurrency scheduler. It may be useful for API shape, cancellation, and handle
tests, but it must not be used to claim CPU parallel speedup.

`PreemptiveParallel` means different thread bodies may execute concurrently on
host threads. This is the only category that can be compared against the serial
path for speedup.

The current Wasmtime Component Model `thread.new-indirect` path maps to
`ComponentModelCooperative`.

The desired shared-everything `thread.spawn-* shared` path maps to
`ComponentModelShared` only after the runtime actually supports preemptive
parallel execution. A fork implementation may temporarily parse or lower
`shared=true` as cooperative, but it must keep reporting the backend as
`ComponentModelCooperative`.

## Required behavior

All backends must preserve these rules:

- Worker start functions are single-entry and receive one `i32` context value.
- A spawned worker must either complete normally or report a trap/failure to the
  parent runtime.
- Join/wait is explicit at the vibe abstraction boundary.
- Shared mutable state used for parallel speedup must use atomic operations or a
  backend-defined synchronization primitive.
- Serial and parallel variants of a workload must produce the same result before
  timing comparisons are accepted.
- `available_parallelism` for non-parallel backends is semantically `1`.

## Wasmtime fork mapping

Initial fork milestones should map as follows:

| Wasmtime primitive | Vibe backend |
| --- | --- |
| `canon thread.new-indirect` + `thread.unsuspend` | `ComponentModelCooperative` |
| `canon thread.spawn-indirect` implemented as new + resume | `ComponentModelCooperative` |
| `canon thread.available-parallelism shared=false` | `ComponentModelCooperative`, value `1` |
| `canon thread.spawn-indirect shared=true` with real host-thread execution | `ComponentModelShared` |
| WASI `thread-spawn` | `WasiThreads` |

This keeps the source-level Vibe abstraction stable while the fork moves from
cooperative scheduling toward true shared-everything parallel execution.
