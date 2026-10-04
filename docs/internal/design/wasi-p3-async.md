# WASI 0.3 (Preview 3) async — design and lowering

Status: the language model of ADR-0012 and the decisions of
[ADR-0089](wasip3-effect-alignment.md) are implemented. This document is the
source of truth for how async lowers onto the Component Model's async ABI;
what is still open is §6.2.

WASI 0.3 was ratified on 2026-06-11 and made `stream<T>` / `future<T>`
first-class Component Model types. vibe's async model is **an `Async` effect
row + `Future[T]` + AsyncIter**, with a pull-based stream protocol modelled on
the existing `Iterator`.

### How to read this document

| section | contents | nature |
|---|---|---|
| §1, §2 | the language model: types, `await`, streams, the effect row | **current specification**; enough on its own to understand today's language |
| §3 | codegen / ABI measurements (§3.1–§3.19) | **measurement record**: the byte encodings of the canonical built-ins and the constraints measured on a real runtime. Each subsection records what was measured when it was taken; where it names open work, a later subsection or §6 records how that closed |
| §4, §5 | the WIT boundary mapping, versions and pins | current specification |
| §6, §7 | what runs, what is open, unresolved questions | current state |

The language-surface decisions — one `Async` label, the materialized
`Future[T]`, retiring the eager `Stream[T]` for AsyncIter, the two-layer
coroutine / `stream` split and the `future<T>` / `stream<T>` / `async func` WIT
mapping — are ADR-0089's. Synchronous capability effects keep working as
before; async sits on top of them.

## 1. What changes from WASI 0.2 to 0.3

- `pollable` becomes `future<T>`, and `input-stream` / `output-stream` become
  `stream<u8>`. `wasi:io`'s poll / pollable is absorbed into the canonical ABI.
- Instead of taking a pollable through `subscribe()`, a function returns a
  `future<...>`. Two-step `start-foo` / `finish-foo` APIs merge into one
  `foo: async func(...)`.
- Example: `read-via-stream: func() -> result<input-stream, error-code>`
  becomes `read-via-stream: func() -> tuple<stream<u8>, future<result<_,
  error-code>>>`.
- `wasi:http` drops 0.2's `proxy` world for two worlds, **`wasi:http/service`**
  and **`wasi:http/middleware`** (vendored:
  `lib/@vibe/wasi/wit/p3/deps/http.wit`, `world service` / `world
  middleware`).
- The runtime is **wasmtime 47.0.2**, which ships the ratified `0.3.0` with
  component-model async on by default (§5).

## 2. The language model

This section describes the current specification only. Where the
implementation stands is §6; the ABI measurements are §3.

### 2.1 There is no `async` keyword — `Async` is an effect-row label

vibe has no function colouring; side effects are carried by the effect row. So
**there is no `async` keyword**: an "async function" is **a function whose row
contains `Async`** (`with Async`).

- `await(f)` is the builtin `(Future[T]) -> T with Async`
  (`checker/builtins_async.vibe`). It is not a reserved word, so the parser is
  unchanged (`ECall(EIdent("await"), [f])`).
- Using an `Async` computation in a context without `Async` is rejected by the
  effect-escape check (`EEEffectfulCallOutsideEffect`).
- **`effect Async { Suspend(Int) -> Int }` is declared in
  `lib/@vibe/concurrent/experimental/concurrent.vibe`** (#752's "the
  declaration is the contract") and matches the checker's builtin row label
  `"Async"` by name. That is why `handle .. with Async` can discharge it, as
  `TaskGroup::spawn_suspend` does. **Nothing stops a handler from discharging
  the builtin row**: what matches is the name, and the route is `perform`.

### 2.2 `Future[T]` — the two-word cell `[state, payload]`

`Future[T]` is not a type-level phantom: **at run time it is a two-element
array** (`future_ready_expr` and its siblings in `codegen/expr/`). The state
slot can say "not resolved yet", so adding a producer never means redesigning
the representation.

| state | meaning | payload | producer |
|---|---|---|---|
| 0 | ready | the value | `Future::ready(x)` |
| 1 | pending in the guest | not yet (resolve writes it) | `Future::pending()` |
| 2 | host future (a waitable) | the host future handle | `host_future_get()` / `host_future_named("x")` / a WIT-derived binding (`host_response_named`) |
| 3 | host stream cell | the readable end's handle | `host_stream_named("x")`, `HostResponse::body`, a `HostStream` parameter |

State 3 is distinct from the future states so that **a stream cell can never
be awaited as a future**, and the reverse.

`Future::resolve(f, v)` completes a state-1 cell. **It writes the payload
before clearing the state**, and the order is load-bearing: the other order
lets an awaiter observe "ready, but no value yet".

#### Lowering `await` — an AST pass, not codegen

`await` is rewritten into a call of `__aw_poll(fut)` by `await_poll_pass`
(`lowering/effects/await/await.vibe`). It runs right after
`desugar_trait_dicts` and **before** every effect pass: the position where
`compile_call` emits wasm comes after `suspend_cps_pass` /
`evidence_dict_pass`, so a `perform Async::Suspend` emitted there would have
nothing left to discharge it.

```text
__aw_poll(fut) -> Int with Async:
  while 0 < Array::get(fut, 0) {
    let __aw_w = perform Async::Suspend(<payload>)   // or __aw_wait(fut)
    ()
  }
  Array::get(fut, 1)
```

The `Suspend` payload bands (the `@vibe/concurrent` convention plus ADR-0089),
dispatched by the entry boundary's `__entry_settle`:

| payload | meaning |
|---|---|
| 0 | yield |
| 1 | poll wait (retry) |
| negative | sleep debt (`-ms`) |
| 2 ≤ p < 2048 | host-future waitable, `handle + 2` |
| p ≥ 2048 | host-stream read, `handle + 2048` |

[async-host-contract.md](async-host-contract.md) records which handles land in
each band and the adapter-side constants.

**The expansion is hoisted onto the spine, not left in expression position**
(`awp_tail`). `let a = await(x)` becomes `let __aw_f = x; while ..; let a =
Array::get(__aw_f, 1)`. Nested in expression position, it produces shapes
source syntax cannot write (a `let` + `while` as a `let`'s value), which flow
into later passes; with several awaits the compiler recursed without bound —
that happened (#1230).

The loop condition is `EBinOp("<")`, not the builtin `lt`: the see-through
walk of evidence migration does not know `lt` as a pure callee, so `while
lt(..)` makes every `handle` containing an `await` ineligible (measured).

When `waiter_hooks` is on, a round goes through `__aw_wait(fut)` and the
resolving side wakes the waiter directly (removing the O(rounds × awaiters)
polling, §3.15). A missed notify degrades to polling through a once-per-progress
fallback valve, and the deadlock trap is preserved.

#### `Future[T]` and `Spawnable` — no region parameter

The capture check of `TaskGroup::spawn` (`sp_spawnable_ok`,
`checker_spawnable.vibe`) admits `TaskGroup[r]` / `TaskHandle[r,_]` /
`Sender[r,_]` / `Receiver[r,_]` **only when `r` is the same nursery's region**.
`Future[T]` **has no region parameter and is admitted unconditionally**.

> **Decision (implemented)**: `Future` does not get a region argument. In the
> poll model the cell is **shared memory with no scheduler coupling** (await
> re-reads the state slot; resolve is two stores), and the guest is
> single-threaded, so there is no cross-nursery hazard of the kind `Send`
> prevents.
>
> **Revisit when** the cell carries a **waiter list the scheduler can see**:
> then `Future` needs a region tag and moves to the `sp_same_region` branch.
>
> Adding a region by arity (`Future[r, T]`) would not have been enough on its
> own: `Future::pending()` takes no argument, so `r` would stay a fresh
> variable unrelated to the spawn site's region, and the check would only hold
> once the constructor took a `TaskGroup` the way `Sender`'s does.

A future whose value owns a host stream is the exception: a response future
has one owner, and `sp_spawnable_ok` refuses to capture it in a spawned task
(#3152; [async-host-contract.md](async-host-contract.md)).

#### Eligibility for the suspend lowering (ADR-0076)

Because `await` becomes a `perform`, code containing an `await` is subject to
the eligibility rules of the suspend CPS split (`scps_*`). The boundary today:

- **Eligible**:
  - the let / seq / tail / branch-tail spine, and `while` + `let mut` (#1230:
    `let mut x = v` becomes a one-element cell, `while` a tail-recursive local
    `let rec` closure);
  - **a let-chain compound at the HEAD of a sequence** (a brace block
    statement, the desugared output of an async-iterator `for` in statement
    position — #1536 (a) v3's let-floating rebalances it onto the continuation
    spine, ADR-0076 addendum 42);
  - **a call of a row-free closure parameter whose every by-name call site
    passes a provably suspend-inert argument** (#1536 (a), below);
  - an `if` condition or `match` scrutinee that is itself a direct target
    perform, a concrete needing call or a CPS-local call (evaluated once into a
    fresh `let`, then selected — addendum 44);
  - **an ordinary assignment (`=`) on the continuation spine whose right-hand
    side is that direct shape** (evaluated once into a fresh `let`, assigned
    once — addendum 45), and **a `while` condition of that shape** (evaluated
    once per check inside the recursive loop closure — addendum 46);
  - **`break` / `continue` inside a loop** (the exit continuation is cut out as
    a closure and the transfer becomes a call on the CPS spine — addendum 47);
  - **a suspension embedded in a compound expression** — operands, call and
    constructor arguments, a compound `while` condition, compound assignment
    such as `+=` — linearized into a let chain in the original evaluation
    order (addendum 48);
  - **an `if` / `match` that is the whole value of a `let` / `let mut`** (the
    binding and the continuation are distributed into the branches; the
    condition or scrutinee is evaluated once in place, and `match` arms are
    alpha-renamed before the continuation moves — addendum 49), and **a block
    that is the whole value of a `let` / `let mut`** (`{ stmts..; value }`; the
    binding moves inside the statement prefix and floated binders are
    alpha-renamed — addendum 50, which is what lets "branches containing
    statements" through);
  - **the right-hand side of an assignment that is such a selection or block**
    (a boxed target before cellification, an off-spine target on the
    continuation spine, by the same two rewrites — addendum 51);
  - **an `if` / `match` nested inside a compound** (bound to a name whole,
    without descending into the branches, then handed to addendum 49's
    distribution — addendum 52);
  - **a non-tail `&&` / `||`** (also bound whole, without descending into the
    right operand, and only after asking the receiving let-short-circuit
    procedure whether it accepts it; the bypass is kept — addendum 53);
  - **`return`** (addenda 55–57). Where it sits decides the treatment: in a
    needing function's clone or a closure literal, `return v` means "this
    computation's value is v" and is **moved to the tail before the split**;
    inside a loop the value is saved, the loop is left with `break`, and the
    value returned outside (nested loops put a guard at each level and carry
    the exit outward one level at a time); inside a `handle` body it means
    "leave the enclosing function", so **the cell lives outside the `handle`
    and the return happens after it**. **A `return` that cannot be moved this
    way makes the body refused** (addendum 54), so the cost of an incomplete
    rewrite is a refusal, never a miscompile;
  - **a `for-in` whose iterand kind can be shown syntactically**: an argument
    annotated `Array[..]` / `String`, a binding of an array / string literal, a
    **literal in iterand position** (`for x in [1, 2]` / `for c in "ab"`), or
    a **call** of a callee with a declared return type, in iterand position or
    through a name bound to the call. Before the split an Array becomes the
    indexed `while` form and a String the `String::char_code_at` form. An
    iterand whose kind cannot be shown is not rewritten: codegen tells a
    String apart at run time and materializes its bytes (#807), so rewriting it
    into the Array form would iterate zero times and be silently wrong
    (addenda 58 / 60 / 63).
- **Callee names are resolved behind a scope-blind binder probe**: if a local
  binding with the same spelling occurs anywhere in the walked expression, the
  proof is dropped. Without the probe, trusting the top-level declaration
  indexed a String as an Array and answered wrongly with neither a diagnostic
  nor a trap (#1714, addendum 63).
- **One lexical classification stack is the authority for eligibility.** Only
  the last visible binder of a name is classified — inert, CPS or opaque;
  inert and CPS are accepted, opaque refused. Only then are the unbound
  generated prefixes, builtins / constructors / needing functions,
  `scps_fn_row_of` and `scps_callee_first_order` consulted. Independent name
  sets would let an old inert or CPS proof leap over a newer opaque binder of
  the same name. A source-bound `__scps_*` stays opaque. Eligibility and the
  culprit diagnostic share the same predicate and scope transitions (#1718,
  addendum 64).
- **Ineligible**: a `for` whose iterand kind cannot be shown; a selected `&&` /
  `||` right operand that does `return` / `break` / `continue`; a call of a
  closure parameter whose argument proof fails; a row-variable callee (`with
  e`). A closure literal is step-split on its own spine by the prepass, and
  supported nested handles of different effects keep the existing
  handler-ownership lowering, so neither is part of a blanket compound-ANF
  refusal.

Admitting closure parameters **unconditionally** would be unsound: a
`perform` in a closure literal is charged lexically to the row of the
function the literal sits in (#761), so "the declared row is empty, therefore
it does not perform" does not hold. #1536 (a)'s acceptance therefore rests on
**a proof about the argument flow**. Only `f`'s by-name call sites reach the
CPS clone `__scps_cps_E_f` (a call through a value runs the untouched
original), so for a slot where every by-name site can be shown to pass a
suspend-inert value — a closure literal that contains no perform, references
no needing name and calls no opaque callee, or the delegating function's own
row-free parameter proven the same way (the `AsyncIter::any` →
`AsyncIter::find` forwarding shape) — `pred(v)` in the clone is accepted as a
plain call. One site passing a literal that performs taints the whole slot,
which is refused as before with `cannot see through`
(`fixtures/err_effect_closure_param_taint.vibe`). This is what lets a suspend
body call `AsyncIter::find` / `AsyncIter::any` / `AsyncIter::all`; the
`for`-driven terminals (`AsyncIter::collect` / `AsyncIter::fold` /
`AsyncIter::count`) became writable with the let-floating of #1536 (a) v3
(addendum 42).

### 2.3 Relationship to synchronous effects

Synchronous effects (`handle` / `perform` / `resume`) are implemented by
evidence passing (#817; replay is gone entirely), and `Async` rides on top of
them. `Async::Suspend` is an ordinary operation; the only special treatment is
**the meaning of its payload bands** and the fact that `await_poll_pass`
synthesizes it. The semantics of synchronous effects do not change.

### 2.4 Stream types

The language has three deliberately distinct stream roles:

| type | run-time representation | used for | role |
|---|---|---|---|
| `ByteStream` | nominal byte sequence | `String::to_bytes` / `ByteStream::to_string` and WIT `stream<u8>` boundaries | the boundary specialization; never a generic guest stream |
| `HostStream` | the two-word cell `[3, handle]` | `host_stream_named`, `HostStream::next` (`-> Option[Int] with Async`), `HostStream::close` (idempotent), and the scalar `host_stream_next` / `host_stream_close` the generated loops use | a readable `stream<u8>` end owned by the host (#1955) |
| AsyncIter | a trait (`lib/@vibe/builtin/async_iter.vibe`) | guest pull iteration | guest-only protocol; refused in WIT signatures |

The removed `Stream[T]` was an eager, Array-backed prototype. It no longer
resolves as a compiler-owned nominal type, and `Stream::next` /
`Stream::to_string` no longer resolve as builtins (#1538), so an Array-backed
guest value cannot be advertised as a component stream. stdin is not a
`HostStream`: `wasi:cli/stdin@0.3.0` hands over a stream and a completion
future together, which the opaque `StdinStream` carries (§3.18.3, #1539).

Whether `for x in s { ... }` is an eager loop or an await loop is decided by
the iterand's type. **The separate `for await` spelling was removed by
#1350**: that an iteration may suspend is already said by the effect row, so a
syntactic marker said it twice. Whether the `for` itself requires `Async` is
read from **the iterand's type** (#1358): a type implementing an iterator
trait whose `next` returns a `Future`, or a `HostStream`, needs `Async` in the
enclosing row. The desugar reads the same bit to choose the await loop, so the
two decisions agree by construction.

`ByteStream` is nominal even though today's linear conversion lowering
materializes the bytes internally. Array builtins reject it, so that
representation is not part of the source contract. Exact-byte and empty-stream
conversion are covered by the linear and component gates.

### 2.5 `Task[T]` was removed (#1227); concurrency is `@vibe/concurrent`

`Task::spawn` / `join` / `cancel` / `race` / `timeout` were **removed** from the
front end; writing them gives `unknown name`. `spawn` ran its thunk
immediately, so `spawn(f); spawn(g)` was always serial — it looked concurrent
and was silently serial, with no warning and no failure.

The concurrency surface is `lib/@vibe/concurrent`
([concurrency.md](concurrency.md), ADR-0068):

- the stable core, `TaskGroup::run` / `TaskGroup::spawn`, `TaskHandle::join`,
  channels and `Parallel::map`, in `@vibe/concurrent`;
- the suspendable-task lane — `TaskGroup::spawn_suspend`, `pump` /
  `pump_all`, `sleep_wait`, `send_wait` / `recv_wait`, `result_wait` and the
  task-level `effect Async` — in `@vibe/concurrent/experimental` behind
  `VIBE_UNSTABLE=1`. Promoting it is #3200.

In a component, suspendable tasks really interleave on host waits (#1537,
#2065): a task that awaits a host future, reads a host stream or sleeps parks
on it, and the group waits on all of them in one shared waitable set,
dispatching on whichever completes (§3.11's completion-order dispatch).
Cancellation releases a parked read with `future.cancel-read` /
`stream.cancel-read` and a pending call or timer with `subtask.cancel`
([async-host-contract.md](async-host-contract.md)). **The tasks are guest
fibers** scheduled inside one component instance, not Component Model
subtasks the host can see, schedule or cancel; backing them with subtasks is
#3147.

## 3. Codegen strategy: the Component Model async canonical ABI

vibe calls the Component Model's async canonical built-ins directly and does
not depend on the Wasm stack-switching proposal. Entries are lifted in the
**stackful, callback-less** form (§3.1): the lifted core function returns
nothing and delivers its result through `task.return`, and a wait is a call to
`waitable-set.wait` that suspends the whole task on the host's fiber. The
emitted code is therefore straight-line — compute, `task.return`, return — and
no explicit state machine is generated for the entry. wit-bindgen's callback
form, which does need one, is recorded as a portable fallback and is not
implemented.

The canonical built-ins in use:

- `task.return` for an async export's result; `subtask.drop` / `subtask.cancel`;
- `future.new` / `future.read` / `future.write` / `future.drop-readable` /
  `future.drop-writable` / `future.cancel-read`;
- `stream.new` / `stream.read` / `stream.write` / `stream.drop-readable` /
  `stream.drop-writable` / `stream.cancel-read`;
- `waitable-set.new` / `waitable-set.wait` / `waitable-set.drop`,
  `waitable.join`;
- `canon lower ... async` for imports and `canon lift ... async` for exports.

Where each piece lives:

- **The guest's await** is §2.2's AST rewrite: `await` performs
  `Async::Suspend` with a payload naming what it waits on, and the entry
  boundary's `__entry_settle` settles it by calling into the adapter.
- **The adapter**, a core module the composer generates
  (`comp_generate_hostfuture_adapter_core_module` and its siblings in
  `lib/@vibe/compiler/codegen/component/component_codegen*.vibe`),
  owns every canonical call: it issues the reads, parks in
  `waitable-set.wait`, and hands values to the guest through raw `vibe.*`
  imports ([async-host-contract.md](async-host-contract.md)).
- **Concurrency between guest tasks** is the in-guest scheduler resuming tasks
  in the order their waits complete (§3.11, #1537), not a second stack.

These emitters are separate from the evidence-passing effect lowering. On
wasmtime 47 component-model async is on by default; the flags the gates pass
are listed in §5.

### 3.1 M1b feasibility spike（landed、実測 — wasmtime 45.0.0 / x86_64 linux）

wit-bindgen の `async func() -> u32` を手動で最小化し、async-lifted export が
wasmtime 45 で**実際に動く**ことと、emit すべき最小形を確定した
（blueprint: `src/x/cm_async/cm_async_lift_probe.wat`、戻り値 42 を確認）。

確定した最小形（callback-less / **stackful** form）:

- 戻り値型の component type は async: `(type (func async (result T)))`。
- `task.return` は `(core func (canon task.return (result T)))` で lower し、
  core module に import として供給。
- async lift は `(canon lift (core func ...) async)`（callback 無し）。
- **stackful form では core function は値を返さない（void）**。結果は
  `task.return` 経由のみで届ける。status-i32 を返すのは callback/stackless
  form で、stackful では reject される。
- フラグ: `-W concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`。

**設計含意（重要）**: stackful form なら **backend は straight-line code を
emit できる**（結果計算 → `task.return` → return）。await を含む場合も
`future.read` / `waitable-set.wait` で**ブロックする直線コード**を書けばよく、
§3 冒頭の明示的 stackless 状態機械分割は **不要**。wasmtime の
`component-model-async-stackful` は host fiber 実装で、WASM stack-switching
proposal（非 x86_64 で未サポート）とは別物のため、エンジン依存も回避できる。
これは当初の stackless 設計を大幅に簡素化する。

トレードオフ / 未確認:
- callback/stackless form（wit-bindgen が採用）は stackful フラグ不要
  （`concurrency-support=y component-model-async=y` のみで動作）だが、明示的な
  callback 状態機械の生成が必要で codegen が重い。**PoC は stackful 直線形を
  主とし、callback form を portable fallback として記録**。
- `component-model-async-stackful` の非 x86_64 / wasmtime 46 default での
  可用性は要確認。
- 別途、`component-model-async-builtins` は **wasmtime 45.0.0 では無効な
  `-W` フラグ**（M0 で誤記載していた。docs/report も修正）。**正しいフラグ名は
  `component-model-more-async-builtins`（🚝）**で、stream/future の canonical
  built-ins はこれで有効化される（§3.3 の M2c-3 spike で確定）。

検証基盤: 既存 `src/x/cm_async/cm_async_probe.wat`（flag 受理の sync probe）に
加え、本 spike の `cm_async_lift_probe.wat`（async-lift 実動 probe）を追加。

### 3.2 M1b 実装ブループリント（byte-level encoding map）

`cm_async_lift_probe.wat` を `wasm-tools dump` して抽出した、component encoder が
emit すべき正確なバイト列（wasmtime 45 で検証済み）。`component_codegen.vibe`
は既に async func type opcode `0x43`(67) と sync canon lift を持つので、不足は
(a) async lift option、(b) `task.return` canon、(c) core 側の import + void entry。

**core module**（`linked_compile.vibe`、async entry のとき）:
- import section: `import "cm" "task-return"`、func 型 `(param i32) (result)`
  = `02 63 6d  0b 74 61 73 6b 2d 72 65 74 75 72 6e  00 00`
  （module名"cm" / name"task-return" / kind=func(00) / typeidx=0）。
- entry func body: 値を計算し `call $task_return` して **void で return**
  = 例 `41 2a  10 00  0b`（i32.const 42; call task_return; end）。
- 型: task_return 用 `(param i32)->()` = `60 01 7f 00`、entry `()->()` = `60 00 00`。

**component sections**（`component_codegen.vibe`）:
- task.return canon: section `08`、内容 `01` + `09 00 79 00`
  （`09`=task.return opcode、`00 79`=result Some(u32, valtype `0x79`)、`00`=options空）。
  valtype をパラメタ化（s32=`0x7a`? 等は要確認、u32=`0x79` は実測済み）。
- async component func type: `43 00 00 79`
  （`0x43`=async functype opcode、`00`=params数0、`00`=result-form tag、`79`=u32）。
  既存 `emit_comp_func_type(is_async=1)` が `0x43` を出すが result は s64(`0x78`)
  固定 — 結果型をパラメタ化する必要あり。
- core instance: task.return core func を `FromExports`("task-return") で 1 つの
  core instance にし、main module 実体化の `cm` 引数に渡す。
- async canon lift: `00 00 <core_func_idx> 01 06 00`
  （`00`=lift, `00`=func sort, core_func_idx, options vec len `01`, **async opt
  `0x06`**, type_idx）。現 `emit_canon_lift_func` は options に async(`0x06`)を
  含めないので async 変種を追加する。
- export: 既存 `emit_comp_export_section` を流用。

**フラグ**: `-W concurrency-support=y -W component-model-async=y
-W component-model-async-stackful=y`。

最初の縦串 PoC は await 無し（`() -> Int with Async` の body が定数 / 純粋
計算）で `task.return` 経路を通し、その後 `await(Future::ready(x))` → 単一
`future.read` ブロックへ広げる。

### 3.2.1 M1b codegen stage 1（landed）+ stage 2 の前提発見

**stage 1（done）**: `component_codegen.vibe` に async component emitter を実装:
`emit_canon_task_return` / `emit_canon_lift_async_section`（async canonopt
`0x06`）/ `emit_comp_async_functype_section`（opcode `0x43`）/
`comp_emit_component_wasm_async`。`component_codegen_test.vibe` 10/10 で、emit
結果が §3.2 の検証済みバイト列と一致すること（および sync lift には async
option が混入しないこと）を確認。emitter は既存 sync lift と同じ構成ヘルパ
（header / core module / core instance / alias / export）を再利用するため、
runnable な probe とのバイト一致＝全体も valid と判断できる。

**stage 2 で判明した前提（重要）**: selfhost ツリーには **`--component`
オーケストレーションが存在しない**（`comp_emit_component_wasm*` は定義・テスト
のみで、CLI からは呼ばれていない。`vibe compile --component` / `--compose-p3`
の実体は host (`src/`) 側）。したがって「実 `.vibe` → async component を
`vibe compile` で生成して wasmtime で動かす」真の E2E には、まず **selfhost 側に
component-compile オーケストレーション（entry → core wasm → component wrap）を
構築する**必要がある。これは linked_compile の小改修ではなく独立した feature で、
core-side の async entry 生成（`cm.task-return` import + void entry）もその中に
位置づくべき。M1b は「emitter（stage 1, done）」と「orchestration + core-side
（stage 2, 別 feature）」に再分割する。

stage 2 の真の E2E 検証は、selfhost component-compile orchestration 着地後に
`vibe compile --component async.vibe` → wasmtime 45 で実施する。それまでの
emitter の正しさは byte-exact 一致（runnable probe 基準）で担保する。

### 3.3 M2c-3 feasibility spike: 真の `stream<u8>` canonical built-ins（landed）

M2c までの `Stream[T]` は eager Array backing（`String::to_bytes` /
`Stream::to_string` / `for` が body を先頭で materialize）。M2c-3 は WASI
0.3 `stream<u8>` の **`stream.read` ベース**へ置き換え、handler が request body
を逐次読み body 全体を保持しない形にする。codegen 着手前に §3.1 と同様、
wasmtime 45 が受理する最小形を手書き probe で確定した
（`src/x/cm_async/cm_stream_read_probe.wat` / `run_stream_probe.sh`、`run` => 42）。

確定事項（wasmtime 45.0.0 / wasm-tools 1.252, x86_64 linux）:

1. **runtime 実行を確認**（parse だけでなく）。`stream.new` は **base M1b フラグ
   のみで実行可**（probe の `run` が `stream.new` を呼び、非ゼロの packed handle
   pair が返れば 42）。一方 **`stream.read` / `stream.write` は
   `-W component-model-more-async-builtins=y`（🚝）が必須**（無いと module が
   parse 失敗）。これで §3.1 の「async-builtins フラグは 45 で無効」を補正
   （正しい名は `more-` 付き）。
2. wasm-tools 1.252 が受理する WAT 形:
   - `(core func $snew (canon stream.new $st))` — lower 後 `[] -> [i64]`
     （readable | writable<<32 の packed end indices）。
   - `(core func $sread (canon stream.read $st (memory $li "memory")))` /
     `stream.write` 同様 — `(param i32 i32 i32) -> i32`（handle, ptr, len → status）。
3. **memory cycle**: read/write の canon は、それらを import する core instance
   と同じ memory を参照できない（instance ↔ canon の循環）。先に別の libc memory
   module を instantiate し、canon は `(memory $li "memory")` を指す。
4. **単一タスクの self write→read は deadlock**: reader 不在の `stream.write` は
   block（stackful suspend）し、同じタスクが唯一の reader 候補のため進まない
   （probe で instantiate→実行→block を確認）。つまり実 `stream.read` には
   **並行 producer**（spawn した subtask、もしくは host 提供の readable end =
   HTTP request body）が必要。この producer 配線が M2c-3 の次スライス。

### 3.3.1 producer 調査: intra-wasm subtask は不可、producer は host（追記）

§3.3 の deadlock を解消する producer を**コンポーネント内の subtask** で用意できるか
を WAT で検証した結果、**この方向は wasmtime 45 では行き止まり**と判明した。確定事項:

- async-lowered cross-component 呼び出しの core ABI を確定:
  `(canon lower (func $f) async (memory $li "memory"))` は core func
  `(param <result-area-ptr>) -> (i32 status)` を生成（同期 lower は param なしで
  結果を直接返す）。`waitable-set.new` / `waitable-set.wait (memory ...)` の
  canon も wasm-tools 1.252 が受理する。
- **しかし async-lifted な親 `run` から別コンポーネント instance の関数を呼ぶと
  `wasm trap: cannot enter component instance` で trap する。これは async 固有
  ではなく、sync 親 → sync 子でも同じく trap する**（component instance の
  reentrance 制約）。つまり「self-stream の writable 端を別 wasm subtask に渡して
  並行に書く」構成は、コンポーネント境界の reentrance 制約に阻まれて成立しない。
- 単一タスク self round-trip は §3.3 の通り deadlock。両 intra-wasm 経路が塞がる。

**設計含意（pivot）**: 実 `stream.read` の producer は **host 側**であるべき。WASI
0.3 の HTTP handler では request body の readable end（`stream<u8>`）を **wasmtime
（host）が供給**し、handler はそれを `stream.read` で読むだけ。host が producer
なので wasm↔wasm の reentrance は発生せず、deadlock もしない。したがって M2c-3 の
codegen は「self stream を作って書いて読む」ではなく、「**import した
`wasi:http` の readable stream を `stream.read` で消費する**」形を直接の目標とする。

実装順（改訂）:
- (a) `component_codegen.vibe` に `stream.read` の canon emit（`(memory ...)`
  option 付き、`more-async-builtins` 前提）と、readable `stream<u8>` を引数に取る
  async import の lower を追加。
- (b) host 供給の readable stream（まずは `wasi:http/types` の incoming-body、
  または最小の host test harness が供給する `stream<u8>`）を `stream.read` ループ
  で Array に読み込み、`for` / `Stream::next` をそのループへ lower。
- (c) gate / probe は host 提供 stream を使う（`--invoke` だけでは host stream を
  供給できないため、wasi:http world での e2e、もしくは host harness を用意する）。

### 3.4 M1b-2 アプローチ確定（trampoline、実測済み）

core-side（`linked_compile.vibe`）を改修せずに済む **trampoline 方式**を実測で
確定した（`src/x/cm_async/cm_async_trampoline_probe.wat`、wasmtime 45 で 42）。
selfhost は既に entry を `run : () -> i64`（値を直接 return）で core wasm に
コンパイルできるので、それを**そのまま main module** とし、小さな async
**trampoline module**（`("main","run")` と `("cm","task-return")` を import、
void `run` = `call entry; call task-return`）で包む。string-lift が 2 つ目の
core module を合成するのと同じ構造で、`linked_compile.vibe` は無改修。

確定した component core-func index 空間: `task.return` canon = 0 / alias
`main."run"` = 1 / alias `tramp."run"` = 2、async lift は core func 2 を参照。
trampoline core module は result valtype（vibe Int = i64 = `0x7e`）を埋めた
ほぼ定数のバイト列（`comp_generate_string_trampoline` と同じ要領で生成可能）。

これで M1b-2 の codegen アプローチは実機で裏付けられた。残る emitter 実装は:
`comp_generate_async_trampoline(core_valtype)`（trampoline module 生成）+
`comp_emit_component_wasm_async_trampolined(main_core, entry_name, valtype)`
（2 module 合成: main / tramp / task.return canon / instances(main, cm,
env-alias, tramp) / async functype / alias tramp.run / async lift / export）。
さらに orchestration（async entry → main core wasm → wrap → 出力）と CLI 配線。

### 3.5 M1b-2c orchestration（landed）+ M1b-2d（WASI import 配線）

`compile_source_wasi_only`（cli adapter 経路 `selfbuild_cli_args_entry` が通る
universal な source-compile）に、entry が `() -> Int with Async`（name
"run"、no params）であることを **AST の TyFn effect 注釈から検出**して
`comp_emit_component_wasm_async_trampolined` で包む hook を追加。

**実測（stage1 selfhost compiler、`let run: () -> Int with Async = () -> { 42 }`）**:
- 出力が **component**（magic `0d 00 01 00`）になり `wasm-tools validate` OK。
- 非 async entry（`run : () -> Int`）は **plain core module のまま**（無回帰）。
- ただし wasmtime 実行は instantiate で失敗: main core module が
  `wasi_snapshot_preview1.fd_write` を 1 件 import しており、async component が
  これを充足していない。

**M1b-2d（landed、縦串完成）**: 真の run を達成した。
- `comp_generate_wasi_fd_write_stub`: no-op `fd_write`(`(i32,i32,i32,i32)->i32`=0)
  の core module。`comp_emit_component_wasm_async_trampolined_p1` がこれを
  3 つ目の module として同梱し、main の instantiation に `wasi_snapshot_preview1`
  引数として供給（preview1 adapter 不要で自己完結）。core instances:
  0=wasi-stub / 1=main(+wasi) / 2=cm / 3=env / 4=trampoline。
- nullary vibe fn は `(param i64)->result`（i64 は unit 引数）に lower される
  ため、trampoline は dummy `i64.const 0` を積んで entry を呼ぶよう修正。
- selfhost core は effect 基盤で exnref を使うため、実行に wasmtime の
  exceptions proposal を有効化。

実測フラグ:
`-W exceptions=y -W concurrency-support=y -W component-model-async=y
-W component-model-async-stackful=y`。

**実測結果**: stage1 selfhost compiler が
`let run: () -> Int with Async = () -> { 42 }` をコンパイル → component
（`wasm-tools validate` OK）→ wasmtime 45 で **42 を返す**。M1（async front-end）
〜 M1b（codegen + orchestration）の縦串が `.vibe` ソースから実機実行まで完成。

注: 現状は narrow PoC（entry 名 "run" / `() -> Int` / await 無しで Async
宣言）。`await` 本体の codegen、非 Int 戻り値、param 付き entry、複数 wasi
import（fd_write 以外）、entry 名一般化は後続。

回帰保護: この E2E は `scripts/test_async_component_gate.sh`
（pkf task `test-async-component`、CI gates-shard `cli` shard）に
固定。wasmtime/wasm-tools 不在時は graceful skip。非 async control が plain
core module のままであること（async wrap が通常ビルドに漏れない）も検証する。

### 3.6 M1b-3（`await` 本体 codegen）spike — canon built-in blueprint

wit-bindgen で `future<u32>` を await する component（`import await-val: func()
-> future<u32>` を `run: async func() -> u32` が `.await`）を生成し、`await` の
lowering に必要な canonical built-ins を抽出した:

| canon | 用途 |
|---|---|
| `future.new <ty>` | future 生成 → (writable, readable) handle |
| `future.read <ty> (memory M) async` | readable を読む（buffer へ）。status: COMPLETED / BLOCKED |
| `future.write <ty> (memory M) async` | writable へ書く（`Future::ready` の resolve） |
| `future.drop-readable/writable <ty>` | handle 破棄 |
| `future.cancel-read/write <ty>` | 読み書きキャンセル |
| `waitable-set.new` / `.poll (memory M)` / `.drop` / `waitable.join` | BLOCKED 時の待機 |
| `context.get/set i32 <n>` | task-local context（executor 用） |
| `task.return (result T)` / `task.cancel` | 結果返却（M1b で実装済） |

これらは **core-level canonical built-ins**で、core module に import として供給
する（`task.return` と同様）。

**重要な発見**: `await` は **単一 call ではなくループ**。`future.read` が
COMPLETED なら buffer から値を load、**BLOCKED なら waitable-set に登録して
`.wait`/`.poll` で待ち、ready 後に再 read** する必要がある（wit-bindgen が
futures-rs executor 一式を取り込むのはこのため）。stackful lift 下では待機が
fiber を suspend するので明示的状態機械は不要だが、**read→(block時)wait→retry の
ループ + memory buffer 管理**を core codegen で emit する必要があり、`task.return`
（単発 call）より大幅に重い。

**M1b-3b（landed、ready-future fast path）**: `await(Future::ready(x))` のような
**ready future の await は値 `x` と等価**なので、`compile_call.vibe` の builtin
dispatch に lowering を追加した。これにより **await を使う async プログラムが
初めてコンパイル&実行可能**になった（従来は codegen 無しで不可）。gate を
`await(Future::ready(42))` body へ更新し、selfhost → async component →
wasmtime 45 で **42** を実測。

当初は `await`/`Future::ready` を**引数の値そのもの**へ lower する identity
だったが、`Future[T]` を **2要素配列 `[state, payload]`**（`state = 0` が ready、
`future_ready_expr` / `future_state_ready`）に変えた（#1230）。ready しか無い今も
挙動は同じ（`await` は slot 1 を読むだけ）だが、**pending future を後から足すのに
表現を作り直さなくて済む** — M1b-3c は `await` に slot 0 の分岐を生やすだけになる。
future を作る側は `Future::ready` / `Stream::next` の2つで、
`Future[T]` を返す user-level コード（`lib/@vibe/builtin/async_iter.vibe` の
`AsyncIterator::next`）は元から `Future::ready(..)` 経由なので影響しない。
（#1538 以前は `Stream::fold` も future を作っていた。eager combinator ごと
退役したので、この位置に残るのは上の2つだけ。）

さらに `await` の lowering 位置を `compile_call.vibe` から **AST パス
`await_poll_pass`** へ移した（#1230）。`compile_call` は wasm を直接吐く位置で、
`suspend_cps_pass` / `evidence_dict_pass` が走り終わった後なので、pending future
が要る `perform Async::Suspend(..)` を出しても discharge できる相手がいない。
新パスは `desugar_trait_dicts` の直後（= async `for` が `await(..)` を生成した
直後）かつ全 effect パスの**前**に走り、`@vibe/concurrent/experimental` の `Receiver::recv_wait`
と同じ suspend-and-retry 形へ **spine に持ち上げて**展開する:

```
let __aw_f_N = <future>
while 0 < Array::get(__aw_f_N, 0) {
  let __aw_w = perform Async::Suspend(1)
  ()
}
let __aw_v_N = Array::get(__aw_f_N, 1)
<await があった式（await は __aw_v_N に置換）>
```

`1` は poll wait（`concurrent.vibe` の payload 規約: 0 = yield / 1 = poll /
負 = sleep debt）。producer が future を解決するときは slot 1 を書いて slot 0 を
クリアする。`await(Future::ready(x))` は `x` へ潰す peephole 付き。

**その場に埋めるのではなく持ち上げるのが要点**: vibe にはブロック式が無いので、
その場展開だと `let a = await(..)` が `ELet(a, ELet(f, .., ESeq(EWhile, ..)), ..)`
という**ソースでは書けない形**になり、1関数内に2つ並んだ時点でコンパイラ自身が
無限再帰した。持ち上げれば合成物は常に let/seq spine 上に載る ―― `scps_split_tail`
（追記36 のループ対応）が同じ理由で最初から取っていた規律と同じ。持ち上げるのは
**無条件に評価される位置**だけで、分岐・ループ本体・closure 本体は自分の spine で
処理する。

fixture は `fixtures/async_await_multi.vibe`（let-value / match scrutinee /
被演算子の各位置に await、want 50）。

**producer**: `Future::pending() -> Future[T]` が state 1（未解決）の future を
作り、`Future::resolve(f, v)` がその場で完了させる（payload を書いてから state を
クリアする ―― 逆順だと awaiter が「ready なのに値がまだ」を観測しうる）。
これで `Future[T]` は ready / pending の両方を作れる。まだ未解決の future を
await する側には continuation を park する driver が要る（in-tree では
`@vibe/concurrent/experimental` の `spawn_suspend` の `handle .. with Async`）。fixture
`fixtures/async_future_pending.vibe` は await 前に resolve する形で、表現と
builtin 2本を pin している（スケジューリングは pin していない）。

**M1b-3c（todo、真の blocking await）**: 実 async ソース（host async import /
subtask spawn）から得た future を待つ場合は §3.6 のとおり `future.read` +
waitable-set 待機ループが必要。これは (a) async source 基盤、(b) core module へ
の future canon built-in import + buffer + ループ emit、(c) component への
future<T> 型 + canon 定義、を要する本格改修。spike で canon の signature/option
は判明済みなので blueprint→byte で進められる。

### 3.7 M1b-3c spike — blocking await の実機確認（mechanics proven）

self-contained で**実際にブロックする** await を wit-bindgen で構成し wasmtime 45
で実行確認した: guest が future を作り（`future.new`）、**writer subtask を spawn**
（`wit_bindgen::spawn`）し、`future.read` で**ブロックして** writer の書き込みを
待ち、値を得て `task.return`。`-W exceptions -W concurrency-support
-W component-model-async -W component-model-async-stackful` で **42 を返す**。

つまり blocking await の runtime mechanics（spawn → block-on-read → resume）は
wasmtime 45 で動くことが確定。残るは selfhost codegen での再現:

最小 await ループ（host async source から得た future を待つ場合、spawn 不要）:
```
loop {
  st = future.read(handle, buf)        ; async option
  if st == COMPLETED { break buf }     ; 値が来た
  ws = waitable-set.new                 ; BLOCKED
  waitable.join(handle, ws)
  waitable-set.wait(ws)                 ; stackful fiber を suspend
}                                        ; ready 後に再 read
```
- **host async source からの await**（上記、spawn 不要）が最小。ただし async
  source（host async import を提供する runner、または wasi:clocks 等）の用意が前提。
- **self-contained future**（guest が future を生成して待つ）には subtask spawn
  ＝最小 async executor（context.get/set + waitable-set 管理）が必要で、より重い
  （wit-bindgen は futures-rs executor 一式を取り込む）。

**M1b-3c codegen の規模**: selfhost core codegen に future canon built-in の
import・memory buffer・上記待機ループ（+ self-contained なら最小 executor +
spawn）を emit する大型 feature。mechanics と canon は確定済みなので実装は
blueprint→byte で進められるが、async 全体で最大の塊。

### 3.8 M1b-3c-1b landed — blocking await の codegen（spawn 相当は退化ケースのみ、#1230）

**まず結論の範囲を明確にする（#1240 review で指摘され訂正した）**: 本節が
実証したのは「**host async import を待つ blocking await**を、待機ループを
別関数に括り出した形で emit できる」ことであり、**真の interleaving spawn
（親の処理と並行して走る第2の guest 計算）ができることではない**。後者は
未解決のまま（M-conc-2 / M1b-3c-2 送り）。詳細は本節末尾の「実証範囲の限界」
を参照。

その上で、§3.7 が「self-contained future は subtask spawn ＝最小 async
executor（context.get/set + waitable-set 管理）が必要でより重い」と書いて
いた点については、実機実証（`tools/wasip3_component_probe/spawned_future/`、
wit-bindgen 0.60 の `spawn_local` を使った probe を新規構築し
`wasm-tools dump` でバイト単位に検証）で以下が分かった:

- `wit_bindgen::spawn_local`（guest が「writer subtask を spawn する」ために
  使う API）は canonical-ABI レベルでは**何も残さない**——`futures::stream::
  FuturesUnordered` による純粋な guest 内部の cooperative executor であり、
  `future.new`/`.read`/`.write` を一切呼ばない。writer の結果を `run` に渡す
  `oneshot::channel()` も guest メモリ内だけで完結する ordinary Rust future。
- 実測で増える import/export は `context-get/set`、`waitable-set-poll`、
  `[callback][async-lift]run`。このうち `context.get/set` については、
  wit-bindgen の `async_support.rs` / `subtask.rs` が spawn の有無に関係なく
  無条件に呼んでいるため、**spawn 固有の要件ではなく** wit-bindgen が
  デフォルトで使う **callback 方式**（`[callback]` export 経由で毎 wake
  event に再入する明示的 state machine）由来と考えられる。ただし後述の通り、
  これは「stackful 方式なら interleaving spawn も executor 無しでいける」
  ことの証明にはなっていない。
- 手書き WAT（`tools/wasip3_component_probe/spawned_future/component.wat`）で「待機ループを `$writer`
  という**ただの内部 wasm 関数**に分離し、`$run` がそれを呼んで
  `task.return` する」という構造にしても、`tools/wasip3_component_probe/stackful/component.wat`
  と全く同じ canon 集合（`task.return`、`[async-lower]<host-import>`、
  `waitable-set.new/.wait/.drop`、`waitable.join`、`subtask.drop`）だけで
  正しく動作する（300ms の genuine suspend を経て 42 を返す、wasmtime 47
  実機確認済み）。

この結果に基づき、`component_codegen.vibe` に
`comp_emit_component_wasm_async_spawned_future`（固定シェイプの
self-contained コンポーネントを合成する emitter。`future.*` 系 canon
emitter は追加していない——emit するシェイプには不要なため）と対応する canon
built-in emitter群（`waitable-set.new/.wait/.drop`、`waitable.join`、
`subtask.drop`、`canon lower ... async`）を実装し、
`scripts/test_spawned_future_component_gate.sh`（probe の Rust host
driver を再利用し、genuine blocking wait を経て 42 を返すことを実行時
確認）で検証した。vibe ソース構文レベルの spawn/future プリミティブの
追加と実 `.vibe` エントリへの配線（`await(x)` を任意のユーザーコードから
このコーデックに繋ぐこと）は別チケット（M1b-3c-2 相当）に委ねる——本節は
M1b-1 と同じ「emitter・byte-exact 検証のみ」フェーズ。

#### 実証範囲の限界（#1240 review で訂正）

Phase B の `$writer` は `$run` が**同期的に呼ぶただの内部 wasm 関数**で
あり、第2の Component-Model task ではない。Phase B の中で並行に走るものは
何も無い。したがって Phase B が示したのは:

> `spawn f; await t` は、**spawn と join の間に観測可能な親の処理が
> 一切無い**退化ケースにおいて、直接呼び出しへコンパイルして正しく動く
> （そのケースでは spawn は意味論的に no-op なので消えてよい）

ということだけである。**真の spawn（親の処理と interleave する第2の guest
計算）が追加機構を要さないことは示していないし、示せない**——stackful
fiber は1本の call chain しか走らせないので、並行な guest 計算には別 task
か guest 側 poll executor のどちらかが要る。Phase A の実測はむしろ逆を
示唆する（`wit_bindgen::spawn_local` は `FuturesUnordered` executor 一式 +
`context.get/set` + `waitable-set.poll` を引き込む）。

つまり現在の lowering の下では、**spawn と join の間に親子間の
handshake や観測可能な処理があると順序が変わるか deadlock する**——
これは linear backend の eager `Task::spawn`（§2.5。**#1227 で撤去済み**）
が抱えていた制限と同じもので、今回それを超えてはいない。真の
interleaving spawn は **M-conc-2 / M1b-3c-2 の未解決事項として残る**。

> **追記（§3.11 で訂正）**: 上段の「並行な guest 計算には別 task か guest 側
> poll executor のどちらかが要る」という推論は **誤りだった**。stackful 方式では
> `waitable-set.wait` の payload[0](どの waitable が発火したか)による完了順
> ディスパッチだけで interleaving が成立する——第2のスタックも
> `context.get/set` も `waitable-set.poll` も要らない。Phase A が見ていた
> `FuturesUnordered` + `context.get/set` は wit-bindgen の **callback 方式**の
> 都合であって interleaving の要件ではなかった。実機反証は §3.11。

### 3.9 M1b-3c-2 landed — async component を production runtime が駆動できるようになった（#1230）

§3.8 までの async component は、**プロジェクト内のどのツールでも動かせなかった**。
`func_wrap_concurrent` な host import を持つ component は素の
`wasmtime --invoke` では deadlock trap する（§3.7 bug #1）ため、
`scripts/test_spawned_future_component_gate.sh` は
`tools/wasip3_component_probe/spawned_future/host/` の**専用 Rust host バイナリ**
を gate 実行時に cargo build して駆動していた（crates.io アクセスが必要）。

M1b-3c-2 でこの driver を production runtime 側に取り込んだ:

- **`runtime/viberun` の wasmtime を 45 → 47.0.2 に bump**し、
  `component-model` / `component-model-async` / `async` feature を有効化した。
  既存の同期 core-module パスは**ソース無改修**で移行できた（API 破壊なし）。
- **component / core module をヘッダで判別**する（`\0asm` の後ろ 4 byte が
  `0d 00 01 00` なら component、`01 00 00 00` なら core module）。component なら
  新設の `run_async_component` に振り分ける。
- `run_async_component` は §3.7 の罠を踏まえ、
  `instantiate_async` + `Store::run_concurrent` + `TypedFunc::call_concurrent`
  の組で駆動する（`call_async` では deadlock trap する）。Engine は同期パスと
  別に建てるが、Config は**共有の `engine_config()` から派生**させ、component/
  concurrency オプションを追加するだけにする——`Config::new()` から作ると
  `max_wasm_stack`（`MOONRUN_WT_WASM_STACK_MB`、既定 64 MiB）が失われ、深い
  再帰を含む guest が core-module パスでは動くのに component パスでだけ
  call-stack exhaustion する（#1242 review）。Store には他の全 store と同じ
  `MOONRUN_WT_MEMORY_MB` limiter を付ける（同 review、当初は付け忘れており
  `--help` が謳う上限が component パスだけ無視されていた）。
- host import `get-async` は**本物に suspend する timer**（`tokio::time::sleep`、
  `wasi:clocks` backing がやるのと同じこと）で実装した。ブロッキングな
  `std::thread::sleep` では await の意味が消えるため使わない
  （core-module 側の `vibe.sleep` import が抱えている制限そのもの）。

gate はこれで probe 専用バイナリへの依存が消え、`viberun <component.wasm>` を
呼ぶだけになった。

#### 副産物: eager-completion パスの実バグを発見・修正

実 host を繋いだことで、**probe の host では原理的に踏めなかったバグ**が出た。
`$writer` の epilogue が `subtask.drop` を**無条件に**呼んでいたが、
async-lowered call が**即座に完了した場合**（status RETURNED が call から直接
返る = §3.8 の `br_if $done` 経路）は **subtask が生成されない**——packed 結果の
handle bit は 0 である。そのため host import が suspend せずに解決した瞬間に
`unknown handle index 0` で trap した。

これは実 host では**ごく普通に起きる**（キャッシュ済みの値、timeout 0、
既にデータが届いている socket read など）。probe の host は常に 300ms 寝るので
blocked パスしか通らず、永久に露見しなかった。

修正は #1240 review の waitable-set leak 修正と同じ形——両 drop を同一の
「blocked パスを通った」フラグでガードする（両リソースは blocked パスの同一
直線コード上で同時に生まれるため、フラグ1つで正しい）。emitter
(`component_codegen.vibe`) と probe WAT の両方に適用済み。gate は
**blocked パス（300ms 実測で suspend/resume を確認）と eager パス（delay 0）の
両方**を検証するようになった。

### 3.10 M1b-3c-3 landed — 本物の並行 await（host 操作が同時に in-flight、#1230）

§3.8 の「実証範囲の限界」で未解決として残した並行性のうち、**片方は既存の
canon 集合だけで到達できる**ことが分かった。まず2つの問いを分離する:

| | 何が並行するか | 必要なもの |
|---|---|---|
| **M1b-3c-1c** | **guest の計算が2本** interleave する | 第2の CM task か guest 側 poll executor。**未解決** |
| **M1b-3c-3（本節）** | guest の計算は1本、待っている **host 操作が複数同時に in-flight** | **何も追加不要** — waitable set に複数 subtask を join する設計そのもの |

後者は `Promise.all` / `join!` の形であり、stackful fiber が1本の call chain
しか走らせないという制約と矛盾しない（guest は1本のまま、待っている相手が
複数になるだけ）。

probe（`tools/wasip3_component_probe/concurrent_awaits/component.wat`）で
実機確認したうえで、`comp_emit_component_wasm_async_concurrent_awaits` として
emitter 化した。**canon 集合は M1b-3c-1b から一切増えていない**
（`task.return`、`[async-lower]get-async`、`waitable-set.new/.wait/.drop`、
`waitable.join`、`subtask.drop`）。並行性を生むのは **操作の順序だけ**——
どちらの async-lowered call も、**どちらかを待ち始める前に発行する**。
「A を発行→A を待つ→B を発行→B を待つ」は同じ命令列・同じ戻り値でありながら
2倍の時間がかかる。

検証は2つ独立に立てた（片方だけでは弱いため）:

- **値**: `run` は 84（= 42 + 42）を返す。各 call が自分専用の結果スロットに
  書くので、片方しか完了しなかった／同じスロットを2回読んだ実装は 42 になり
  落ちる。
- **時間**: host が1呼び出しあたり 300ms suspend する条件で、並行なら ~300ms、
  直列なら ~600ms。両側で挟む（`>= 0.8×` で「本当に suspend した」、
  `< 1.6×` で「直列ではない」）。**並行性を実際に検査しているのはこちら**——
  値チェックは直列実装でも同じように通ってしまう。

実測（`runtime/viberun` 経由、M1b-3c-2 で駆動可能になったもの）:

| delay | 1 call（spawned-future） | 2 calls（concurrent-awaits） |
|---|---|---|
| 300ms | 42 / 310ms | **84 / 312ms** |
| 1000ms | 42 / 1028ms | **84 / 1015ms** |

2本の 1000ms 呼び出しが1本と同じ 1015ms で終わる——スケールは 1× であって
2× ではない。gate は `scripts/test_concurrent_awaits_component_gate.sh`
（`pkf run test-concurrent-awaits-component`）。JIT の cold start（実測 ~200ms）
が並行/直列の判別幅を食うため、計測前に warmup 実行を1回挟んでいる。

**残る未解決は M1b-3c-1c のまま**: 親の処理と interleave する第2の *guest*
計算は、本節の機構では作れない。

### 3.11 M1b-3c-1c — interleaving は ABI 側の追加機構を要さなかった（§3.8 の予測を訂正、#1230）

§3.8 は「真の interleaving spawn には**別 task か guest 側 poll executor の
どちらかが要る**」と書き、根拠として Phase A の実測（`wit_bindgen::spawn_local`
が `FuturesUnordered` executor 一式 + `context.get/set` + `waitable-set.poll`
を引き込む）を挙げていた。**これは誤りだった** ——
`tools/wasip3_component_probe/interleaved_tasks/` で実機反証した。

Phase A が見ていたものは wit-bindgen の **callback 方式**（`[callback]` export
経由で毎 wake event に再入する明示的 state machine）の都合であって、
interleaving 自体の要件ではない。stackful 方式では
`waitable-set.wait` が **payload[0] で「どの waitable が発火したか」を返す**
——完了順ディスパッチに必要なものはそれだけである。

#### probe の設計（偽装できない形にした）

```
  task A   await get-after(300) -> await get-after(300) -> log 1
  task B   await get-after(100)                         -> log 2
```

どちらも「片方を待ち始める前に」発行する。結果は `log[0]*10 + log[1]`。

| | 結果 | 実測時間 | 意味 |
|---|---|---|---|
| `component.wat` | **21** | **613ms** | B の継続が A の途中で走った。合計は **A 自身の 2×300ms** ——B は完全に重なった |
| `serial_control.wat` | **12** | **713ms** | A を最後まで待ってから B。300+300+100 |

タイムライン: t=0 で A の1st と B を発行 → **t=100 で B が解決し B の継続が走る**
（A はまだ1st await 中）→ t=300 で A が state machine を1つ進めて 2nd await を発行
→ t=600 で A の継続。

負の対照（`serial_control.wat`）は同一の canon 集合・同一の値・同一の log
エンコードで順序だけを変えたもので、**値と wall-clock の両方で反対の答えを出す**
ことを gate が確認する（`scripts/test_interleaved_tasks_probe_gate.sh`）——
これが無いと「21 を返す」という assertion が判別的である保証が無い。

#### 確立したこと / 残ること

**確立**: 2つの論理的な guest 計算が、**1本の stackful fiber 上で** await 点で
interleave する。**第2のスタックも `context.get/set` も `waitable-set.poll` も
不要**で、canon 集合は M1b-3c-1b から不変。

**残る**: A が2つの await をまたいで持ち越す状態を、この probe は**メモリ上の
スロットに手で置いた state machine** として書いた。任意の vibe ソースに対して
この変換を行うのが **ADR-0076 の CPS/suspend lowering** そのものである。
つまり M1b-3c-1c の残作業は **ABI 側ではなく codegen 側に局所化された**——
「別 task か poll executor が要る」という §3.8 の前提が消えたぶん、当初の
見積もりより小さい。

emitter（固定シェイプの component 合成）は本節では作っていない——M1b-3c-1a と
同じ「mechanics 実証のみ」フェーズ。実 `.vibe` ソースからこの形へ落とすには
上記の state 表現が先に要る。

### 3.12 ADR-0089 step 2 — `future.*` / `stream.*` canon emitter landed（#1218）

§3.6 の canon 表のうち **`future.new/read/write/drop-readable/drop-writable`
と `stream.new/read/write/drop-readable/drop-writable` を初めて emitter 化**
した（`emit_canon_future_*` / `emit_canon_stream_*` +
`emit_comp_future_type_section` / `emit_comp_stream_type_section` +
固定シェイプ `comp_emit_component_wasm_future_value` /
`comp_emit_component_wasm_stream_value`、gate =
`scripts/test_future_value_component_gate.sh` /
`scripts/test_stream_value_component_gate.sh`)。probe は
`tools/wasip3_component_probe/future_value/component.wat` と
`tools/wasip3_component_probe/stream_value/component.wat`（hand-authored、wasmtime 47 実測 42）。

**§3.3 の「self round-trip は deadlock」の回避方法が確定**: M2c-3 spike は
BLOCKING read で producer 不在 → deadlock だったが、**read/write の両方に
`async` canonopt を付けると片側が fiber ではなく waitable として park する**
ため、単一 task が自分自身と rendezvous できる:

```
future.new -> async future.read (BLOCKED)
  -> waitable.join(readable, ws)
  -> async future.write 42   ; pending read があるので copy は即時完了
  -> waitable-set.wait        ; FUTURE_READ (event code 4)
  -> read buffer から値を load -> drop-readable/-writable -> ws.drop
```

実測で pin した encodings（すべて probe が diagnostic 値として報告する形で
検証、trap に頼らない）:

- `future.new` の packed i64 は `(writable << 32) | readable`
  （**readable が下位 32bit**。逆に読むと future.read が wrong-handle で trap）
- async `future.read`/`future.write` の BLOCKED は `0xffffffff`
- pending read に対する write は **call から直接 COMPLETED が返る**
  （§3.9 の eager-completion パスと同じ「即時完了」形。subtask は作られない）
- 完了 event は FUTURE_READ = **4**（payload[0] = readable end index）。
  stream 側は STREAM_READ = **2**、read/write の core sig は
  `(handle, ptr, count) -> status`（future より 1 引数多い）、完了 status は
  `(amount << 4) | code` に pack される
- wasmtime 47 でも future.*/stream.* canon は
  `-W component-model-more-async-builtins=y`（🚝）が必要（§3.3 の 45 での
  観測から不変）。**この component は host import を持たない**ので、
  `func_wrap_concurrent` driver（viberun）不要 — 素の
  `wasmtime --invoke run()` で駆動できる（§3.9 bug #1 の deadlock 条件に
  当たらない）

canon section のバイト形状（`wasm-tools dump` で回収、emitter 各関数の doc
comment にも記載): component 型 `(future u32)` = `65 01 79`、
`future.new` = opcode `0x15` + typeidx、`.read`/`.write` = `0x16`/`0x17` +
typeidx + canonopts（async `06`、memory `03 <idx>`）、
`.drop-readable`/`.drop-writable` = `0x1a`/`0x1b` + typeidx。

これで §3.6 の blocking-await ループの **`future.read` 側の部品が全部
byte-exact で手元に揃った**。残る M1b-3c 系の未着手は「実 `.vibe` ソースの
await をこの経路に配線する」（ADR-0076 の suspend lowering との接続、
ADR-0089 step 3-4）と、host 供給 future を read する形の e2e（host 側
FutureWriter driver が必要 — viberun に future を返す import を足す）。
→ **後者は §3.13 で landed。**

### 3.13 ADR-0089 D2 — host 供給 `future<u32>` の e2e（waitable-set.wait backend 実測、#1218）

§3.12 末尾の残件「host 供給 future を read する e2e」が landed。これは
ADR-0089 Decision 1 の 3-backend 分割のうち **`waitable-set.wait` backend の
初の end-to-end 実測**であり、Decision 2 の「waitable を第3の wait 種として
park する」形が component lowering レベルで実現した:

- **host 側** (`runtime/viberun` `run_async_component`): root import
  `get-future: func() -> future<u32>` を追加。wasmtime 47 に FutureWriter
  型は無く、**producer ベース** — `FutureReader::<u32>::new(store, async {
  tokio::time::sleep(delay); Ok(42) })` が pair を作って readable end を
  即時返し、producer future は guest の read が pending になってから
  event loop に poll される（pull 型だが「writer が delay 後に書く」と
  観測上同一）。delay は `VIBE_ASYNC_GET_DELAY_MS` /
  `VIBE_ASYNC_DELAY_SCALE_PCT` を `get-async` と共有。
- **guest 側** (probe `tools/wasip3_component_probe/host_future_value/
  component.wat` → byte-exact 移植
  `comp_emit_component_wasm_host_future_value` +
  `comp_generate_host_future_value_guest_core_module`):

```
[async-lower]get-future        ; eager RETURNED (code 2) — pair 生成は suspend しない
  -> handle = results buffer から load
  -> async future.read (BLOCKED — producer timer 未発火)
  -> waitable.join(fut, ws) -> waitable-set.wait
       ; ここで task が本当に SUSPEND する。host が timer を回し、
       ; 完了は completion order で FUTURE_READ (4) event として届く
  -> read buffer -> 42 -> drop-readable (writable 側は host 所有) -> ws.drop
```

- **実測**: delay 300ms で `42` を **311ms**（wall clock が genuine
  suspend/wake の証明 — §3.10 と同じ論法）、delay 1ms/50ms でも 42。
  gate = `scripts/test_host_future_value_component_gate.sh`
  （pkf task `test-host-future-value-component`、viberun 駆動 +
  wall-clock ≥ 0.8×delay assert + probe parity）。
- **新しく pin した encodings**: component-level import 型は
  **`func async` が必須**（sync `(func (result (future u32)))` に async
  canonopt を付けると `wasm-tools validate` が "the async canonical option
  requires an async function type" で reject — WIT 上の綴りは
  `func() -> future<u32>` のままで、async は lowering 規約）。async
  functype の result に **defined type index を置く形は `43 00 00 <s33
  idx>`**（primitive valtype byte の位置に正の type index）。import
  externdesc は `00 <name> 01 <functype idx>`
  （`emit_comp_async_functype_section_result_type` /
  `emit_comp_import_section_typed`）。
- **diagnostic 帯域**（task.return 値、trap に頼らない）: 5000+code =
  get-future が eager に完了しなかった / 1000+x = read が BLOCK しなかった /
  3000+ev = wait が FUTURE_READ 以外を返した。

**in-guest scheduler との関係**: `@vibe/concurrent/experimental` の pump は linear
backend 上で動き host waitable を持たないため、Suspend payload の
**>= 2 を waitable handle 用に予約**した上で in-guest では poller として
park する（= 完了源が無いので deadlock trap に縮退。yield 扱いだと silent
livelock になる — spawn_suspend arm の判定を `r == 1` から `r >= 1` に変更）。
waitable park 種の実体は本節の component lowering 側にあり、実 `.vibe`
ソースの await をこの経路へ配線する step 4 本体（suspend lowering との接続）
は **§3.14 で landed**。

### 3.14 ADR-0089 step 4 本体 — 実 `.vibe` ソースの await → `waitable-set.wait`（#1218）

§3.13 の残件「実ソースの await をこの経路へ配線する」が landed。以下の
program が selfhost compiler の single-source lane（entry 名 `run`）で
コンパイルされ、**自動で** adapter-backed async component に wrap されて
viberun 上で 42 を返す（producer delay 300ms で実測 ~313ms —
wall clock が genuine park/wake の証明）:

```vibe
let run: () -> Int with Async = () -> {
  let f = host_future_get()
  await(f)
}
```

**lowering チェーン全体**（gate =
`scripts/test_hostfuture_source_component_gate.sh`、pkf task
`test-hostfuture-source-component`）:

1. **surface**: `host_future_get() -> Future[Int]`（pure builtin、
   checker/builtins_async.vibe）。component-level import
   `get-future: func() -> future<u32>` の readable end を Future cell に
   包む。cell は第3の状態 **state 2 = waitable**（`[2, handle]`; 0=ready,
   1=pending に追加）。compile_call が
   `EArray([2, vibe_hf_get_raw()])` に AST lower する。
2. **await**: await_poll_pass が program の `host_future_get` 使用を key に
   拡張形 `__aw_poll` を注入 — loop 内で `__aw_pay(fut)`（state 2 なら
   **`handle + 2`**、それ以外は 1）を計算して `perform
   Async::Suspend(payload)`、resume 値を `__aw_settle(fut, v)` で cell に
   書き戻す（payload 先、state 後 — Future::resolve と同順）。helpers は
   synthesized row-free top-level fn（suspend CPS の spine 制約を満たす
   let-chain 形）。非使用 program の `__aw_poll` はバイト不変。
3. **boundary**: `lc_inject_async_sleep_boundary` の keying を拡張 —
   `host_future_get` を呼ぶ Async-row entry は sleep 無しでも boundary
   handler を得る。arm は synthesized `__entry_settle(q)`:
   `1 < q → vibe_hf_wait_raw(q - 2)` /（sleep machinery 併用時のみ
   `q < 0 → sleep_blocking(-q)`）/ else `assert` trap（poll-wait の
   Suspend(1) は tail-resumptive boundary では従来どおり充足不能）。
   waitable payload は poll-wait と違い **boundary で充足できる**:
   canonical ABI が `waitable-set.wait` の中で task 全体を suspend する
   ので、tail-resumptive arm が block してよい。
4. **host imports**: `vibe.host_future_get () -> i64` /
   `vibe.host_future_wait (i64) -> i64`（builtin_registry の
   `vibe_hf_get_raw`/`vibe_hf_wait_raw`、checker_visible=false)。i64 は
   guest-tagged（内部 Int = value << 1、generic vibe.* call path の規約）。
   **component の adapter module だけが実装を提供する** — plain-wasm host
   に waitable 機構は無いので、`vibe run`（core lane）ではこの program は
   unknown-import で instantiate に失敗する（仕様）。
5. **composition**（`comp_emit_component_wasm_async_hostfuture`、wrap は
   `preprocess_compile.vibe` が core の `vibe.host_future_get` import を
   sniff して p1 shape から自動 route）: buffers は memhost memory に
   置き、値は i64 で渡すため **vfs の shim/fixup 循環が不要** —
   memhost → canon defs（async-lower get-future / future.read /
   drop-readable / task-return(u32) / waitable-set.new/join/wait/drop）→
   adapter（`host_future_get` = lower(8) → RETURNED assert → handle、
   `host_future_wait` = read(fut,0) → BLOCKED なら ws_new/join/wait →
   FUTURE_READ assert → drop-readable → ws_drop → mem[0]、eager 完了も
   同経路で値を返す）→ fd_write stub → main(wasi=stub, vibe=adapter) →
   u32 trampoline（`(i64)->i64` の run を wrap_i64 → task.return）→
   async lift。result は **u32**（viberun の typed driver に合わせる —
   trampolined-p1 の s64 と違う点に注意）。
6. **駆動**: viberun `run_async_component` の既存 `get-future`
   FutureReader import（§3.13）がそのまま producer。

制限（記録）: sleep との併用は #1342 で解消した（adapter が `vibe.sleep` を
提供する — §3.18.6）。TaskGroup
（spawn_suspend）との併用は D1 以来の mixing guard が reject。in-guest
pump backend では Suspend(handle+2) は poller 扱い → 完了源が無く
deadlock trap（§3.13 の縮退規則）。

### 3.15 ADR-0089 — resolve → direct wake の waiter list（in-guest poll モデルの最適化、#1218）

§3.13/§3.14 の残件だった「poll モデルの O(rounds×awaiters) 最適化」が
landed。**意味論は不変** — 変わるのは「pump が待ち条件の変わりようがない
poller を毎ラウンド resume して再検査させる」無駄だけで、観測可能な結果・
決定性・deadlock trap はすべて保存される。設計は「wake = 再開可能化」:

1. **データ**（`lib/@vibe/concurrent`）: `TaskCell` に `direct_wait` flag
   と `waiters: Array[TaskCell]`、`Channel` に `waiters`。待つ側
   （`TaskHandle::result_wait` / `Sender::send_wait` / `Receiver::recv_wait`）
   は park 直前に**待ち先へ自分を登録**して `direct_wait` を立て、pump は
   立っている task を skip する。完了側（terminal 遷移 / channel の
   push・take・close）が flag を下ろす = wake。下りた task は通常の
   round-robin で resume され**従来どおり条件を再検査する**ので、spurious
   wake は単なる 1 poll と等価（`TaskHandle::wake` の手動 wake も同じ理由で
   安全なまま）。
2. **自己識別**: suspend payload は Int で cell を運べないため、module
   global `conc_running_stack`（push/pop bracket: spawn_suspend の初回 leg
   と park_kind wrapper の resumed leg）の top が「今走っている task」。
   task 外（entry-level の blocking helper）は stack が空 → 登録 no-op →
   従来の plain poll に自然に縮退する。
3. **builtin future**（resolve → direct wake の本体): compiler hooks
   `__aw_wait(f)` / `__aw_notify_resolve(f)` を library が export し、
   linked lane が「entry が import している dep がこの2名を export して
   いれば **auto-link**」する（ユーザは magic 名を import しない）。
   `await_poll_pass` は両 hook が呼べるとき `__aw_poll` の 1 round を
   `perform Async::Suspend(1)` から `let __aw_w = __aw_wait(fut)`
   （登録 + 同じ Suspend(1)）へ差し替え — **imported concrete-Async-row
   named fn の spine call は recv_wait と同型**なので suspend CPS /
   evidence migration の実証済み機構にそのまま乗る（配線前に手書き mimic
   fixture で実測してから配線）。`Future::resolve` の lowering は
   func_table に notify が居るとき payload/state 書き込みの**後**に
   `__aw_notify_resolve(f)` を追記。future cell の同定は登録時に slot 2 へ
   採番した id（await は slot 0/1 しか読まない）+ parallel-array registry。
   `host_future_get` を使う program は従来の waitable 形が優先
   （hooks 形と排他、boundary 駆動なので in-guest direct wake の出番なし）。
4. **安全弁**（意味論不変の要）: notify 漏れ（resolve が hook 無し unit で
   コンパイルされた等）があっても、pump は「resume できる task が無い」
   とき・pump_all は stall 検出時に、**progress epoch ごとに1回だけ**
   全 `direct_wait` を一括クリアして poll に縮退する
   （`conc_clear_direct_waits` + `TaskGroup.direct_valve_used`、
   `conc_progress` が re-arm）。本当に blocked な task は再登録するので、
   次の stall はこれまでどおり deadlock trap（`conc_require`）。pump_all は
   ループ脱出時に parked task が残っていれば同じく trap — 「pump_all が
   parked を残して静かに return する」新経路は作らない。
5. **sleep との相互作用**: `conc_settle_sleep_debt` は direct-parked task を
   `other_parked` に数えない — 「sleeper が resolve する future を待つ
   awaiter」が仮想時計を堰き止めて force-settle 待ちになる従来の遠回り
   （§3.13 の stall counter 経路）が、直ちに settle される形に改善。

検証: `suspend_test.vibe` に direct-wake 意味論の pin を追加（複数 awaiter
の一斉 wake / 手動 wake の spurious-poll 安全性 / direct-parked consumer +
sleeping producer の clock 非阻塞 / builtin future の複数 awaiter direct
wake）。既存の D2 fixture 群（cross-task resolve、result_wait、channel）は
hooks mode で異なる schedule を通るが観測結果は不変。

### 3.16 ADR-0089 (c) — named host future（host import async の一般化、#1218）

§3.13/§3.14 の host future は**匿名の1本**（component import
`get-future: func() -> future<u32>`）に固定されていた。(c) はこれを
**名前つき N 本**へ一般化する — WIT 由来の async import が「1 import =
1 名前」であることに合わせた形。

```vibe
let run: () -> Int with Async = () -> {
  let a = host_future_named("price")
  let b = host_future_named("qty")
  await(a) + await(b)      // 2本が同時に in-flight
}
```

1. **surface**: `host_future_named: (String) -> Future[Int]`（pure。await
   だけが `Async` を運ぶのは `host_future_get` / `Future::pending` と同じ）。
   引数は **string literal 必須** — component import 名は compile time に
   決まるものであり値ではない。名前は component-model の label 形
   `[a-z][a-z0-9-]*` に制限し、違反は codegen 時の明示エラー
   （`compile_call.vibe`）。
2. **cell**: lowering は `host_future_get` と同一の `[state=2, handle]`
   （waitable cell）。違うのは handle の出どころだけで、`__aw_poll` の
   `Suspend(handle + 2)` 経路・entry boundary の `__entry_settle`・
   `vibe.host_future_wait` はそのまま共有される（park は handle 単位なので
   wait 半分は 1 本で足りる）。
3. **core import**: 名前ごとに `vibe.host_future_get$<name> () -> i64`。
   採番順は「匿名（あれば）→ 名前をソートした順」で、**プログラム内の
   出現順に依存しない**（同じ名前集合なら同じバイト列）。名前付きだけを
   使うプログラムは匿名 `host_future_get` import を持たない。
4. **composer**: `comp_core_host_future_names` が core import 名の列を
   読み、`comp_emit_component_wasm_async_hostfuture` が名前ごとに
   component import `<name>: func() -> future<u32>` + canon lower-async +
   adapter の getter を1組ずつ生成する。`future.read` /
   `future.drop-readable` の canon 定義は**共有**（すべて同じ
   `future<u32>` 型）。名前が1本のときの構造（import 0-6 / func 7,8）は
   step 4 のものと同一で、変わったのは下の eager read だけ。
5. **eager read（並行性の要）**: adapter の getter は pair を作った直後に
   `future.read` を**発行**し、handle ごとの landing slot
   (`HF_VALUE_BASE + handle*4`) と read 状態 (`HF_STATE_BASE + handle*4`:
   1 = blocked / 2 = 即完了) に記録する。`host_future_wait` は再 read せず
   park と回収だけを行う。wasmtime は `FutureReader` の producer を
   「read が pending になってから」しか polling しないため、read を await
   時まで遅らせると2本目の timer が1本目の完了後にしか始まらない —
   実測で 300ms + 100ms が 422ms（逐次）だったものが eager read で
   ~300ms（重畳）になる。
6. **host**: viberun は `VIBE_ASYNC_FUTURES="price=40:300,qty=2:100"` の
   各エントリを root import として link する（値と遅延が名前ごとに違うので
   完了順が観測できる）。

gate = `scripts/test_named_hostfutures_component_gate.sh`（pkf task
`test-named-hostfutures-component`）: WIT に `price` / `qty` が現れ匿名
`get-future` が現れないこと、値 42 = 40 + 2（各 await が自分の future に
settle）、wall が `0.8×P` 以上かつ `0.9×(P+Q)` 未満（park している かつ
2本が**重なっている** = 逐次実行ではない）、および単一名 program が他方の
名前を import しない control。byte level は `component_codegen_test.vibe` の
2-name composition テスト。

### 3.17 ADR-0089 Decision 3 — host 供給 `stream<u8>` の終端 probe（#1218）

Decision 3（AsyncIter/ByteStream の p3 接続）の emitter を書く前に、
**推測できない runtime の事実**が1つある: guest が host 供給の
`stream<u8>` を1バイトずつ読んでいったとき、**stream の終わりがどう
報告されるか**。`stream.read` は `(amount << 4) | code` を packed status
で返すが、どの code が「writer は居なくなった、もう来ない」を意味するかは
仕様書からではなく実測で決めるべきもの（§3.12/§3.13 の probe → byte-exact
移植という手順と同じ）。

**probe**: `tools/wasip3_component_probe/host_stream_value/component.wat`。
`body: func() -> stream<u8>` を import し（host 側は viberun の
`VIBE_ASYNC_STREAMS="body=10|15|17"`、producer は wasmtime 自身の
`Vec<u8>` StreamProducer なので**runtime の挙動**を測っている）、1バイト
ずつ読んで合計を返す。

**実測（wasmtime 47.0.2、2026-08-02）**:

- 3回の1バイト read はいずれも 1 item を転送する
- **4回目の read が `amount = 0` / `code = 1` を返す** = 終端。
  待つべき別の「closed」イベントは無く、**writer が居なくなったことを
  見つけた read がその場で inline に報告する**
- 合計 42（= 10 + 15 + 17）が返るので、終端の前にバイトが本当に届いて
  いることも同時に確認できている

つまり reader 側の終端判定は `(status >> 4) == 0 && (status & 0xf) == 1`。
gate = `scripts/test_host_stream_value_probe_gate.sh`（pkf task
`test-host-stream-value-probe`）が 42 を pin しているので、wasmtime の
bump で encoding が変わったら「終わらない reader」ではなく gate failure に
なる。

**このスライスで landed したのはここまで**（probe + viberun の host stream
import + gate）。残りの Decision 3 = guest surface
（`host_stream_named(name) -> ByteStream` / `ByteStream::next(s) -> Int
with Async`）、`Suspend` の stream 帯と entry boundary の settle arm、
per-name `stream<u8>` component import を出す composer、AsyncIter/`for await`
への接続。設計は §3.16 の named host futures と同型で、park が「future 1本
ごと」から「read 1回ごと」に変わる点だけが違う。
→ **guest surface / stream 帯 / composer は §3.18 で landed**。`for await`
という別綴りは **#1350 で削除済み** — iteration の suspend 可能性は effect
row（`with Async`）が既に語っており、構文レベルの `await` マーカーは
二重表現だったため、素の `for` に一本化した（同期/非同期の選択は iterand の
型だけで決まる）。**`for` からの消費は #1341 で landed**（§3.18.2）。残るは
一般 `Stream::next`（`Future[Option[T]]` protocol）と eager `Stream[T]`
combinator の退役。

**追加実測（2026-08-02、per-byte delay producer 追加後）** — viberun の
`VIBE_ASYNC_STREAMS="body=10|15|17@60"`（`@delay_ms` = 1バイトごとに遅延
する custom StreamProducer）で BLOCKED → park 経路を初めて実走させたところ、
runtime 事実が2つ増えた:

1. **park 後の set 解体は unjoin が先**。join したままの waitable-set を
   `waitable-set.drop` すると `resource has children` で trap する。
   `waitable.join(handle, 0)`（set 0 = remove）で外してから drop する。
   Vec producer では read が一度も BLOCK しないため、probe 自身の
   「join したまま drop」がこの日まで latent だった。
2. **終端は最終バイトと INLINE でも届く**。1 item ずつ渡して drop する
   producer では最後の read が `amount 1 / code 1`(バイト + CLOSED 同時)
   を返し、その後にもう一度 read すると
   `cannot read after being notified that the writable end dropped` で
   trap する。つまり終端は「別 read の `amount 0 / code 1`」(buffered
   producer)と「最終バイト同梱の `code 1`」(per-item producer)の
   **2形状**あり、reader は両方を扱わなければならない。

probe gate は no-delay run(分離終端)+ delayed run(inline 終端 + wall
clock 下限 = park の実在)の両方を pin する。adapter 側の反映は §3.18 の
5 を参照。

### 3.18 ADR-0089 Decision 3 — named host stream（実ソースの stream 読み、#1218）

§3.17 の終端実測を受けた本体スライス。次の実ソースが single-source lane
（entry 名 `run`）でコンパイルされ、自動で adapter-backed async component に
wrap され、viberun（`VIBE_ASYNC_STREAMS="body=10|15|17"`）上で **42** を
返す:

```vibe skip
// doctest-skip: needs an Async-row entry + component adapter; not runnable standalone
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let mut sum = 0
  let mut b = host_stream_next(s)
  while 0 <= b {
    sum = sum + b
    b = host_stream_next(s)
  }
  sum
}
```

lowering は §3.16 の named host futures と同型で、park が「future 1本ごと」
から「read 1回ごと」に変わる:

1. **surface**: `host_stream_named: (String) -> HostStream`（pure。名前は
   §3.16 と同じ string-literal + component-label 検証）と
   `host_stream_next: (HostStream) -> Int with Async`（次の byte 0-255、writer
   が居なくなったら -1。以後の read は cell 側で latch されて -1 のまま）。
   §3.17 の予告した `ByteStream::next` ではなく `host_stream_next` の綴りに
   したのは、eager な `Stream[Int]`（`String::to_bytes` 等）と表現が異なる
   ため — AsyncIter への統一は Decision 4 の boundary 規則と合わせて別
   スライス。
2. **cell**: `[state 3, handle]`（state 3 = host stream。future cell の
   0/1/2 と不交なので取り違えは構造的に起きない）。生成は
   `vibe_hs_get_raw$<name>` → core import `vibe.host_stream_get$<name>`。
3. **read = Suspend の stream 帯**: `host_stream_next(..)` 呼び出しは
   boundary machinery が注入 fn `__hs_next` に retarget する
   （sleep→`__slp_perform` と同じ shadow-aware rename）。`__hs_next` は
   state 3 のとき `perform Async::Suspend(handle + 2048)` — **予約 stream
   帯 [2048, 3071]**（future 帯は handle + 2 = [2, 1025]、adapter が
   handle ≤ 1023 を enforce するので帯は構成的に不交）。resume 値を
   row-free `__hs_fin` が処理する: v < 0 なら cell を閉じて（state 3 → 0）
   -1、それ以外は byte をそのまま返す。
4. **boundary**: `__entry_settle` に stream arm が増える
   （`2047 < q → vibe_hs_read_raw(q - 2048)`、hs machinery が発火した
   program のみ — future-only / sleep-only の boundary はバイト不変）。
   machinery keying は hf と同じ entry-row-keyed（user の
   `handle ... with Async` 下では in-guest scheduler の poller 縮退 =
   deadlock trap、§3.13）。
5. **adapter**: 共有 `host_stream_read (i64) -> i64` — `stream.read(h,
   slot, 1)` を発行し、BLOCKED なら waitable-set.wait で park
   （STREAM_READ = 2 のみ受理）、**wake 後は unjoin
   （`waitable.join(h, 0)`）してから set を drop**（さもないと
   `resource has children` trap — §3.17 追加実測 1）。終端は2形状
   （§3.17 追加実測 2）: zero-transfer status は code 1 = CLOSED のみ
   受理して `stream.drop-readable` 後に -1、**最終バイト同梱の CLOSED**
   （`amount 1 / code 1`）は per-handle closed latch
   （`comp_hs_closed_base()`、handle*4）を立ててバイトを返し、次の read が
   「latch クリア + drop-readable + -1」を一括で行う — drop まで handle
   index は再利用されないので latch が別 stream に aliasing する窓は
   構造的に無い。それ以外の zero-transfer code は loud trap。**future の
   eager read はしない** — park が read 単位なので、呼び出し間に pending
   read を残すと次の read と衝突する（double-read）。per-name getter は
   pair 生成 + handle 返し（+ latch の防御的クリア）だけ。
6. **composer**: `vibe.host_stream_get$<name>` sniff で wrap を key
   （future と OR）。per-name component import `<name>: func() ->
   stream<u8>` + 共有 `stream.read`/`stream.drop-readable` canon pair。
   future と stream の混在 program は 1 つの adapter / composition を共有し
   （`price: future<u32>` と `body: stream<u8>` が同じ WIT に並ぶ）、
   **hf-only の component 出力はバイト不変**。

gate = `scripts/test_named_hoststreams_component_gate.sh`（pkf task
`test-named-hoststreams-component`）: stream lane（上の while program が
42 = 10+15+17、WIT に `body: ... stream<u8>`、`get-future` 無し）+
**delayed lane**（`body=10|15|17@60` — 各 read が BLOCKED → park する経路と
inline 終端を実走、42 + wall ≥ 0.8×3×delay で park の実在を pin）+ mixed
lane（future 30 + stream 5+7 = 42、両 import が WIT に出る）。byte level は
`component_codegen_test.vibe` の stream-only / mixed composition テスト。
検証済みの consume 形: 直列 let 読み、while ループ、自己再帰、EOS 後の
再読（latch で -1）。

#### 3.18.1 `host_stream_close` — 部分消費した stream の明示解放（done）

§3.18 が follow-up として残していた制限（途中で読むのをやめた stream の
readable end を解放する surface が無い）を埋めたスライス。read 半分は EOS に
到達したときだけ drop するので、それ以前に読むのをやめた handle は component
instance の寿命まで残っていた。

surface は `host_stream_close: (HostStream) -> Unit`。**`Async` は付かない** —
`stream.drop-readable` は block しない canon call なので park も予約帯も
boundary settle arm も要らず、注入 fn `__hs_close` が adapter を直接呼ぶ。

```vibe skip
// doctest-skip: needs an Async-row entry + component adapter; not runnable standalone
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let a = host_stream_next(s)
  let b = host_stream_next(s)
  host_stream_close(s)          // 残りは読まない
  host_stream_close(s)          // 二重 close は no-op
  let after = host_stream_next(s)  // close 後の read は -1
  a + b + (after + 1)
}
```

冪等性は **cell の state word が担保する**（飾りではなく load-bearing:
1つの handle に `stream.drop-readable` を2回投げると host 側で trap する）。
`__hs_close` は state 3 のときだけ drop し、同じ step で cell を閉じる
(3 → 0) ので、2回目の close も close 後の read も adapter には届かない。
inline-terminal read が立てた CLOSED latch も同時にクリアする — その drop が
まさに latch の待っていた settle なので。

**gating on use（byte 互換の要）**: `__hs_close` は source が実際に
`host_stream_close` を呼んだときだけ注入される。`vibe_hs_close_raw` を参照する
のはこの注入 fn だけで、import はその名前の使用で gate されるため、無条件に
注入すると **drain するだけの program にも close import と adapter func が
生えて**、既に pin されている stream composition のバイトが動く。adapter 側の
close func も同じ sniff（guest が `vibe.host_stream_close` を import するか）で
gate し、**func list の最後に append** するので既存 index は不変。

gate lane = `test_named_hoststreams_component_gate.sh` の close lane
（5 bytes 中 2 bytes だけ読んで close → 再 close → close 後 read で 42、
かつ drain-only component に close import が無いこと + closing component に
guest import と adapter export が両方あることを .wat で確認）。

#### 3.18.2 `for b in <host stream>` — 表現の分離と読み出しへの接続（done, #1341）

D3 の「AsyncIter への接続」の最初のスライス。**着手前に測った事実が設計を
決めた**:

```vibe skip
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let mut sum = 0
  for b in s { sum = sum + b }
  sum
}
```

これは **エラーにならず 4 を返していた**（`VIBE_ASYNC_STREAMS="body=10|15|17"`、
期待値 42）。原因は型ではなく**表現の衝突**である: `host_stream_named` の
戻り型は `Stream[Int]` で、これは eager な配列バックの stream と同一の静的型
だった。ところが実行時表現は非互換で、eager 側は要素の配列、host stream 側は
2語の cell `[state, handle]`。`for` は静的型しか見ないので array ループを選び、
cell の2語（state 3 + handle 1）を足していた。**診断も trap も出ない、
それらしい小さい数**という最悪の失敗形。

したがって修正は「`for` に host stream 対応を足す」ではなく、まず
**表現ごとに別の名前型を与える**こと:

- `host_stream_named(name) -> HostStream`（`Stream[Int]` ではない）
- `host_stream_next(HostStream) -> Int with Async`
- `host_stream_close(HostStream) -> Unit`

これで eager 用の `Stream::to_string` を host stream に適用するのは
**型エラー**になり、静かなゴミではなくなる（記述当時は `Stream::map` /
`Stream::fold` も同じ barrier の対象だったが、#1538 で退役した）。

その上で desugar（`build_host_stream_for`, desugar_trait_dict.vibe）が
`for` を read へ落とす:

```vibe skip
let __hs_src = <iter>
let mut __hs_b = host_stream_next(__hs_src)
while 0 <= __hs_b {
  let <name> = __hs_b
  <body>
  __hs_b = host_stream_next(__hs_src)
}
```

これは §3.18 の gate が #1339 以来走らせてきた手書き while ループそのもの
なので、**新しい codegen は無い — 表面だけ**。AsyncIter protocol
（`next -> Future[Option[(T, Self)]]`）は経由しない: host stream の read
primitive はスカラの `host_stream_next` であり、protocol を挟むと
`Future[Option[...]]` の割り当てを1バイトごとに行うことになる。

**index binding は非対応**（`for b, i in s`）。read 回数を数えることになるが、
byte offset は再走査可能なコレクションの位置とは別物なので、それらしい誤った
意味を与えるより未対応のままにした。

row 要求は #1358 と同じ理由で必要（read ごとに park する）。`HostStream` は
AsyncIterator の impl を持たないので、`afe_async_iterand`（checker_effects）に
明示の分岐を置いた。回帰ロックは
`scripts/test_named_hoststreams_component_gate.sh` の `for` lane —
while ループと同じ 42 を返すこと、および `{ Async }` の無い row で
**reject されること**の両方を pin する。

**projection（Codex review on #1369 で修正）**: 当初この routing は
identifier と直接の `host_stream_named(..)` 呼び出しにしか効かず、
`for b in h.s`（struct field 経由）は 42 ではなく 4 を返していた。原因は
**両方の pass に struct の field 型が無かった**こと — desugar の
`struct_sets` は field 名だけを持ち、async effect pass も同様だった。
両者に `Struct.field -> 型名` の表を持たせて解消した:

- desugar: `collect_struct_field_types` が `fn_returns` に予約キー
  (`struct_field_type_key`, `.` は識別子に現れないので衝突しない) で相乗り。
  `infer_arg_type_name` の `EDot` arm がそれを引く。**sort の前に push する
  必要がある** — この表は binary search されるので、後から append しても
  見えない（最初の実装はこれを踏み、seeding を別の collector に置いてしまい
  無効だった）。
- checker_effects: 同じ表を module cell で持ち、`afe_expr_head_name` の
  `EDot` arm が引く。これが無いと desugar だけが await ループを組み立て、
  row 無しで park できてしまう（#1358 が塞いだ穴の別ルート）。

副産物として `let s = h.s; for b in s` も通る（`extend_var_types` が
`infer_arg_type_name` を通すため）。回帰ロックは gate の projected `for`
lane（bytes を読むこと + `{ Async }` 無しの row が reject されること）。

**#1538 の boundary slice（done）**: `HostStream` は routing key であると同時に、
**legacy `Stream[T]` consumer への入力では barrier** である。checker は
`HostStream` を期待する `Stream[T]` に渡すと型エラーにするので、
`Stream::to_string` と、同じ型を受け取る
ユーザー定義関数は state-3 cell を eager array として読めない
（#1538 前は `Stream::map` / `Stream::fold` も同じ列にいた）。この判定は
この二つの compiler-owned nominal name にだけ閉じており、`CtNamed` 全体の
concreteness や通常の user-defined/generic nominal assignability は広げない。

任意の非 `Stream[T]` parameter（例えば `take_int(s)`）に `HostStream` を渡す
ことまでを拒否する一般 nominal barrier ではない。その横断的な型検査強化は
別作業のままにする。この狭い fail-closed boundary は generic `HostStream` と
legacy eager `Stream[T]` の誤交差を防ぐ一般安全策であり、#1539 の provider
lifecycle を実装した証拠ではない。#1539 の既存 `stdin_stream` は
`Stdin` authority を持つ `Option[String]` pull closure で、§3.18.3 の ratified
stdin route は別の provider-aware lifecycle を必要とする。

**残り**: 一般 `Stream::next`（`Future[Option[T]]`）を host read へ落とす件は
まだ。実測では `await(Stream::next(s))` は ADR-0076 の evidence-passing
migration に弾かれて**コンパイルすら通らない**（"the site is not eligible
for evidence-passing migration"）ので、これは D3 の接続作業ではなく
suspend lowering 側の適格性の話。eager `Stream[T]` combinator の退役も別途。

#### 3.18.3 #1539 — `wasi:cli/stdin@0.3.0` lifecycle measurement and shadow provider prerequisite

`tools/wasip3_component_probe/stdin_read_via_stream/component.wat` retains the
ratified `wasi:cli/stdin@0.3.0` result type
`tuple<stream<u8>, future<result<_, error-code>>>`, including the nominal
`wasi:cli/types@0.3.0/error-code` alias. It also retains the preview-2
`wasi:cli/run@0.2.12` command export. Thus an error result cannot be silently
accepted as a representation-compatible non-nominal value.

**Measured on pinned wasmtime 47.0.2:** with binary stdin `10,15,17`, `drain`
performs canonical async `stream.read` calls for each byte, observes the
separate zero-item EOF status, drops the readable stream, and awaits canonical
`future.read` completion success; it returns `42`. `drop` obtains the same
pair, drops its readable stream immediately, awaits completion success, and
returns `43`. BLOCKED stream/future reads use `waitable-set.new`,
`waitable.join`, and `waitable-set.wait`; the end is unjoined before its set is
dropped. Other statuses, events, byte values, EOF forms, and result tags are
diagnostic return paths, not success.

`bash scripts/test_wasi_cli_stdin_p3_probe_gate.sh` is the merged executable
probe/gate for this measurement. The generated shadow is validated by
`bash scripts/test_wasi_cli_stdin_provider_component_gate.sh`; phase C of
`scripts/test_wasi_p3_guarantee_gate.sh` (`pkf run test-wasi-p3`) invokes both.
It parses, validates, and prints the component, generates deterministic binary
input, and executes both async-lifted lanes. Required mode requires exactly
wasmtime 47.0.2; missing tools, an unpinned provider, and
ABI/type/link/command-export failures fail closed. The default local mode skips
unavailable tools or an unpinned provider. The aggregate is IN `ci-required`:
it is the only lane that runs a composed component end to end under a real
host, so a componentized regression has nowhere else to be caught. The cost of
folding it in is that an unavailable host implementation or an unpinned
wasmtime blocks a merge rather than reporting.

##### Why the current `HostStream` ABI cannot represent stdin

The current generic `HostStream` cell is exactly `[3, handle]`: one readable
`stream<u8>` handle identified by a named host-stream getter. It has no slot
for another owned resource, no provider identity, and its
`host_stream_named("name")` import is modeled as a getter for that one stream.
It is therefore correct for the generic named-host-stream contract in §3.18,
but it is not a lossless carrier for stdin.

`wasi:cli/stdin@0.3.0::read-via-stream` is instead a **synchronous
acquisition** which returns **two separately owned readable handles** in one
result: the readable byte stream and the readable completion future. The latter
settles the stdin lifecycle after the stream is drained or dropped. Replacing
that call with `host_stream_named("stdin")` would discard the completion handle
at acquisition, make its ownership unrepresentable, and make lifecycle failure
invisible. It must not be treated as an alias or special name of the generic
HostStream ABI.

In particular, `stream.drop-readable` releases only the stream resource. It
does **not** by itself complete the stdin lifecycle: the completion future must
still be read, its result checked, and then released. This corrects the stale
short-hand that described stream drop alone as a completed stdin close.

##### Provider-aware contract (shadow lifecycle + atomic public source route)

The #1539 prerequisite is a distinct, opaque provider-aware handle whose
adapter state retains both owned ends from `read-via-stream`:

```text
acquire stdin provider (sync, Stdin authority)
  -> opaque stdin-provider handle { readable-stream, completion-future, state }
read opaque handle -> byte | EOF                  with Async
close opaque handle -> lifecycle-complete result  with Async
```

The compiler now exposes this contract through one unforgeable nominal scalar:

```text
Stdin::read_via_stream() -> StdinStream with Stdin
StdinStream::next(StdinStream) -> Int with Async
StdinStream::close(StdinStream) -> Unit with Async
StdinStream::read_chunk(StdinStream, Int) -> Option[String] with Async
```

`StdinStream` is neither `Int`, generic `HostStream`, nor `Stream[T]`; source
cannot construct it and it is not `Send`. The four public provider builtins are
**direct-call-only**: any value-position reference (local/top-level alias,
chain, compound/container/field, returned value, or unknown HOF transport) is a
checker error. A user-defined wrapper with an explicit `Stdin` or `Async` row is
an ordinary function and may be passed as a value under the existing effect
rules. This deliberately does not add the generic higher-order effect-flow
propagation deferred by #1536. Their observable authority and effect
requirements are fixed as follows:

- Acquisition is synchronous but requires `Stdin` authority. It calls
  `read-via-stream` once and transfers ownership of **both** returned readable
  handles into the opaque provider state.
- Reads require `Async` because canonical `stream.read` may block. They retain
  the existing byte/EOF behavior only after the provider adapter has performed
  the required read/wait/unjoin work.
- EOF and early close both require `Async`: each must release the stream end,
  await the completion future, validate success, and release the future end.
  Therefore lifecycle-complete close cannot be a synchronous operation.
- A completion `error-code` is fail-closed. There is no approved public
  `Stdin`/`Exception`/`Result` mapping yet; an adapter must not turn it into
  EOF, success, a generic integer, or a legacy `Option` value.
- `read_chunk(stream, n)` is a direct compiler-owned, use-gated operation with
  `Async`. For positive `n`, it reads one provider byte at a time and returns
  exactly `n` bytes except for the final short chunk. Bytes are validated as
  `0..255` and appended through one-byte `String::from_char_code`, without
  UTF-8 expansion. It does not promise to preserve internal provider read
  boundaries. EOF settles before `None`; subsequent calls return `None`. An
  exact multiple needs one extra call to observe EOF. For `n <= 0`, it returns
  `None` without reading or settling, so the caller must close the stream.
  Early stopping likewise requires explicit, idempotent `close`. A pull
  closure/direct-`for` adapter remains blocked on transitive higher-order
  effect evidence (#1536) and is not part of this surface.

The existing `host_stream_close(HostStream) -> Unit` is deliberately
synchronous and only drops its one generic stream handle (§3.18.1). It cannot
wait for or validate a missing completion future, so it **cannot safely
implement** provider stdin close. Reusing it would either leak/unjoin the
future or silently report a failed lifecycle as a successful close.

##### Staged prerequisite and invariants

Stages 1--3 were first implemented by the production-unused shadow emitter
`comp_emit_component_wasm_stdin_provider_shadow` and its private component
scenarios. #1539 now also has a bounded **core-only** route: `linked_compile`
reserves checker-invisible raw rows for exact core imports
`vibe.stdin_provider_acquire () -> i64`, `stdin_provider_read (i64) -> i64`,
and `stdin_provider_close (i64) -> i64`; the stdin-first wrapper sniffs parsed
module/name pairs and the dedicated arbitrary-core composer validates exact
signatures before composing the nominal stdin/types imports.

The guest receives only a tagged-i64 bridge instance. The bridge rejects odd
or high-bit-aliased wire IDs before i32 narrowing, and only then calls the
proven opaque lifecycle functions. The full shadow instance, scenario exports,
canonical stream handle, and completion-future handle never cross into the
compiled guest. The bridge ABI is `wire = value << 1`; read returns tagged
bytes or tagged `-1` after settlement and close returns tagged zero.

The three raw registry rows remain `checker_visible=false`. Exact direct calls
lower through compiler-owned ABI wrappers to those imports; the `read_chunk`
wrapper additionally implements repeated hidden raw reads. Public operation
values never reach codegen because the checker rejects them. Source
emits only the exact `vibe.stdin_provider_*` core imports and the nominal
`wasi:cli/types@0.3.0` + `wasi:cli/stdin@0.3.0` component imports.

`stdin_stream`, generic HostStream, and named future/stream behavior remain
unchanged. `host_stream_named("stdin")` is reserved and rejected. A source core
that mixes stdin-provider imports with named future/stream imports is explicitly
rejected in this bounded slice. GC and standalone/non-Async-entry compilation
are also rejected explicitly; linear and RC component lanes are supported.

The provider permits multiple active acquisitions. Adapter IDs allocate
monotonically from 16 slots and are never recycled: capacity overflow traps
before another canonical acquisition, while concurrent/reentrant use of the
same open slot traps on its non-open phase. Successful EOF/close remains
idempotent through aliases. Wasmtime 47 source gates measure drain, early close,
function aliases, a sequential second acquisition, and two simultaneously open
acquisitions.

Load-bearing invariants for stages 1--3:

- Each successful acquisition owns exactly one stream end and one
  completion-future end; up to 16 acquisitions may coexist, and neither end may
  escape as a generic `[3, handle]` HostStream.
- EOF and early close converge on one settlement state machine. Once settlement
  begins, subsequent reads/closes are idempotent at the opaque-handle boundary
  and cannot issue a second drop, read, join, or unjoin.
- Every successful join has exactly one unjoin before its waitable set is
  dropped. Each stream/future readable end is dropped exactly once, including
  all diagnostic/failure exits.
- A completion error, unexpected status, or unexpected event is a failing
  transition, never EOF or successful close. Public propagation remains
  intentionally undecided and fail-closed.

The synthetic compiled-shaped drain and early-close cores are composed and
validated by `test_wasi_cli_stdin_provider_guest_component_gate.sh`; they check
bytes 10/15/17, EOF/repeated reads, early settlement, and repeated close on the
pinned Wasmtime 47.0.2 lane. The original shadow gate and exact 208-byte nominal
prefix remain separately preserved.

This is only the successful-close lifecycle slice. **Read-error injection is
unmeasured** (`io`, `illegal-byte-sequence`, and `pipe` have no claimed runtime
measurement). The forced completion-tag, wrong-byte, and extra-byte
expected-trap scenarios are controls of cleanup/fail-closed branches, not
measurements of provider-generated errors. Each byte-mismatch control settles
and drops both owned ends through the shared close path before trapping. Those
shadow-scenario controls introduced no API by themselves; the production
checker-visible `StdinStream` source/console API is the surface documented in
§3.18.3 above.

#### 3.18.4 `HostStream` as a PARAMETER — the serve lane's request body (done, #1540)

§3.18's `HostStream` came from a NAME: `host_stream_named("body")`. That is not
enough for a `vibe serve` handler, where the body is an argument of the call,
not something to go and fetch. Since #1540 scope 3/4 a `HostStream` can be a
function PARAMETER.

```vibe skip
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let mut out = ""
  let mut go = true
  while go {
    let b = host_stream_next(body)
    if b < 0 { go = false } else { out = String::concat(out, String::from_char_code(b)) }
  }
  "200\n\n\{out}"
}
```

- **boundary**: `lc_wrap_host_stream_params` rewraps every parameter annotated
  `HostStream` into the two-word cell `[3, handle]` on entry to the handler.
  From there the read path is §3.18's, unchanged: `__hs_next` → a Suspend in
  the stream band (`handle + 2048`) → `__entry_settle` → `vibe_hs_read_raw`.
  No named getter is injected, so the compiled core imports
  `vibe.host_stream_read` and nothing else — plus `vibe.host_stream_close` if
  the handler stops reading early (§3.18.1).
- **trampoline**: the canonical ABI flattens `stream<u8>` to one i32 handle
  after the strings' (ptr, len) pairs, and the lift is async, so the core
  function returns nothing — the result leaves through `task.return`.
- **adapter**: `comp_generate_serve_stream_adapter_module` — §3.18's measured
  read loop (BLOCKED / STREAM_READ = 2 / unjoin before dropping the set / the
  two terminal shapes and the CLOSED latch), implemented with NO names at all.
  It is deliberately not `comp_generate_hostfuture_adapter_core_module`: that
  module's whole index layout is derived from the named future/stream counts,
  so teaching it "no names, still a reader" moves every index four other lanes
  depend on, and supplying a dummy name would reintroduce the
  `[async-lower]<label>` component import #1796 ruled out as a composition
  cycle. Every band is indexed by handle — a serve instance carries many
  request tasks at once, and `stream.read` registers its landing address with
  the canon BEFORE blocking, so a shared slot would let two producers write to
  one address.
- **CLI**: `serve_handler_takes_body_stream` picks the lane. `with Async` and
  `body: HostStream` REQUIRE EACH OTHER — either alone is a diagnostic naming
  the other, because Async alone has nothing to await and a HostStream alone
  can never be read (reading suspends).
- **adapter (Rust)**: `VIBE_HTTP_ADAPTER_BODY_STREAM=1` builds the variant
  whose import is `handler(.., body: stream<u8>)`. There is no
  `.collect().await` anywhere in it; the reader goes straight through.

**Reads that park, and a handler that stops early, work in this lane.** The
first version served only buffered bodies, whose reads all complete eagerly;
a chunked upload slow enough that a read actually parks, and a handler that
stops reading before the end, trapped with `uninitialized element` inside the
injected `__hs_next`. PR #1931 (#1924) fixed the component realloc — the
trampoline's `cabi_realloc` writes back MAIN's `__heap_ptr`, and an allocator
that left it odd corrupted the handler's first heap object, so the lane worked
or trapped depending on the length of the request strings — and added
regressions for both shapes. `scripts/test_serve_body_stream_gate.sh` pins a
chunked upload fed a byte at a time (the adapter's park branch) and the same
body under request strings of every length mod 8.

> **Pitfall (measured 2026-08-16): the `vibe.*` Int ABI is NOT "always tagged".**
> §3.13/§3.18 say "i64 values are guest-tagged on the wire (the adapter
> shifts)". That holds for THAT lane, whose core comes from the CLI's **RC
> compile** (`enable_rc` on, `linked_compile`'s tag_mode 1 = `value << 1`).
> `vibe serve`'s core comes from `compile_wasi_module_no_dce_impl`, which
> passes `enable_rc` **off**, so an Int there is a plain i64. **One import
> name, `vibe.host_stream_read`, with two value representations decided by the
> compile mode.** Mixing them does not trap: every byte the handler reads is
> silently doubled, which is how "abc" came back as `sum=588` instead of 294.
> The serve lane's trampoline and adapter are both untagged.

#### 3.18.5 Core value ABI at component adapter boundaries (ADR-0106, #1930)

The core function type `(i64) -> i64` does not identify how a vibe `Int` is
represented. RC builds use one-bit tagged values (`n << 1`), while non-RC
builds use plain i64 values. Applying the wrong convention does not necessarily
trap: a stream byte can be doubled and still look valid.

A core that imports a host-future getter, a named host-stream getter, or (as of
#1342) the host `sleep` under an async `run` entry MUST contain one
`vibe.tagmode` custom section. A serve core whose validated,
exported `handler` has the four-parameter `(String, String, String,
HostStream) -> String with Async` signature MUST also contain the section,
even when the handler never reads or closes its `HostStream` parameter and
the file exports other Async helpers. An unrelated HostStream-typed export or
ordinary/library entry does not select this adapter and emits no section, even
when it calls the raw stream-read builtin. The payload is exactly one
little-endian i32:

- `0`: plain i64 values (`VIBE_RC=0`)
- `1`: one-bit tagged values (`VIBE_RC=1`)

The section is a required ABI declaration. A composer MUST reject a missing,
truncated, malformed, unsupported, or conflicting declaration. It MUST NOT
infer a default from the import name, function signature, or compiler version.

The shared host-future/named-stream adapter accepts modes 0 and 1. It decodes
every handle and encodes every returned future value, stream byte, and EOS
sentinel according to that mode. The serve stream-parameter adapter accepts
only mode 0 because its handler core is compiled through the non-RC serve
pipeline; mode 1 is a composition error.

Core modules that do not select either adapter omit `vibe.tagmode`. This keeps
ordinary wasm byte-identical and prevents adapter-only metadata from becoming
a global output-size cost.

#### 3.18.6 `sleep` inside an async component (done, #1342)

An `() -> Int with Async` entry that calls `sleep(ms)` had no working route.
The boundary settles the suspend through `sleep_blocking`, which is a
`vibe.sleep (i64) -> ()` core import; that core fell into the self-contained
trampolined-p1 wrap, which instantiates it with a preview1 `fd_write` stub and
no `vibe` instance at all. The composer emitted the component anyway and the
compiler exited 0, so the failure surfaced only when something tried to load
the artifact:

```
$ wasm-tools validate --features all sleep.component.wasm
error: missing module instantiation argument named `vibe`
```

Two changes. First, `vibe.sleep` keys the adapter-backed composition — the same
one host futures and host streams ride. Second, the self-contained wrap now
proves its core's imports are satisfiable before emitting anything, and names
the offending import when they are not.

The sleep half is not a getter/wait pair like the other two. The host side is
an `async func`, so its async-lowered call returns a packed status whose high
bits hold a **subtask** rather than a future or stream handle:

```
import sleep-for: async func(ms: u32) -> u32     ; component import

; adapter func `sleep (i64) -> ()`, exported to the compiled core as vibe.sleep
packed = [async-lower]sleep-for(ms, 24)
if (packed & 0xf) != RETURNED(2):                ; a real delay starts a subtask
   sub = packed >> 4
   waitable.join(sub, ws) -> waitable-set.wait(ws, 32)
     ; the task genuinely suspends here; the wake carries
     ; event SUBTASK(1) with status RETURNED(2) in payload[1]
   subtask.drop(sub) -> waitable-set.drop(ws)
```

`subtask.drop` sits inside the parked branch: a zero (or already elapsed) delay
can complete eagerly, and there is no subtask to drop then — dropping one
unconditionally is the bug §3.9 records finding on the `$writer` epilogue.

The sleep half's scratch slots (24 = async-lower results, 32 = wait payload)
are disjoint from the getters' (8 and 16). The getters may share slot 8 because
an async-lowered getter call completes before the next one starts; `sleep-for`
does not — its subtask stays outstanding across the park.

`sleep-for` is a viberun root import, linked from a tokio timer like every
other suspend in that runner. Never a blocking thread sleep: the measurement
that makes this lane worth having is that a host future created **before** the
sleep keeps making progress **during** it. With delay D on both, the program

```vibe skip
let run: () -> Int with Async = () -> {
  let a = host_future_named("price")
  sleep(300)
  await(a) + 2
}
```

returns 42 in ~D. A blocking sleep would serialize it to ~2D. That bound, the
`sleep-for` import, the plain-i64 (`VIBE_RC=0`) lane and the fail-closed
rejection are all pinned by `scripts/test_async_sleep_component_gate.sh`.

Everything else on that composition is byte-identical: the sleep functype,
imports, canon defs and adapter func are all emitted last and only when the
core imports `vibe.sleep`.

### 3.19 ADR-0089 Decision 3 — the real provider: `wasi:http`'s incoming body (#1540)

§3.18's host streams were measured against viberun's test provider
(`VIBE_ASYNC_STREAMS="body=10|15|17"`, wasmtime's own `Vec<u8>`
StreamProducer). The production producer is `wasi:http`'s incoming request
body, and connecting it was not a provider swap: the serve lane and the
host-stream lane were two disjoint compositions.

| | serve lane (before #1540) | host-stream lane |
|---|---|---|
| emitter | `comp_emit_component_wasm_string_handler` (`VIBE_SERVE_COMPONENT=1`) | `comp_emit_component_wasm_async_hostfuture` |
| guest surface | `handler(method, url, headers, body: String) -> String` | `host_stream_named(name) -> HostStream` |
| the body | **materialized** by the full adapter (`Request::consume_body` + `collect` → String) | a raw `stream<u8>`, one component import per name |
| composition | `wac plug` (adapter component + guest) | its own core-module composition, adapter core module included |

The body reached the guest already collapsed into a String; the `stream<u8>`
had been consumed inside the adapter.

**The shape measured and rejected** (#1540, #1796): the adapter exports
`body: func() -> stream<u8>` and the guest imports it. Together with the
adapter → guest `handler` edge that is a **cycle**. `wac plug` exits 0 having
pushed the unconnectable `body` import up to the root world, and `wac
compose`'s lexical DAG cannot write the mutual reference at all. Using one
instance's `body()` export as a request-local slot is unsound too: concurrent
requests have no identity there. **Do not implement this shape.**

**The shape that shipped**: the body rides on the existing handler edge as an
argument.

```wit
import handler: func(method: string, url: string, headers: string, body: stream<u8>) -> string;
```

`wit-bindgen` generates that import, and the adapter passes
`Request::consume_body`'s reader through without collecting it (the variant
`VIBE_HTTP_ADAPTER_BODY_STREAM=1` builds). `scripts/test_http_body_stream_probe_gate.sh`
is the probe: it componentizes and validates, checks that after `wac plug` the
only root imports are the host's `wasi:http/types@0.3.0`, and has `wasmtime
serve` answer a POST with a body with a guest-specific response. The rest of
the work is §3.18.4: the string-bearing async lift's `task.return` option set
was measured (`scripts/test_async_string_lift_probe_gate.sh`), the canon
emitters were generalized without moving existing scalar callers' bytes, the
serve handler accepts `body: HostStream` with `Async` as an async lift, and the
incoming handle reaches the guest's read path as a `[3, handle]` cell.
`scripts/test_serve_body_stream_gate.sh` pins it end to end; all of these run in
phase B of `scripts/test_wasi_p3_guarantee_gate.sh`.

## 4. The WASI 0.3 boundary mapping

| vibe | WASI 0.3 / Component Model |
|---|---|
| `Future[T]` | `future<T'>` (`T'` is the canonical form of `T`) |
| `ByteStream` (nominal) | `stream<u8>`; a guest AsyncIter in a component signature is refused |
| an export whose row carries `Async` | `async func` |
| a `vibe serve` handler `(method, url, headers, body: String) -> String` | the guest exports a sync `handler: func(string, string, string, string) -> string`; the full adapter (§4.1) wraps it in `wasi:http/handler` |
| a `vibe serve` handler `(.., body: HostStream) -> String with Async` | an async-lifted `handler(.., body: stream<u8>) -> string`; the body-stream adapter hands the request body over uncollected (§3.19) |
| awaiting a WIT `async func(..) -> response` binding (outbound, e.g. a `fetch(url)` derived by `from_wit_future_imports`) | a subtask of that function, imported with exactly the WIT's type (#3131); `response` is the binding's `record { status: s32, body: stream<u8> }` |
| request and response bodies | `stream<u8>` |

**Worlds.** An incoming handler is served as `wasi:http/service`. A handler that
also awaits WIT responses is composed by
`comp_emit_component_wasm_service_handler` into one component that exports
`handler` and imports the binding's interface; a provider implements that
interface over `wasi:http/client` (`scripts/build_http_client_provider.sh`), so
the plugged result exports `handler` and imports `wasi:http/client`
(`fixtures/serve_service_world`). With the provider in `handler` mode it
forwards to an imported `wasi:http/handler` instead, which makes the composition
a `wasi:http/middleware` (`fixtures/serve_middleware_world`).
`scripts/test_serve_body_stream_gate.sh` runs both under `wasmtime serve`.

### 4.1 The HTTP handler under `wasmtime serve`

`vibe serve` (the `wasmtime-serve` host action of `runtime/vibe`) composes a
handler and serves it:

1. the compiler componentizes the handler: the packed-string trampoline
   (`comp_emit_component_wasm_string_handler`, matching the `(ptr << 32) | len`
   string ABI) for a `String` body, the stream lane
   (`comp_emit_component_wasm_stream_handler`) for a `HostStream` body, or
   `comp_emit_component_wasm_service_handler` when the handler awaits WIT
   responses;
2. `wac plug` composes it with the full adapter
   (`scripts/build_wasi_http_p3_full_adapter.sh`, built with
   `VIBE_HTTP_ADAPTER_BODY_STREAM=1` for the stream lane);
3. `wasmtime serve -Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W
   component-model-async=y -W component-model-async-stackful=y` serves the
   result.

**The full adapter's contract.** The handler is `(method: String, url: String,
headers: String, body: String) -> String`, or the same with `body:
HostStream` and `Async`.

- In: the request's method; its path with query as `url`; its headers,
  serialized as `"name: value"` lines (`get-headers().copy-all()`); its body,
  collected into a String through `Request::consume-body`, or handed over as
  the stream.
- Out: one response string, `"STATUS\n<Header: value lines>\n\n<body>"`. The
  first line is the status code (200 when it does not parse), the lines up to
  the blank line are response headers (`Fields::append`), and the rest is the
  body. Without a blank line the string reads as `"STATUS\nBODY"`.

The response is one encoded string because the handler's export returns one
value. Returning a structured response, or exporting `wasi:http/handler` from
the guest itself, needs vibe bindings for the `request` / `response` / `fields`
resources — the bindings #3142 asks for on the client side; the server side
has no open issue.

**Values cross untagged.** The serve lane compiles its core with RC off
(`compile_wasi_module_no_dce_impl`), and the stream adapter accepts only
`vibe.tagmode` 0 (§3.18.5, ADR-0106).

**Gates.** `scripts/test_wasi_http_p3_full_gate.sh` (`pkf run
test-wasi-http-p3-full`) serves `fixtures/serve_handler_smoke.vibe` through the
whole pipeline and checks auth by request header: with `x-token: secret` the
answer is 200 `ok:GET:/`, without it 401 `unauthorized`.
`scripts/test_serve_body_stream_gate.sh` covers the stream, service and
middleware lanes. Both run in phase B of `scripts/test_wasi_p3_guarantee_gate.sh`
(`pkf run test-wasi-p3`, the CI `wasi-p3-gate` job).

**Open:**

- **Trailers.** The adapter ignores the request's trailers and sends none with
  the response. No open issue owns them.
- **The guest importing `wasi:http/client` itself**, with a request that
  carries a method, headers and a streamed body, rather than reaching the
  client through a provider component: #3142.

## 5. Versions and pins

- **WIT.** `lib/@vibe/wasi/wit/p3/` is a byte-identical copy of
  `wasmtime-wasi-http` 46.0.1's `src/p3/wit/`, the ratified `wasi:http@0.3.0`
  (`lib/@vibe/wasi/wit/p3/VENDOR.md`). `scripts/build_wasi_http_p3_full_adapter.sh`
  includes `wasi:http/service@0.3.0` from it, and phase D of
  `scripts/test_wasi_p3_guarantee_gate.sh` asserts that a composed serve
  component references `wasi:http@0.3.0` (`VIBE_P3_WIT_PIN`), so drift between
  the adapter, the vendored WIT and the runtime fails loudly.
- **Runtime.** wasmtime **47.0.2**: `runtime/viberun/Cargo.toml` (with the
  `component-model`, `component-model-async` and `async` features),
  `scripts/install_wasmtime_release.sh`, the CI `wasi-p3-gate` job (one leg,
  phases `async,http,stdin`) and the other workflows. It serves the ratified
  `0.3.0` world with component-model async on by default. The pre-ratification
  RC world (`0.3.0-rc-2026-03-15`) does not link against it (`resource
  implementation is missing`), and there is no 45.x compatibility leg.
- **Flags.** The gates and `vibe serve` pass `-W exceptions=y -W
  concurrency-support=y -W component-model-async=y -W
  component-model-async-stackful=y` (plus `-Sp3 -Shttp` to serve). Compiled
  cores use Wasm exception handling, hence `exceptions`; the async flags are
  defaults since wasmtime 46 and harmless. A hand-written probe that uses the
  `future.*` / `stream.*` built-ins also needs `-W
  component-model-more-async-builtins=y` (§3.3, §3.12).
- **Tools.** The CI job pins `wasm-tools` 1.253.0 and `wac` 0.10.1 (older `wac`
  releases failed on the `wasi:http@0.3` async-lift shape). The adapters build
  with `wit-bindgen` 0.54.

## 6. Where it stands

### 6.1 What runs

| vertical | what | gate |
|---|---|---|
| generating and running an async component | a `.vibe` entry `() -> Int with Async` → async lift + trampoline, driven by `runtime/viberun` (wasmtime 47) through `instantiate_async` / `run_concurrent` | `test_async_component_gate.sh` |
| awaiting a ready future | `Future::ready` → `[0, payload]`; `__aw_poll` reads slot 1 | same |
| a pending guest future | `Future::pending()` → `[1, _]`, completed by `Future::resolve`; the await parks by poll wait, with the direct-wake waiter list (§3.15) | `fixtures/async_future_pending.vibe` |
| awaiting a host future | `host_future_get()` / `host_future_named("x")` → `[2, handle]` → `Suspend(handle + 2)` → boundary settle → the adapter's `future.read` + `waitable-set.wait` | `test_hostfuture_source_component_gate.sh`, `test_named_hostfutures_component_gate.sh` |
| concurrent awaits | several host operations in flight at once (two 1000 ms calls in 1015 ms) | `test_concurrent_awaits_component_gate.sh` |
| reading a host stream | `host_stream_named("body")` → `[3, handle]`; `HostStream::next` / `host_stream_next` (a byte, or the end) → `Suspend(handle + 2048)` → the adapter's per-read `stream.read` + park; `HostStream::close` releases a partly read end | `test_named_hoststreams_component_gate.sh` |
| `for` over a host stream | the iterand's type selects the await loop; a row without `Async` is refused | same (`for` lane) |
| `sleep` in a component | `sleep(ms)` → `Suspend(-ms)` → the boundary's `sleep_blocking` → the adapter async-lowers `sleep-for: async func(ms: u32) -> u32` and parks on the returned subtask (#1342, §3.18.6); a host future created before the sleep progresses during it | `test_async_sleep_component_gate.sh` |
| spawned tasks on host waits | `TaskGroup::spawn_suspend` tasks park on host futures, stream reads and timers in one shared waitable set and resume in completion order; cancelling the last waiter releases its read or timer (#1537, #2065) | `test_named_hostfutures_component_gate.sh`, `test_named_hoststreams_component_gate.sh`, `test_wit_async_import_component_gate.sh` (`fixtures/async_spawn_host_futures/`) |
| WIT-derived async imports | `from_wit_future_imports` derives bindings for a WIT file's `async func() -> s64` and `async func(..) -> response`; each call is a subtask of the function as written (#2064, #3131) | `test_wit_async_import_component_gate.sh` |
| outbound HTTP | a `fetch(url)` binding awaited as `Future[HostResponse]` (status and a streaming body), answered by viberun's `http` mode or, under `wasmtime serve`, by a provider over `wasi:http/client` (#2066) | `test_wit_async_import_component_gate.sh`, `test_serve_body_stream_gate.sh` |
| serve: the request body as a stream | `handler(.., body: HostStream) with Async` → an async lift with `body: stream<u8>` (#1540, §3.18.4) | `test_serve_body_stream_gate.sh` |
| serve: service and middleware worlds | a handler awaiting WIT responses composes into `wasi:http/service`, and with the provider's `handler` mode into `wasi:http/middleware` (#2066, §4) | `test_serve_body_stream_gate.sh` |
| stdin as a provider | `Stdin::read_via_stream()` → `StdinStream` (`next` / `read_chunk` / `close`) over `wasi:cli/stdin@0.3.0` (#1539, §3.18.3) | phase C of `test_wasi_p3_guarantee_gate.sh` |
| the WIT mapping | `with Async` export → `async func`, `Future[T]` → `future<T'>`, nominal `ByteStream` → `stream<u8>` | `wit_gen_test` |

### 6.2 Remaining work

| item | scope | owner |
|---|---|---|
| Component Model subtasks as `TaskGroup`'s backend | tasks are guest fibers inside one instance; start a task as a Component Model async subtask with its own handle, joined through the shared waitable set, with `TaskHandle::cancel` reaching it as `subtask.cancel` | #3147 |
| the guest importing `wasi:http/client` directly | vibe bindings for the `request` / `response` / `fields` resources; a request with a method, headers and a streamed body | #3142 |
| promoting the suspendable-task lane | `TaskGroup::spawn` runs a suspending body, `TaskGroup::run` drives parked tasks itself, and the lane's names move into `@vibe/concurrent`'s contract | #3200 |
| a `handle` that reaches `Async` across an await | abortive handles split with the body (#1537); a `handle` that resumes, or that handles `Async` itself, is still refused | no open issue |
| suspend-lowering eligibility | the ineligible shapes listed in §2.2 | no open issue |
| HTTP trailers, and a guest-exported `wasi:http/handler` | §4.1 | no open issue |
| streaming a real provider's response body | viberun's `http` mode buffers the body before the future lands (`VIBE_HTTP_BODY_LIMIT`, `VIBE_HTTP_TIMEOUT_MS`) | no open issue |
| runner-private root futures beside WIT futures | refused by name in one component ([async-host-contract.md](async-host-contract.md)) | no open issue |

## 7. Unresolved questions

- **The canonical form `T'` of a payload `T`**, in particular an enum or a
  record as the element of a `future` or `stream`. Host futures and streams
  carry `u32` / `u8`, and WIT-derived imports `s64` and the `response` record;
  nothing more general is lowered.
