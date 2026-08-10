# WASI 0.3 async component probe (M1b-3c blueprint recovery)

Companion probe for #1230 (real non-blocking `await` codegen). The byte-level
canon built-in blueprint `docs/spec/wasi-p3-async.md` §3.2/§3.6/§3.7 describe
was derived from hand-written `.wat` probes under `src/x/cm_async/` that were
**never committed** and were lost when the MoonBit host tree (`src/`) was
retired (#594). This directory re-derives the same information with a
reproducible, checked-in probe instead of scratch files, using current
tooling (`wit-bindgen` 0.60, wasmtime 47) rather than hand-authored WAT.

## What this proves

`guest/` is a minimal Rust component (via `wit-bindgen::generate!` with
`async: true`) implementing `wit/world.wit`:

```wit
world probe {
  import get-async: async func() -> u32;
  export run: async func() -> u32;
}
```

Building it (`cargo build --release --target wasm32-unknown-unknown`)
produces a plain core module whose imports/exports use the canonical ABI
names vibe's own codegen (`component_codegen.vibe`) needs to emit for real
blocking `await`. Confirmed names (see `canon-imports-exports.wit-abi.txt`,
captured via `wasm-tools print`):

| canon | wire name |
|---|---|
| async-lowered host import call | `[async-lower]get-async` |
| task.return | `[task-return]run` |
| task.cancel | `[task-cancel]` |
| subtask.drop | `[subtask-drop]` |
| subtask.cancel | `[subtask-cancel]` |
| waitable-set.new | `[waitable-set-new]` |
| waitable-set.poll | `[waitable-set-poll]` |
| waitable-set.drop | `[waitable-set-drop]` |
| waitable.join | `[waitable-join]` |
| context.get/set (slot N) | `[context-get-N]` / `[context-set-N]` |
| async-lift export (primary) | `[async-lift]run` |
| async-lift export (callback re-entry) | `[callback][async-lift]run` |

These match `docs/spec/wasi-p3-async.md` §3.6's canon table (`future.new`,
`future.read`, `waitable-set.*`, `waitable.join`, `context.get/set`,
`task.return`/`task.cancel`) modulo the `future.*` names, which don't appear
here because this probe's import is a **bare async function** (`async func()
-> u32`), not a `future<u32>`-typed value — WASI 0.3 elides the explicit
`future.new`/`.read` pair for a directly async-lowered import/export and
folds the wait into the `[async-lower]`/`[async-lift]` call itself, backed by
the same `waitable-set`/`subtask` machinery. A probe that explicitly passes a
`future<T>` *value* (an import returning `future<u32>` that the guest
then reads itself) is needed to see literal `future.*` calls — now built
in `future_value/` (ADR-0089 Part B step 1): its capture shows the
`[future-new-0]get-future` / `[async-lower][future-read-0]get-future` /
`[future-drop-readable-0]get-future` family, named per introducing WIT
function and per type index, with the read itself arriving async-lowered
on the same waitable-set machinery. `get-async`'s implicit wait already
exercises the `waitable-set.new`/`.poll`/`waitable.join` loop, which is
the part `compile_call.vibe`'s `await` lowering actually needs to emit.

`future_value/component.wat` (ADR-0089 Part B step 2) then EXECUTES the
`future.*` family from hand-authored WAT: a self-contained single-task
component where the guest calls `future.new`, issues an async
`future.read` (BLOCKED — no writer yet), joins the readable end into a
waitable set, performs an async `future.write` of 42 (which completes
eagerly against the pending read), waits (FUTURE_READ, event code 4),
and returns the delivered value. Verified on wasmtime 47:
`wasmtime run -W exceptions=y -W concurrency-support=y
-W component-model-async=y -W component-model-async-stackful=y
-W component-model-more-async-builtins=y --invoke 'run()'
future_value/component.wat` → `42` (the `more-async-builtins` flag is
required — the future.* canons are still 🚝-gated in 47). Encodings pinned
by the run: `future.new` packs `(writable << 32) | readable` (readable end
in the LOW bits), async `future.read`/`.write` return BLOCKED =
`0xffffffff`, a write against a pending read returns COMPLETED from the
call itself, and the completion event is delivered as FUTURE_READ = 4.
`comp_emit_component_wasm_future_value`
(`component_codegen.vibe`) is the byte-exact emitter port, gated by
`scripts/test_future_value_component_gate.sh`.

`stream_value/component.wat` applies the same rendezvous to `stream<u8>`
(1 element moved; `stream.read`/`.write` take an extra element-count
param, the completion event is STREAM_READ = 2, and completed statuses
pack `(amount << 4) | code`). Also 42 on wasmtime 47 under the same
flags; emitter port `comp_emit_component_wasm_stream_value`, gate
`scripts/test_stream_value_component_gate.sh`.

`host_future_value/component.wat` (ADR-0089 Decision 2 / step 4, #1218) is
the HOST-owned-writer counterpart the future_value probe deferred: the
component genuinely imports `get-future` and the write end lives in
runtime/viberun (a wasmtime `FutureReader::new` producer that resolves
only after a tokio timer — wasmtime 47 has no `FutureWriter` type; the
producer form is pull-based but observably identical). The guest's
async-lowered import call completes eagerly with the readable handle,
`future.read` comes back BLOCKED, and the task parks in
`waitable-set.wait` until the host completion arrives as a FUTURE_READ
event — measured 42 in ~311ms against a 300ms producer delay (the wall
clock proving genuine suspend/wake), and it pinned one new encoding: the
component-level import type must be `func async` (the `async` canon-lower
option rejects a sync function type at validation). Driven by
`viberun <component.wasm>` (a func_wrap_concurrent import cannot be driven
by bare `wasmtime --invoke`); emitter port
`comp_emit_component_wasm_host_future_value`, gate
`scripts/test_host_future_value_component_gate.sh`.

## Update: stackful blocking-wait mechanics now proven (`stackful/`)

The open question below ("does callback-less stackful async-lift handle a
*genuinely* blocking wait?") is now **resolved: yes**, via a fully
hand-authored Component Model probe in `stackful/` — see that section below
for the two real bugs found (and fixed) along the way. Read on for the
original (still-accurate) background on how the ABI names were recovered.

## Open question this does NOT resolve: stackful vs. callback

`wit-bindgen`'s default Rust codegen (confirmed above: both `[async-lift]run`
**and** `[callback][async-lift]run` are exported) uses the **callback form**
— an explicit state machine the host re-enters via the `[callback]` export
on every wake event. This is the portable choice (works on any
Component-Model-async-capable engine, no wasmtime-specific flag needed).

`docs/spec/wasi-p3-async.md` §3.1 chose the **stackful** form instead
(`-W component-model-async-stackful=y`): no `[callback]` export at all, no
explicit state machine — wasmtime runs the async-lifted export on a real host
fiber and blocking `await`/`future.read` calls just... block, exactly like
vibe's existing codegen already treats every other host import. This is
*much* simpler for vibe to emit (straight-line code, no state-machine
transform), and `component_codegen.vibe`'s existing `emit_canon_lift_async_section`
already emits exactly this shape (async-lift, no callback) — confirmed still
accepted and running correctly by wasmtime 47.0.2 via
`scripts/test_async_component_gate.sh` (all 8 entries pass, re-verified on
this branch before any code changes).

What's **not yet verified**: whether callback-less stackful async-lift also
correctly handles a *genuinely blocking* `waitable-set.wait` (not just the
trivial always-ready cases the existing gate covers). `wasmtime 47` still
exposes the `component-model-async-stackful` flag (confirmed via
`wasmtime run --wasm help`), so the mechanism itself hasn't been removed —
but a probe exercising a real block-then-resume under the callback-less form
specifically is the next concrete step before writing `component_codegen.vibe`
changes.

## Tooling versions used (matches CI's `wasi-p3-gate` job pins)

- `wasmtime v47.0.2` (`.github/workflows/ci.yml`'s `wasi-p3-gate` job already
  pins this; per that job's comment, "47 had been the sole target everywhere
  else in this repo for a while")
- `wasm-tools 1.253.0`, `wac 0.10.1` (same CI job's pins)
- `wit-bindgen-cli` / `wit-bindgen` crate **0.60.0**

**Gotcha found and worth remembering**: `wit-bindgen` **0.41.0** (the version
this repo's docs implicitly reference by being written around that era) has a
real bug in `generate!`'s `async: true` macro expansion for a bare
(non-interface-scoped) world export: the export glue calls
`T::async_run()` but the generated `Guest` trait only declares
`async fn run()` — this fails to compile with "not found in this scope" no
matter how the impl is shaped, because the trait itself is missing the method
the glue calls. 0.60.0 does not have this bug (trait and glue agree on `run`
directly). If any future work touches `wit-bindgen`, use >= 0.60.

## Reproducing

```bash
# from this directory
cargo build --release --target wasm32-unknown-unknown --manifest-path guest/Cargo.toml
wasm-tools print guest/target/wasm32-unknown-unknown/release/probe_guest.wasm \
  | grep -E '\(import|\(export'
```

To regenerate `wit/` bindings by hand (not required to build, `wit_bindgen::generate!`
does this at compile time): `wit-bindgen rust wit/ --async all --out-dir src_gen`.

## `stdin_read_via_stream/`: ratified stdin ABI availability check (#1539)

`stdin_read_via_stream/component.wat` declares the ratified
`wasi:cli/stdin@0.3.0` import and `read-via-stream` result type
`tuple<stream<u8>, future<result<_, error-code>>>`. Its `error-code` is
imported from `wasi:cli/types@0.3.0` and aliased into the stdin instance, which
preserves the WIT type's nominal identity rather than using a byte-sized
stand-in.

`scripts/test_wasi_cli_stdin_p3_probe_gate.sh` parses and validates the
component. Its minimal `wasi:cli/run@0.2.12` command export lets wasmtime 47
instantiate it before resolving the `read-via-stream` import. Generic ABI/type
mismatch or missing-command-export diagnostics fail. An explicit
missing-stdin-implementation diagnostic skips the local default lane and fails
required mode; only a successful link passes required mode. Link success is an
availability result, not a lifecycle result. The probe is included in the
optional `test-wasi-p3` aggregate.

## `stackful/`: hand-authored blocking-wait probe (M1b-3c mechanics proof)

`stackful/component.wat` is a **fully hand-written** Component Model binary
(no `wit-bindgen`, no `wasm-tools component embed`/`component new`) that
implements the exact shape `component_codegen.vibe` needs to emit for a real
blocking `await`: a callback-less "stackful" async-lift export whose guest
code performs the canonical-ABI `future.read`-equivalent retry loop directly
— `waitable-set.new` → `waitable.join` (subtask, set) →
loop { `waitable-set.wait` → check `STATUS_RETURNED` } → `subtask.drop` →
`task.return`. It imports one async host function (`get-async: async func()
-> u32`) so the whole thing can be driven by a real async host implementation
(`stackful/host/`, a Rust binary using `wasmtime-47`) that suspends for
300ms via `tokio::time::sleep` before resolving — i.e. a *genuinely*
non-ready wait, not the trivially-ready case the existing
`scripts/test_async_component_gate.sh` gate covers.

Building/running it end-to-end (see "Reproducing" below) now prints:

```
[host] get-async: suspending for 300ms
[host] get-async: resolved with 42
[host] run() = 42 (elapsed 302.7ms)
```

confirming: the guest's wasm fiber genuinely suspends (no thread blocking on
the host side — real async `tokio::time::sleep`), resumes correctly once the
host resolves, and the `waitable-set.wait` retry loop observes the right
status transition and returns the right value. This is the core mechanical
proof needed before writing the real `future.read`/`waitable-set` codegen
in `component_codegen.vibe` (M1b-3c-1b, tracked in #1230).

### Two real bugs found and fixed while building this

Both were silent-wrong-behavior bugs (no error from `wasm-tools validate` or
from wasmtime at instantiation time), so worth documenting for whoever
writes the actual codegen:

1. **Host driving API: `call_async` is the wrong entry point for a component
   that imports host functions via `func_wrap_concurrent`.** Calling the
   exported `run` function with the "plain" `TypedFunc::call_async(&mut
   store, ()).await` pattern (correct for host functions defined via
   `func_wrap`/`func_wrap_async`) produced a genuine host-side suspend/resume
   (the 300ms delay really elapsed) but then trapped with `wasm trap:
   deadlock detected: event loop cannot make further progress` right after
   the host resolved. The fix is to drive the call through
   `Store::run_concurrent` + `TypedFunc::call_concurrent`, which properly
   integrates with wasmtime's own concurrent task scheduler:
   ```rust
   let (result,) = store
       .run_concurrent(async move |accessor| run.call_concurrent(accessor, ()).await)
       .await??;
   ```
   `run_concurrent`'s own doc comment example shows this exact pattern (see
   `wasmtime::component::concurrent::run_concurrent` in `wasmtime-47.0.2`).
   Every reference in the crate docs describing plain `call_async` assumes
   `func_wrap`/`func_wrap_async` host functions, not `func_wrap_concurrent`
   ones — this distinction isn't called out anywhere obviously, so it's easy
   to miss. (Using the wrong API didn't just perform worse — it deadlocked.)

2. **`waitable-set.wait`'s payload MUST be written into the same memory the
   guest reads from — `canon lower ... async`'s `memory` option and
   `canon waitable-set.wait`'s `memory` option must agree with the guest's
   own memory, not just with each other.** The natural way to avoid the
   well-known "memory cycle" (the guest's own exported memory isn't
   available yet while building the `canon lower` functions that must be
   supplied as *imports* to that same guest's instantiation — see the older
   parts of this README's history in git blame / session notes) is to
   instantiate a small standalone module (`$memhost`) purely to have *a*
   memory to point every `(memory ...)` canonical option at before the guest
   exists. That does solve the circular-import problem for
   *instantiation*, but if the guest module still separately **declares and
   exports its own memory** (`(memory (export "memory") 1)`), the guest's
   `i32.load`/`i32.store` instructions operate on *that* memory — a
   different Wasm memory instance than the one the host actually wrote the
   `waitable-set.wait` payload into. Every host-side write (the subtask
   status code, the eventual `u32` result) silently lands in memory the
   guest never reads. There's no trap, no validation error — the guest just
   always observes zeroed payload bytes (`code = 0`, i.e. `STARTING`,
   forever), which is indistinguishable from "the host hasn't produced an
   event yet" and causes the exact same trap #1 that was originally
   attributed purely to the driving-API bug — both bugs were compounding
   until this one was isolated with a debug instrumented build
   (`debug_component.wat`-style: loop capped at N iterations, stash the raw
   `(iter, event0, code)` tuple to a fixed memory address, `task.return`
   that instead of the real result) that showed `code` never leaving `0`
   even though the host-side trace (`RUST_LOG=wasmtime=trace`) clearly
   logged `deliver event Subtask { status: Returned }`.

   **Fix**: the guest module must **import** its memory from the same
   standalone module used for the canonical options, not declare its own:
   ```wat
   (core module $guest
     ...
     (import "env" "memory" (memory 1))   ;; NOT (memory (export "memory") 1)
     ...)
   ...
   (core instance $guest-inst (instantiate $guest
     (with "$root" (instance ...))
     (with "[export]$root" (instance ...))
     (with "env" (instance (export "memory" (memory $mem-inst "memory"))))))
   ```
   This generalizes directly to `component_codegen.vibe`: whatever memory
   the guest module's own compiled code uses for its heap/locals-spill area
   must be the *exact same* memory instance referenced by every `(memory
   ...)` canonical option on every async-related canon built-in the guest
   imports (`canon lower ... async`, `canon waitable-set.wait`,
   `canon waitable-set.poll`, and any future `canon future.read`/
   `canon stream.read` uses) — not a separate bootstrap-only memory.

### Reproducing

```bash
cd stackful
wasm-tools parse component.wat -o component.wasm
wasm-tools validate --features all component.wasm
cd host && cargo build --release && cd ..
./host/target/release/p3host component.wasm
# expect: "[host] run() = 42 (elapsed ~300ms)", exit 0
```

## `spawned_future/`: self-contained future via a spawned writer subtask (#1230 M1b-3c-1b)

The `stackful/` probe above only proves "await a host async import directly"
(`run` calls `get_async().await` inline). #1230's next milestone
(M1b-3c-1b) asked for the harder-sounding "self-contained future produced
by a spawned writer subtask" case instead -- `docs/spec/wasi-p3-async.md`
§3.7 describes this as heavier ("wit-bindgen が futures-rs executor 一式を
取り込む") and the single largest remaining chunk of the whole async
effort. This probe determines exactly what that costs at the
canonical-ABI level, in two phases.

### Phase A: recover the ABI shape via wit-bindgen (`spawned_future/guest/`)

A `wit-bindgen` 0.60 (`async: true`, `async-spawn` feature) guest whose
`run` export does NOT call `get-async()` directly -- it spawns a writer
task via `wit_bindgen::spawn_local` that awaits the host import and
forwards the result through a `futures::channel::oneshot`, and `run` only
awaits that channel. Building it and dumping imports/exports
(`wasm-tools print ... | grep -E '\(import|\(export'`, captured in
`spawned_future/canon-imports-exports.wit-abi.txt`) shows:

**Zero `future.*` canon built-ins appear.** `spawn_local` is a purely
guest-internal cooperative executor (`futures::stream::FuturesUnordered`,
see `wit-bindgen-0.60.0/src/rt/async_support/spawn.rs`) -- it never
constructs a canonical-ABI `future<T>` value, and the `oneshot::channel()`
used to hand the writer's result back to `run` is an ordinary
guest-memory Rust future with no ABI representation at all. This matches
spec §3.7's own wording literally: the self-contained-future case is
realized by pulling in a futures-rs-style executor, not by using
canonical-ABI `future.*` primitives.

The only *extra* imports/exports versus the plain `stackful/` case are
`[context-get-0]`/`[context-set-0]`, `[waitable-set-poll]` (instead of/
alongside `-wait`), and an extra `[callback][async-lift]run` export --
and these are NOT inherent to "spawning a writer". They're artifacts of
`wit-bindgen`'s own runtime architecture, which defaults to the
**callback** form of async-lift (an explicit state machine re-entered via
the `[callback]` export on every wake event) and uses `context.get/set`
as general-purpose thread-local-like storage so its generic multi-task
executor can find "the currently running task" from arbitrary nested Rust
call sites -- both `async_support.rs` and `subtask.rs` call
`context_get`/`context_set` unconditionally as part of ordinary
task/subtask bookkeeping, regardless of whether `spawn_local` is used at
all.

vibe's own codegen strategy (spec §3.1) deliberately chose the
**stackful, callback-less** form instead, precisely because it lets the
backend emit straight-line/loop code with no explicit state machine.
Under that model the whole call stack for `run` (or vibe's compiled
equivalent) survives suspension as a real host fiber, so a "currently
running task" pointer can simply live in an ordinary local variable / the
call stack itself -- no `context.get/set` needed, even when "the writer"
is split into its own internal wasm function.

### Phase B: hand-authored proof (`spawned_future/component.wat` + `host/`)

A direct structural refactor of `stackful/component.wat`: the retry-loop
body that previously lived inline in `run` is extracted into its own
internal wasm function `$writer` (the "spawned writer subtask" -- an
*ordinary wasm function call*, not a second Component-Model subtask),
and `$run` just calls it and forwards the result to `task.return`. Same
canon built-in set as `stackful/` (`task.return`,
`[async-lower]get-async`, `waitable-set.new/.wait/.drop`,
`waitable.join`, `subtask.drop`) -- no `future.*`, no `context.get/set`,
no `waitable-set.poll`. `host/` is a copy of `stackful/host/` (same
wasmtime config, same `run_concurrent`/`call_concurrent` driving API, same
300ms host-side suspend to prove a genuinely non-ready wait).

```bash
cd spawned_future
wasm-tools parse component.wat -o component.wasm
wasm-tools validate --features all component.wasm
cd host && cargo build --release && cd ..
./host/target/release/p3spawnedfuturehost component.wasm
# expect: "[host] run() = 42 (elapsed ~300ms) [spawned-writer-subtask fixture]", exit 0
```

**Conclusion for `component_codegen.vibe`**: no new `emit_canon_future_*`
emitters are needed for the shape M1b-3c-1b actually emits. Structuring
the wait loop as two internal wasm functions (writer + reader) in one core
module needs the exact same canon built-in set `stackful/` already
requires. `Task::spawn(|| await(host_call()))` immediately followed by
`await(that_task)` can be compiled by emitting the spawned closure's body
as a callee function invoked from the await site.

### Important limit on that conclusion (#1240 review)

Phase B's `$writer` is an ordinary internal wasm function called
**synchronously** by `$run` — not a second Component-Model task. Nothing
in Phase B runs concurrently with anything else. So Phase B demonstrates
only that `spawn f; await t` compiles correctly **when no observable
parent work happens between the spawn and the join** — in that degenerate
case the spawn is semantically a no-op and compiles away to a direct call.

It does **not** show that a real spawn — a second guest computation that
interleaves with parent work before the join — needs no extra machinery,
and it cannot: a stackful fiber runs one call chain, so concurrent guest
work requires either another task or a guest-side poll executor. Phase A's
evidence points the other way: a genuine `wit_bindgen::spawn_local` pulls
in a `FuturesUnordered` executor plus `context.get/set` and
`waitable-set.poll`. The Phase A section above attributes those purely to
wit-bindgen's callback-form architecture; that is plausible for
`context.get/set` specifically (both `async_support.rs` and `subtask.rs`
call them unconditionally, spawn or not), but it is **not established**
that a stackful implementation could support interleaving spawn without an
equivalent executor.

Net: **real interleaving spawn remains open** (M-conc-2 / the M1b-3c-2
follow-up). Under the lowering this milestone ships, any parent/child
handshake or observable work between spawn and join would reorder or
deadlock — the same limitation the linear backend's eager `Task::spawn`
already carries (`docs/spec/wasi-p3-async.md` §2.5).

## Update: eager-completion bug this probe's host could not surface (#1230 M1b-3c-2)

`spawned_future/component.wat`'s `$writer` dropped its subtask
**unconditionally** in the epilogue. That is wrong: an async-lowered call
that completes **eagerly** — status `RETURNED` straight out of the call
itself, the `br_if $done` fast path, no suspend — creates **no subtask**;
the handle bits of the packed result are `0`. Dropping it traps with
`unknown handle index 0`.

This probe's own host could never surface it: `get-async` always slept
300ms, so only the blocked path ever ran. The trap appeared the moment the
same component was driven through `runtime/viberun`'s new async-component
path (M1b-3c-2, `docs/spec/wasi-p3-async.md` §3.9) with a zero-delay host
import — and a host import resolving without suspending is entirely
ordinary in production (a cached value, a zero timeout, a socket read whose
data already arrived).

The fix is the same shape as the `$has_ws` waitable-set-leak fix from the
#1240 review: guard **both** drops on the one "we took the blocked path"
flag, since the subtask and the waitable set come into existence together
on that path. Applied here and in the emitter
(`component_codegen.vibe`'s `comp_generate_spawned_future_guest_core_module`).
`scripts/test_spawned_future_component_gate.sh` now exercises **both**
paths — blocked (asserting the elapsed wall-clock, so a
never-suspended run cannot pass) and eager.

Generalizable lesson, same family as the two bugs above: **a probe host
that only ever exercises one path proves only that path.** Anything the
emitter emits for a fast path needs a host that actually takes it.

## `concurrent_awaits/`: two host operations in flight at once (#1230 M1b-3c-3)

The "spawn" limit recorded above splits into two questions, and only one of
them is actually hard:

| | what runs concurrently | what it needs |
|---|---|---|
| interleaving spawn (M1b-3c-1c) | **two guest computations** | a second Component-Model task, or a guest-side poll executor. Still open. |
| **this probe** (M1b-3c-3) | one guest computation, **several host operations** | nothing new — a waitable set with several joined subtasks is exactly this |

The second is the `Promise.all` / `join!` shape, and it does not contradict
the stackful constraint: the guest still runs one call chain; it just has
more than one outstanding thing to wait for.

`component.wat` here is the `spawned_future/` guest with its single call
split into "start both, then wait for both". **The canon set is unchanged** —
`task.return`, `[async-lower]get-async`, `waitable-set.new/.wait/.drop`,
`waitable.join`, `subtask.drop`. What produces the concurrency is purely the
ORDER: both async-lowered calls are issued before either is waited on. A
"start A, wait A, start B, wait B" body emits the same instructions, returns
the same value, and takes twice as long.

Two things differ mechanically from the single-call probes:

- each call gets its **own result slot** (addr 0 and addr 4), which is what
  makes the returned sum (84 = 42 + 42) prove both calls really completed;
- `waitable-set.wait`'s **payload[0]** — which waitable fired — becomes
  load-bearing. The single-subtask probes could ignore it; here one loop
  retires both subtasks in whatever order the host resolves them.

Measured through `runtime/viberun` (which can drive these since M1b-3c-2):

| host delay per call | 1 call (`spawned_future/`) | 2 calls (this probe) |
|---|---|---|
| 300ms | 42 in 310ms | **84 in 312ms** |
| 1000ms | 42 in 1028ms | **84 in 1015ms** |

Two 1000ms calls finish in the time of one. That 1x-not-2x scaling is the
actual proof; the value check alone would pass on a serial implementation
too. Ported to `comp_emit_component_wasm_async_concurrent_awaits` and gated
by `scripts/test_concurrent_awaits_component_gate.sh`.

## `interleaved_tasks/`: the M1b-3c-1c question, answered against the prediction (#1230)

The "real interleaving spawn remains open" note above ended with a
prediction: that concurrent guest work "requires either another task or a
guest-side poll executor," citing Phase A's `spawn_local` dragging in a
`FuturesUnordered` executor plus `context.get/set` and `waitable-set.poll`.

**That prediction was wrong**, and this probe disproves it on real hardware.

What Phase A was actually measuring is wit-bindgen's **callback** form —
the explicit state machine that re-enters through a `[callback]` export on
every wake event. Under the stackful form vibe emits, `waitable-set.wait`
already reports **which** waitable fired (payload[0]), and completion-order
dispatch is all interleaving needs.

The probe is built so it cannot pass by accident:

```
  task A   await get-after(300) -> await get-after(300) -> log 1
  task B   await get-after(100)                         -> log 2
```

both started before either is waited on; the result is `log[0]*10 + log[1]`.

| | result | elapsed | reading |
|---|---|---|---|
| `component.wat` | **21** | **613ms** | B's continuation ran while A was still mid-sequence, and the total is A's *own* two awaits — B cost nothing |
| `serial_control.wat` | **12** | **713ms** | A awaited to completion first: 300 + 300 + 100 |

`serial_control.wat` is the same component — same canon set, same host
import, same delays, same log encoding — with only the ordering changed. It
is checked by the gate too, and must produce the **opposite** answer on
both the value and the clock. Without it, "returns 21" would be an
assertion with no evidence that it discriminates.

Timeline: at t=0 both A's first await and B are issued; **at t=100 B
resolves and B's continuation runs** while A is still waiting; at t=300 A
advances its state machine and issues its second await; at t=600 A's
continuation runs.

**Established:** two logical guest computations interleave at their await
points on ONE stackful fiber. No second stack, no `context.get/set`, no
`waitable-set.poll`; the canon set is unchanged from `spawned_future/`.

**Still open:** A's state across its two awaits is a hand-placed memory
slot here — a hand-rolled state machine. Performing that transformation for
arbitrary vibe source *is* ADR-0076's CPS/suspend lowering. So the
remaining M1b-3c-1c work is localized to codegen, and is smaller than the
old estimate now that "needs another task or a poll executor" is off the
table.

Needs viberun's `get-after` host import (a per-call delay); `get-async`'s
single fixed delay makes completion order and start order coincide, which
is enough to show calls overlap but says nothing about dispatch order.

Because these delays are baked into the committed WAT (they are part of the
artifact), viberun also exposes `VIBE_ASYNC_DELAY_SCALE_PCT` to scale every
host suspend by a percentage. Ratios are preserved, so completion order --
the thing the probe asserts -- is unaffected; only the clock moves:

| scale | interleaved | serial | saving |
|---|---|---|---|
| 2% | 21 in 23ms | 12 in 25ms | 2ms |
| 100% | 21 in 612ms | 12 in 713ms | 101ms |
| 200% | 21 in 1212ms | 12 in 1412ms | 200ms |

The gate uses 2% for its warmups -- which otherwise ran the probe's full
~1.3s of sleeps purely to warm the JIT, costing as much as the measurement
they exist to protect -- and 100% for the measured runs, so the margin is
untouched. Raise it above 100 if a loaded machine ever narrows that margin.
