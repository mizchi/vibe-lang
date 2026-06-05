# Vibe threading contract

This file defines the semantic contract that `vibe` expects from experimental
thread backends. Wasmtime fork work should implement toward this contract, not
toward backend-specific accidents.

## Stable backend names

The MoonBit API in `threads.mbt` exposes these backend identifiers:

| Backend | ID | Spawn semantics | Parallel speedup claim |
| --- | --- | --- | --- |
| `SerialOnly` | `serial` | `NoSpawn` | no |
| `LinearLocal` | `linear-local` | `ImmediateComplete` | no |
| `WasiThreads` | `wasi-threads` | `PreemptiveParallel` | yes |
| `ComponentModelCooperative` | `component-cooperative` | `Cooperative` | no |
| `ComponentModelUnsafeOsThreads` | `component-unsafe-os-threads` | `PreemptiveParallel` | yes, fork-local |
| `ComponentModelShared` | `component-shared` | `PreemptiveParallel` | future yes |

## Semantic boundaries

`Cooperative` means a thread can make progress only through the Component Model
concurrency scheduler. It may be useful for API shape, cancellation, and handle
tests, but it must not be used to claim CPU parallel speedup.

`ImmediateComplete` means the current compiled backend creates Vibe-owned local
task handles and marks them terminal in the same Wasm instance. This keeps the
source-level API executable while the Component Model backend is being wired,
but it is not a worker scheduler and cannot claim parallelism.

`PreemptiveParallel` means different thread bodies may execute concurrently on
host threads. This is the only category that can be compared against the serial
path for speedup.

The current compiled `Threads::spawn` / `Threads::wait` lowering maps to
`LinearLocal`, which is the default backend selected by `--unstable-threads`.
The CLI/runtime may carry a different backend ID with `--thread-backend`.
Metadata-only builtins (`Threads::probe_wat`, `Threads::runtime_hints`) are
allowed to observe that ID, but stateful compiled lowering
(`Threads::channel_*`, `Threads::spawn`, `Threads::wait`) rejects
non-`linear-local` IDs until the corresponding lowering path is connected.
The same backend ID is threaded through codegen options so
`Threads::runtime_hints()` reports backend-specific flags.

The current stateful compiled lowering kind is represented by
`ThreadCompiledStatefulLowering` in `threads.mbt`. Today only `LinearLocal`
maps to `LinearLocalStateful`; every Component Model backend maps to
`NoCompiledStateful` until normal Vibe codegen can emit the component/thread
adapter shape instead of the local linear-memory FIFO/task records.

The current Wasmtime Component Model `thread.new-indirect` path maps to
`ComponentModelCooperative`.

The current `mizchi/wasmtime` fork-local OS-thread path maps to
`ComponentModelUnsafeOsThreads`. It is useful for local validation and speedup
probes, but it is not the final shared-everything backend.

The desired proposal-complete shared-everything `thread.spawn-* shared` path
maps to `ComponentModelShared` only after the runtime actually supports
preemptive parallel execution with a safe shared state model. A fork
implementation may temporarily parse or lower `shared=true` as cooperative, but
it must keep reporting the backend as `ComponentModelCooperative`.

The Component Model canonical `thread.spawn-*` return value is a transient
component thread-table index. Vibe must not expose it as a stable user-level
join handle. The index may be useful for diagnostics while the thread is live,
but completion and terminal status at the Vibe abstraction boundary are owned by
Vibe-generated runtime state.

For `ComponentModelUnsafeOsThreads` and the future `ComponentModelShared`,
Vibe-level completion is represented by a generated start-function trampoline:

- the parent drops the canonical spawn return index;
- the trampoline writes a shared state word and terminal status code;
- the parent waits with `memory.atomic.wait32` and the trampoline wakes it with
  `memory.atomic.notify`;
- terminal status codes are `0 = completed`, `1 = cancelled`, `2 = failed`.

The generated shared slot ABI is centralized in `threads.mbt`:

| Offset | Field |
| --- | --- |
| stride `32` | per-thread slot size |
| `+0` | state (`0 = empty`, `1 = running`, `2 = terminal`) |
| `+4` | terminal code (`0 = completed`, `1 = cancelled`, `2 = failed`) |
| `+8` | payload |
| `+12` | input/context |
| `+16` | cancel request flag |
| `+20` | mode |

The compiled linear backend uses the same Vibe-owned handle principle, but it
does not claim parallelism. It is a single-instance local runtime used to keep
the source-level contract executable while the Wasmtime fork backend matures.

Source-level local channel handles are nominal Vibe `ThreadChannel[T]` values.
The current compiled API instantiates this as `ThreadChannel[String]`. Its
runtime payload is still the same tagged integer representation used by other
linear-memory handles: a raw pointer to this record:

| Offset | Field |
| --- | --- |
| size `16` | channel record size |
| `+0` | capacity (`<= 0` means unbounded) |
| `+4` | queued message count |
| `+8` | head node pointer (`0` when empty) |
| `+12` | tail node pointer (`0` when empty) |

Local channel nodes are 8 bytes:

| Offset | Field |
| --- | --- |
| size `8` | node record size |
| `+0` | next node pointer (`0` at tail) |
| `+4` | tagged Vibe string payload |

Shared channel handles for preemptive Component Model probes use a separate
fixed-capacity ring layout. This avoids cross-thread allocator use during
`send`, and every header/cell field is i32-aligned for atomic access:

| Offset | Field |
| --- | --- |
| size `40` | channel record size |
| `+0` | lock word (`0 = unlocked`, `1 = locked`) |
| `+4` | capacity (`> 0`; unbounded shared channels are not connected yet) |
| `+8` | queued payload count |
| `+12` | next receive index |
| `+16` | next send index |
| `+20` | cell buffer base pointer |
| `+24` | closed flag |
| `+28` | send epoch, incremented and notified after successful send |
| `+32` | recv epoch, incremented and notified after successful receive |

Shared channel cells are 4 bytes:

| Offset | Field |
| --- | --- |
| size `4` | cell size |
| `+0` | i32 tagged Vibe payload |

The generated `channel-spawn-abi` probe validates the split of responsibilities
for the unsafe OS-thread path: worker trampolines send payloads through this
shared channel layout, while parent-side join and terminal status continue to
use Vibe-owned slots. The canonical `thread.spawn-indirect` return index remains
ignored in that path.

Source-level local task handles are nominal Vibe `ThreadTask[T]` values. The
current compiled `Threads::spawn` instantiates this as `ThreadTask[Int]` because
`Threads::wait` returns a terminal status code today. Its runtime payload is the
same tagged integer representation used by the local backend: a raw pointer to
this record:

| Offset | Field |
| --- | --- |
| size `16` | task record size |
| `+0` | state (`0 = empty`, `1 = running`, `2 = terminal`) |
| `+4` | terminal code (`0 = completed`, `1 = cancelled`, `2 = failed`) |
| `+8` | channel/context pointer |
| `+12` | payload |

The current compiled `Threads::spawn` creates an immediate terminal local task
with terminal code `0`. It deliberately models Vibe-owned task identity and
completion without using the Component Model canonical spawn return value.

The current probe generator is `src/cmd/thread_probe_codegen`; the shell runners
generate temporary WAST from that command before invoking Wasmtime.
Generated WAST templates use `@VIBE_*` placeholders that are rendered from
`ComponentThreadSlotAbi` and `SharedThreadChannelAbi`; the expanded output must
not leave placeholders in the final WAST.

## Required behavior

All backends must preserve these rules:

- Worker start functions are single-entry and receive one `i32` context value.
- A spawned worker must either complete normally or report a trap/failure to the
  parent runtime.
- Join/wait is explicit at the vibe abstraction boundary.
- Join/wait must not depend on the canonical `thread.spawn-*` return value for
  `ComponentModelUnsafeOsThreads` or `ComponentModelShared`; it must use
  Vibe-owned shared state.
- Shared mutable state used for parallel speedup must use atomic operations or a
  backend-defined synchronization primitive.
- Serial and parallel variants of a workload must produce the same result before
  timing comparisons are accepted.
- `available_parallelism` for non-parallel backends is semantically `1`.

## Wasmtime fork mapping

Initial fork milestones should map as follows:

| Wasmtime primitive | Vibe backend |
| --- | --- |
| current compiled local channel/task lowering | `LinearLocal` |
| `canon thread.new-indirect` + `thread.unsuspend` | `ComponentModelCooperative` |
| `canon thread.spawn-indirect` implemented as new + resume | `ComponentModelCooperative` |
| `canon thread.available-parallelism shared=false` | `ComponentModelCooperative`, value `1` |
| fork-local `canon thread.spawn-indirect` OS-thread execution behind `WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=1` with trampoline-owned shared completion/status | `ComponentModelUnsafeOsThreads` |
| proposal-complete `canon thread.spawn-indirect shared=true` with real host-thread execution and safe shared state ownership | `ComponentModelShared` |
| WASI `thread-spawn` | `WasiThreads` |

This keeps the source-level Vibe abstraction stable while the fork moves from
cooperative scheduling toward true shared-everything parallel execution.
