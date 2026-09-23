# ADR-0085: Migrate `Error` to the typed `Exception[E]` core effect

Status: accepted (Phase 3 implemented — #1344)

Date: 2026-07-30 (Phase 3 landed 2026-08-02)

Related: #1218, #1136, #1344, ADR-0016(`handle`/`throw`), ADR-0050(generic effect
handler), ADR-0071(effectset), ADR-0073(checked `Error`), ADR-0084(effect
taxonomy).

> **Spelling addendum (#1461 / #1501, 2026-08-06):** parts of this document
> still use the spelling of the time, `with Error` / `handle .. with Error`.
> Since then #1461 and #1501 retired `Error` as an effect-row item and as a
> handler name, so the "compatibility alias" described below is a **parse
> error** on the current surface. Use `Exception` in both positions (`vibe fmt`
> rewrites the old spelling). Only the operation qualifier `perform
> Error::Throw` is still accepted, as internal compatibility for reading old
> generated output, because it is neither a row item nor a handler name. New
> source uses `perform Exception::Throw`.
>
> **Implementation status (2026-08-02, #1344):** the typed `Exception[E]` row
> **is in the checker**. `throw(v)` requires `Exception[typeof(v)]`, and
> `Exception[E1]` neither authorizes nor discharges `Exception[E2]`.
> `with Exception[E]` / `handle .. with Exception[E]` /
> `effectset { Exception[A], Exception[B] }` are all accepted.
> For what is checked and what is still gradual, read
> [Implementation status (Phase 3)](#implementation-status-phase-3).
> The non-generic `Exception` alias from #1279 has not been removed — **it
> remains as the erased (kind-less) spelling** (see "What `Error` means"
> below).

## Context

Under ADR-0073, today's `Error::Throw` is a non-resumable, fully checked
semantic effect, and an unhandled `Error` is turned into a diagnosed failure at
an entry boundary that carries an explicit row. The payload, however, is
effectively fixed to `String`, so distinct failure domains cannot be told apart
by type and row.

Adding per-type exceptions such as `IOException` as a subclass hierarchy would
require a subtype mechanism separate from effectset closed-world normalization,
handler exhaustiveness, and the package contract hash. Reusing the existing
generic effect identity makes that extra mechanism unnecessary.

## Decision

Introduce the following as a language-reserved core ambient effect.

```vibe skip
effect Exception[E] {
  Throw(E) -> Nothing
}
```

`Nothing` is a notational convenience meaning "does not return normally". The
bottom-like typing that lets today's checker place `throw` in any expression
position is kept; the surface name of the bottom type is decided separately.

- `throw(value)` is sugar for `perform Exception[E]::Throw(value)`, where `E`
  is determined by the static type of `value`.
- `Exception[IoError]` and `Exception[ParseError]` are distinct normalized
  `OperationRef`s; a row or handler for one neither authorizes nor discharges
  the other.
- `Exception[E]` is a non-resumable effect. `resume` inside a handler arm is
  rejected, as in ADR-0073.
- Declaring several exception types uses an effectset union, not subclassing.

```vibe skip
enum IoError {
  NotFound(String),
  PermissionDenied(String)
}

enum ParseError {
  UnexpectedToken(String, Int),
  Eof
}

effectset ConfigExceptions = {
  Exception[IoError],
  Exception[ParseError]
}
```

An ordinary exception family is a closed enum, and exhaustiveness comes from a
`match` on the payload. An `ExceptionKind` trait, open subclasses, and dynamic
downcasts are not part of the initial design. They will be added by a separate
ADR only if an open-world escape hatch is demonstrated to be necessary, for
example for FFI adapters.

### Decision: Option A (closed exhaustiveness) — #1344

The first item of #1344 was to choose between Option A and Option B.
**We take Option A (closed exhaustiveness). We do not take Option B (a
trait-bounded escape hatch).**

- **Option A**: an exception family is a closed enum. Each `E` is a separate
  row element, and a handler discharges only the exact kind. Payload
  exhaustiveness is provided directly by the enum's `match`.
- **Option B**: introduce a trait bound such as `ExceptionKind` and open
  `Exception[T]` as an existential-like entry point for `T: ExceptionKind`.
  This is open-world: exception types coming from FFI or plugins can be added
  after the fact.

Three points decide it.

1. **Option B is incompatible with the closed world of rows.** Both effectset
   normalization and the package contract hash depend on "the set of row
   elements is fixed at compile time" (ADR-0071). Opening it with a trait bound
   means the row element of `Exception[T]` is determined only by the
   instantiation at a call site, so what `decl_authorizes_effect` must compare
   against is not fixed until run time. This has the same shape as the hole
   #1340 closed, where "an instantiation of a generic effect slips past the
   check".
2. **The mechanism Option B requires duplicates one that already exists.**
   "Group several failure domains into one row" is already expressible as an
   effectset union (`effectset ConfigExceptions
   = { Exception[IoError], Exception[ParseError] }`). The only thing a trait
   bound would newly make writable is accepting *unknown* exception types, and
   that is the opposite of least privilege.
3. **A decision to open can be made later; a decision to close cannot.**
   Starting with Option A, an escape hatch can be added by a separate ADR once
   it is shown empirically to be needed. Starting with Option B, closing it
   after existing code has come to depend on the open world would be a
   breaking change.

The paragraph above — no `ExceptionKind` trait / open subclasses / dynamic
downcasts in the initial design — is therefore **the decision**, not a
presentation of both sides.

A `.vibex` `main` may keep an explicitly declared `Exception[E]` as a core
ambient effect. The runtime entry handler turns a declared typed exception into
a diagnosed unsuccessful process outcome and does not leak a raw Wasm exception
to the host.

## Relationship to WebAssembly exception handling

WebAssembly exception handling is a low-level control mechanism that defines
typed tags, payload values, `throw` / `throw_ref`, and `try_table` with
matching catches. It does not define source-level checked rows, effectset
unions, or enum exhaustiveness.

Wasm EH is therefore not the type-system foundation of `Exception[E]`, but a
lowering candidate for non-resumable transfer. vibe's linear/gc backends
already lower `Error::Throw` to a dedicated Wasm tag, which is consistent with
these semantics.

Whether multiple `E`s become "one tag per normalized `E`" or "a vibe exception
tag + type id + payload" at the ABI level is deferred as a backend/ABI choice.
Whichever is chosen must not change the checker's
`Exception[E1] ≠ Exception[E2]` or the entry boundary's diagnostic contract.

### Reconciliation (the "needs verification" item, resolved in #1344)

The Phase 3 implementation **does not expose the kind to lowering at all**.
`Error::Throw` / `Exception::Throw` / `Exception[IoError]::Throw` are all
identified as the same operation by `is_exception_throw_operation`
(core/exception_effect.vibe) and lower to the single existing abortive Wasm
tag. The regression lock is that fixtures/exception_typed_row.vibe actually
returns 42 (compiler_gate.sh 81).

The conditions under which "kind-specific statically, a single tag
dynamically" is sound are stated here.

- At run time, `handle .. with Exception[IoError]` catches **every** vibe
  exception. This is correct because the checker rejects the handle body if its
  row still carries any kind other than `Exception[IoError]`, not because the
  tag discriminates. In other words, **the exact-kind guarantee is entirely a
  property of the checker**; Wasm EH neither supports nor contradicts it.
- A throw whose payload kind does not resolve has kind `""` (erased). Only an
  erased declared label authorizes it: a row that names only kinds
  (`with Exception[K]`) refuses it, and so does a kinded handler arm (#2964,
  #3015, #2985). The one exception is a row that also carries an effect
  variable (`with Exception[K] + e`), where the erased requirement may be what
  `e` stands for. So a kinded row is a guarantee a caller can rely on.
- Whether to adopt WebAssembly typed tags / `try_table` is therefore **an
  optimization unobservable to source semantics**. Adopting them would let
  "does not catch" be expressed by the tag, but that only duplicates the
  checker guarantee above at run time; it provides no new guarantee. This
  implementation concretely backs the ADR's claim that a backend without EH can
  keep the current effect/evidence lowering.

Per-kind tags are actually needed only if we want to sort out, **dynamically**,
payloads whose kind the checker cannot resolve. That does not happen under
Option A's closed exhaustiveness (a payload whose kind is unknown cannot be
split by an enum `match` either), so there is no reason to pursue per-kind tags
at present.

References:

- [WebAssembly 3.0 control instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#syntax-instr-control)
- [WebAssembly 3.0 exception validation](https://webassembly.github.io/spec/core/valid/instructions.html#valid-throw)
- [Legacy exception-handling proposal](https://github.com/WebAssembly/exception-handling/blob/master/proposals/exception-handling/Exceptions.md)

## Compatibility and migration

During the migration, `Error` is treated as a compatibility alias for
`Exception[String]`. The payload shape and entry diagnostics of existing
`throw("message")`, `with Error`, and `handle ... with Error` are preserved.

1. **Phase 0**: pin down a Lean model of typed exception identity and
   exact-kind handlers. The existing ADR-0073 model remains the source of
   truth for the checked/ambient policy and the entry boundary.
2. **Phase 1**: introduce ADR-0071's `NormalizedEffectArguments` as the real
   representation of checker rows, distinguishing different instantiations of
   a generic effect.
3. **Phase 2**: introduce the reserved `Exception[E]` and the
   `Error = Exception[String]` alias. Consolidate the compiler's
   `"Error::Throw"` string checks into a normalized core exception predicate.
4. **Phase 3**: check the payload type of `throw(value)` and require
   `Exception[typeof(value)]` in the row. Add accept/reject fixtures for
   exact-kind handlers and effectset unions first.
5. **Phase 4**: migrate stdlib/compiler/docs to `Exception[E]` and deprecate
   the `Error` alias.
6. **Phase 5**: remove the compatibility alias. This is treated as an explicit
   breaking change.

Through Phase 2, the compiler source itself does not use the new syntax. Before
migrating the compiler source in Phase 3 and later, update the seed compiler
and the stage2/stage3 fixpoint.

### What `Error` means — a correction to this ADR's original text

Phase 2 above says `Error = Exception[String]` alias. **The implementation does
not do that. `Error` is an ERASED exception row that carries no kind.**

The reason is #786. Existing code throws suberror values such as
`throw(KeyInvalid("x"))` **under a plain `with Error`**, and there are hundreds
of them. Defining `Error` as `Exception[String]` would turn every one of those
throws into `missing { Exception[KeyInvalid] }`. A migration whose first step
demands rewriting the entire existing codebase is not a workable ordering.

So the implemented `Error` is **the weakest label, compatible with every kind**
(`exception_kinds_compatible`, core/exception_effect.vibe). It works in both
directions:

- Declared side erased (`with Error`): authorizes a throw of any kind. This is
  why existing code needs no change.
- Required side erased (a throw whose payload kind does not resolve, a callee
  or callback declared `with Exception`): authorized by an erased declared
  label only. It used to be authorized by every `Exception[K]` too; that let
  `fn relabel(f: () -> Int with Exception) -> Int with Exception[String]`
  claim a kind it did not keep, and a kinded handler around it read an Int as
  a String (#3015). `declared_exception_label_covers` owns the rule.

As a result, this feature is **provably additive with respect to existing
code**: a declared row either (a) carries an erased exception label
(= compatible with every kind), (b) carries no exception label at all
(= already rejected with the same diagnostic before the change), or (c) carries
a kinded label (= a spelling that does not exist in the codebase), and only (c)
can newly fail.

A consequence is that **Phase 5 (removing the alias) is not a mere rename but
a genuine breaking change**. Removing `Error` removes the escape hatch that
"allows a throw of unknown kind", and it gets closer to safe the wider the
resolution coverage below becomes (local binders and annotated parameters were
closed in a follow-up; pattern binders and field projections are resolved by
the typed channel of #3017).

## Implementation status (Phase 3)

What landed in #1344:

- Row checking of `with Exception[E]` (`decl_authorizes_effect`,
  checker/checker_effects.vibe). `Exception[E]` is **explicitly excluded**
  from #1340's "instantiation-independent v1 that compares by base name"
  (`row_base_membership`) — otherwise, by the same rule as
  `State[Int] ~ State[String]`, `Exception[IoError] ~ Exception[ParseError]`
  would hold, and the one guarantee of typed exceptions would vanish.
- `handle .. with Exception[E]` (parser: `collect_row_item_targs` is also used
  in the `with` clause). Arms are qualified as `Exception[E]::Throw`, and
  `collect_handle_effects` publishes that as a discharge label.
- `effectset { Exception[A], Exception[B] }` — the union goes through the
  existing expansion.
- Assignment compatibility of fn types (`row_contains_label` /
  `effect_label_base_name`): passing an `Exception[A]` value into an
  `Exception[B]` slot is "effect would be dropped". Conversion to and from
  erased is allowed in both directions.
- Entry boundary: even when `main`'s row declares a kinded exception,
  `lc_row_has_error` picks it up and turns it into a diagnosed process failure
  (`lc_wrap_entry_error_boundary`).

**Coverage of throw payload kind resolution**: the effect pass is an AST walk
without typing, so the payload's kind is first recovered from syntax and the
module environment. When syntax cannot answer, it uses the payload type the
checker recorded for each throw site (`typed_throw_kind_record`, keyed by the
`throw` offset plus a payload fingerprint, #3017). This resolves results of
builtin calls, unannotated locals, pattern binders, field projections, and
formals inside a generic body (`Array[T]`). If the checker's type is still an
inference variable, the kind stays `""`. What syntax alone resolves:

| payload | kind |
| --- | --- |
| `throw("boom")` / `throw(1)` / `throw(1.5)` / `throw(true)` | the literal's type |
| `throw(NotFound("cfg"))` | the constructor's result type |
| `throw(Eof)` | nullary constructor |
| `throw(make_err(x))` | the top-level function's return type |
| `throw(Wrapped::{ .. })` | the struct literal's type |
| `let e = NotFound("cfg"); throw(e)` | from the initializer (recursively) |
| `fn f(e: IoError) { throw(e) }` | head name of the parameter annotation |
| `match r { Err(e) => throw(e) }` | the checker's type (pattern binder, #3017) |
| `throw(r.cause)` | the checker's type (field projection, #3017) |

Local binders were invisible in #1344's v1, but **the shape produced by the
#1324 migration (`let e = ..; Err(e)` → `let e = ..; throw(e)`) was exactly
that**, so a follow-up closed it. The implementation threads a `(name, kind)`
scope through the perform walk, using the same mechanism as `ov_names`/`ov_effs`,
which already ride the walk the same way (`throw_kind_bind*`,
checker/checker_effects.vibe).

An unknown kind falls back to "accepted by any exception row", so this gap
**produces only missed detections, never false positives**. To preserve that
property, **binders that cannot be resolved are also put in scope explicitly
with kind `""`**: when a name is not in scope, lookup falls through to the
module table, so without that entry a top-level binding of the same name would
answer in place of the local (which would be a false positive). This covers
pattern binders, `for` elements and indices, `loop` params, unannotated
parameters, `let rec`, and applied locals (the scope holds the kind of the
value, not the kind of the result).

For the same reason, the "full OperationRef normalization of row elements"
that #1340 left open has been done early only for `Exception[E]`; other generic
effects (`State[Int]` etc.) remain on the base-name comparison v1.

### No kind at run time (2026-08-03, surfaced in PR #1372 review)

The throw-site kind resolution above (#1377) is about **compile time**. What
follows is a separate, independent limitation on the runtime side.

"Erased is compatible with every kind", above, is **only a static discipline**.
The runtime emits no kind and keeps a single abortive tag, so **an erased
`handle { .. } with Error { Throw(msg) => .. }` also catches a typed
`Exception[E]` throw, and `msg` receives an enum value**. The static type of
`msg` is `CtUnknown`, so code that uses it as a `String` passes type checking.

With #1324 slice 1, `TaskGroup::run` / `TaskHandle::join` / `Sender::send`
started throwing enum payloads, and two existing String-only sinks actually hit
this (both confirmed by measurement):

| sink | symptom |
| --- | --- |
| entry boundary (`lc_wrap_entry_error_boundary`) | interpreted the payload as a packed `(ptr<<32)\|len`, and **dumped an entire data segment to stderr** |
| `TaskGroup::spawn` child runner (`cell.fail_msg = msg`) | `String::length(m)` of `TaskError::Failed(m)` was **2129** (a raw pointer) |

**First-stage mitigation (PR #1375)**: both now route the payload through
`__to_string`. ADR-0058's int/string test
(`64 <= ptr && ptr + len <= memory_size`) is the identity on a real string and
returns a bounded decimal otherwise, so arbitrary memory is no longer read.
However, **a non-String payload became "a bare decimal that looks like a
message", and its content was lost**.

### kind side channel (#1374, 2026-08-03)

**The fix in place**: the throw site records the payload's static type name
into a one-slot module cell, and the handler side reads it with `__exn_kind()`.
**The payload representation does not change at all**, so every existing
handler keeps working unchanged — purely additive.

| layer | implementation |
| --- | --- |
| write | `desugar_trait_dicts` inserts `Array::set(__exn_kind_cell, 0, "<Kind>")` immediately before `perform <Exception>::Throw(v)`. The kind is resolved by codegen's `infer_arg_type_name`, and if it cannot be resolved `""` is **always** written (so the previous throw's kind does not linger) |
| read | `__exn_kind() -> String` is a checker-only intrinsic (`lookup_exn_kind` in `checker/builtins_misc.vibe`). Desugaring lowers it to a cell read, so neither backend has any new emission |
| cell | `let __exn_kind_cell = ["", ""]` is appended only to programs that need it (slot 0 = kind, slot 1 = the rendered message of #1392 slice 3). The "initialized once, same identity, mutation visible" property of module-level lets is already pinned by `fixtures/module_let_memo_test.vibe` |

**Why not a wasm global or a new builtin**: keeping the cell as ordinary vibe
AST means the implementation does not fork between the two backends, linear
and wasm-gc. No new global index allocation and no memory layout change are
needed.

**Why one slot is enough**: the interval from the write to the handler's read
is a single abortive unwind, and no other guest code runs within it:

- `Error` is non-resumable (#640), so control never returns to the throw site,
  and no code other than the handler runs after the write.
- ADR-0076's task pump re-enters a task only at suspend points, never
  mid-unwind. A sibling task cannot interleave a write.
- For a nested throw inside a handler arm, the inner one writes first and the
  inner handler reads first — the correct innermost-wins order.

A handler that stores the payload and inspects the kind **later** is outside
this interval, so read `__exn_kind()` inside the arm. Both sinks do so.

**Sink behavior**:

| kind | output | reason |
| --- | --- | --- |
| `String` / `Int` | result of `__to_string` (identical to before #1374) | ADR-0058's test is faithful |
| `""` (unresolvable) | result of `__to_string` | it may be a String; keeps #1375's conservative behavior |
| other | rendered message, or `<Kind>` if there is none | see #1392 slice 3 below |

regression lock:

- `fixtures/exn_kind_side_channel_test.vibe` — directly asserts the kind for
  enum / String / Int / struct / unresolvable / nested / consecutive throws
- the pair `fixtures/err_entry_boundary_typed_payload.vibe` (`<Boom>`) and
  `fixtures/err_entry_boundary_string_payload.vibe` (verbatim) +
  compiler_gate 44c

### message side channel (#1392 slice 3, 2026-08-03)

The remaining limitation of the kind side channel was that "the **value** of a
non-String payload cannot be printed". We had written that this needed
"per-kind formatting", but **that dispatch cannot, in principle, be solved on
the handler side**: the `m` of an erased `with Error { Throw(m) => .. }` is
statically `CtUnknown`, so neither `T::to_string` nor a `[T: Show]` witness can
be resolved there. Adding trait dispatch (giving `Show` a method) would not
rescue this point either.

**The only place where the type is known is the throw site**. So rendering is
done at the throw site too, and the resulting String is placed in slot 1 of the
same cell as the kind.

| layer | implementation |
| --- | --- |
| write | at the same place as the kind write. Runs the interpolation renderer of #1392 slices 1/2 on the payload temp (`interp_show_target` → `T::to_string`, otherwise the `Option`/`Result` expansion of `interp_expand`) |
| read | `__exn_message() -> String`. The same kind of checker-only intrinsic as `__exn_kind()` |

**Write only when a structural renderer is found**. If none is found, write
`""` to clear the slot. This is the crux: the reader can only apply the simple
rule "trust it if non-empty" — `__to_string`'s pointer decimal is a perfectly
ordinary non-empty string, so writing it would make an enum without
`derive(Show)` come out as `192` instead of `<NoShow>` (worse than #1374).
Whether the rendering is faithful is a **static** property of the throw site,
so the decision is made there as well.

Measured at the sinks:

| payload | #1374 | #1392 slice 3 |
| --- | --- | --- |
| `Failed("io")` (`derive(Show)` enum) | `<AppError>` | `Failed(io)` |
| `"plain message"` | verbatim | verbatim (unchanged) |
| `Bang(5)` (no renderer) | `<NoShow>` | `<NoShow>` (unchanged) |
| `Some(7)` | `<Option>` | `Some(7)` |
| `Failed("child blew up")` from a `TaskGroup` child | `<TaskError>` | `Failed(Failed(child blew up))` |

The doubled `Failed` in the last row is correct: the outer one is
`TaskHandle::join`'s wrapper and the inner one is the child's own payload. In
#1374 this inner part was lost entirely.

**Only renderers generated by this pass are called** (#1398 review, Codex P1).
In an interpolation `"\{v}"` the user wrote the call, so any `T::to_string` may
be used, but the call at the throw site is **synthesized**, and it

- runs **every time**, even if no handler reads the message
- is inserted after type checking, so its effects never appear in the throwing
  function's checked row
- if the formatter itself throws, it replaces the original exception or
  recurses during formatting

Measured: a `Boom::to_string` containing `println` ran for a `throw(Bang(1))`
whose only handler ignored the payload. Derived renderers are structural,
total, and effect-free, so restricting the eager path to them removes this
danger (`dtd_derived_renderers`).

**Why the `""` sentinel is sound** (#1398 review, Codex P2). Every renderer
reachable from here produces non-empty output by construction: a derived struct
renderer starts with the type name (`P { ..`), a derived enum renderer is the
variant name itself, and the wrapper expansions are `Some(..)` / `Ok(..)` /
`Err(..)` / `None`. A user-defined formatter for which "returning the empty
string is correct" is never called from here in the first place, because of
the P1 restriction above.

regression lock:

- compiler_gate 87 — four cases: `derive(Show)` enum / String / no renderer /
  hand-written formatter. The third pins "no worse than #1374", the fourth pins
  "a hand-written formatter runs only in interpolation"
- `@vibe/concurrent`'s "a typed child throw is reported by kind" was updated
  from `Failed("<SendError>")` to `Failed("Closed")` (the variant name is what
  a caller wants to switch on)
- `suspend_test.vibe`'s "result_wait propagates a cancelled sibling to the
  awaiter" — #1324 slice 2, which moved the suspend lane to `Exception[E]`,
  depends on this channel. It asserts that a cancelled sibling's `Cancelled`
  arrives still as the variant name through the CPS-split callee's throw →
  erased runner arm → `fail_msg` → `join`'s re-throw

## Integration order with #1324 (removing Result)

#1324 proposes dropping `Result` and unifying on exceptions; it builds on the
completed form of this ADR. **The order is fixed as #1344 → #1324**, because:

1. `Result[T, E]` can be dropped only after the failure type `E` can be
   expressed in the row. Before Phase 3, `Error`'s payload was effectively a
   String, so replacing `Result[T, ParseError]` with `with Error` lost the
   information in `E`. Now `with Exception[ParseError]` carries the same
   information, so the replacement loses nothing.
2. Code that returned `Result` often carries the failure value around in a
   local binding before returning it (`let e = ...; Err(e)`), and converting
   that to a throw gives `throw(e)` — exactly the case that fell into
   unknown kind in #1344's v1. **Because the main shape of the migration was
   one that escaped checking, a #1344 follow-up made local binders and
   annotated parameters resolvable** (table above). The remaining unresolvable
   shapes (pattern binders / field projections) are not the main shape of the
   migration, so they can stay gradual.
3. Phase 4 (migrating stdlib/compiler to `Exception[E]`) touches the same code
   as #1324, so it is done together with #1324 to avoid rewriting it twice.

### Migration progress, and a constraint from the bundle (2026-08-03)

| slice | target | row |
| --- | --- | --- |
| 1 (#1372) | 5 stack-driving functions in `@vibe/concurrent` | `Exception[TaskError]` and others |
| 2 (#1401) | 3 suspend-lane functions in `@vibe/concurrent` | `Exception[SendError]` / `Exception[TaskError]` |
| 3 | `@vibe/json` (11 accessors + `parse` + `parse_message` + `RpcMessage::parse`) | **erased `Error`** |

**Only slice 3 uses erased `Error`, because of a bootstrap constraint**. The 7
files of `@vibe/json` are listed in `compiler_sources_manifest.tsv` and are
included in the compiler's merged bundle. `validate_module_source_compiles` in
`scripts/generate_bundle.sh` (#979 sticky-failure guard) compile-checks
candidate module sources with the **pinned seed compiler**, but the current
seed (`vpkg-structured-header-2026-07-27`, source commit `08c4c58`) predates
ADR-0085's `Exception[E]` and **cannot parse bracketed labels**:

```
vibe: uncaught error: expected ',' or '}' in effect list
```

It reproduces in both positions, `fn` declarations and closure literals (the
current stage2 accepts both). This is exactly the rule CLAUDE.md /
docs/internal/operations/bootstrap.md describe: "when the compiler source
itself uses new syntax, do the bootstrap bump first".

Since the payload is a `String`, erased `Error` **loses no information** — as
ADR-0085's migration section says in calling `Error` a compatibility alias for
`Exception[String]`, ADR-0058's test is the identity on a real string, so
`handle .. with Error { Throw(msg) => msg }` receives the actual message. What
is lost is only **static precision** (the binder becomes `CtUnknown`, so the
checker does not stop code inside that handler from using `msg` as something
other than a String).

**follow-up**: after the bootstrap bump, tighten `@vibe/json`'s rows back to
`Exception[String]`. The rest of #1324 (the `@vibe/compiler` body itself,
deleting prelude `result.vibe`) also goes entirely through the bundle, so **the
bump is a prerequisite for those as well**.

## Formal contract

The executable source of truth for typed identity:

- `formal/VibeFormal/Effect/ExceptionPolicy.lean`
- `formal/VibeFormal/Proofs/ExceptionPolicyCorrect.lean`

The model uses `ExceptionKind` as a minimal stand-in for a normalized `E` and
verifies the following.

- An escaping `Exception[E]` always leaves a row requirement for the exact `E`.
- `handle Exception[E1]` does not catch `Exception[E2]` (`E1 ≠ E2`).
- A capability requirement is not removed by a typed exception handler.
- A broken checker that erases kind identity has a counterexample in which it
  allows an empty row while letting an exception of another kind escape.

During the migration, the entry boundary guarantee that "a declared exception
is turned into a process failure" reuses ADR-0073's `ErrorPolicy.lean` /
`ErrorPolicyCorrect.lean`. Generalizing to a typed entry outcome happens after
Phase 2's runtime representation decision.

## Consequences

- Least privilege and API compatibility diffs per exception family become
  possible.
- There is no Java-style open subclass hierarchy; effectset unions and
  closed-enum exhaustiveness are reused.
- Current codegen special-cases `Error::Throw` with many string comparisons.
  Adding only an alias and renaming in bulk would miss branches, so
  consolidation into a normalized predicate is the migration gate.
- The state of Wasm EH support does not change source semantics. A backend
  that cannot use EH may use the current effect/evidence lowering or an
  equivalent host boundary lowering.

## Rejected / deferred alternatives

- **Bulk-renaming only the name `Error` to `Exception`**: the payload type and
  row identity stay String, so #1136's per-type exceptions are not solved.
- **Subclass hierarchy**: rejected because it adds a subtype/dispatch rule
  separate from effectset normalization.
- **Treating the Wasm tag as the source exception type itself**: a tag is a
  lowering identity and does not replace source rows/exhaustiveness.
- **Making every exception a single erased row element**: the formal model's
  cross-kind witness shows the unsoundness of a requirement disappearing under
  a handler for another kind.
