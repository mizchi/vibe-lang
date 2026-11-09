# ADR-0126: CPU-bound tasks on native worker threads, one Store per job

Status: **proposed** (#3484). This records the executor design #3484 asks for
before its implementation. It is a design to build and measure. Nothing here
describes current behaviour.

## What is settled already

[concurrency.md](concurrency.md) (ADR-0068) fixes the language side, and this
design does not reopen it:

- **The schedule is the backend's.** Whether two tasks run at the same time is
  the backend's decision. The same program produces the same permitted traces
  on one worker or many, and the number of workers is a host property that no
  API exposes ("Safe parallel API").
- **What crosses a task boundary.** A spawned closure is `Spawnable`, a result
  is `Send`, and a message is logically a deep copy ("Memory model").
- **Who owns the workers.** On native and WASI hosts, a multi-worker backend is
  an embedder that owns them. Each worker has its own `Store`, `Instance`,
  linear memory and handler state. Thread ids, Stores and shared memory never
  become language values ("Native/WASI backend policy").
- **Workers carry no authority of their own.** A worker borrows its task's
  authority, and moving a task to another worker changes nothing
  ([vibex-runtime-contract.md](vibex-runtime-contract.md)).

The cooperative backend (one heap, the in-guest scheduler) is the reference
behaviour. #3477's native CPU waves run the compiler's function emission in
separate *processes*
([function-cpu-workers.md](../compiler/function-cpu-workers.md)). There is no
thread-backed executor, and no public `TaskGroup` workload runs on one.

## Decisions

### 1. Which children run on a worker

A worker runs a **CPU job**. A child of `TaskGroup::spawn` or
`Parallel::map` is a CPU job when all three of the following hold:

1. **Its body is a call to a top-level function, written at the spawn site,
   with arguments the compiler can encode.** The arguments are the child's
   captured `Send` values (`Parallel::map`'s element and the function's own
   arguments). The function is identified statically. No function value, and
   no closure environment beyond those values, crosses to the worker.
2. **Its row is `Exception` and nothing else.** A CPU job performs no host
   capability and no user effect. A worker has no ambient authority, and
   delegating a capability to one would need the delegation and provider rules
   that [vibex-runtime-contract.md](vibex-runtime-contract.md) has not yet
   implemented for workers.
3. **Every module-level value its function reaches, transitively through
   the calls it makes, is `Send`.** An effect row does not say this: a
   top-level `let cell: Array[Int] = [0]` that one function `Array::set`s and
   another reads carries no effect. The compiler's own
   `lc_pf_refusal_cell` is such a cell. The `Spawnable` judgement treats a
   top-level function as capturing nothing, which holds within one heap but
   not across Stores. A child reading such a cell sees the parent's update
   when it runs cooperatively, but the cell's initial value in a fresh worker
   Store. Re-initializing a module-level value gives the same result only when
   it is immutable. The check is a transitive walk over the job function's
   call graph. Anything it cannot see through (a function value, a call it
   cannot resolve) makes the child cooperative, never a CPU job.

Every other child runs cooperatively, exactly as it does now. Being a CPU job
is not an observable property: the result, the failure, the order of results
and fail-fast are the same either way. A program that wants parallel CPU work
writes ordinary `Parallel::map` over a pure function. There is no new spawn
spelling, attribute or type.

### 2. Registration is static; the boundary is owned bytes

For each CPU-job spawn site, the compiler emits a private export
`__vibe_cpu_job$<site>`. It takes one input buffer and returns one result
buffer. Both buffers are the canonical encoding of the site's argument tuple
and of `Result[U, TaskError]`. The codec is derived per type from the same
structural walk that decides `Send`. It is not a hand-maintained codec like
the function-worker body input
([function-cpu-workers.md](../compiler/function-cpu-workers.md), "Feedback",
item 2).

- Only bytes cross. A guest pointer, a function-table index or an RC header
  never leaves its Store.
- The worker decodes into its own heap and the parent decodes the result into
  its own, so the logical deep copy of ADR-0068 becomes a real one.
- A type whose encoding is not derived is not a CPU job (decision 1 falls back
  to cooperative). It is never encoded by reference.

### 3. The executor

The host keeps one bounded pool of **N native threads**. N comes from the
host (a `--cpu-workers` / `VIBE_CPU_WORKERS` setting at the entry), never from
the program. N = 1 means no pool: every child runs cooperatively, so the
reference behaviour is always one setting away.

- The compiled `Engine` and `Module` are shared across threads, which Wasmtime
  supports.
- **Each job gets a fresh `Store` and `Instance`.** One Store is never entered
  by two threads, and nothing in a Store outlives its job.
- Reusing an instance across jobs is not part of this decision. It would need
  a complete reset proof and stale-state mutation tests, and #3484 asks for
  that to be measured, not assumed.
- **A worker never runs `_start`.** For an ordinary program, `_start` runs the
  entry, so running it per job would re-run `main` and its effects. The
  compiler emits a separate setup export, `__vibe_cpu_init`, which does the
  runtime setup `_start` does before the entry and nothing else. A worker
  calls that export, then the job export. This is the same separation the
  function-worker route gets by compiling a `__no_entry__` image
  ([function-cpu-workers.md](../compiler/function-cpu-workers.md), "Ownership
  and transport").
- **Module-level values stay lazy.** The linear backend evaluates a
  non-function top-level binding on its first access and memoizes it
  (`linked_compile_function_bodies.vibe`). `__vibe_cpu_init` does not force
  them: a job evaluates a module-level value when it first reads one, as the
  cooperative run does. Forcing them all at setup would run initializers the
  job never reaches, and one that traps or does not terminate would abort a
  program the cooperative route completes. `Send` makes a value immutable,
  not its initializer total. A job therefore sees the value its own first
  access computes, which decision 1 restricts to immutable values, so it is
  the parent's value too.
- Anything else the job needs is an argument. This is the "explicit task-local
  context" lesson of function-cpu-workers.md item 4: a missing source-location
  table was a read-only instance global that the job silently lacked.

### 4. Admission under three bounds, led by what the parent awaits

`Parallel::map` consumes results in input order. A `TaskGroup` joins children
by handle, in whatever order the program writes: joining the last child
first is supported, and `concurrent_test.vibe` does it. So the executor
cannot assume one consumption order. It admits jobs against three separate
bounds:

- at most **N active** jobs;
- at most **Q queued input bytes**, for jobs encoded and waiting for a thread;
- at most **R completed-but-unconsumed output bytes**.

A job that finishes before the parent consumes it keeps its result buffer and
counts against R. Speculative admission (starting a job nobody is waiting on
yet, in spawn order) stops while R is full, so a slow job the parent awaits
stalls admission instead of letting every other result accumulate.

**Spawning never waits for admission.** `Parallel::map` spawns every child
before it joins any, so a spawn that blocked on Q or R would never reach the
join that frees them. A spawned job therefore stays a descriptor that holds
its arguments as ordinary values on the parent's heap, the same values a
cooperative child would capture, and it is encoded only when it is admitted.
Q bounds the bytes encoded and waiting for a thread, not the number of
spawned jobs. When the queue is empty, one input larger than Q is admitted
alone, so Q is exceeded by at most one input and an oversized input still
runs.

**The job the parent awaits is never held back by R.** A join on a job that
has not started is encoded if it is still a descriptor, moves to the front of
the queue, and starts as soon as one of the N threads is free, whatever Q and
R hold. Every running job is a
bounded CPU computation with no host wait (decision 1), so a thread always
frees. A join therefore always makes progress. Without this rule, joining
the last handle first could deadlock: R is full of earlier results that the
blocked parent cannot consume, and the awaited job never starts. R can be
exceeded by at most the N results that were running when it filled, plus the
awaited job's own result. These bounds limit wire bytes, and the decoded heap
of each worker is its own Store's. Neither is a proof of whole-process RSS,
which decision 7 requires measuring.

### 5. Failure, traps and cancellation keep the cooperative meaning

- **An exception** escaping the job's function is encoded as the job's
  `TaskError::Failed` result. Joining raises it, and fail-fast cancels
  siblings, exactly as cooperatively.
- **A trap** in a job aborts the whole program with that trap's message, as a
  trap in a cooperative child does today. The executor does not turn a trap
  into a catchable `TaskError`, because that would make the backend
  observable.
- **A normal close drains; it does not cancel.** When the group's body
  returns normally with jobs still unjoined, `run` waits for each of them to
  finish, exactly as `TaskGroup::run` drains unfinished cooperative children
  at a normal close. A job that fails there raises its `TaskError::Failed`
  from `run`, as a cooperative child does.
- **Cancellation is fail-fast, `TaskHandle::cancel`, or the body unwinding
  with an exception.** Cancelling a job drops it if it has not started. A
  running job is interrupted through Wasmtime epoch interruption, its Store
  is dropped, and its result is discarded. A CPU job performs no host effect
  (decision 1), so interrupting it leaves nothing half-done outside its own
  Store.
- **"No group closes while a child is live"** holds on the executor too. The
  group's `run` returns only after every job of the group has been consumed,
  drained, discarded or interrupted, and no worker thread retains the group's
  inputs after that.

### 6. What this does not decide

- **Capability-carrying jobs**, which need delegation to a worker.
- **Instance reuse** (decision 3).
- **Shared-everything Wasm threads** (#488) and Component Model subtasks
  (#3147). By #3147's own measurement, a subtask runs a CPU-bound child to
  completion inside the call: subtasks give host scheduling and cancellation,
  not CPU parallelism.
- **The compiler's own function-emission route.** It keeps its process waves
  until this executor demonstrates its own costs. Moving it is #3485 / #3483.

### 7. Accepted when

All of the following are true at once:

- **Real thread overlap.** A public `TaskGroup` / `Parallel::map` workload over
  a pure CPU-bound function runs on at least two native worker threads with
  overlapping useful CPU work. Thread and trace evidence distinguishes this
  from cooperative interleaving, timers and child processes.
- **Equivalence.** N = 1 (cooperative), N = 2 and N = 4 agree on results, on
  publication order and on failure observations. The tests are:
  - slow-first-job backpressure, with R held at its bound;
  - handles joined in reverse spawn order with R full, which must complete;
  - `Parallel::map` with Q and R both saturated before its first join, which
    must complete;
  - one input larger than Q;
  - a module-level value whose initializer traps, read only on a branch the
    job does not take, which must not abort the program;
  - cancellation of a running job;
  - a worker trap aborting the program;
  - repeated jobs;
  - two consecutive groups with different inputs, to prove no state leaks
    between Stores.
- **Cost.** Measurements report whole-process peak RSS alongside guest and
  buffer accounting, CPU and wall time, and show no regression on the
  ordinary (N = 1) route.
- **Self-test.** The gate that checks this has a self-test that turns it red:
  - a job made to read a mutable module-level cell, which must stay
    cooperative;
  - a worker that runs `_start`;
  - a worker setup that forces every module-level initializer;
  - a spawn that blocks on Q or R;
  - an executor that skips R;
  - a trap turned into a `TaskError`;
  - a normal close that cancels a failing job instead of draining it.
