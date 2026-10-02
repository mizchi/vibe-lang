# ADR-0085: `Exception` — a checked, typed, non-resumable effect

Status: accepted (#944, #1344). This document also carries ADR-0073 (the
exception row is fully checked, and the entry boundary turns an escaping
exception into a diagnosed failure), which it absorbed.

Related: ADR-0050 (`handle` is the one handler), ADR-0071
([effectset.md](effectset.md)), ADR-0076
([effect-evidence-passing.md](effect-evidence-passing.md)), ADR-0084
([effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md)), ADR-0088
(`allows` on entry points), #626, #939, #944, #1136, #1324, #1344, #1461,
#1501.

The user-facing description is the cheatsheet's "Error boundary", "Typed
exceptions" and "suberror" sections
([cheatsheet.md](../../user/reference/cheatsheet.md)).

## Context

- **Unchecked exceptions made the row meaningless.** To ease the selfhost
  migration, #626 had exempted the exception effect from transitive checking,
  so an exception could escape a function that declared nothing. A row on a
  function type, in an effect-polymorphic signature or in a package contract
  then promised nothing, and higher-order code had no consistent answer for a
  function value that may throw (#939).
- **One payload type could not tell failures apart.** The payload was in
  practice a `String`, so an I/O failure and a parse failure had the same row
  and the same handler. Adding a subclass hierarchy for typed exceptions would
  need a subtyping and dispatch mechanism next to effectset normalization,
  handler exhaustiveness and contract hashes; generic effect identity already
  gives distinct row elements without one.
- **`Result` left the language** (#1324). Failure travels in the row
  (`fn f(..) -> T with Exception[E]`), the success value flows on, and the
  place a `handle` sits is the boundary where a caller chooses to recover.

## Decision

### A checked, non-resumable effect

- `throw(x)` is `perform Exception::Throw(x)`. It is call-form only
  (`throw x` is refused, #2265); the parser desugars it and the printer
  re-sugars it, so both spellings are one requirement.
- A function that throws, or calls a function whose row carries `Exception`,
  either declares `Exception` in its own row or discharges it with a `handle`.
  The requirement propagates through calls like any other effect.
- A function value carries the row in its type. A function that may throw
  cannot be passed where a row-less callback is expected; a pure function can
  be passed where one that may throw is allowed.
- The row is surface. Adding `Exception` to a public function widens its
  effect surface and is a breaking change.
- `Exception` is **non-resumable** and the only abortive effect: in a `Throw`
  arm, `resume` is a checker error, and the arm's value is the value of the
  whole `handle`.
- An empty row means no exception escapes. It does not mean termination:
  divergence, a Wasm trap, an assertion failure and resource exhaustion are
  outside the row model.

Checking is on by default. `VIBE_CHECK_ERROR_ROW=0` is a temporary opt-out for
code that has not been annotated, kept in
`lib/@vibe/compiler/cli_adapter_cli_main_with_lanes.vibe`. It does not touch
the separate rule for a builtin whose own declared row carries the exception
effect.

### Typed kinds

The core effect behaves as a reserved generic effect:

```text
effect Exception[E] {
  Throw(E) -> Nothing      // "never returns normally"
}
```

- `throw(value)` requires `Exception[K]`, where `K` is the static type of
  `value` (its *kind*).
- **Distinct kinds are distinct row elements.** `Exception[IoError]` neither
  authorizes nor discharges `Exception[ParseError]`; throwing a kind the row
  lacks is `missing { Exception[ParseError] }`.
- **The bare `Exception` is the erased spelling**, compatible with every kind
  in both directions: `with Exception` allows any throw, and an erased
  `handle .. with Exception` catches kinded throws too
  (`exception_kinds_compatible` in
  `lib/@vibe/compiler/core/exception_effect.vibe`).
- **A family is a closed enum, or an `effectset` union.** A braced `suberror`
  (or an `enum`) with one constructor per member is one kind, caught by one
  arm with an exhaustive `match` on the payload. An effectset of kinds
  (`effectset IoErrors = { Exception[NotFound], Exception[Denied] }`) is for
  rows: it lets a function declare `with IoErrors`, but no handler catches one
  of its kinds while letting the other propagate.
- **`suberror` is sugar** for an enum used as a kind (#2983).
  `suberror NotFound(String)` declares the type `NotFound` with one
  constructor; the braced form declares a type with several. Payloads are
  positional.
- `Exception[K]` requires `K` to be a type in scope, in a row and in a handler
  arm; an undeclared name or an effectset name is refused. A kind may not name
  a type parameter of its own declaration (`with Exception[T]`, #3002): a row
  is not substituted at a call site. Kinds are compared through the checker's
  resolution of each spelling, so a type alias and its target are one kind
  (#3033).

**Handler rules.**

- A **kinded arm is strict** (#2985). At run time
  `Exception[K]::Throw(e) => ..` catches every exception its body raises, so
  the checker allows the body to raise only `K`. An erased or unresolved throw,
  a callee declared with the erased `Exception`, and a throw of another kind
  are all refused under a kinded arm. A closure literal handed straight to a
  callee is judged against the row the callee's parameter declares; an erased
  `handle .. with Exception` nested inside is its own catch-all boundary.
- A kinded arm binds its payload at the kind's type (#2963):
  `Exception[IoError]::Throw(e)` gives `e : IoError`. The erased
  `Exception::Throw(m)` binder is untyped, since it may receive any kind.
- A handle has **at most one exception arm**: the channel carries no kind and
  only the first arm would be compiled, so two kinded arms side by side are
  refused. Match on the payload inside one arm, or nest handles.

The decision is closed exhaustiveness (#1344's "Option A"). An open
`ExceptionKind` trait, open subclasses and dynamic downcasts are not part of
the design: a trait-bounded `Exception[T]` would make a row element depend on
call-site instantiation, which effectset normalization and contract hashes
cannot handle (the hole #1340 closed for generic effects); an effectset union
already expresses "several failure domains"; and opening a closed design later
is additive, while closing an open one is breaking.

### The erased row is not `Exception[String]`

(Cited from `lib/@vibe/compiler/core/exception_effect.vibe` as
"`Error` の意味", the meaning of the erased spelling, then written `Error`.)
The erased `Exception` is **kind-erased**, strictly weaker than every kinded
label and compatible with all of them; it is not an alias of
`Exception[String]`. Code throws suberror values under a plain erased row
(`throw(KeyInvalid("x"))`, #786), and a `String`-kinded reading would have
refused every one of those throws. Because the erased label is compatible in
both directions, introducing kinds was additive for existing code: a row with
the erased label accepts every kind, a row with no exception label was refused
before and after, and only a row that names a kind — a spelling no code used
then — could start failing. The flip side is that the erased spelling is a
real escape hatch, not a rename target: removing it would remove "a throw of
unknown kind is allowed" from the language.

### How far a throw's kind resolves

The exception check is an AST walk without full types, so it rebuilds a
payload's kind from syntax and the module environment:

| payload | kind |
| --- | --- |
| `throw("boom")` / `throw(1)` / `throw(1.5)` / `throw(true)` | the literal's type |
| `throw(NotFound("cfg"))` | the constructor's result type |
| `throw(Eof)` | a nullary constructor |
| `throw(make_err(x))` | a top-level function's return type |
| `throw(Wrapped::{ .. })` | the struct literal's type |
| `let e = NotFound("cfg"); throw(e)` | the initializer (recursively) |
| `let e: IoError = v; throw(e)` | the annotation's head name (#2964) |
| `fn f(e: IoError) { throw(e) }` | the parameter annotation's head name |
| `match r { Err(e) => throw(e) }` | **unresolved** (pattern binder) |
| `throw(r.cause)` | **unresolved** (field projection) |

Local binders are carried as a `(name, kind)` scope through the walk
(`throw_kind_bind*` in `lib/@vibe/compiler/checker/`). A binder the walk cannot
resolve is still put in scope, with kind `""`, so that a same-named top-level
binding does not answer for it. Pattern binders, `for` elements and indices,
`loop` parameters, unannotated parameters, `let rec`, and an applied local
(the scope records a local's value kind, not its result kind) are all of this
kind.

**An unresolved kind is gradual only under the erased row** (#2964, #3015). A
row that names kinds and not the erased `Exception` promises exactly which
kinds leave the function, so it refuses an unresolved requirement: a throw of
an unresolved payload, a call to a callback typed `with Exception`, and a call
to a callee declared `with Exception`. The message names the edits: annotate
the payload (`let e: K = ..`), give the callback or callee a kinded row, or
declare the erased `with Exception`.

### Spelling: `Error` is retired

`Error` was the effect's earlier name. As a row item and as a handled-effect
name it is a parse error (#1461, #1501) — `` `Error` was retired as an effect
spelling in #1461 `` (`lib/@vibe/parser/parser_smoke_test.vibe`) — and
`vibe fmt` rewrites both places to `Exception`, token by token, so it converts
source the parser no longer accepts. The operation qualifier
`perform Error::Throw(x)` is still accepted: it names an operation the runtime
dispatches, not a row (measured: a function declared `with Exception` whose
body is `perform Error::Throw("x")` checks clean on the committed seed). Inside
the compiler every spelling check goes through
`lib/@vibe/compiler/core/exception_effect.vibe`, which stores and prints only
`Exception`.

### Entry boundary

An entry point may grant the exception effect: `fn main allows Exception`
(`allows` is ADR-0088's spelling for an entry row). An entry whose row carries
any exception spelling gets an outermost handler
(`wrap_entry_exception_boundary`,
`lib/@vibe/compiler/normalize/desugar/exceptions.vibe`). An escaping exception
writes `vibe: uncaught error: <text>` to stderr and exits with status 1
(#2976), with a trap as the fallback for a host whose exit call returns; a raw
Wasm exception never reaches the host. The text is the payload itself when its
kind is `String`, `Int` or unresolved; otherwise the payload rendered at the
throw site, or `<Kind>` when the type has no derived renderer
(`fixtures/err_entry_boundary_string_payload.vibe`,
`fixtures/err_entry_boundary_typed_payload.vibe`).

An entry that does not grant `Exception` is checked like any function: a throw
reaching it must be handled first. A program that wants failure as a value
returns its own enum.

## Runtime representation

Kinds stop at the checker. `Exception::Throw`, `Exception[K]::Throw` and the
`Error::Throw` qualifier are one operation for codegen
(`is_exception_throw_operation`) and lower to one abortive Wasm exception tag;
a handle lowers to `try_table` with a catch on it (ADR-0076, "Exception").

"Statically by kind, dynamically one tag" is sound because:

- a kinded handler catches every exception at run time, and is right to,
  because the checker allows its body to raise only that kind (the strict-arm
  rule above);
- the gradual hole is confined to the erased row, where any kind may pass and
  any kind may be caught, so the runtime still matches the declaration.

Per-kind Wasm tags would therefore only replicate a guarantee the checker
already gives; they become useful only for sorting payloads whose kind the
checker could not resolve, which closed exhaustiveness does not need. The
per-kind ABI (one tag per kind, or a vibe tag plus a type id) is deferred; it
must not change `Exception[E1] ≠ Exception[E2]` or the entry diagnostic.

### Kind and message side channel

An erased arm's binder has no static type, so it cannot render a typed payload
or tell it from a string. The throw site, where the type is known, records it:

| layer | implementation |
| --- | --- |
| cell | `let __exn_kind_cell = ["", ""]`, appended only to programs that need it: slot 0 is the payload's static type name, slot 1 its rendered message |
| write | immediately before `perform <Exception>::Throw(v)`, the desugaring stores the kind (`""` when unresolved, so no earlier kind survives) and the rendered message |
| read | `__exn_kind()` and `__exn_message()`, checker-only intrinsics that lower to cell reads, with no new emission in either backend |

One slot is enough: between the write and the handler's read there is a single
abortive unwind; an exception does not return to its throw site; the
concurrent task pump re-enters a task only at a suspend point, never
mid-unwind; and a throw inside an arm is written and read innermost first. A
handler that keeps the payload and inspects it later is outside that window
and must read the channel inside the arm.

The message is written only when a renderer **generated by the compiler**
exists for the payload's type (a `derive(Show)` renderer, tracked in
`dtd_derived_renderers`, or the built-in `Option` expansion), and is cleared
to `""` otherwise. A hand-written
`T::to_string` is not called: the call would run on every throw whether or
not anyone reads it, its effects would appear in no checked row, and a
formatter that throws would replace the original exception. Derived
renderers are total, effect-free and never return `""`, which is what lets a
reader trust any non-empty message. The entry boundary above and the
`@vibe/concurrent` child runner are the two readers
(`fixtures/exn_kind_side_channel_test.vibe`).

## WebAssembly exception handling

Wasm exception handling — typed tags, payload values, `throw` / `throw_ref`,
`try_table` with matching catches — is a control mechanism, not a type system:
it defines no checked row, no effectset union and no enum exhaustiveness. It
is how a non-resumable transfer is lowered, not the reason `Exception[E]` is
sound, and a backend without it could lower the same semantics through the
effect machinery or a host boundary.

## WIT boundary

An `Exception[E]` row does not project to WIT `result<T, E>` today; a
fallible component export converts once, in its body, into the
`@vibe/wit_runtime` `Result`. See
[effect-wit-mapping.md](effect-wit-mapping.md).

## Formal contract

The executable references are Lean models in `formal/` (see
[formal/README.md](../../../formal/README.md)).

- `formal/VibeFormal/Effect/ErrorPolicy.lean`,
  `formal/VibeFormal/Proofs/ErrorPolicyCorrect.lean`,
  `formal/VibeFormal/Proofs/ErrorPolicyExamples.lean` — the checked policy.
  The model distinguishes normal return, a throw, a capability perform, a
  transitive call, sequencing, a handler and the entry boundary. Under the
  checked policy an empty row returns normally (`checked_empty_returns`), and
  an entry that grants only the exception effect either succeeds or fails with
  a diagnosed error (`checked_error_only_entry_succeeds_or_fails`). The
  rejected ambient policy is kept as a comparison witness (an empty-row term
  that raises), and a broken checker that drops capability requirements is
  kept as a negative witness (an empty row admitting an `Fs` operation).
- `formal/VibeFormal/Effect/ExceptionPolicy.lean`,
  `formal/VibeFormal/Proofs/ExceptionPolicyCorrect.lean` — typed identity,
  with `ExceptionKind` standing in for the normalized `E`: an escaping
  `Exception[E]` keeps the exact `E` requirement
  (`raised_requires_exception`), a handler of `E1` does not catch `E2`
  (`handler_does_not_catch_other_kind`), a capability requirement survives a
  typed handler (`performed_requires_capability`), and a checker that erases
  kinds accepts an empty row while another kind escapes
  (`broken_cross_kind_handler_is_unsound`).

The model's handler catches only its kind; the implementation's catches
everything and lets the strict-arm rule refuse every body that could raise
another kind. On the programs the checker accepts, the two agree.

**What is proved, and what is not.** Lean proves these properties of the
abstract terms, the checked policy and the entry boundary. It does not prove
that the checker agrees with the model on every syntax, import and
higher-order path, nor the Wasm unwind, the diagnostic text or
finalizer-exactly-once. The correspondence is held by the regression
fixtures (`fixtures/exception_typed_row.vibe`,
`fixtures/err_exception_kind_mismatch.vibe`,
`fixtures/exception_family_catch_test.vibe`,
`lib/@vibe/compiler/tests/checker_exception_kind_test.vibe`).

## Consequences

- An empty row again means that no exception escapes, though not totality.
- Exception rows propagate through the compiler's own source and through
  every higher-order API, which therefore relies on latent-effect checking and
  row polymorphism.
- Least privilege and API compatibility work per exception family: a
  function can promise `Exception[IoError]` and nothing else.
- The compiler decides "is this the exception effect" in one module
  (`exception_effect.vibe`), not by comparing strings at each use.

## Rejected alternatives

- **Renaming `Error` to `Exception` and nothing else** — keeps a `String`
  payload and one row element, and does not solve #1136's typed failures.
- **A subclass hierarchy** — needs a subtyping and dispatch rule next to
  effectset normalization.
- **Treating the Wasm tag as the source exception type** — a tag is a
  lowering identity, not a row or an exhaustiveness check.
- **A single erased row element for every exception** — the formal model's
  cross-kind witness shows a handler of one kind discharging another's
  requirement.
- **Keeping the ambient (unchecked) policy of #626** — exceptions escape empty
  rows (the ambient comparison witness above).

## Open

- Kinds of pattern binders and field projections do not resolve; they stay
  gradual under the erased row.
- The `VIBE_CHECK_ERROR_ROW=0` opt-out has not been retired.
- The per-kind runtime ABI is deferred, as above.
