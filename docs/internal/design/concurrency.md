# ADR-0068: structured concurrency

Status: accepted for the core, which ships as `@vibe/concurrent` with no
opt-in ([stable-surface §3.1](../../user/reference/stable-surface.md)). The
suspendable-task lane, `@vibe/concurrent/experimental`, is proposed: it is
accepted when one spawn covers both lanes and no program drives the scheduler
by hand (#3200).

Related: ADR-0008, ADR-0012, ADR-0071, ADR-0075, ADR-0076, ADR-0085,
ADR-0089, ADR-0090, ADR-0100; #3147, #3200.

## Scope

This document is the specification of structured concurrency: what a program
observes when it opens a task group, spawns into it, waits, cancels, sends a
message, or fails. The frozen contract is
`lib/@vibe/concurrent/index.vpkg`; this document says what its declarations
mean and which compiler checks come with them.

Elsewhere:

- the user guide is the book's chapter 17
  (`book/en/17_concurrency.vibe.md`);
- the host side -- WASI 0.3 futures, streams and the entry boundary -- is in
  [wasi-p3-async.md](wasi-p3-async.md) and
  [async-host-contract.md](async-host-contract.md);
- the compiler as a concurrent workload is in
  [compiler-parallelism.md](compiler-parallelism.md).

Where one of those disagrees with this document about what a program
observes, this document decides.

## Decisions

1. **The public model is shared-nothing structured concurrency.** OS threads,
   Workers and Wasm threads are not language values. A program opens a task
   group, spawns tasks into it, and the group does not return while a task in
   it is live.
2. **A task group is scoped by a generative region.** Each `TaskGroup::run`
   mints a region that no source text can name. The group, its task handles
   and its channel endpoints carry that region, and the compiler refuses a
   body that returns one of them or stores one in a location declared before
   the body.
3. **Failure is an exception row, not a wrapper** (ADR-0085). `run` and
   `join` return the value itself and throw `TaskError`. A task that fails
   cancels the siblings that are not already running, and `run` throws the
   first failure it observed.
4. **What crosses a task boundary is judged by the compiler.** `Send` is a
   structural judgement the compiler makes from the type; no program can
   implement it. A spawned closure may capture only `Send` values and
   endpoints of its own group (`Spawnable`).
5. **The meaning does not depend on the backend.** What ships is one
   cooperative, deterministic scheduler inside one instance. Component Model
   subtasks (#3147) and shared-everything threads (#488) are candidate
   backends that must produce the same observations. JSPI is a way to lower
   suspension, not a thread model.
6. **The compiler is the first CPU-bound user.** Its parallel frontend uses
   the same shared-nothing contract: workers return values, and a coordinator
   commits them in a canonical order
   ([compiler-parallelism.md](compiler-parallelism.md)).

## Terms

| Term | Meaning |
| --- | --- |
| task group | the scope opened by `TaskGroup::run` (or `taskgroup { g => .. }`); every task spawned into it ends before `run` returns |
| task | one unit of execution, failure and cancellation, owned by one group |
| task handle | `TaskHandle[rg, e, T]`, the value `spawn` returns; `join` reads the task's outcome through it |
| region | the type argument `rg` that `run` mints fresh for each call |
| endpoint | a value tagged with a group's region: the group itself, a task handle, a `Sender`, a `Receiver` |
| ready queue | the group's FIFO of spawned tasks that have not started |
| parked | a suspendable task stopped at a suspension point, its continuation stored in its cell |
| nursery | the formal model's name for a task group (Trio's term); the library spells it `TaskGroup` |

A task is not an OS thread. A conforming backend may run tasks on one thread
or several, and the program observes the same outcomes either way, up to the
orders this document leaves open.

## Core surface

The stable core declares (`lib/@vibe/concurrent/index.vpkg`; the comments
naming the error types' variants are added here):

```text
type TaskGroup[rg, e]
type TaskHandle[rg, e, T]
type TaskError                // Failed(String) | Cancelled
type SendError                // Closed
type ChannelConfigError       // NegativeCapacity
type Channel[rg, e, T]
type Sender[rg, e, T]
type Receiver[rg, e, T]
type Parallel

fn TaskGroup::run[T, rg, e](body: (TaskGroup[rg, e]) -> T with e) -> T with Exception[TaskError] + e
fn TaskGroup::spawn[rg, e, T: Send](n: TaskGroup[rg, e], f: () -> T with Exception + e) -> TaskHandle[rg, e, T]
fn TaskHandle::join[rg, e, T](h: TaskHandle[rg, e, T]) -> T with Exception[TaskError] + e
fn TaskHandle::cancel[rg, e, T](h: TaskHandle[rg, e, T]) -> Unit
fn Channel::bounded[rg, e, T: Send](n: TaskGroup[rg, e], capacity: Int) -> (Sender[rg, e, T], Receiver[rg, e, T]) with Exception[ChannelConfigError]
fn Sender::send[rg, e, T](s: Sender[rg, e, T], v: T) -> Unit with Exception[SendError] + e
fn Sender::clone[rg, e, T](s: Sender[rg, e, T]) -> Sender[rg, e, T]
fn Sender::release[rg, e, T](s: Sender[rg, e, T]) -> Unit
fn Receiver::recv[rg, e, T](rh: Receiver[rg, e, T]) -> Option[T] with e
fn Parallel::map[rg, e, T: Send, U: Send](n: TaskGroup[rg, e], xs: Array[T], f: (T) -> U with Exception + e) -> Array[U] with Exception[TaskError] + e
```

The implementation lives in `lib/@vibe/concurrent/experimental/concurrent.vibe`;
`@vibe/concurrent` re-exports the stable subset of it.

`e` is the row a spawned task may perform besides `Exception`. It is a
parameter of the group, so it appears in `run`'s own row: whatever a child
does is visible in the signature of the function that runs the group, and a
group whose children perform nothing asks nothing of its caller.

A minimal program (the book's first example):

```vibe
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main allows Console + Exception {
  let answer = TaskGroup::run((n) -> {
    let h = TaskGroup::spawn(n, () -> {
      21 * 2
    })
    TaskHandle::join(h)
  })
  println("answer = \{answer}")
}
```

The eager `Task::*` prototype (`Task::spawn` / `join` / `cancel` / `race` /
`timeout`) is not part of the language: it ran its thunk inside `spawn`, so
two spawns always ran one after the other. Those names are not registered
builtins (`lib/@vibe/compiler/tests/checker_async_test.vibe`).

## Task groups

`TaskGroup::run(body)` creates an open group, calls `body` with it, and then
closes the group:

1. Every task still in the ready queue runs (or is resolved `Cancelled`, see
   below).
2. Every suspendable task still parked is pumped until it is terminal, under
   the same rules as `pump_all`: host futures and stream reads settle, timers
   and sleep debts run down, and siblings that wait on each other interleave.
3. If any task failed, `run` throws `TaskError::Failed(m)`, where `m` is the
   first failure the group observed. Otherwise it returns the body's value.

A child's failure does not interrupt the body. The body sees it only through
`join`, and the group reports it when it closes even if the body caught the
`join` failure and returned normally.

A throw that escapes the body itself is not converted. The group cancels its
parked children, releases what it holds on the host (a pending timer), and
re-throws the payload unchanged, kind included. Tasks still in the ready queue
never run.

`taskgroup { g => body }` is parser sugar for `TaskGroup::run((g) -> body)`:
the parser builds the same call, so every check below applies to it unchanged.
The body after `=>` is one expression; several statements need their own
braces. The sugar resolves `TaskGroup::run` by name, so the program still
imports `TaskGroup` from `@vibe/concurrent`.

Groups nest. A task may open a group of its own, and the inner group closes
before the task that opened it can finish.

## Lifecycle

### Tasks

A task is in one of these states:

```text
Ready -> Running -> Succeeded
            |   \-> Failed
            v
          Parked -> Running        (suspendable tasks only)
Ready  -> Cancelled                (cancel point: dispatch)
Parked -> Cancelled                (cancel point: parked)
```

A terminal state (`Succeeded`, `Failed`, `Cancelled`) is set once and never
changes, so joining twice observes the same outcome.

`TaskGroup::spawn` does not run the closure. It appends the task to the
group's ready queue and returns the handle; the task runs when something
drives the queue: a `join`, a blocking `send` or `recv`, or the group's
close. Dispatch is FIFO in spawn order. `TaskGroup::spawn_suspend` differs:
its body starts at once and runs to its first suspension (see the
suspendable lane below).

A spawn is accepted only while the group is open, the rule the lifecycle model
in `formal/VibeFormal/Async/Transition.lean` proves against. A spawn into a
group that is cancelling after a child failed -- including from a body that
caught the failed child's `join` and carried on -- traps with a message saying
the group is cancelling, and a spawn after the body returned (closing or
closed) traps with a message saying so (#3277). `TaskGroup::adopt` (the
suspendable lane) follows the same rule.

### Join

`TaskHandle::join(h)` returns the task's value, throws `Failed(m)` for a task
that failed, and throws `Cancelled` for one that was cancelled. While the task
is not terminal, `join` drives the group on the caller's stack:

- a task in the ready queue: run the next ready task, and look again;
- a parked task: run any ready task first (it may be the producer the parked
  task waits on), otherwise pump the group until this task is no longer
  parked.

Joining a task that is currently running -- a join that cycles back through
the tasks being driven -- traps with a message naming the cycle, and a join
whose target can never be woken traps as a deadlock.

### Cancel

`TaskHandle::cancel(h)` is a request, idempotent, and a no-op on a terminal
task. It is observed at two points:

- **dispatch**: a task in the ready queue is resolved `Cancelled` without
  running its body;
- **parked**: a parked suspendable task is resolved `Cancelled` at once, and
  its stored continuation is dropped, so reference counting frees what it
  captured (ADR-0076). A host wait it was parked on is released.

A running task is not interrupted, and no check inside a running body
observes the request. A cancelled child does not fail the group: only its own
`join` throws `Cancelled`.

### Groups

A group's phases follow the formal model:

```text
Open -> Cancelling -> Closing -> Closed
   \-----------------> Closing
```

`Cancelling` is entered when the first child fails while the group is open.
`Closing` is entered when the body returns, and `Closed` once every child is
terminal. A group's channels close with it.

### Failure and fail-fast

An exception that escapes a child's closure becomes that child's `Failed(m)`.
The group records the first failure it observes, then:

- every task still in the ready queue is resolved `Cancelled` when its turn to
  dispatch comes;
- every parked suspendable sibling is cancelled at once.

A sibling that is already running finishes. When several children fail, which
one the group reports depends on the order the scheduler observed them; a
program must not rely on it.

The message `m` is built from the payload: a `String` or `Int` payload is its
own text; a payload the throw site can render arrives rendered (`SendError`
derives `Show`, so `Closed` becomes `"Closed"`); any other payload arrives as
`<TypeName>`. The original value does not cross the task boundary:
a caller of `run` or `join` matches `TaskError`, not the child's own error
type.

A failure the program wants to recover from is a value. A child that handles
its own `Exception[E]` and returns an ordinary enum is a succeeded task, and
the enum's payloads must be `Send` like any other result.

Wasm traps, process aborts, and a host killing the instance are not task
failures. They end the instance.

### Deadlock

The scheduler is deterministic, so a wait that nothing in the group can satisfy
never resolves. Such a wait traps instead of hanging:

- a stack-driving `join`, `send` or `recv` with no ready task to run, and
  `pump_all`, `join` on a parked task, or a group close, when every task left
  waits on something no task in the group can produce, trap with one message:
  ``vibe: deadlock in TaskGroup::run: every task left is waiting on something
  no task in the group can produce ...``.

A cooperative yield is never counted as evidence of a deadlock: resuming a
yielding task always advances it, so an endlessly yielding task is an ordinary
infinite loop.

## Lean lifecycle oracle

The backend-independent part of the lifecycle is a Lean model:

- `formal/VibeFormal/Async/State.lean`: task, nursery and cancel-request state
- `formal/VibeFormal/Async/Transition.lean`: the transition per scheduler event
- `formal/VibeFormal/Async/Trace.lean`: finite traces of permitted transitions
- `formal/VibeFormal/Proofs/AsyncSafety.lean`: terminal outcomes and join results are stable
- `formal/VibeFormal/Proofs/NurseryCorrect.lean`: spawn requires an open nursery; close requires every child terminal
- `formal/VibeFormal/Proofs/AsyncExamples.lean`: accepted traces and rejected broken ones

The model has no separate `Created` state: spawning an unregistered task makes
it `ready`. A parked task is `blocked` with a wait reason (`join`, an external
key, or `yield`). Task outcomes are `succeeded` / `failed` / `cancelled`; a
nursery is `open` / `cancelling` / `closing` / `closed`.

The transition relation fixes:

1. `spawn` is allowed only into an `open` nursery and an unused task id.
2. A cancel request is idempotent and is observed as `cancelled` only at
   dispatch, suspension, or a blocked wait.
3. Cancelling one child explicitly does not turn the nursery's cause into a
   failure.
4. With several failing children the nursery keeps the first one it observed;
   every child is terminal before the nursery is `closed`.
5. A terminal task and a `closed` nursery do not change in later steps, so
   repeated joins observe the same outcome.

An implementation must be able to project its event trace onto this relation.
Backends differ only in which permitted event comes next.

The oracle does not model the heap, threads, host waitables, channel queues,
message linearization, fairness, infinite traces, or finalizers. Terminal
states are proved to be set once; that a concrete unwind runs each finalizer
exactly once is not proved, and today there is no finalizer registration to
prove it about.

Two smaller models cover the static rule and the channel:

- `formal/VibeFormal/Parallel/SpawnCapture.lean`: the capture rule
  `sp_spawnable_ok` enforces -- a capture is legal when it is `Send` or an
  endpoint of the spawning group's own region;
- `formal/VibeFormal/Parallel/ChannelDelivery.lean`: one channel delivers what
  was sent, once each, in order, and a close does not discard buffered
  messages.

### Parallel refinement oracle

A multi-worker backend refines the lifecycle rather than replacing it:

- `formal/VibeFormal/Parallel/State.lean`: worker slots, task assignment, heap owners
- `formal/VibeFormal/Parallel/Transition.lean`: claim / release, projected onto async events
- `formal/VibeFormal/Parallel/Trace.lean`: physical worker traces
- `formal/VibeFormal/Proofs/ParallelSafety.lean`: the assignment invariant, trace refinement, and disjoint task-local heaps
- `formal/VibeFormal/Proofs/ParallelExamples.lean`: a two-worker run, a release, and rejected double claims and shared accesses

Each running task holds exactly one worker slot, and two workers cannot claim
the same task. Suspension, cancellation and completion release the slot, and
a woken task may resume on another worker; worker affinity and migration are
not observable.

Every parallel step contains the async step it projects to, so a backend
cannot add threads by changing cancel points, the first-failure rule, or the
close condition. Simultaneous execution is represented as an interleaving,
which loses no observation because tasks share no mutable location.

Heap safety is stated as ownership: each location has one owner task, and a
running task touches only locations it owns. With unique worker assignment,
two workers never touch the same task-local location. That an allocator, a
deep copy or a move actually realizes this ownership is a separate refinement
obligation; the Lean model does not verify an allocator or Wasm memory
accesses.

## Channel semantics

`Channel::bounded(n, capacity)` creates a bounded multi-producer,
multi-consumer channel owned by group `n`:

- `capacity` is an `Int`, 0 or more. 0 is a rendezvous channel. A negative
  capacity throws `NegativeCapacity`. There is no unbounded channel: it would
  lose backpressure.
- `Sender::send` returns once the message is linearized: buffered, handed to a
  receiver, or consumed by a receiver it drove. While the buffer is full (or,
  at capacity 0, no receiver has taken the message) it drives the group's
  ready tasks on the caller's stack.
- `Receiver::recv` returns `Some(message)` in linearization order, or `None`
  once the channel is closed and drained. While the channel is open and empty
  it drives the group's ready tasks.
- Messages from one `Sender` arrive in the order they were sent. Messages from
  different senders arrive in their linearization order, which a program must
  not depend on.
- `Sender::clone` adds a sender; `Sender::release` removes one. Releasing the
  last sender closes the channel. A sender is not released implicitly:
  forgetting `release` leaves the channel open until its group closes.
- Messages already buffered stay receivable after the close; `recv` returns
  `None` only after they are drained.
- A `send` on a closed channel throws `SendError::Closed`. So does a blocked
  `send` whose channel closes before its message is taken. No sentinel value
  stands in for either.
- A group's channels stay open while the group closes, so children joined at
  close can still use them, and close once the group is closed.

An explicit `close(sender)` is not part of the surface. Closing is decided by
the last release and by the group's scope.

The suspendable lane adds `Sender::send_wait` and `Receiver::recv_wait`, which
suspend the calling task instead of driving others (below). Both lanes share
one linearization, so the guarantees above hold across them.

<a id="send-と-capture-safety"></a>

## `Send` and capture safety

This section is the canonical statement of the `Send` allowlist. Other
documents link here instead of copying it. The behaviour is pinned by
`lib/@vibe/compiler/tests/send_allowlist_test.vibe`, so the list below cannot
drift from the checker without a test failing.

### `Send`

`Send` is a marker the compiler judges from a type's structure
(`type_send_ok` in `lib/@vibe/compiler/checker/checker_trait.vibe`). It is
not a trait a program can grant: `impl Send for X` is refused with
`` `Send` is a compiler-judged structural marker and cannot be implemented;
remove `impl Send` ``.

Send:

- `Unit`, `Bool`, `Int`, `Double`, `String`, `Char`;
- a tuple or an anonymous record whose components are all `Send`;
- `Option[T]` when `T` is `Send`;
- a declared struct with no `mut` field whose fields are all `Send`, and a
  declared enum whose payloads are all `Send`, at the instantiation in use.
  The name does not matter: a `Result[T, E]` a program declares itself is
  `Send` exactly when its components are (`Result` is not a builtin, #1324);
- a type alias, judged by what it stands for;
- `FrozenArray[T]` when `T` is `Send`;
- inside a generic body, a type parameter bounded by `Send`, or by a trait
  whose supertraits include `Send`: every instantiation is checked at its call
  site.

Recursive types are judged coinductively: meeting the same type at the same
instantiation again does not fail the check. A non-regular recursion (each
level at a new instantiation) is cut off at a fixed depth and judged not
`Send`.

Not Send:

- `Array`, `Bytes`, and any struct with a `mut` field;
- closures;
- a type with an unresolved type variable, even when every resolved part is
  `Send`: an unannotated `Result::Ok(1)` leaves `E` open and is refused;
- a type parameter with no `Send` bound;
- any named type with no visible declaration -- host resources, opaque
  handles, and the builtin `Map`.

`Send` is required wherever a value moves between tasks: a spawned task's
result (`TaskGroup::spawn[.., T: Send]`), a channel's element type
(`Channel::bounded[.., T: Send]`), and `Parallel::map`'s inputs and outputs.

### `Spawnable`: what a spawned closure may capture

A closure is never `Send`, so a spawned closure is judged by what it
captures. A capture is legal when it is:

- a value whose type is `Send`;
- an endpoint of the spawning group's own region: a `TaskGroup`,
  `TaskHandle`, `Sender` or `Receiver` whose region is the region of the
  group passed to this spawn. An endpoint of another group is refused like
  any other non-`Send` value;
- a builtin `Future[T]`, unless its value owns a host stream (a
  `HostResponse` or `HostStream` anywhere inside it, or a type parameter with
  no `Send` bound that could be instantiated at one). A response body has one
  reader, so the request belongs inside the task that reads it.

A captured `let mut` is refused whatever it holds: it shares a mutable cell
across the spawn boundary. A capture that holds a host stream is refused with
the edit (open the stream inside the task).

The check is `check_spawnable_captures`
(`lib/@vibe/compiler/checker/checker_spawnable.vibe`). It runs at every call
whose callee has spawn's shape -- a `TaskGroup[rg, e]` first parameter and a
closure last parameter -- which covers `TaskGroup::spawn`,
`TaskGroup::spawn_suspend`, `Parallel::map`, a local `let` alias, a renamed
import, and a wrapper of the same shape. It is selected by the callee's type,
not its spelling. A spawn-shaped function taken as any other value -- passed
as an argument, stored in a field, returned -- is refused where it is taken,
because no later call could see the closure it would run.

The closure argument must be one whose captures the check can see:

- a closure literal at the call;
- a name bound by a local `let` to a closure literal, whose captures were
  recorded where the `let` was checked;
- a top-level function, which captures nothing;
- inside a spawn-shaped function, its own closure parameter: every call site
  of that function is itself checked.

Anything else -- a closure a helper returned, a field, a rebound name -- is
refused: ``no impl `Spawnable` for closure `q`: its captures cannot be seen
here -- write the closure literally at this call, or bind it with a local
`let` to a closure literal``. A local closure called inside the spawned body is
a capture too, and is judged the same way.

The adoption lane (`TaskGroup::adopt` / `TaskHandle::settle`) takes no
closure, so it is not spawn-shaped and this check does not apply to it.

## Regions and escape

`TaskGroup::run` mints a fresh region for each call: the checker binds the
call's `rg` to a rigid name of the form `#region_<n>`, which the lexer cannot
produce, so no source text can forge or unify with it. Like the spawn check,
this is selected by the callee's type: a function taking one closure whose one
parameter is a `TaskGroup[rg, e]` with `rg` quantified by the function itself,
and returning that closure's result. A `let` alias, a renamed import and a
wrapper of that shape mint their own region per call; `run` taken as any other
value is refused; a runner whose region an earlier use already fixed is
refused with the edit (call `TaskGroup::run` directly, or bind it with a local
`let` at each use).

A body written as a closure literal at the call -- the usual spelling, and
the one the `taskgroup { g => .. }` sugar produces -- is checked inside the
region, the way ADR-0090's `region r { .. }` block is: the group parameter
carries the region from the first line of the body, and every binding visible
at the call is outside the region. A **write that stores the region in a
location declared before the body** is refused where it is written: an
assignment, a field write, `Array::set` / `Array::push`, or any other mutable
container write the checker knows retains its argument, made from the body or
from a closure written in it, to an outer binding directly or through a local
alias of one. The target's declared type does not matter -- a generic struct
value whose type argument is still open, an array annotated
`Array[Option[TaskHandle[Int]]]`, an unannotated `let mut slot = None` are all
refused the same way. Neither does the stored value's type alone. A type
names the region only as far as it has room for it: a struct or enum does not
show its fields' types, an annotation may spell `TaskHandle[Int]` for a handle
of the group, and a closure's type does not list what it captured. Where the
stored value's type may hide a region, the value is judged by what it READS --
a value can carry a region only if a variable it reads carries it, since the
token itself is a variable. A variable carries what its type shows, or, where
its type may hide a region, what its binding recorded: a `let` or `let mut`
records what its value read AND what every write into it anywhere in its scope
writes (a field write, `Array::push` / `Array::set`, an assignment, a write
through an alias of it or by a helper handed it -- a flow-insensitive union,
so a write later in a loop than the read that stores the binding counts too),
a parameter of a re-checked callee (below) what its argument carried, and a
binding that records nothing (a pattern, a loop variable, a parameter of a
lambda written in the body) carries every region it was declared inside. So
`Some(Box::{ h: handle })`, `let b = Box::{ h: handle }` written later, `let b
= Box::{ h: None }` with `b.h = Some(handle)` after it, an enum payload, a
struct two levels deep, and the result of a helper declared `->
TaskHandle[Int]` or `-> Box` are all refused when stored outside:

```text
region escapes its nursery scope: this write stores this TaskGroup::run call's
own Nursery/Task/Sender/Receiver token in a binding declared outside the body
-- join the task (or use the endpoint) inside the body and store the result
instead, or declare the binding inside the body
```

A joined result, or a handle kept in a local declared inside the body, is not
an escape. Neither is a nested group storing the outer group's handle in a
local of the outer body.

**Code written outside the body is checked where the token reaches it.** A
call made inside the region that passes a value carrying the region -- a
handle, an endpoint, the group, a closure that captured one -- to a function
declared in the module, or to a `let`-bound closure literal, checks that
callee's lambda again under the call's region:

- the callee's own scope (the module for a top-level function, the scope the
  closure was written in) lies outside the region, so a top-level binding and
  every binding the callee captured are outer bindings, as they are for a
  write in the body;
- each parameter is bound to its argument's type at the call, so the token is
  seen even where the callee's annotation spells the type without a region
  (`TaskHandle[Int]`);
- a parameter whose argument is a location declared before the region stands
  for that outer binding, for that region only (a nested group's helper may
  still store the outer group's handle in a local of the outer body).

A write the second check refuses refuses the call, naming the callee:

```text
region escapes its nursery scope: this call to `put` stores this
TaskGroup::run call's own Nursery/Task/Sender/Receiver token in a binding
declared outside the body -- join the task (or use the endpoint) inside the
body and pass the result instead, or declare the binding inside the body
```

This covers a helper that stores its argument (`fn put[T](c: Cell[T], v: T)
{ c.v = Some(v) }` called as `put(c, handle)`) wherever it is declared and
however many calls away the write is, a method (`c.put(handle)`), a closure
bound before the group or inside the body (`stash(handle)`), directly or
through a `let` alias, and a lambda applied where it is written. A body passed
by name (`TaskGroup::run(body)`) is checked the same way, its group parameter
carrying the region as a literal body's does:

```text
region escapes its nursery scope: `body`, the body this TaskGroup::run call
runs, stores the call's own Nursery/Task/Sender/Receiver token in a binding
declared outside it -- join the task (or use the endpoint) inside the body and
store the result instead, or declare the binding inside the body
```

A body passed to `TaskGroup::run` whose code is not visible here -- a `let mut`
closure, a parameter, a call's result, a function stored in a field -- is
refused, since it was checked where it was written, outside the region
(`... is a function whose body the checker cannot see ... -- write the body
inline at the call, or bind it with `let` to a closure literal and pass that
name`).

An argument whose type may hide the region -- a struct built from the
handle, say -- is judged by what it reads, as a stored value is, so
`put(c, Box::{ h: handle })` re-checks `put`, whose parameter then carries
what the argument carried.

What the callee RETURNS is not judged at the call. The second check also
finds which regions the callee's result carries -- by its type, or, where the
type may hide one, by what its tail and every explicit `return` read -- and
the call's result carries those into the caller: the result of `fn start(g:
TaskGroup) -> TaskHandle[Int]`, of a helper that returns a struct, tuple or
closure built from its argument, or that hands it back with an explicit
`return` in any branch, carries the group's region, while a helper that is
handed a closure over the region and returns another closure passes nothing
on. Joining or matching on the result inside the body is legal; storing it
outside, returning it from the body, or handing it to a function that keeps
it is refused by the same checks as the handle itself. A call nothing checks
again (an imported function) carries what its arguments carry. A generic
`fn id[T](x: T) -> T` shows the region in its result type, which answers the
same way.

A callee is checked again once per distinct call shape -- the callee, and for
each argument whether it carries the region, the regions its location
predates, and, for a function argument, which function it is -- so a helper
that recurses with a different callback (`walk(safe, h)` calling
`walk(stash, h)`) checks that callback too.

A callee that keeps nothing -- one that only reads its argument, or stores a
joined result -- is accepted. A function the callee is passed is followed: the
parameter stands for the argument's own body during the second check, so a
helper that calls `f(handle)` judges the closure it was handed. A closure that
captured a value of the region is checked at each call even when no argument
carries the region, since it may hand that value to such a function.

A function VALUE whose body the checker cannot see is judged by where it comes
from. A parameter of a lambda written inside the region (or checked again
under it) is answered for at that lambda's own calls, where its argument is
known, so `let apply = (f) -> f(n)` followed by `apply((g) -> 1)` is accepted.
Any other -- a parameter of the function that minted the region
(`fn run_with(cb: (TaskHandle[Int]) -> Unit)` calling `cb(handle)` in its
group), a value a call returned, a `let mut` closure, a function stored in a
field -- is refused when it is handed the token, since nothing about what it
keeps is known (`this call passes this TaskGroup::run call's own ... token to
`cb`, a function whose body the checker cannot see`). A function imported from
another module is not checked again; see [Known gaps](#known-gaps). The second
check runs only inside a region and only for such a call; its diagnostics,
types and substitution are discarded, and the per-run tables it touches are
restored (`lib/@vibe/compiler/checker/checker_region_retention.vibe`).

After the body is checked, the call is also refused when:

- **the returned value mentions the region** -- the body returns a task
  handle, an endpoint, or anything containing one, through its tail or an
  explicit `return`, a value whose type hides the region judged by what it
  reads as above: `region escapes its nursery scope: the value returned from
  this TaskGroup::run body still depends on its own
  Nursery/Task/Sender/Receiver token`;
- **a binding visible at the call now mentions the region**: `region escapes
  its nursery scope: an outer binding now depends on this TaskGroup::run
  call's own Nursery/Task/Sender/Receiver token`. This scan sees a binding
  only when every use of it shares one type instance (an array whose element
  type is still open, a `let mut` option), so it is a backstop behind the
  write check, which it does not repeat. The return check has no such limit.

Inside the body, a `let` bound to a region-tagged type is not generalized
(`is_region_tagged_ty` puts it under the same value restriction as an
`ArrayBuilder`), so the binding keeps its region.

Pinned by `fixtures/region_ok_basic.vibe`, `fixtures/err_region_escape_return.vibe`,
`fixtures/err_region_escape_run_local_alias.vibe`,
`fixtures/err_region_escape_run_rename.vibe`,
`fixtures/err_region_escape_run_value.vibe`,
`fixtures/region_ok_run_local_alias.vibe`, `fixtures/region_ok_not_a_runner.vibe`
and, through the sugar, `fixtures/err_taskgroup_sugar_region_escape.vibe`. The
write check is pinned by the `taskgroup_escape_*_reject` rows of
`fixtures/typecheck/expected.tsv` (generic struct field, annotated array set
and push, annotated `let mut`, an alias, a closure, the sugar, an alias of
`run`, a channel endpoint; and, for code written outside the body, a helper
declared above or below the call, a helper two calls away, a helper writing a
top-level array, a helper whose annotation hides the region, a method, a
closure bound before the group, inside the body and through an alias, a body
passed by name, a helper and a closure that hand the handle to the callback
they are passed, and a function-typed parameter of the function that minted
the group; and a helper returning the handle under `TaskHandle[Int]`, in a
struct, a closure or a tuple, or with an explicit `return` in a branch or a
`match` arm, a struct written directly, through a `let`, two levels deep or
handed to a helper, an enum payload written directly or handed to a helper, a
struct returned from a literal body through its tail, an explicit `return`, an
`if` or `match` tail or two structs deep, a helper recursing with another
callback, a body-local binding the handle is written into later -- by a field
write, `Array::push`, `Array::set`, an assignment, an alias or a helper, or
later in a loop -- and a `let mut`, call-result or field body) and by
`fixtures/taskgroup_outer_write_ok_test.vibe` (the writes and calls that stay
legal, a helper's erased result joined inside the body among them).

ADR-0090's `region r { .. }` mints its region the same way for region-bound
mutable storage. The write check above, and the second check of code written
outside the body, are that construct's own, applied to a task group's body;
only the diagnostic's wording differs (`region escapes its scope: this call to
`put` stores a value that captures this region into an outer binding`, pinned
by `region_escape_helper_push_reject` and, for a region-bound list handed over
inside a struct, `region_escape_struct_arg_reject`).

## Safe parallel API

There is no `Thread` type, worker handle or shared reference. The safe
parallel API is the task group, its handles and its channels. Whether two
tasks actually run at the same time is the backend's decision, and the same
program produces the same permitted traces on one worker or many.

`Parallel::map(n, xs, f)` spawns one task per element into `n` and joins them
in index order. It returns the results in input order; completion order is not
observable. A failing element makes `map` throw a `TaskError`, and fail-fast
cancels the elements that have not started. Its closure is judged like a
spawn's.

The boundary rules:

- a spawned closure satisfies `Spawnable`, and a task's result is `Send`;
- mutable cells, handlers, continuations and task handles of other groups do
  not cross a task boundary;
- when external effects must happen in a fixed order, route them through a
  channel to one task. Do not derive an order from task identity, completion
  time, or a CPU count;
- the number of workers is a property of the host, not of the program. No
  API exposes it, so changing it cannot change what a program computes.

## The suspendable-task lane

`@vibe/concurrent/experimental` is the whole runtime: the stable core plus
the API below. Importing it requires `VIBE_UNSTABLE=1` (ADR-0008), and it is
outside the SemVer promise ([stable-surface §6](../../user/reference/stable-surface.md)).

```text
effect Async { Suspend(Int) -> Int }

fn TaskGroup::spawn_suspend[rg, e, T: Send](n: TaskGroup[rg, e], f: () -> T with Async + Exception) -> TaskHandle[rg, e, T]
fn TaskGroup::pump[rg, e](n: TaskGroup[rg, e]) -> Bool
fn TaskGroup::pump_all[rg, e](n: TaskGroup[rg, e]) -> Unit
fn Sender::send_wait[rg, e, T](s: Sender[rg, e, T], v: T) -> Unit with Exception[SendError] + Async
fn Receiver::recv_wait[rg, e, T](rh: Receiver[rg, e, T]) -> Option[T] with Async
fn TaskHandle::result_wait[rg, e, T](h: TaskHandle[rg, e, T]) -> T with Exception[TaskError] + Async
fn sleep_wait(ms: Int) -> Unit with Async
```

plus the lower-level adoption API (`TaskGroup::adopt`, `TaskHandle::settle`,
`park`, `park_poll`, `park_kind`, `wake`, and `TaskStep[T]`). The effect
declaration is transparent: a program that declares the same `effect Async`
names the same effect.

### Why a second lane exists

A run-to-completion task (`spawn`) can wait only by driving other tasks on its
own stack. It cannot stop halfway and come back later, so two tasks that each
wait on the other mid-body -- a producer that overflows a channel's capacity
while a consumer drains it -- cannot both make progress, and the program traps
as a deadlock. A suspendable task can: its body is compiled to a sequence of
steps (ADR-0076's suspend lowering), and at a suspension point its
continuation is stored in its cell and resumed later. The lane exists until
one spawn covers both shapes (#3200).

### Spawning and the inline-closure rule

`TaskGroup::spawn_suspend(g, f)` registers the task and runs `f` immediately,
up to its first suspension; it does not enter the ready queue. A body that
finishes without suspending settles the task at once.

The body is written inline, as a closure literal at the call. A closure passed
to `spawn_suspend` -- or to any parameter whose row carries `Async`, such as a
wrapper around it -- must be compiled with the step-returning convention, and
only a literal written at that parameter is. A local closure passed by name
is refused with the edit:

```vibe skip
// doctest-skip: intentionally rejected -- a named task closure (#3194)
let p = () -> Int with Async + Exception {
  5
}
let h = TaskGroup::spawn_suspend(g, p)
// pass the task closure inline at `TaskGroup::spawn_suspend` instead of
// passing `p`: this local closure has the plain call convention
```

and a closure rebound to a new name (`let q = p`) is refused by `Spawnable`
(``no impl `Spawnable` for closure `q` ``). The accepted form, from
`fixtures/spawn_suspend_wrapper_inline.vibe`'s inline variant:

```vibe
import @vibe/concurrent/experimental {
  TaskGroup, TaskHandle
}

fn main() -> Int allows Async + Exception {
  TaskGroup::run((g) -> {
    let h = TaskGroup::spawn_suspend(g, () -> Int with Async + Exception {
      5
    })
    TaskGroup::pump_all(g)
    TaskHandle::join(h) + 1
  })
}
```

A body that suspends carries its row on the literal, as above. Without it the
suspension is charged to the enclosing function instead (measured: an
unannotated `() -> { sleep_wait(5); 41 }` makes `main` fail with ``effect row
mismatch for 'main': missing { Async }``). A body that never suspends needs no
annotation: `TaskGroup::spawn_suspend(g, () -> 6 * 7)` settles at once.

Pinned by `fixtures/err_spawn_suspend_{alias,ascribed,rebound,wrapper,wrapper_rebound}_plain.vibe`
and `fixtures/spawn_suspend_wrapper_inline.vibe`, whose gate rows in
`tests/gates/late/adr_0068_taskgroup_g_body_syntax_sugar.sh` assert the
messages. Whether a named task closure becomes acceptable, or the inline rule
becomes part of the frozen surface, is decided with #3200.

### Waiting inside a suspendable task

Inside a suspendable body, the `_wait` forms suspend the calling task; the
stack-driving forms do not.

| waits by | siblings | operations |
|---|---|---|
| blocking the instance | nothing runs | `sleep` outside a suspendable body |
| driving on the caller's stack | ready siblings run to completion | `join`, `send`, `recv` |
| suspending the task | siblings interleave with it | `sleep_wait`, `send_wait`, `recv_wait`, `result_wait`, `await` |

(When the entry's row carries `Async`, the compiler routes `sleep` everywhere
through the entry's async boundary instead, ADR-0089.)

- `Sender::send_wait` buffers when there is room. Otherwise it deposits the
  message (its linearization point) and suspends until that message is
  consumed. A close before then throws `Closed`.
- `Receiver::recv_wait` takes a buffered or deposited message, returns `None`
  on a closed and drained channel, and otherwise suspends.
- `TaskHandle::result_wait(h)` is the suspending `join`: it returns the
  sibling's value or throws its `Failed` / `Cancelled`. A sibling's failure
  usually cancels the waiting task first, through fail-fast.
- `sleep_wait(ms)` parks the task with a sleep debt. Inside a suspendable body
  the compiler rewrites a plain `sleep(ms)` to the same suspension, so the two
  are the same there. Sleeps overlap: when every parked task owes time, the
  scheduler spends the smallest debt once and debits it from every sleeper,
  so three tasks sleeping 300 ms each cost 300 ms, not 900. No wall clock is
  read.
- `await` on a builtin `Future[T]` parks the task until the future resolves.
  A task waiting on a future is woken by the resolve, not by polling.

A task blocked on a channel, a sibling or a future is woken by the event it
waits for. A waiting task that nothing in the group can wake makes `pump_all`,
`join` or the group's close trap with the deadlock message.

### Driving the lane

`TaskGroup::pump(g)` resumes one parked task, round-robin, and answers whether
anything ran. `TaskGroup::pump_all(g)` pumps until no task is parked. Neither
is required for correctness any more: `join` on a parked task pumps until that
task settles, and the group's close pumps every parked child. They remain the
way to interleave tasks before the body's own next step.

### Exceptions in a suspendable body

An exception that escapes the body -- before its first suspension or in any
resumed leg -- fails the task and the group exactly as for `spawn`, and
cancels parked siblings.

A `handle` inside a suspendable body may wrap code that suspends when it is
abortive: its arms handle another effect's operations (an
`Exception::Throw(m) => ..` catch is the shape), never mention `resume`, and
cannot reach `Async` themselves. The handler is reinstalled around every
resumed leg, so a throw after an `await` is caught by the arms written around
it (`fixtures/async_spawn_host_futures/catch_across_await.vibe`).

To observe a failure outside the tasks, put the `handle` around the
`TaskGroup::run` call itself. What arrives there is the group's
`TaskError::Failed(m)`, with the child's error rendered into `m`.

### Host waits

When a program's entry boundary settles host futures (ADR-0089), a
suspendable task that awaits a host future, reads a host stream, or sleeps
parks on a host waitable. When nothing else can run, the group waits on every
pending waitable at once, through the component adapter's shared waitable set,
and resumes whichever lands first, so tasks waiting on different host futures
interleave in completion order. Cancelling such a task releases its wait.
Without that boundary the library's hooks report "no host waitables"; a
waiting task then parks as a poller and an unsatisfiable wait traps as a
deadlock.

The tasks themselves are still guest-side continuations scheduled by
`@vibe/concurrent` inside one component instance. Backing them with Component
Model subtasks that the host can schedule and cancel is #3147.

## Effects and authority

Concurrency is not one coarse effect. What a child may do is the group's row
`e`, which is part of `run`'s row, so a task cannot perform anything the
function running its group does not declare, and authority is settled at the
entry as for any other call (ADR-0075, ADR-0088). The suspendable lane's
`Async` row is discharged inside the library: `spawn_suspend`'s body carries
`Async + Exception`, and its caller's row gains nothing from it.

Channels carry their authority as values: holding a `Sender` is what lets a
task send, so a channel's identity and direction stay in the types rather
than in an effect row.

A stored continuation belongs to its task: it is resumed by the scheduler for
that task only, at most once, and it is never `Send`, so no capture or
message can carry it to another task.

[vibex-runtime-contract.md](vibex-runtime-contract.md) states the executable
authority contract a multi-worker backend must keep: a child's authority is a
subset of its parent's and of what the composed host can delegate, and a
worker has no ambient authority of its own.

## Memory model

Logically, each task owns its heap and a message is a deep-copy snapshot taken
when the send linearizes; the receiver never holds a reference into the
sender's heap.

Today every task runs in one heap and a message is passed by reference. `T:
Send` admits only values with no mutable interior, which is what keeps that
from being observable. `FrozenArray::from_array` and `to_array` copy at the
conversion, so a retained `Array` handle cannot change a value after it
became `Send`.

A future backend may move a message instead of copying it only when the
compiler proves the sender's last use and that every allocation reachable from
it is transferable. A root reference count of 1 is not such a proof: it says
nothing about interior aliases.

The language memory model is data-race-free. There are no shared mutable
references, atomics, locks or weak-memory orderings in the surface, and a
shared-everything backend does not add them.

## Scheduler observability

The schedule is not part of the contract. A program may rely only on these
synchronization points: spawn, a suspension, a task's completion, a channel's
linearization, and a group's close. When external effects from several tasks
must be ordered (several tasks writing to `Console`, say), send them to one
owning task over a channel.

The cooperative backend switches tasks only at these points: a stack-driving
operation runs other tasks, a suspension parks one, and `spawn_suspend` runs
the new task's first leg before it returns. It is deterministic --
the ready queue is FIFO and parked tasks resume round-robin -- so a program
run twice produces the same trace. A parallel backend may run tasks at any
moment; because tasks share only what the rules above allow, the difference
is limited to the message and external-effect orders this document leaves
open.

## Backend mapping

| Backend | Suspension | Isolation / messages | Parallelism | Status |
| --- | --- | --- | --- | --- |
| cooperative, in-guest | stack driving, plus stored continuations from ADR-0076's suspend lowering | one heap; `Send` keeps sharing unobservable | none | ships; the reference behaviour |
| host waitables (Component Model) | a parked task waits on a host future, stream read or timer through the adapter's waitable set | as above | host I/O overlaps; task bodies do not | ships with an entry boundary that settles host futures |
| Component Model subtasks | async lift/lower, one subtask per task | component / resource boundaries | as the host provides | not implemented (#3147) |
| JSPI with Workers | `WebAssembly.Suspending` / `promising` | an instance and heap per Worker, messages copied | up to the number of Workers | not implemented; JSPI only lowers suspension |
| shared-everything threads | thread intrinsics over a shared store | task-local arenas inside one store; same message API | host threads | opt-in probe only (#488) |

The Component Model provides tasks and threads with weaker lifetime rules than
this document's. "No group closes while a child is live" stays a runtime rule
of the language on every backend; it is not weakened to the host's minimum.

### Native/WASI backend policy

A production multi-worker backend for native and WASI hosts is an embedder
that owns the workers, not a guest calling `wasi:thread-spawn`. Each worker
has its own `Store`, `Instance`, linear memory and handler state; only `Send`
values cross between workers, and one coordinator publishes results. Thread
ids, `Store`s, shared memory and Wasmtime flags never become language values.
For the compiler, an ordinary process pool over the AOT-compiled compiler
image already meets this shape
([compiler-parallelism.md](compiler-parallelism.md)).

Core Wasm threads (shared memory and atomics) and guest-side WASI thread spawn
are not needed to implement these semantics. A backend that uses them stays
opt-in until it shows task-local isolation and the same conformance traces.

## Shared-everything threads (#488)

#488 probed the shared-everything-threads proposal across vibe and Wasmtime.
Its results are backend feasibility and probes; none of the following is
public API:

- proposal intrinsics such as `thread.spawn-ref`;
- Wasmtime-specific flags, thread ids, or the available parallelism;
- shared references, shared functions, atomics, locks;
- raw `Int` channel ids or `String`-only messages.

The proposal is a draft, and Wasmtime does not implement it: the flag is
accepted but not wired to the validator or the text parser
([wasm_threads_requirements.md §4](../compiler/wasm_threads_requirements.md)).
The path is enabled only behind feature detection and is not a CI or release
gate.

It becomes a production lowering only when all of these hold:

1. The proposal's grammar and Wasmtime's intrinsic names agree, and upstream
   regression tests pass.
2. Shared heap types, shared function / table / composite types, and the
   needed component intrinsics are implemented.
3. Task-local handler state, cancellation and arena isolation survive.
4. It produces the same set of conformance traces as the cooperative backend.
5. It reproduces on a pinned upstream Wasmtime release, not a locally patched
   build.

## Conformance

What is pinned, and where:

| Property | Pinned by |
| --- | --- |
| deferred spawn, FIFO dispatch, idempotent join and cancel, cancel before dispatch, a cancelled child does not fail the group, close joins unjoined children | `lib/@vibe/concurrent/experimental/concurrent_test.vibe` ("Lifecycle conformance locks") |
| child throw becomes `Failed(m)`, fail-fast cancels ready siblings, a recoverable result is a value, message rendering by payload kind, a throw escaping the body keeps its payload | `concurrent_test.vibe` ("Failure conformance locks") |
| negative capacity, per-sender FIFO, last-release close, drain then `None`, `Closed` on a closed channel, rendezvous, a full buffer blocks | `concurrent_test.vibe` ("Channel conformance locks") |
| `Parallel::map` index order, first failure, empty input | `concurrent_test.vibe` ("Composition") |
| mid-body interleaving, wake values, cancel of a parked task, fail-fast from either leg, sleeps, futures, `result_wait`, close pumping parked children, CPS-split callees | `lib/@vibe/concurrent/experimental/suspend_test.vibe` |
| the `Send` allowlist | `lib/@vibe/compiler/tests/send_allowlist_test.vibe`, `fixtures/send_bound_structural.vibe`, `fixtures/err_type_send_*.vibe` |
| `Spawnable` captures, aliases, renamed imports, closure values | `fixtures/region_ok_spawnable_*.vibe`, `fixtures/err_spawnable_*.vibe`, `fixtures/spawnable_alias_send_ok.vibe` |
| region escape through `run` and its aliases | the fixtures listed under [Regions and escape](#regions-and-escape) |
| the inline-closure rule | `fixtures/err_spawn_suspend_*_plain.vibe`, `fixtures/spawn_suspend_wrapper_inline.vibe` |
| host waits, catching across `await`, nested groups | `fixtures/async_spawn_host_futures/` (run by `scripts/test_named_hostfutures_component_gate.sh`) |

The compile-rejection fixtures are exercised by the late compiler gate
(`tests/gates/late/`), whose rows assert the diagnostic text as well as the
refusal.

Not pinned yet, because no second backend exists: differential traces between
backends, replay of a failure from a scheduler seed, and the #488 probe in an
opt-in environment.

## Naming

The formal model calls the scope a *nursery* (Trio's term). The library
spells it `TaskGroup` and the handle `TaskHandle` (asyncio's and Swift's
spelling), the names most readers already know for these semantics, and the
sugar is `taskgroup { g => .. }`. The handle is not called `Task`, to stay
clear of the retired `Task::*` builtins. A task group is an ordinary library
type plus compiler checks keyed on its shape, not a capability effect: there
is no `Spawn[r]` effect and no `Nursery[r]` type. (The `Spawn[r]::spawn`
requirement in [vibex-runtime-contract.md](vibex-runtime-contract.md) names
the spawn operation in that document's authority model; no program performs
it.) The diagnostics still say "nursery" in places (`region escapes its
nursery scope`).

## Known gaps

- **Functions imported from another module.** Code written outside a body is
  checked again where the token reaches it, which needs the callee's body; a
  module's interface carries only types. A helper imported from another module
  that stores its argument (`put(c, handle)` with `put` exported by
  `./cells.vibe`) is trusted, so it still keeps the handle past its group, and
  the program compiles and runs (measured). Refusing every imported callee
  instead would refuse the library itself (`TaskHandle::join(h)`,
  `Sender::send(tx, v)`); the standard library's own retaining operations are
  listed by name and checked like `Array::push`. Closing it needs a summary of
  which arguments a function keeps, published in the module's interface.
- **A closure literal handed to a library function.** A closure written in the
  body is checked before the call it is passed to has fixed its parameter's
  type, so a write of that parameter does not yet carry the region:
  `Array::map(hs, (h) -> { Array::push(outer, h); 0 })` keeps the handles in
  an outer array, and compiles and runs (measured). The `for h in hs` loop is
  refused, because its variable is typed from `hs` first. On both routes,
  joining the escaped handle after the group returns the task's value
  (measured), so no program is answered wrongly today, but nothing enforces
  that the handle stays in its group.
- **Mid-run cancellation.** A cancel request is observed at dispatch and at a
  parked task only. A running task, and a suspendable task that is running
  when the request arrives, are not interrupted.
- **Messages are shared, not copied.** Sound only because `Send` admits no
  mutable interior.
- **One scheduler.** Every task runs on the cooperative in-guest scheduler;
  the JSPI, Component Model subtask (#3147) and shared-everything (#488)
  backends do not exist, so the conformance suite has nothing to compare
  against.
- **Finalizers.** There is no finalizer registration. A cancelled parked task
  releases what its continuation captured through reference counting, and a
  task that is never parked releases at its normal end.
- **The suspendable lane is a second spelling.** `spawn_suspend` beside
  `spawn`, and the inline-closure rule, remain until #3200.

## Out of scope

- raw OS thread or Worker APIs, thread affinity, priorities, and a stable CPU
  count;
- shared mutable memory, atomics, mutexes, and a weak-memory model;
- moving a continuation to another task;
- user-declared handlers that a task inherits across a spawn boundary;
- long-lived actors with mailboxes and supervision (`Process[Msg]`);
- acquiring several resources atomically, and performance guarantees for work
  stealing;
- Component Model subtasks as the task backend, which is #3147's subject.

These are added only if they leave the semantics above unchanged.

## References

- [WebAssembly proposals](https://github.com/WebAssembly/proposals)
- [JavaScript Promise Integration](https://github.com/WebAssembly/js-promise-integration)
- [Component Model concurrency](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Concurrency.md)
- [Shared-everything threads](https://github.com/WebAssembly/shared-everything-threads)
- [Generalized Evidence Passing for Effect Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
