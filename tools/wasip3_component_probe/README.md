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
`future<T>` *value* (e.g. an import returning `future<u32>` that the guest
then reads itself) would be needed to see literal `future.read` calls — not
yet built here; `get-async`'s implicit wait already exercises the
`waitable-set.new`/`.poll`/`waitable.join` loop, which is the part
`compile_call.vibe`'s `await` lowering actually needs to emit.

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
