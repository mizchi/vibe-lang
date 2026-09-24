# Async host runtime contract

The inventory #2832 checkbox 1 asks for: every async host import, read off the
emitters rather than off a design document, with what the values mean, who owns
a handle, what completion looks like, and what is refused.

Checkbox 2's separation — runtime-neutral contract vs Wasmtime configuration —
is the [Two bands](#two-bands) split below. It is not a stylistic division: the
two bands differ in how many implementations exist, and therefore in whether
they can disagree.

Names and core types are already machine-checked by
`docs/generated/host-runtime-contract.json` +
`scripts/check_host_runtime_contract.py`. **This file holds what that manifest
cannot: the meaning of the bits.** Where a claim here is mechanically
checkable, it has a gate and this file names it; where it is not, it says so.

Measured against `779f1b6`; the `vibe.sleep` section re-measured after #2903's fix.

## Two bands

| | `vibe.sleep` | the other nine |
|---|---|---|
| manifest band | `portableCore` | `componentAdapterOnly` + `componentAdapterPatterns` |
| implementations | **two** (`runtime/viberun`, `scripts/wasm_vibe_host_runner.js`) | **one** (the adapter the composer emits) |
| can two backends disagree? | yes — the risk is real, see **#2903** | they did, see below |

That asymmetry is the whole of checkbox 4's "no backend may silently
reinterpret the same import". The one import with two declared implementers is
the one that diverged, and #2903 showed the divergence was not between the
hosts: both read the module's own `vibe.abi` declaration and both obeyed it.
The emitter was the party that did not.

The other nine were counted as safe because each has a single implementer. That
count was wrong: a runner does not have to register an import to answer it.
`wasm_vibe_host_runner.js`'s fallthrough supplied every one of them as `0`, so
they had two implementations — the adapter's, and a zero — and nothing said so.
See the `componentAdapterOnly` section for the measurement and for what #2928
changed.

## The import set

Emitted by `lib/@vibe/compiler/codegen/wasi/linked_compile.vibe` in one import
section, in reserved-index order, each demand-gated on a `used_builtin_names`
lookup (gating at `:9587-9648`, emission at `:13508-13620`).

### portableCore — linked by a core runner

| import | core type | emitted | implemented by |
|---|---|---|---|
| `vibe.sleep` | 1 · `(i64) -> ()` | `:13512` | `viberun/src/main.rs:3449`, `wasm_vibe_host_runner.js:2814` |
| `vibe.stdin_read_char` | 5 · `() -> i64` | `:13522` | both runners, **synchronously** |
| `vibe.stdin_read_stream` | 3 · `(i64) -> i64` | `:13646` | both runners |

`stdin_read_char` is described at `linked_compile.vibe:9593-9597` as
"implemented async by the host". Both shipped runners implement it with a
blocking read. The description is a statement about an intended host, not about
either host that exists.

### componentAdapterOnly — never linked by a core runner

| import | core type | emitted |
|---|---|---|
| `vibe.host_future_get` | 5 · `() -> i64` | `:13535` |
| `vibe.host_future_wait` | 3 · `(i64) -> i64` | `:13543` |
| `vibe.host_stream_read` | 3 · `(i64) -> i64` | `:13569` |
| `vibe.host_stream_close` | 3 · `(i64) -> i64` | `:13581` |
| `vibe.stdin_provider_acquire` | 5 · `() -> i64` | `:13591` |
| `vibe.stdin_provider_read` | 3 · `(i64) -> i64` | `:13599` |
| `vibe.stdin_provider_close` | 3 · `(i64) -> i64` | `:13607` |
| `vibe.host_future_get$<name>` | 5 · `() -> i64` | `:13556`, one per sorted-deduped name |
| `vibe.host_stream_get$<name>` | 5 · `() -> i64` | `:13616`, one per sorted-deduped name |

Neither `scripts/wasm_vibe_host_runner.js` nor `runtime/viberun`'s core lane
registers any of these, and that is by design: they are satisfied inside the
composed component by the adapter
`lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe`
emits.

This paragraph used to end "A core module importing them and run through either
runner fails at instantiation, not at the call", verified by ABSENCE from each
runner's member list. That was the wrong thing to verify, and the claim was
false for one of the two runners. `wasm_vibe_host_runner.js` builds its `vibe`
import object as a Proxy whose fallthrough answers an unknown field with
`() => 0n`, so absence from the member list does not refuse the import — it
supplies a function that returns zero. Measured before #2928, a core module
importing `vibe.host_stream_get$body` and `vibe.host_stream_read` instantiated,
ran, printed `sum=0` and exited 0; the loop shapes that test for the `-1` EOS
sentinel instead trapped with a bare `RuntimeError: unreachable`.

Since #2928 the node runner refuses these names on CALL, with a message naming
the import and the viberun lane that implements it. Not on instantiation: a
program that links one and never reaches it does not need the capability.

`runtime/viberun`'s core lane is the one that fails at instantiation, and that
is measured rather than inherited from the design — the same module, the same
question:

```
viberun: unknown import: `vibe::host_stream_read` has not been defined
   2: wasmtime::runtime::linker::Linker<T>::instantiate
```

exit 1, and the program's own output is absent, which is what separates
"refused before user code" from "ran and then failed".

So the two lanes fail at different MOMENTS, and that is stated rather than
averaged. `scripts/host_async_import_unsupported_test.sh` asks both, so neither
half of this paragraph can go stale without a gate noticing.

### A third dynamic prefix the manifest does not know

`vibe.wit_future_get$<versioned-interface>#<func>` is parsed and routed by the
composer in `component_codegen.vibe` (`comp_is_wit_future_get_import`,
`comp_wit_future_interface` / `comp_wit_future_func`, `comp_hostfuture_import_label`,
and the instance-import emission in `comp_emit_component_wasm_async_hostfuture`)
but `grep -c wit_future` is **0** in `linked_compile.vibe`,
`core/builtin_registry.vibe` and `checker/builtins_async.vibe`. Nothing
produces it from source today; it reaches the composer only from the synthetic
fixture core, `comp_generate_async_wit_future_fixture_core`. (Cited by name:
this paragraph used to give line numbers, and they had drifted by 15-45 lines
within a week.)

This matters for sequencing #2064: `check_host_runtime_contract.py`'s `validate_emitter_contract`
compares the emitter's dynamic prefixes against the manifest's
`componentAdapterPatterns` by **exact dict equality**, so the first commit that
makes `linked_compile.vibe` emit `wit_future_get$` turns a green required gate
red unless the manifest row lands in the same change. That is a consequence of
the gate working, not a defect in it.

## What the values mean

### `vibe.sleep` — the argument is a RAW millisecond count

**The module declares its own answer.** Every emitted core module carries a
`vibe.abi` custom section reading `host_import_abi=raw`
(`codegen/wasm_emit/metadata.vibe:45`; every call site passes `"raw"`, and
nothing in the tree ever emits `tagged`). Under that declaration the `i64` a
host receives IS the millisecond count, and the **guest** is what untags: the
RC raw-ABI shim in `codegen/expr/compile_call.vibe`
(`cc_raw_abi_shim_applies`) removes the `n << 1` tag before the import call,
gated on `ctx.enable_rc`. That is option 1 of the two #2903 laid out, and it
was already the design — it just had a hole in it.

The hole was one name. `sleep_blocking` was absent from the shim's name list
while `sleep` was present, so the argument reached the host still tagged and
`sleep(1000)` handed it `2000`. It is not an obscure spelling: the injected
`__entry_settle` pays a suspend sleep debt by calling `sleep_blocking`
(`linked_compile.vibe:4222`, `:4255`), and both names resolve to the same
`vibe.sleep` import (`:10996`), so an ordinary `sleep(ms)` inside `allows
Async` reached the host through the uncovered name. Measured on the same
program before and after, with `VIBE_RC=0` as the control:

| | `VIBE_RC=0` | `VIBE_RC=1` |
|---|---:|---:|
| before | 1000 | **2000** |
| after | 1000 | 1000 |

So the two shipped core runners were never in disagreement with each other on
a module this compiler produces: `runtime/viberun` passes the `i64` through,
and the node runner's `decodeHostInt` returns `Number(value)` unshifted once
`detectHostImportAbi` reads `raw` off the section (`:708`, `:1313`).

Pinned by `tests/gates/early/run.sh` gate `27g/27`, which asserts the VALUE
handed to `vibe.sleep` on both RC lanes with an observer that decodes nothing.

**One decoder is still stale, and it is unreachable.**
`decodeTaggedOrRawInt` (`wasm_vibe_host_runner.js:686`) shifts by **2**, a tag
width the RC lane stopped using, and it is a heuristic on the low two bits —
which for `ms << 1` are a function of `ms`'s parity, so it would reinterpret
the same import per call site. It runs only when the ABI is not `raw`, and the
only way to get there is `VIBE_IMPORT_ABI=tagged`, an env override that
**wins over the module's own declaration** (`:2470`). No module in the tree
declares `tagged` and nothing in the repo sets that variable, so this is a
dead lane rather than a live divergence — but it is a loaded one, and the
override silently contradicting a module that says `raw` is the hazard #2903's
"fifth implementer" paragraph is about. Not fixed here; see the list below.

### Host futures

- **Getter** (`host_future_get`, `host_future_get$<name>`) issues `future.read`
  **eagerly** into a per-handle landing slot and records a state: `1` =
  BLOCKED (`0xffffffff` from the canonical read), `2` = completed inline. A
  handle in any other state never went through a getter, and the adapter traps.
- **Wait** (`host_future_wait`) only **settles**. It does not re-read: a second
  `future.read` on a future that already has one pending is a canonical-ABI
  error, which is why the read is in the getter and not here.
- **Drop** is conditional -- this is *the conditional-drop rule* the
  runtime-neutral list below names. A call that completed eagerly (status
  RETURNED, code `2`) created no subtask, so it is neither joined nor dropped
  (`component_codegen.vibe:2760-2761`). The probe in
  `tools/wasip3_component_probe/` traps on eager completion and so never
  exercised this branch; the composer reaches it.
- **A settled cell latches**, so awaiting the same `Future[T]` twice costs one
  host read. `__aw_settle` (`lowering/effects/await/await.vibe`) writes the
  resumed value into the cell's payload word and then sets the state word to
  `0`, so `__aw_poll`'s `while 0 < state` loop does not run again and the
  second `await` reads the cached payload -- the future-side counterpart of
  the stream's post-close `-1` latch below. It must not re-read: per the Wait
  bullet, a second `future.read` on a future that already has one pending is a
  canonical-ABI error. Measured, not inferred (#2832), on both spellings: with
  a 300ms producer delay `host_future_named` returns `42` in ~317ms and
  `host_future_get` returns `84` in ~316ms, while two sequential reads of two
  futures take ~618ms. The value cannot separate the two worlds -- the host
  hands back the same number either way -- so the wall clock is what decides.
  `scripts/test_named_hostfutures_component_gate.sh` asserts the named row AND
  the ~618ms two-read control, because a window that no longer separated one
  host read from two would let the first row pass while proving nothing;
  `scripts/test_hostfuture_source_component_gate.sh` asserts the anonymous
  row, since the anonymous routing is a different path through the wrap even
  though `__aw_settle` is shared.

### Host streams

- **Getter** (`host_stream_get$<name>`) does **no** eager read and keeps no
  per-handle state — the park is per-read, and a read left pending between
  calls would double-read.
- **Read** (`host_stream_read`) returns one byte, or `-1` at end of stream.
  End of stream has **two** shapes and both are handled
  (`component_codegen.vibe:2096`): a zero-transfer CLOSED code `1` (drop the
  readable end, return `-1`), or the final byte arriving *with* the CLOSED code
  (latch `comp_hs_closed_base` so the next call settles to `-1`). Any other
  zero-transfer code traps loudly rather than being read as EOS.
- **Close** (`host_stream_close`) clears the CLOSED latch and issues
  `stream.drop-readable`. No park — dropping is synchronous. The guest cell's
  state word gates the one call, because a second `stream.drop-readable` on a
  dropped end traps host-side. The raw ABI is uniformly `(i64) -> i64` even
  though the surface returns `Unit`.

### Canonical read encodings

Every constant here is a measurement taken against
`tools/wasip3_component_probe/host_stream_value`, not a choice
(`component_codegen.vibe:2091-2098`):

| what | encoding |
|---|---|
| a blocked read | `0xffffffff` |
| a completion | `(amount << 4) \| code` |
| the wake event for a read | `2` |
| the status in a `waitable-set.wait` payload | the **second** word |
| end of stream | a zero-transfer code `1`, **or** riding along with the final byte |

Reading again after either terminal shape traps, which is why both end the
loop rather than one being treated as the normal case and the other as an
error.

### Guest cell shapes

A `Future[T]` is a two-word cell `[state, payload]`, and the state word is
what distinguishes the four things that share the representation
(`checker/builtins_async.vibe:21-23`):

| state | meaning | payload |
|---|---|---|
| `0` | ready | the value |
| `1` | guest pending | guest-side |
| `2` | host future | the handle |
| `3` | host stream | the handle |

`HostStream` is the state-3 cell. The states are disjoint on purpose:
`compile_call.vibe:3372-3373` records that the host-stream state is "distinct
from every future cell state so a future cell can never be read as a stream or
vice versa".

A host stream arriving as a **parameter** is the bare handle, not a cell, and
the parameter is shadowed by a cell built at the top of the body — without
that, a read would pull state and handle out of a single integer
(`tests/gates/mid/run.sh:301-304`, the #1540 lane).

## The suspend-request band protocol

The injected `__entry_settle` (`linked_compile.vibe:4190-4260`) dispatches a
single `Int` request. The bands are documented at `lc_hs_req_base`
(`linked_compile.vibe:2966-2977`) and are load-bearing magic numbers:

| request | meaning |
|---|---|
| `req < 0` | sleep debt of `-req` ms → `sleep_blocking` |
| `req == 0` | cooperative yield |
| `req == 1` | poll wait — **deterministically traps** (it would livelock under the tail-resumptive boundary) |
| `2 ≤ req ≤ 1025` | host-future waitable, handle `req - 2` |
| `req ≥ 2048` | host-stream read, handle `req - lc_hs_req_base()` |

The future band's top, `1025`, is `2 + comp_hf_max_handles()` — and
`comp_hf_max_handles() = 1023` lives in `component_codegen.vibe:5778` while
`lc_hs_req_base() = 2048` lives in `linked_compile.vibe:2975`. The bands are
disjoint "by construction, not by runtime discipline", as that comment says,
and the construction spans two files that nothing read together until
`scripts/check_async_band_contract.sh`.

## The adapter slot bands

`component_codegen.vibe:5738-5781`:

| base | value |
|---|---|
| `comp_hf_value_base` | 4096 |
| `comp_hf_state_base` | 8192 |
| `comp_hs_value_base` | 12288 |
| `comp_hs_closed_base` | 16384 |
| `comp_hf_max_handles` | 1023 |

Every adjacency is **exactly** full — `4096 + 1023×4 + 4 = 8192`, and the same
to `12288` and to `16384`. Margin zero at three boundaries. Raising the handle
cap without moving the bases silently overruns into the next band, which is why
`scripts/check_async_band_contract.sh` asserts the arithmetic rather than the
constants.

## Cancellation does not exist

No cancellation operation is emitted or implemented anywhere. `subtask.cancel`,
`future.cancel-read`, `future.cancel-write` and `task.cancel` have zero
occurrences across both emitters and `runtime/viberun`; the only hit for
"cancel" in the async surface is a prose comment at
`checker/builtins_async.vibe:160` recording that `future.cancel-*` remains
M-conc-2.

ADR-0068 (`concurrency.md`) specifies cooperative cancellation as the public
model. That specification currently has no ABI under it. #1537 scope item 3
names these operations; this file records their absence as a fact rather than
leaving it to be inferred from a design document that describes the intent.

## Runtime-neutral vs Wasmtime-specific

Checkbox 2's split, stated concretely:

**Runtime-neutral** — anything a second implementation would have to match:
the import names and core types (already in the manifest), the request-band
protocol, the four cell states `0`/`1`/`2`/`3` and their disjointness, the
stream `-1` EOS sentinel and its two shapes, the conditional-drop rule
(`### Host futures`), and the settled-future latch.

**Component Model canonical ABI** — not portable, and not something a core
runner can honour: `future.read`'s `BLOCKED` = `0xffffffff`, the
`waitable-set.wait` completion-order dispatch, `subtask.drop` /
`waitable-set.drop` / `stream.drop-readable` opcodes, the `[async-lower]`
call-to-subtask folding.

**Wasmtime configuration** — the flags `runtime/vibe:929` passes
(`-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W
component-model-async=y -W component-model-async-stackful=y`), and
`VIBE_ASYNC_FUTURES` / `VIBE_ASYNC_STREAMS`, which are a **test harness**, not
part of the contract: they exist only in `runtime/viberun/src/main.rs:917`
and `:1000` and link named root imports from an env spec. The runner reserves
`get-future`, `get-async`, `get-after` and `sleep-for` against redefinition
(`:935`, `:1011`).

## What is still not pinned

- The `VIBE_IMPORT_ABI=tagged` override, which beats a module's own `vibe.abi`
  declaration and then decodes through a 2-bit-tag heuristic the RC lane no
  longer matches. Unreachable by default and unused in the tree; it should
  either refuse to contradict the declaration or be removed, rather than
  quietly answering differently.
- The `stdin_read_char` "async by the host" description, which no host
  implements that way.
- Cancellation, restated: there is no ABI for it, so nothing here says what a
  dropped or abandoned future or stream does to the host side.
