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

### Dynamic import prefixes

Five import families are minted per program rather than listed:
`vibe.host_future_get$<name>`, `vibe.wit_future_get$<address>` (#2064),
`vibe.wit_response_get$<address>` and `vibe.wit_response_arg_get$<address>`
(#2066), and `vibe.host_stream_get$<name>`.
Each has its own emission loop in `linked_compile.vibe` and its own
`componentAdapterPatterns` row in `docs/generated/host-runtime-contract.json`.
`check_host_runtime_contract.py`'s `validate_emitter_contract` compares the two
by **exact dict equality**, so a loop added without its row (or a row without
its loop) turns the required gate red in the same change. The composer reads
the prefixes back in `component_codegen.vibe` (`comp_is_wit_future_get_import`,
`comp_is_wit_response_get_import`, `comp_is_wit_response_arg_import`,
`comp_wit_future_interface` /
`comp_wit_future_func`).

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
- **Wait on any** (#1537). `host_future_arm (i64) -> i64` answers `1` when the
  handle's read already completed, else joins the handle to ONE shared
  waitable set (created on first use, its handle kept in the adapter's scratch
  word 40) and answers `0`. `host_future_wait_any () -> i64` blocks on that
  set; for a FUTURE_READ event `payload[0]` names the future, which leaves the
  set and is marked completed, so `host_future_wait` then takes its value
  without blocking. It returns the suspend payload (`handle + 2`). Both are
  imported only when a program's entry
  boundary settles host futures AND it links `@vibe/concurrent`: the library's
  `__conc_host_arm` / `__conc_host_wait_any` / `__conc_host_take` default to
  "no host waitables", and linked_compile gives them these bodies
  (`lc_host_hooks_install`). A spawned task awaiting a host future parks on
  its handle; `TaskGroup::pump` resumes whichever lands first, with its value,
  once nothing else can run. An `Exception` entry beside them exits through
  its boundary; the adapter serves `stderr_write_stream` / `process_exit` as
  trapping stubs, #2976's rule for the p1 wrap.
- **Streams in the same set** (#1537). A task's byte read parks too:
  `host_stream_arm (i64) -> i64` starts a one-byte `stream.read` into the
  handle's byte slot and joins the shared set (or answers `1` when the read
  completed inline, or the CLOSED latch is set), recording the read as
  pending (band 20480) with its status (band 24576). `host_future_wait_any`
  answers a STREAM_READ event by recording `payload[1]` as that status and
  returning `handle + 2048`; a FUTURE_READ returns `handle + 2`. These are the
  suspend payloads the tasks parked with, so the scheduler matches them
  directly. `host_stream_read` then settles the armed read instead of issuing
  a second one, and interprets its status exactly as before (a byte, the
  inline CLOSED latch, or `-1` at the end).
- **The sleeper's timer in the same set** (#1537). While tasks wait on host
  waitables and another task sleeps, `host_sleep_arm (i64) -> i64` starts a
  `sleep-for` call for the earliest sleeper's remaining milliseconds and
  joins its subtask to the shared set (the results land in scratch word 48,
  which nothing reads). It answers `1` when the call returned inline, else
  the timer's id in the TIMER band, `n + 4096` for an adapter counter `n`
  recorded per subtask (an i64 counter at word 56, an i64 per handle in band
  28672), so an id never repeats even though a dropped subtask handle is reused
  (the future band is [2, 1025], the stream band [2048, 3071]).
  `host_future_wait_any` answers
  the subtask's RETURNED event (status `2`) by dropping the subtask and
  returning that id. Each task group keeps its own timer (`host_timer` /
  `host_timer_ms` on `TaskGroup`) and, when it fires, debits only the
  sleepers that were pending when it was armed. So a sleep and a host wait
  settle in whichever order they land rather than sleep first
  (`fixtures/async_spawn_host_futures/sleep_and_host.vibe` and
  `sleep_short.vibe`, each ~300ms where either fixed order takes ~400-500ms;
  `sleep_after_host.vibe` pins that a later sleep keeps its debt). Imported
  only beside the other hooks, when the program also sleeps.
- **Nested task groups share the set** (#1537). A group running inside a
  task of another group waits on the same shared set, so it can receive an
  event that belongs to the enclosing group. A timer id it did not arm goes
  to a mailbox (`conc_host_fired_timers`) that the owning group checks on
  its next settle. A future or stream event with no task of its own parked
  on it is left untaken: the adapter already recorded it as completed, so
  the owning group's next arm answers "ready" and takes the value
  (`fixtures/async_spawn_host_futures/nested_groups.vibe`).
- **Cancelling the last waiter** (#1537). `TaskHandle::cancel` on a task
  parked on a host future that no other task awaits calls
  `host_future_cancel (i64) -> i64`: a read still BLOCKED leaves the shared
  set and is cancelled with a synchronous `future.cancel-read` (a cancel that
  finds the value landed counts as landed, and a landed response's body
  stream is dropped with it), then the readable end is dropped and the state
  cleared, as `host_future_wait`'s teardown does. Without it every such
  cancellation held one of the adapter's 1023 handles for the rest of the run
  (`fixtures/async_spawn_host_futures/cancel_many.vibe`). A parked STREAM
  read is released the same way, by `host_stream_cancel (i64) -> i64`: an
  armed read leaves the set and is cancelled with a synchronous
  `stream.cancel-read` (whatever it transferred is discarded), the per-handle
  bands are cleared and the readable end is dropped. Dropping is sound
  because a host stream cannot be captured by another task (it is neither
  Send nor a same-nursery endpoint), so the cancelled task was its only
  reader (`stream_cancel_many.vibe`). A task group's fail-fast sibling
  cancel releases each parked sibling's read the same way, and an event that
  fires with no task anywhere waiting on it is released by whichever group
  receives it.
- **Releasing a group's timer** (#1537). A group that closes with its timer
  still armed -- every sleeper it covered was cancelled, or the group failed
  -- calls `host_sleep_cancel (i64) -> i64` with the timer's id. The adapter
  finds the subtask whose recorded id it is, takes it out of the shared set,
  cancels it with a synchronous `subtask.cancel` (a timer that returned but
  was not yet delivered answers RETURNED, which is just as done), drops it
  and clears its slot; `host_future_wait_any` clears the slot when it drops a
  delivered timer, so an id never matches a dropped handle. A timer that
  already fired while another group waited is only a mailbox entry by then,
  and the group removes that instead. Without it each such group held a
  subtask handle for the rest of the run
  (`fixtures/async_spawn_host_futures/timer_release_many.vibe`: 1100 groups).
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

- **A future addressed by WIT imports from its interface** (#2064). A
  `host_future_named` argument of the form
  `<ns>:<pkg>/<iface>@<version>#<func>` (`cc_is_wit_future_address`) is
  emitted by linked_compile as `vibe.wit_future_get$<address>` instead of
  `vibe.host_future_get$<name>`, with the same `() -> i64` type and the same
  wait half. The composer imports every such function from ONE instance of its
  versioned interface, and each is a `future<s64>`. The addresses come from WIT text:
  `from_wit_future_imports` (`@vibex/wasm_wit_parser`) derives a binding per
  `async func() -> s64` and refuses any other function rather than skipping
  it. `scripts/test_wit_async_import_component_gate.sh` compiles
  `fixtures/wit_future_import/main.vibe` against those derived bindings and
  checks for the single `example:prices/api@1.0.0` instance import. The file
  lane composes the adapter for a `run` entry whose core imports a host future
  or stream (`maybe_wrap_stdin_provider_core`), as the single-file lane
  already did, so a program that imports its bindings builds to a component
  directly. viberun links a `VIBE_ASYNC_FUTURES` entry whose name is such an
  address (`example:prices/api@1.0.0#get-price=40:300`) inside that versioned
  instance as `future<s64>`, so the gate also executes the program. It
  measures 42 in about one producer delay for two concurrent futures, and
  bounds that from above (they were in flight together) and below (the task
  parked).

- **A WIT response carries a status and a streaming body** (#2066).
  `host_response_named(<address>)` is `Future[HostResponse]`, for a WIT
  function `async func() -> response` whose `response` is the package `types`
  interface's `record response { status: s32, body: stream<u8> }`.
  linked_compile emits `vibe.wit_response_get$<address>` (same `() -> i64`
  type, same wait half). The composer imports the `types` instance for the
  record and the API instance for the functions, and declares
  `future<response>` over the imported record. The adapter lands the record
  in the future's 8-byte slot, `{status: s32 @0, body: stream<u8> @4}`, and
  the wait returns it as one scalar, `(status << 32) | body`: the record's
  flat lowering side by side. A status outside `[-2^30, 2^30)` does not fit
  the tagged value and traps in the adapter. `HostResponse::status` and
  `HostResponse::body` take the scalar apart; `body` wraps the stream handle
  in a host-stream cell, which the shared stream read half reads (present
  whenever a response is, even with no named stream). Each `body` call wraps
  the same end, so read it through one cell: once one reaches end of stream
  the end is dropped, and reading through another traps. Every future in a
  response component comes from ONE interface, and anything else is refused
  by name. Scalar `future<s64>` functions of that interface may sit beside
  the responses (MIXED): the API instance type declares both future types,
  the composer adds a second canon read/drop (and cancel-read) pair of the
  s64 type, and the adapter records each handle's kind (band 36864, 1 = a
  response) at its getter, then picks the pair and the value encoding by it
  (`fixtures/wit_response_mixed`: 211 in ~320ms for a response beside a
  scalar future). Named host streams may share it too: they are ROOT
  imports, so they (then `sleep-for`) take the component funcs before the
  interface's aliased functions, the lowers keep the core order (futures,
  then streams), and the `stream<u8>` type the body declared serves their
  getters as well (`fixtures/wit_response_import/stream_main.vibe`: 248). The
  same mapping lets scalar WIT futures share a component with named streams
  (`fixtures/wit_future_import/stream_main.vibe`, and `stream_spawn_main.vibe`
  with `sleep-for` as well: 84 each). Runner-private root futures still cannot
  share a WIT component: they carry `future<u32>`, the WIT ones `s64`. `from_wit_future_imports` derives the bindings (it admits the
  function only with `use types.{response};` and exactly that record).
  A response function may take ONE `string` parameter (a request URL,
  `async func(url: string) -> response`); the derivation spells it
  `host_response_named_with("<address>?<label>", url)`. The guest pushes the
  argument's bytes one at a time through `vibe.host_arg_push` into the
  adapter's argument buffer (length at word 64, bytes from 65536 -- page 1,
  above every fixed band -- growing the memory a page at a time, so a string
  has no length bound short of a failed grow), then calls `vibe.wit_response_arg_get$<address>`,
  which passes `(buffer, length)` as the lowered string, starts the call and
  resets the length, so each request starts from an empty buffer. Any other
  parameter shape is refused by name.
  viberun's `VIBE_ASYNC_RESPONSES="<address>=<status>:<delay_ms>:<b1>|<b2>"`
  links each function inside its interface; `echo` in place of the body links
  a one-string-parameter function whose body is the argument's own bytes
  (`fixtures/wit_response_request`: two requests, 594). The gate runs
  `fixtures/wit_response_import/main.vibe` with two 300ms responses, gets 440
  (both statuses plus every body byte) and bounds the wall clock the same way.

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

## Cancellation

ADR-0068 (`concurrency.md`) specifies cooperative cancellation as the public
model; what the component adapter emits under it is the three READ-side
cancels, all synchronous: `future.cancel-read` (`host_future_cancel`),
`stream.cancel-read` (`host_stream_cancel`) and `subtask.cancel`
(`host_sleep_cancel`, a group's pending timer). Each runs when the last task
that could take a value is gone -- cancelled, failed fast, or its group
closed -- and is followed by the drop of the handle it cancelled; the bullets
under `### Host futures` say when. `future.cancel-write` and `task.cancel` are
not emitted: the guest never writes a host future, and a guest task is not a
Component Model task (#1537 scope item 3).

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
- What an abandoned future or stream does to the HOST side beyond the canon
  cancel: wasmtime drops the producer's future, and a second runtime could do
  otherwise without any conformance row here noticing.
