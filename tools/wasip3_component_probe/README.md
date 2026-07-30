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
