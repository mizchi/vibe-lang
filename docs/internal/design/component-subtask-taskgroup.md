# Component Model subtasks as the `TaskGroup` backend

ADR-0125, proposed. Owner: #3147. Related: ADR-0068 (the task model and its
backend-independence rule), ADR-0012 and ADR-0089 (the async ABI and the host
waits), #3200 (one spawn for both lanes), #3484 (CPU parallelism on native
threads, a separate backend).

This document records what a `TaskGroup` task is on the component target
today, what a Component Model (CM) subtask can and cannot carry there, measured
on wasmtime 47.0.2, and the mapping that follows. It changes no code.

## Decision

1. **A subtask-backed child is a call into a second instance of the program.**
   The emitted component instantiates the program's core module twice: the
   *main instance*, which runs the entry and owns the groups, and the *task
   instance*, which exports one async, stackful (callback-less) function per
   qualifying spawn site. Spawning calls that export through `canon lower ...
   async`, which yields the child's subtask handle. A component instance cannot
   call its own lifted export: measured, the call traps with `cannot enter
   component instance` (probe 5 below). So the issue's "a lifted async
   export called through the component's own canon lower" is not
   implementable; the export must belong to another instance of the same code.
2. **Join, cancel and failure map onto the subtask, and the meaning stays
   ADR-0068's.** A child's subtask joins the main instance's shared waitable
   set, beside the host waits of fiber tasks, and resumes in completion order.
   `TaskHandle::cancel` and fail-fast cancel a child with `subtask.cancel`;
   the child sees it in a `cancellable` wait, releases its own host waits and
   calls `task.cancel`. A child's exception crosses as a value
   (`result<T, string>`) and becomes the group's `TaskError::Failed(m)`. A trap
   stays a trap of the whole program.
3. **What crosses is copied by the canonical ABI.** The task instance has its
   own memory, so a child's captures arrive as the export's parameters and its
   result as its WIT result. A spawn site qualifies only when every capture and
   the result have a WIT projection. A channel between the two instances
   becomes a `stream<T>`; until that step lands, a site that captures a channel
   endpoint runs on fibers.
4. **The fiber backend stays the reference, and the default.** Everything that
   does not qualify runs on guest fibers exactly as today: non-component
   targets, `vibe test`, groups opened inside a subtask-backed child, spawn
   sites whose captures or result have no WIT projection, and `Parallel::map`.
   The subtask backend is opt-in per build until the conformance rows below
   pass. CM subtasks give the host scheduling and cancellation, not CPU
   parallelism (probe 7); that is #3484.

## What runs today

Inventory of the component that `fixtures/async_spawn_host_futures/main.vibe`
compiles to (two `TaskGroup::spawn_suspend` tasks awaiting host futures;
stage2 built from main at `c000874cc`, decoded with `wasmparser` 0.257):

- One component instance. The only task the host sees is the async lift of
  `run`; it is stackful (`Lift { options: [Async] }`, no callback).
- The program's core module imports the adapter's `vibe` functions
  (`host_future_arm`, `host_future_wait`, `host_future_wait_any`,
  `host_future_cancel`, `host_sleep_arm`, `host_sleep_cancel`, `sleep`, one
  `host_future_get$<name>` per named future). It holds 41 mutable globals.
- The adapter core module
  (`lib/@vibe/compiler/codegen/component/component_codegen_comp_generate_hostfuture_adapter_core_module.vibe`)
  owns every canonical built-in the component uses:

  | built-in | used for |
  |---|---|
  | `canon lower ... async` (`fast`, `slow`, `sleep-for`) | each host call is a host subtask |
  | `future.read` (async), `future.drop-readable`, `future.cancel-read` | a host future's value; releasing a cancelled task's read |
  | `waitable-set.new` / `.wait` (not cancellable) / `.drop`, `waitable.join` | the one shared waitable set every group's parked waits live in |
  | `subtask.drop`, `subtask.cancel` (sync) | retiring and cancelling host calls and timers |
  | `task.return` | the `run` export's result |

  No component emitter produces `task.cancel`, `context.get` / `context.set`,
  `backpressure.*` or `thread.*`; `future.new` / `stream.new` appear only in
  the fixed-shape value probes' emitters. A stream-reading program adds
  `stream.read` and `stream.cancel-read`
  ([async-host-contract.md](async-host-contract.md)).
- A task is a guest fiber: `spawn_suspend` runs the body's first leg, and at a
  suspension the CPS-split continuation (ADR-0076) is stored in the task's
  cell. When nothing can run, the group's boundary waits on the shared set and
  resumes whichever task's wait landed. The tasks interleave on host waits
  (`scripts/test_named_hostfutures_component_gate.sh` asserts 42 in under
  400 ms for the fixture above; re-run here: 42 in 327 ms), but the host sees
  one task, so it can neither schedule nor cancel a child.

The `wasi-p3-gate` CI job (`scripts/test_wasi_p3_guarantee_gate.sh`) covers
this through hand-written ABI probes (`tools/wasip3_component_probe/`, for
example `concurrent_awaits` and `interleaved_tasks`) and compiler-emitted
components (`test_named_hostfutures_component_gate.sh`,
`test_named_hoststreams_component_gate.sh`,
`test_wit_async_import_component_gate.sh`, among others). Every one of them
calls only host functions; none has a guest-to-guest subtask.

## Measurements

The probes are in `tools/wasip3_component_probe/subtask_taskgroup/`.
`gen_probes.py` writes one component per probe: a Worker component lifts the
async stackful export `child(ms) -> u32`, which awaits viberun's `get-after`
host import and answers `ms + 1`, and a Main component calls it through `canon
lower ... async`. `stream_channel.wat` is written by hand. They were assembled
with the `wat` crate 1.257.1 and validated with `wasmparser` 0.257 with every
feature on (wasm-tools was not installed), and run under `runtime/viberun`
(wasmtime 47.0.2, `component-model-async` and `-async-stackful` on, as in the
gates). Rows 1 to 4 are the median of three runs after a warm-up run; the
others are single runs.

| # | probe | question | answer | wall |
|---|---|---|---|---|
| 1 | `siblings_concurrent` | two children, both started before either is waited on | `602` (301 + 301) | 0.31 s |
| 2 | `siblings_serial` | control: the second starts after the first returned | `602` | 0.61 s |
| 3 | `siblings_cancel` | child b (3000 ms) is cancelled once a (300 ms) returned; answer = a × 10 + `subtask.cancel`'s status | `3014`: status 4, cancelled before returning | 0.30 s |
| 4 | `siblings_cancel_unobserved` | the same, with the child's wait not `cancellable` | `3012`: status 2, the cancel waited for the child to return | 3.01 s |
| 5 | `self_concurrent` | one instance lowers its own lifted `child` | trap: `cannot enter component instance` | |
| 6 | `siblings_trap` | a child executes `unreachable` while a sibling is in flight | the whole run traps; the caller cannot observe it | |
| 7 | `siblings_spin1` / `spin2` | one and two CPU-bound children (no waits) | each call returns status 2 from the call itself; two cost twice one | 0.11 s / 0.21 s |
| 8 | `siblings_fanout` | 1000 children of 50 ms in flight at once, drained from one set | `51000` | 0.07 s, 28.8 MB peak RSS (18.3 MB with 1 child) |
| 9 | `stream_channel.wat` | Main passes a `stream<u32>` readable end to the child, writes 1..5 and drops the writable end; the child reads in rounds of two | `15` | 0.01 s |

Further measurements with the same probes:

- **Fan-out.** 3000 children in flight cost 50.4 MB peak RSS, about 11 KB per
  in-flight child. A stackful child is a wasmtime fiber.
- **Eager calls.** A call into a child that returns without blocking yields
  status 2 and handle 0, so there is nothing to drop: 200,000 such calls take
  0.40 s, about 2 µs each. They are **not** free in wasmtime 47, though: peak
  RSS grows with the count (25.7 MB at 20,000 calls, 89.7 MB at 200,000), and
  at 1,000,000 calls from one parent task the call traps with `resource
  table has no free keys`. Children that block and are dropped do not grow it:
  40 rounds of 1000 blocked children stay at 29.4 MB.
- **A sync cancel needs the subtask out of the set.** A synchronous
  `subtask.cancel` on a subtask that is still joined to a waitable set traps
  with `waitable cannot be used synchronously while added to a waitable set`.
  The child in probe 3 leaves the set (`waitable.join` with set 0) before it
  cancels its own host call, as the adapter already does for a host future.
- **Streams need no extra flag.** Probe 9 runs under viberun's configuration
  and under `wasmtime run` without `component-model-more-async-builtins`.

What the probes establish:

- Guest-to-guest subtasks interleave on host waits (1 against 2), several of
  them inside one task instance, each on its own fiber.
- `subtask.cancel` reaches a child and is observable by the caller (status 4),
  but only cooperatively: the child must be in a `cancellable` wait (3 against
  4). A child that never waits cannot be cancelled before it returns.
- An async-lowered call runs the child eagerly until its first block (7). That
  is the property `spawn_suspend` already promises ("runs the new task's first
  leg before it returns"), and it means CM subtasks add no CPU parallelism.
- A component instance cannot call its own export (5), and component
  instantiation is acyclic, so a task instance can never call the main
  instance either. Everything the main instance and a child exchange after the
  call starts has to travel through a CM value: a `stream`, a `future`, the
  call's parameters, or its result.

## The mapping

### A spawn site becomes an export

For each spawn site the compiler selects, the task closure's body is emitted as
an export of the task instance, `task-N: async func(captures...) ->
result<T', string>`, compiled as an `Async` entry: its suspensions unwind to
that export's boundary, which waits on the child's own waitable set. The spawn
site in the main instance calls the lowered export with the captures as
arguments. The two instances share the core module, so the component carries
one copy of the code and one more `instantiate`.

The task instance is wired to the same imports as the main instance, minus
what no selected body's row needs. The child's authority is a subset of the
parent's by construction (ADR-0075, ADR-0088): the instantiation wiring is the
grant.

### Join

The child's subtask handle joins the main instance's shared waitable set (the
set #3091 introduced for host waits). A `SUBTASK` event with status RETURNED
settles the task: its result has been lifted into the main instance's memory
at the call's result area, and `Ok(v)` becomes the task's value. `join`,
`result_wait`, the group's close and a blocked `send` / `recv` (#3200, PR
#4006) wait for it exactly as they wait for a parked fiber task, so fiber
tasks and subtask children of one group resume in one completion order.
`subtask.drop` follows the settle.

### Cancel

`TaskHandle::cancel`, fail-fast and a throw escaping the group's body cancel a
subtask child with `subtask.cancel`. Before a synchronous cancel the handle
leaves the shared set (measured above). The main instance runs only while
every child is blocked or finished, so a child that is still running is always
in a wait when the cancel arrives.

Inside the task instance, every wait is `cancellable`. On `TASK_CANCELLED`
the child's boundary releases its own host waits through the same calls the
adapter uses today (`subtask.cancel` for a host call or timer,
`future.cancel-read`, `stream.cancel-read`), and then calls `task.cancel`.
The body does not run again, which is what cancelling a parked fiber task does
today. The caller sees status 4 and settles the task as `Cancelled`. A child
that is between waits finishes its current leg first, as a fiber task does;
there is no preemption on either backend.

### Failure

An exception escaping the child's body is caught at its export boundary and
returned as `Err(m)`, with the same rendering `TaskError::Failed(m)` carries
today. The main instance then runs the group's fail-fast as for a fiber task.
A trap in a child aborts the whole component (probe 6), which is what a trap
in a fiber task does today, so no observation changes.

### What crosses: captures, results and `Send`

`Send` and `Spawnable` are unchanged; the checker runs them first. The
subtask backend adds one more requirement, judged per spawn site: every
capture and the result must have a WIT projection, the one ADR-0089 and
`vibe build --component` already use (`Int` as `s64`, `String` as `string`,
tuples, records, non-recursive enums as variants, `Option`, `FrozenArray[T]`
as `list<T'>`). A site that fails it runs on fibers. These `Send` values
have no projection today:

- a recursive type (WIT has none), such as a list ADT;
- a captured builtin `Future[T]` that another task also holds (a CM future
  has one reader; `fixtures/async_spawn_host_futures/shared.vibe` is that
  shape);
- a captured endpoint of the group (`TaskGroup`, `TaskHandle`, `Sender`,
  `Receiver`), until the channel step below.

A fallback to fibers is not a different meaning, because ADR-0068 makes the
schedule unobservable apart from its synchronization points. It is reported
(a build note naming the site and the capture), so an opt-in build cannot
silently lose the backend it asked for.

The copy at the call is the ADR-0068 memory model made literal: a child owns
the task instance's heap and the message is a snapshot. All children of the
task instance share that heap and its RC allocator. They switch only at a
canonical wait, which is made from the boundary at the top of each child's
stack and never inside an allocation.

### Channels

A channel with an endpoint in a subtask child is a `stream<T'>` (probe 9):
the main instance creates it with `stream.new`, and the endpoint that moves
is a parameter of the child's export. ADR-0068's capacity and linearization
rules then need a statement of their own, because a CM stream is a rendezvous
that copies up to the reader's buffer: the side that owns the channel keeps
the buffer, and a send linearizes when the stream write completes. That is a
later step. Until it lands, a site that captures an endpoint runs on fibers.

### Re-entrance in the task instance

Two children in one task instance are two entries into one instance. The
probe children keep their per-call state in locals and in a scratch area they
allocate, so they are re-entrant. The program's core module is not yet:
its entry boundary and the adapter keep per-entry state in globals (the shared
waitable set, the slot maps, the 41 mutable globals of the program counted
above). The task instance therefore needs a re-entrant boundary, with per-task
state reached through `context.get 0` / `context.set 0` (the CM's task-local
slot, which wit-bindgen uses for the same purpose) and a waitable set per
child. The main instance keeps the shared set. Inventorying those globals is
the first implementation step.

### Nested groups and other targets

A group opened inside a subtask-backed child runs on fibers inside the task
instance. Its children cannot be subtasks of the task instance, because a
child's call into its own instance traps (probe 5), and the main instance is
not reachable from it. Adding a third instance for a second level is possible,
but the instance graph is fixed when the component is built, so the depth is
bounded by construction; one level is the first step.

Non-component targets (the core module under `vibe run`, the wasm-gc lane,
JS) keep fibers. They have no CM tasks.

## Alternatives considered

- **The component calls its own export.** Measured to trap (probe 5). This is
  the CM's recursive re-entrance rule, and §3.3.1 of
  [wasi-p3-async.md](wasi-p3-async.md) hit the same trap on wasmtime 45 when
  a parent called into a component it contained.
- **A host-provided spawn import.** The host could call the task instance
  from outside the caller's task chain, which avoids the re-entrance rule. It
  would make the component depend on a vibe-specific host function, so it
  would no longer run under a plain CM host (`wasmtime run`, `wasmtime
  serve`), and the cancel handle would be that host's, not `subtask.cancel`.
- **One single-entry instance per in-flight child.** It avoids the re-entrant
  boundary, but CM instances are created when the component is built, so the
  number of in-flight children would be a build-time constant, and each
  instance costs a full program heap. `backpressure` on a shared instance
  would serialize the children instead, which loses the interleaving the
  backend exists for.
- **CM threads (`thread.new-indirect`, `thread.switch-to`, `thread.yield`).**
  They would keep every task in the main instance, with closures and the heap
  shared, which is closer to today's fibers. A thread has no subtask handle,
  so `subtask.cancel` and per-task backpressure would not apply, and
  wasmtime 47 ships the feature off (`-W component-model-threading`). Not
  measured here; it is a candidate replacement for the CPS fibers, not for the
  host-visible subtask the issue asks for.

## Acceptance

ADR-0125 is accepted when:

1. the probes are a `wasi-p3-gate` row: probe 1 against 2 (interleaving),
   probe 3 (a cancel observed by the caller, status 4, well under the
   cancelled child's delay) and probe 5 (the self call still traps, which is
   what this design depends on);
2. a component build with the subtask backend turned on lowers a qualifying
   `spawn_suspend` site to a task-instance export, and gate rows show two such
   tasks interleaving on host futures (the 42-under-400 ms bound of
   `test_named_hostfutures_component_gate.sh`), a `TaskHandle::cancel`
   reaching the child as `subtask.cancel` with its host wait released, and a
   child's exception arriving as the group's `TaskError::Failed`;
3. `fixtures/async_spawn_host_futures/` produces the same output on both
   backends, and the fiber backend's existing gates are unchanged.

The steps, in order:

1. Wire the probes into the gate (criterion 1).
2. Inventory the per-entry state in the program module's globals and the
   adapter, and move it behind `context.get` / `context.set` in the task
   instance's boundary.
3. Emit the second instance and one export per qualifying site, with the WIT
   projection check and the fallback note (criterion 2).
4. Conformance runs over `fixtures/async_spawn_host_futures/` (criterion 3).
5. Channels as `stream<T'>`, with the capacity and linearization statement.

The eager-call growth measured above (one parent task, about a million
children that never block) is a wasmtime 47 limit to re-measure on each
wasmtime bump; a gate row for it belongs with step 3.

## Reproducing

```bash
cd tools/wasip3_component_probe/subtask_taskgroup
python3 gen_probes.py out
for f in out/*.wat stream_channel.wat; do wasm-tools parse "$f" -o "${f%.wat}.wasm"; done
../../../runtime/viberun/target/release/viberun out/siblings_concurrent.wasm   # 602
```

`VIBE_ASYNC_DELAY_SCALE_PCT` scales every `get-after` delay, as in
`scripts/test_interleaved_tasks_probe_gate.sh`.
