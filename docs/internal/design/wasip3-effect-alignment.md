# ADR-0089: Aligning the language surface with wasip3 futures and streams — one `Async` operation, materialized futures, AsyncIter as the guest stream protocol

Status: Decisions 1–3 and 5 are implemented, and Decision 4's boundary rule is
enforced through Decision 5's WIT mapping. Two parts of Decision 1 are not
built: the JSPI backend, which has no owner, and Component Model subtasks as
`TaskGroup`'s backend, which is #3147. The lowering and ABI source of truth is
[wasi-p3-async.md](wasi-p3-async.md); this document records the decisions.

Date: 2026-07-31

Related: #1218, #1227, ADR-0012 (async on WASI 0.3), ADR-0068 (structured
concurrency, [concurrency.md](concurrency.md)), ADR-0071 (effectset), ADR-0076
(evidence passing / suspend CPS), ADR-0085 (`Exception[E]`), ADR-0088
(capability authorization surface).

## Context

The talk "代数的エフェクトの高速化技法と発展的な機能" (techniques for fast
algebraic effects, @ymdfield, 関数型まつり 2026) surveys the representative
effect patterns — Exception, State, Coroutine, higher-order effects — and
evidence passing as their fast implementation (State as a mutable cell,
exceptions as native exceptions, delimited continuations only where needed).
vibe already uses that scheme (ADR-0076: evidence dictionaries, suspend CPS,
one-shot first-class `resume`). Part A measures whether the talk's patterns can
be written in vibe; Part B decides how the language surface lines up with the
Component Model's `future<T>` and `stream<T>`.

When this ADR was written the repository had three disconnected async stacks:
`Future[T]` / `Stream[T]` / `Task[T]` / `await` were checker-only types with
eager identity codegen; `@vibe/concurrent`'s TaskGroup scheduler worked but
met the host only through a blocking sleep; and the Component Model emitters
in the composer handled fixed shapes only, with no `future.*` / `stream.*`
canon emitters and no async WIT generation. Part B puts them on one
abstraction.

## Part A: the talk's four patterns, measured

| pattern | verdict | evidence |
| --- | --- | --- |
| Exception (`throw -> !`, the continuation is discarded) | **works** | The checked exception effect has the same shape: `resume` in its arm is refused, the arm's value is the `handle`'s result, and nothing after the throw runs. [fixtures/effect_talk_exception_test.vibe](../../../fixtures/effect_talk_exception_test.vibe) |
| State (a mutable cell with a tail `resume`, the talk's primitive form) | **works** | A tail-resumptive handler closing over a `let mut` cell; `while` + `let mut` in a needing function goes through the evidence-dictionary path. [fixtures/effect_talk_state_appdb_test.vibe](../../../fixtures/effect_talk_state_appdb_test.vibe) (the talk's AppDB example) |
| State (classic state-passing, `(s) => resume(s)(s)`) | **not supported** | `handle` has no return / value clause, and an arm returning a lambda is a type mismatch against the body's type. The talk itself recommends the primitive form, so this is not pursued |
| Coroutine (return `Yielded(x, resume)`) | **works, with limits** | A first-class `resume` stored in an ADT payload, returned out of the `handle`, and re-entered by a driver loop until `Done`. [fixtures/effect_talk_coroutine_status_test.vibe](../../../fixtures/effect_talk_coroutine_status_test.vibe). Limits: one-shot (a second resume traps) and spine-shaped suspend bodies only |
| Handler switch (resuming under a different handler) | **not supported, diagnosed** | A stored continuation has its original driver baked in lexically, so wrapping it in a new `handle ... with Yield` delivers to the old arm. The checker refuses such a handle as one that can never fire (#1347). [fixtures/err_handler_switch_dead_handle.vibe](../../../fixtures/err_handler_switch_dead_handle.vibe), compiler gate 83 |
| Higher-order effect with a pure block (`Span(String, () -> Int)`) | **works** | An operation with a function-typed parameter, called from the arm; the span's start/end pairing stays inside the arm. [fixtures/effect_talk_tracing_span_test.vibe](../../../fixtures/effect_talk_tracing_span_test.vibe) |
| Higher-order effect with an effectful block | **not supported, diagnosed** | `Span(String, () -> Int with Log)` under an outer `handle .. with Log` needs the block's evidence to migrate across the arm boundary. The diagnostic names the operation and says higher-order effects are unsupported (#1347). [fixtures/err_higher_order_effectful_block.vibe](../../../fixtures/err_higher_order_effectful_block.vibe), compiler gate 84. Provider effects hit the same wall |
| Distributed tracing | **partly** | The pure-block form plus a mutable cell plus backend switching by handler can be written today; a block that does `Fs` / `Http` depends on the higher-order gap above |

### Cross-cutting findings

1. **Generic effects are checked** (#1340). `effect State[S]` is registered,
   and `with State[Int]` parses (one type argument). A `handle` instantiates
   the effect once, shared by its body and its arms. A `perform` outside any
   handle of the effect takes the type arguments of the enclosing function's
   own row (#3275), so under `with State[Int]` it sends and receives an
   `Int`, and a kinded parameter takes a bare constructor (`with Read[Array]`
   makes `Read::Put(F[Int])` take an `Array[Int]`). A bare `with State`
   leaves each perform instantiated on its own, and a lambda with no row of
   its own does not take the enclosing function's: its row is decided where
   it is used. Passed to a parameter typed `() -> Int with State[String]`, it
   performs at that row's instantiation, and a formal of the callee the row
   names is the type this call gives it (#3311). A row argument that names no
   type is refused (#3319). A row naming `State[Int]` does not cover a callee's
   `State[String]` (#3053), and a handle whose arms answer one instantiation
   refuses a handled call that declares another (#3010).
2. **A tail-resumptive arm cannot abort.** An `Error` / `Exception` arm and a
   suspend-class arm discard the continuation; an arm of an ordinary
   tail-resumptive user effect must end in `resume(v)`, and a bare tail value
   is refused (#2969). It used to be an implicit `resume(value)` (#1087),
   which contradicted the talk's "discarding the continuation is an escape".
3. **Handler switch would need the evidence vector saved under the
   continuation** (the talk's p133 conclusion). The static diagnostic (#1347)
   is a conjunction of three conditions: the program performs the effect
   somewhere, the handle's body cannot reach it statically, and the body
   contains an opaque value call. All three are needed: without the first,
   the `Profiler` handle in `entry.vibe` and label-pun handles that vacuous
   erasure removes on purpose are flagged; without the third, a client-only
   `Http` handle is. Reachability uses the #885 / #1361 overlay, so a body that
   reaches the perform through a row-carrying parameter or an annotated local
   is not flagged. Detecting the switch dynamically is not cheaper: comparing
   "the handler for E now" when a continuation is invoked needs the evidence
   carried as a dynamic vector, which is most of implementing handler switch.
   A rewrapped handle whose body also performs the effect for real is not
   caught, since that handle does fire.

## Part B: aligning with wasip3 `future<T>` / `stream<T>`

The policy: **one suspend operation; `Future[T]` and streams materialized on
working machinery; each lowered 1:1 onto the p3 canonical built-ins.** Six
decisions.

### Decision 1: one `Async` operation, interchangeable backends

The builtin nominal `Async` row label (`await`, `sleep`) and the declared
`effect Async { Suspend(Int) -> Int }` in `@vibe/concurrent` are one label:
suspension is the single operation `Async::Suspend`. `sleep` lowers to a
perform (`__slp_perform`, `Suspend(-ms)`) when the program's entry row carries
`Async` or the program discharges `Async` with a `handle` (which is what makes
sleep virtualizable: a handler receiving `Suspend(-ms)` can fake time). The
`Suspend` payload bands are listed in [wasi-p3-async.md](wasi-p3-async.md)
§2.2.

`Async::Suspend` is an ordinary operation that appears in the source semantic
row (ADR-0075); that is what makes Decision 5's "`with Async` export →
`async func`" projection definable. What does not appear in the row is the
**backend** that discharges it:

| backend | state |
| --- | --- |
| the in-guest cooperative scheduler (`TaskGroup::pump`, `@vibe/concurrent`) | implemented |
| p3 `waitable-set.wait` in the component adapter (completion-order dispatch, wasi-p3-async §3.11) | implemented: host futures, host streams, `sleep`, and spawned tasks waiting on them together (#1537) |
| Component Model subtasks as the `TaskGroup` backend | not implemented: tasks are guest fibers — #3147 |
| JSPI (browsers) | not implemented, no owner |

ADR-0068's "Async is non-transitive" is kept as the non-propagation of the
backend choice; tracking the operation itself follows ADR-0075's executable
contract. Spawning stays the `Spawn[r]` capability's job.

### Decision 2: `Future[T]` is a runtime cell, not a phantom type

`Future[T]` is the two-word cell `[state, payload]` — 0 ready, 1 guest
pending, 2 host future, 3 host stream — and `await` is rewritten by the AST
pass `await_poll_pass` into a poll loop that performs `Async::Suspend` while
the state is non-zero. The cell, the payload bands and the lowering are
specified in [wasi-p3-async.md](wasi-p3-async.md) §2.2. A future taken from a
host import parks the task in `waitable-set.wait` (the "third park kind" next
to poll and sleep); the in-guest scheduler, which has no completion source for
a host handle, treats such a payload as a poller and so degrades to its
deadlock trap rather than a silent livelock.

Two refinements of the decision as first written:

- It first named a `TaskCell` / `TaskStep`-based handle. The cell is what
  shipped: `TaskHandle::result_wait` is the library form of "a task handle is a
  future", and `Future::pending` / `Future::resolve` are the guest producer.
- **`Future` takes no region parameter.** In the poll model the cell is plain
  shared memory with no scheduler coupling, so a capture is `Spawnable` without
  a region check (`sp_spawnable_ok`). Revisit if the cell ever carries a waiter
  list the scheduler can see.

Merging the Int control word and the typed payload into one typed operation
(`perform Async::Await(f) : T`) waits on ADR-0071's generic instantiation of
operations; the split of control (Int) from data (the heap cell) is otherwise
the permanent design.

### Decision 3: eager `Stream[T]` is retired; AsyncIter is the guest stream protocol

The eager, Array-backed `Stream[T]` builtin and the phantom `Task[T]` are gone
(#1538, #1227). Streams take three deliberately distinct roles (wasi-p3-async
§2.4):

- **AsyncIter** (`AsyncIterator`, `next(Self) -> Future[Option[(T, Self)]]`,
  `lib/@vibe/builtin/async_iter.vibe`) is the guest-side pull protocol.
- **`HostStream`** is a host-owned readable `stream<u8>` end, read with
  `HostStream::next` / `host_stream_next` and released with
  `HostStream::close`; `for b in s` over one reads it (#1341, #1955).
- **`ByteStream`** is the nominal boundary type that maps to WIT `stream<u8>`.

stdin is not a named `HostStream`: `wasi:cli/stdin@0.3.0` hands over a stream
and a completion future together, which the opaque `StdinStream` provider
carries (#1539).

### Decision 4: coroutines inside the guest, host-owned streams at the boundary

The talk's `Coroutine` / `Yielded(x, resume)` (Part A) is how a guest-side
AsyncIter producer is written: yield is a perform, and the handler keeps the
continuation and advances it one step per `next`. A producer inside the
component cannot feed a component-level stream — an intra-component producer is
a dead end (wasi-p3-async §3.3.1) — so the model has two layers: **a coroutine
or the scheduler inside the guest; a host-owned `stream<T>` at the component
boundary**. A stream that crosses the boundary is never implemented as a guest
coroutine. Boundary handles stay nominal, non-generic specializations
(`ByteStream`, `HostStream`) for the same reason.

### Decision 5: the WIT mapping

`wit_gen` maps:

- `Future[T]` → `future<T'>`;
- an export whose row carries `Async` → `async func` (`Async` is never emitted
  as an import: it is the suspension effect the async lift implements);
- a stream → `stream<T'>` **only** for a nominal boundary handle whose producer
  end the host owns (`ByteStream` → `stream<u8>`). A guest-produced AsyncIter
  in a component signature stays a hard error, as every unmapped type is:
  advertising it as `stream<T>` would promise an ABI the lowering cannot
  implement.

The serve handler is an async lift too: a `body: HostStream` parameter makes
it `handler(.., body: stream<u8>)` (wasi-p3-async §3.18.4), and a handler that
awaits WIT responses composes into the `wasi:http/service` world (§4). How
resource-qualified capabilities project to WIT follows ADR-0075 / ADR-0088
([effect-wit-mapping.md](effect-wit-mapping.md)).

### Decision 6: probe first, then a byte-exact emitter

The implementation followed the repository's order — a probe measured on
wasmtime, then an emitter checked byte for byte against it. The steps, all
landed under #1218 and its follow-ups; each links to its measurement record in
[wasi-p3-async.md](wasi-p3-async.md):

1. **A `future<T>` value probe** (`tools/wasip3_component_probe/future_value/`).
   Measured: `future.*` built-ins are named `[future-<op>-N]<function that
   introduced them>` (per function and type index); `future.read` arrives
   async-lowered and rides the existing waitable-set machinery; a future value
   adds only the `future.*` family. Details in the probe's
   `canon-imports-exports.wit-abi.txt`.
2. **The `future.*` / `stream.*` canon emitters** (`emit_canon_future_*` /
   `emit_canon_stream_*`, the `(future u32)` / `(stream u8)` type sections, and
   the fixed-shape `comp_emit_component_wasm_future_value` /
   `comp_emit_component_wasm_stream_value`). The async canonopt on both sides
   is what avoids the single-task self-rendezvous deadlock. §3.12.
3. **Decision 1's unification** in the suspend lowering: `sleep` retargeted
   to `Async::Suspend(-ms)` with a tail-resumptive entry boundary that settles
   the debt (`lc_inject_async_sleep_boundary`, gate 77), and `handle ... with
   Async` discharging the builtin row.
4. **`await` in real `.vibe` source reaching the component**:
   `host_future_get()` → a state-2 cell → `Suspend(handle + 2)` → the entry
   boundary parks in `waitable-set.wait` through the adapter. §3.13–§3.14.
   (c) **Named host futures**: `host_future_named("price")`, one component
   import per name, read eagerly by the adapter so several are in flight at
   once. §3.16.

What followed on the same path: the resolve → direct-wake waiter list
(§3.15), named host streams and their close (§3.17–§3.18.1), `for` over a host
stream (§3.18.2), `HostStream` as a serve-handler parameter (§3.18.4), `sleep`
inside a component (§3.18.6), TaskGroup tasks under an Async entry (#2065) and
waiting on host futures, streams and timers together (#1537), WIT-derived async
imports lowered as written (#2064, #3131), and the outbound `wasi:http` client
path (#2066). The current inventory and the open work are in wasi-p3-async
§6.

## Non-goals

- Implementing handler switch, effectful higher-order effects or multi-shot
  `resume`. Part A records the gaps and the diagnostics.
- ADR-0088's authorization model, which is orthogonal: `Async::Suspend` is an
  operation in the row, the backend is not, and spawning is the `Spawn[r]`
  capability.

## Open

- A one-shot violation is a dynamic trap only; there is no static affine
  check. Making `Future[T]` or stored continuations part of a public API would
  need a better misuse diagnostic. No open issue.
- The suspendable-task lane (`TaskGroup::spawn_suspend`, `pump`, `sleep_wait`,
  the task-level `effect Async`) is still `@vibe/concurrent/experimental`
  behind `VIBE_UNSTABLE=1`; promoting it is #3200.
