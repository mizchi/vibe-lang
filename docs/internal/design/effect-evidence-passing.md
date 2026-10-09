# ADR-0076: Effect handlers by evidence passing and suspend CPS

Status: accepted (#817). Every `handle` compiles to an evidence-dictionary
call, a suspend-CPS state machine, or (for `Exception`) a Wasm exception
handler. The replay engine is gone (addendum 34, V2).

Related: ADR-0050 (`handle` is the one handler), ADR-0068 (concurrency,
[concurrency.md](concurrency.md)), ADR-0071 ([effectset.md](effectset.md)),
ADR-0085 ([exception-effect.md](exception-effect.md)), ADR-0089
([wasip3-effect-alignment.md](wasip3-effect-alignment.md)), ADR-0114 (a
declared-effect arm resumes explicitly), #817, #942, #1536.

The user-facing contract — which shapes compile and what the diagnostics say —
is the cheatsheet's "User-defined effects (algebraic)" and "A `handle` that
type-checks can still fail to compile" sections
([cheatsheet.md](../../user/reference/cheatsheet.md)). This document is the
design behind them.

## Context

The selfhost compiler originally compiled every `handle` by **replay**: the
handled body ran inside a wasm `loop`, each `perform` unwound to the handler
while a fixed 128 KiB per-effect region memoized the values already resumed,
and every `resume(v)` re-ran the body from its first statement. Two defects
followed from that design rather than from a bug in it:

1. **Side effects in the body ran once per resume.** A body that performed
   twice printed its prologue three times, and a `let mut` counter updated
   before the performs was added into the result repeatedly
   (`eval/lang-review/findings/2026-07-12-r2.md`, finding M2; pinned by
   `fixtures/effect_handle_replay_corruption.vibe`).
2. **A ceiling of about 16K performs per handle**, the size of the memo
   region.

There was no fast path to generalize: the tail-resumptive inliner of ADR-0021
existed only in the retired MoonBit host, so in the selfhost compiler every
perform, including the ones a direct call could serve, went through replay.

## Decision

Adopt generalized evidence passing in the style of Koka (Xie & Leijen, ICFP
2021), with a selective CPS lowering for the handlers that keep their
continuation as a value.

- **A handled body runs exactly once.** Nothing re-executes it; there is no
  per-effect reserved region and no perform ceiling.
- **A declared-effect arm takes one of two shapes**, decided from its text:
  - every tail of the arm ends in `resume(v)` or leaves the arm with `return`,
    `throw(..)`, `break` or `continue` (ADR-0114, #2969). A direct `resume(v)`
    is legal only as the arm's last expression (#942), so such an arm is
    **tail-resumptive**: it lowers to an entry of an evidence dictionary
    whose return value is the resumed value;
  - the arm refers to `resume` as a **value** (`let k = resume`,
    `Array::push(conts, resume)`). Such an arm keeps a **first-class one-shot
    continuation**, and the handle lowers to suspend CPS.
- **`Exception` arms abort** (ADR-0085). They are the only abortive arms and
  lower to Wasm exception handling.
- **A handle that no lowering can follow is a compile error**, reported by
  `vibe check` / `vibe build` / `vibe run` / `vibe test` alike. There is no
  silent fallback.
- The lowerings are **AST-to-AST passes that run before codegen** and only
  introduce ordinary nodes (records, closures, field calls, enums, matches).
  The linear and wasm-gc backends run the same passes, so a backend never
  sees a non-`Exception` `handle` or a `resume` in live code.

A future direct lowering to WasmFX (`cont.new` / `suspend` / `resume`) would be
one more pass over the same `perform` / `handle` input; it is not part of this
ADR. Host-level suspension of `Async` across the component boundary is
ADR-0089's subject ([wasi-p3-async.md](wasi-p3-async.md)).

## Lowering model

### Pipeline

The effect lowering runs inside `effect_lowering_prelude`
(`lib/@vibe/compiler/codegen/wasi/linked_compile_prelude_run_per_module.vibe`),
in this order:

1. entry wrappers — the standard host provider and the `Exception` boundary
   are installed as ordinary `handle`s around the entry body
   (`wrap_entry_host_provider`, `wrap_entry_exception_boundary`), and an
   `Async` entry gets its sleep boundary, so the passes below treat them like
   hand-written handles;
2. `suspend_cps_pass` (`lib/@vibe/compiler/lowering/effects/suspend/`) —
   consumes every handle whose arm refers to `resume` as a value;
3. `evidence_dict_pass_with_roots`
   (`lib/@vibe/compiler/lowering/effects/evidence/`) — consumes the remaining
   non-`Exception` handles, then hard-errors on any that survives in reachable
   code.

The wasm-gc lane runs the same two passes on the same statements
(`lib/@vibe/compiler/codegen/gc/backend_body_wasi_module_gc_impl.vibe`;
`suspend_cps_pass` there since #3009, `scps_drop_orphaned_originals` since
#3064). `vibe check` runs the prelude right after type checking
(#1511(b), #1536(c)), so an ineligible handle is a check-time diagnostic, not a
codegen surprise. `vibe check --single-file` does not run it.

Shared read-only queries live in `lib/@vibe/compiler/lowering/effects/queries/`;
the audited list of builtins that cannot perform (`idp_pure_builtin_names`) is
in `lib/@vibe/compiler/lowering/effects/direct/direct.vibe`.

### Evidence dictionaries (tail-resumptive arms)

The evidence pass is the effect counterpart of method-bearing trait dictionary
passing (`thread_dict_params` / `synth_dicts` in
`lib/@vibe/compiler/normalize/desugar/`): no new calling convention, the same
codegen shape, the same RC treatment.

- **Dictionary type.** For an effect `E` the pass injects a struct
  `__EvDict_E` with one field per operation of `E`.
- **Needing functions.** A top-level function whose row contains `E` — after
  effectset expansion, with a qualified item such as `E::Op` counting — is a
  *needing* function. It gains a leading parameter `__ev_E`, every
  `perform E::Op(a)` in its body becomes a call through `__ev_E.Op`, and every
  call it makes to another needing function forwards `__ev_E`. Performs of
  other effects are left alone, and each effect migrates independently, so a
  function may need several dictionaries.
- **Handle sites.** `handle { body } with { E::Op(x) => .. resume(v) }` builds
  a dictionary literal from its arms, with each arm's tail `resume(v)` replaced
  by `v` (`edp_strip_tail_resume`). Calls to needing functions inside `body`
  receive it, direct performs in `body` call it, and the `handle` node
  disappears. Nested handles of the same effect shadow lexically, so the
  innermost handler wins, exactly as nested trait dictionaries do.
- **Closure values are typed into the convention** (addendum 34, V1).
  Every function-typed value whose row contains `E` — an annotated closure literal, a parameter, a local, a needing
  function used as a value — takes `__ev_E` first. Values of one row type
  therefore have one arity, and a call through any of them passes the
  dictionary that is lexically in scope. When such a value flows into a
  parameter whose type has no row, the pass eta-wraps it so the dictionary is
  captured inside and the parameter sees a row-free closure (addendum 37).
- **What a body may call.** A call in a needing body or a handled body is
  safe when its callee is a needing function, a builtin from the audited pure
  list, a constructor, a raw host import (`vibe_<area>_<op>_raw`, which cannot
  perform a user effect), a function whose row does not contain `E`, a
  perform-free function whose row contains `E` (it needs no dictionary and is
  treated as inert), a closure literal bound by `let` whose body passes the
  same scan, or a visibly pure rowless local lambda (#3124). Branches, loops,
  struct field reads and nested handles of *other* effects are scanned through.
- **Excluded from the needing set**: functions unreachable from the entry
  (DCE keep flags), self-discharging functions (they install their own handle
  for `E`), and local binders that shadow a needing function's name, which are
  α-renamed to `__edpsh_N_<name>` first (`edp_alpha_rename_shadowed`).
- **Vacuous handles are erased.** When no `perform E::..` exists anywhere in
  the program, every handle of `E` is replaced by its body before migration
  (`edp_erase_effect_handles`). A handle that only names a host label (`Env`,
  `Http`) to discharge a row is the common case.
- **Planning precedes rewriting.** Eligibility for every effect is decided on
  the unmodified program before any migration is applied (addendum 8), and
  the rewrite traversals visit exactly what the eligibility scan visits
  (addendum 10).

Generated names: `__EvDict_E` (`edp_dict_struct_name`), `__ev_E`
(`edp_dict_param_name`).

### Suspend CPS (resume as a first-class value)

The checker binds `resume : (OpResult) -> HandleResult` inside a
declared-effect arm. The direct form `resume(v)` keeps the tail-only rule; an
arm that uses `resume` as a value triggers `suspend_cps_pass` for its handle.

- **Step type.** Per triggered effect `E` the pass injects
  `enum __ScpsStep_E { __ScpsDone_E(v); __ScpsY_E_<op>(payload.., k) }`, one
  `Y` constructor per operation, where `k` is the continuation closure.
- **Splitting.** The handled body is cut at each suspension point into a
  chain of continuation closures: `let x = perform E::Op(a); rest` becomes
  `__ScpsY_E_Op(a, (x) -> rest')`. A per-site driver matches the step: `Done`
  yields the handle's value, a `Y` runs the original arm with `resume` bound
  to a closure that feeds the resumed value to `k` and drives the next step.
- **One shot.** The bound `resume` checks a heap flag; a second call writes
  `vibe: resume one-shot continuation called twice` to stderr and traps.
- **Calls across functions.** A call to a top-level function whose concrete
  row contains `E` goes to a synthesized clone `__scps_cps_E_f` that returns a
  step, composed with `__scps_bubble_E`; the original function is unchanged
  for its other callers. Calls to a function whose concrete row excludes `E`,
  to a first-order row-polymorphic function, to an audited pure or
  safe-mutation builtin (`scps_safe_mut_builtin_names`: `Array::push`,
  `__set_field`, `__index`, ...), to a constructor, or to a local closure
  literal proven inert are plain calls.
- **Closure values** (addendum 31, Vertical B). A closure literal with an
  explicit row that performs `E` is compiled once, in step form; calls through
  a value whose row concretely contains `E` are bubbled. This is what puts a
  handle site inside a library: `TaskGroup::spawn_suspend` in
  `lib/@vibe/concurrent/experimental/` takes such a closure.
- **The spine grammar** grew slice by slice under #1536 (addenda 36 and
  41–66): `let mut` becomes a one-element cell; `while` becomes a recursive
  step-returning closure, with `break` / `continue` as calls to the exit and
  loop continuations; a `for` whose iterand is provably an `Array` or a
  `String` becomes an indexed `while`; compound expressions are linearized in
  evaluation order; `if` / `match` / blocks that are a binding's or an
  assignment's value are distributed into their branches; `return` is hoisted
  to the tail it denotes or carried out of a loop or a handle body through a
  cell. Every binder these rewrites move is α-renamed against a scope-blind
  collision probe.
- **Other effects inside the body.** An abortive handle of another effect
  (an `Exception::Throw` catch) inside a suspending body is split with it and
  reinstalled around every resumed continuation (#1537).

Both arm shapes may exist for one effect in one program, except that a program
which step-compiles a closure for `E` must not also lower an `E` handle by
evidence: a closure value has one compiled form, so the two calling
conventions cannot meet (the convention guard of addendum 31, Vertical B).

### `Exception`

An `Exception` handle lowers to a Wasm `try_table` that catches the
exception tag, in both backends
(`lib/@vibe/compiler/codegen/expr/compile_expr_tail6.vibe`,
`lib/@vibe/compiler/codegen/gc/backend_expr.vibe`). Kinds are a checker
property and do not reach the runtime ([exception-effect.md](exception-effect.md)).
A non-`Exception` handle reaches codegen only inside a provably dead function
and compiles to a single `unreachable`; a `resume` that reaches codegen is an
internal compiler error.

### Shapes that are a compile error

Ordered by lowering. The message of the evidence-pass rejection leads with the
edit and names the culprit call and its `line:col` (#1511, #1514); the needle
the gates grep for is `cannot be compiled here`.

Evidence lowering (a tail-resumptive handle):

- the handled body calls a rowless local closure declared outside the handle
  whose body performs, or calls something the pass cannot see;
- the body calls through an expression rather than a name (`(ops.0)(x)`);
- a callee reaches its `perform` through a rowless parameter that the
  eta-wrap cannot reach (the value does not originate inside a needing body or
  the handled body);
- a self-discharging callee re-performs the effect from one of its own arms
  (#1591);
- an operation takes an effectful block as a parameter — a higher-order
  effect (`edp_higher_order_error_msg`, ADR-0089, #1347);
- the program holds closure values whose row carries `E` and `E`'s migration
  fails anywhere (for example a nested handle of the same effect): with closure
  values in play the migration is all-or-nothing
  (`fixtures/err_closure_value_evidence_ineligible.vibe`).

Suspend lowering (a handle whose arm stores `resume`):

- a call to a row-polymorphic function (`with e`) that is not first order,
  unless every closure argument is a literal that provably cannot perform the
  effect and captures only plain data (#3161);
- a call through a function value that is neither a step-typed CPS local nor
  a proven-inert closure, including a row-free closure parameter whose by-name
  call sites do not all pass inert literals;
- a `for` whose iterand is not provably an `Array` or a `String`;
- a `return` that no hoist reaches, and a selected `&&` / `||` right-hand side
  that transfers control;
- a closure literal that raw-performs more than one suspend-class effect;
- a step-compiled closure passed to a parameter whose concrete row lacks the
  effect (#1707), or called from inside a closure handed to a row-polymorphic
  callee such as `TaskGroup::run`;
- the convention mix described above.

A suspending closure literal without an explicit row annotation is refused
earlier, by the checker: an unannotated lambda's effects belong to the
enclosing function (#761).

### Memory and runtime

There is no reserved per-effect region: `eff_reserve` is zero. Dictionaries
are records; continuations and step values are ordinary heap closures and enum
values under RC. A closure environment owns its captures
(addendum 31, Vertical A), which is what lets a continuation outlive the frame
that created it. On the RC lane, dropping a stored continuation
without calling it releases what it captured through the ordinary RC drop;
there is no separate finalizer stack.

### Relation to ADR-0068

The evidence and suspend lowerings add no cross-task rule. A stored
continuation is an ordinary closure value, so whether it may cross a task
boundary is decided by ADR-0068's `Spawnable` checks on closure values
(`lib/@vibe/compiler/checker/traits/checker_spawnable.vibe`), and it remains
one-shot by the dynamic check above. The cooperative scheduler in
`@vibe/concurrent/experimental` parks a task by storing its `resume` and wakes
it by calling it ([concurrency.md](concurrency.md)).

## Rejected alternatives

- **Enlarging the replay memo region.** Removes the ceiling but not the
  repeated side effects.
- **CPS for every effectful function.** Pays closure allocation on the
  tail-resumptive majority; the static row already tells which functions can
  reach a suspending handler.
- **Waiting for WasmFX.** Not available on node or in browsers; the passes
  here do not block adding it later.
- **Deciding static versus dynamic dispatch from the presence of a row
  variable.** A function with a concrete row can still run under different
  handlers from different call sites (`fixtures/effect_higher_order_swap_test.vibe`
  calls one `compute` under two handlers), so the dictionary is always passed
  and erasing it is a separate optimization.
- **Carrying evidence in a closure environment slot, or as a hidden argument
  of every function.** The environment slot needs a dynamic write channel
  because a closure is usually created outside its handle; the hidden argument
  breaks the cross-module ABI of every function and the seed. Typing closure
  values into the dictionary convention costs neither (addendum 34).

## Open

- **Row-variable callees under the evidence lowering.** A row variable can be
  instantiated to a different set of effects at each call, so a fixed-layout
  dictionary cannot represent it. The idea on record is a vector of
  `(OperationId, closure)` pairs forwarded or filtered like a trait
  dictionary; it needs ADR-0071's operation identity and is not implemented.
  Today a row-polymorphic callee is accepted when the pass can show it
  receives nothing that performs the handled effect, and refused otherwise.
- **Partially discharging a callback's row.** A helper typed
  `fn with_log(f: () -> Int with Log + e) -> Int with e` that handles `Log`
  around `f()` does not remove `Log` from its caller's row (addendum 23).

## Rollout phases (cited by name from code)

| phase | what it was | state |
|---|---|---|
| 1 | pin M2 as a regression (`fixtures/effect_handle_replay_corruption.vibe`) | landed |
| 2 / 2b | `inline_direct_performs`, a pass that spliced an arm into a lexically visible perform (2b: pure builtin calls no longer bailed it out) | deleted in #2500: evidence passing covered every shape it covered, measured 1321/1321 on the unit corpus with it switched off |
| 3 | `evidence_dict_pass` coverage; the "first slice" was a handled body calling a named needing function (`fixtures/effect_handle_call_evidence.vibe`) | landed |
| 3a | first-class one-shot `resume`, depth-0 suspend CPS (addenda 27–28) | landed, gate 50 |
| 3b | yield bubbling across calls (addendum 29) | landed |
| 3c | suspendable tasks in `@vibe/concurrent/experimental` | landed |
| 3d | replay removal, a.k.a. Vertical C (addenda 31, 32, 34 V2) | landed, gate 55 |
| 4 | the same passes on the wasm-gc backend (the "gc follow-up" fixtures) | landed; suspend CPS on gc since #3009 |
| 5 | an alternative WasmFX / JSPI lowering of the same input | not part of this ADR |

## Addenda (cited by number from code)

Code comments, fixtures, gates and other documents cite this ADR's addenda by
number, written `追記N` ("addendum N"). Each heading keeps that key so a search
for the citation lands on it. Every entry states what is true now; addenda
whose content was superseded or reverted have been removed, so the numbering
has gaps. The investigation logs behind each entry are in `git log`.

### Addendum 2 (追記 2): tail-resumptive arms need no CPS

Because #942 accepts a direct `resume(v)` only as an arm's last expression,
every arm that resumes directly is tail-resumptive in Xie & Leijen's sense.
Such an arm is a function from the operation's arguments to the resumed value,
so threading an evidence dictionary as an ordinary parameter and returning the
arm's value from the dictionary closure implements it: no `Outcome` type, no
CPS, no replay. Nested handles of the same effect resolve to the innermost
handler, which lexical dictionary shadowing gives without new machinery
(`fixtures/effect_effectset_expansion.vibe` and
`fixtures/effect_row_operation_item.vibe` each call a self-discharging function
under an outer handle of the same effect and expect the inner answer).
Continuations kept beyond the arm are the suspend class (addenda 27–29), not
this lowering.

### Addendum 4 (追記 4): needing calls inside branches

The first evidence slice produced invalid wasm (`not enough arguments on the
stack for call`) when a call to a needing function sat inside an `if` or
`match` branch of the handled body. The cause was the handle-site rewrite, not
codegen's call lookup; see addendum 6. Pinned by
`fixtures/effect_handle_call_evidence_branch.vibe`.

### Addendum 6 (追記 6): rewrite a handle where it is found

The handle-site rewrite used to collect sites first and later find them again
by a hand-written structural equality that covered seven expression forms. A
body containing any other form (an `if` was the first) never compared equal to
itself, so the site was left with its old calls while the needing function had
already gained its `__ev_E` parameter: an arity mismatch in the emitted wasm.
The rewrite is now a single traversal (`edp_find_rewrite_handles`) that
rewrites a matching handle at the point it finds it, so no step re-discovers a
site and branch positions are eligible. Gate 40v runs the branch fixture of
addendum 4 through the evidence dictionary.

### Addendum 8 (追記 8): plan every effect before rewriting

Eligibility for all effects is decided on the unmodified program first
(`edp_plan_migrations`), and only then is each plan applied
(`edp_apply_migration`). Deciding and rewriting effect by effect let one
effect's rewrite — which introduces `__ev_E.Op` field calls — be read by the
next effect's eligibility scan as an unsafe construct, so a function needing
two effects could never migrate the second.

### Addendum 10 (追記 10): the rewrite walks mirror the eligibility scan

`edp_rewrite_needing_body` and `edp_rewrite_handle_body` must visit exactly the
constructs, in exactly the positions, that `edp_has_unsafe_construct` visits.
A position the scan approves but a rewrite skips leaves a raw `perform` whose
handler the migration has already removed, which is an uncaught exception at
run time. The original instance was `let a = perform Ask::Get` inside a needing
function: the scan read the `let` value, the rewrite did not. Pinned by
`fixtures/effect_handle_call_evidence_let_bound.vibe` (gate 40y). A construct
added to one of the three walks is added to all of them; the comments in
`lib/@vibe/compiler/lowering/effects/queries/queries.vibe` that cite this
addendum mark the places that must agree.

### Addendum 20 (追記20): rows of hoisted closures are backfilled

An unannotated closure literal carries no row in the AST: the checker infers
one but does not write it back. Lambda hoisting (`dlh_hoist_expr`,
`lib/@vibe/compiler/normalize/desugar/lambda_hoist.vibe`) therefore fills a
hoisted function's empty row from the effects its body performs
(`dlh_collect_performed_effect_names`), because the evidence pass classifies
needing functions by row text alone. Planning tries the full needing set first
and drops unreachable needing functions only on a retry
(`edp_try_plan_for_effect`), so a never-called but eligible function still
migrates. Pinned by `fixtures/effect_handle_call_evidence_closure_literal.vibe`
(gate 40h5, the gc lane).

### Addendum 23 (追記23): interpolation rendering and the scope of row polymorphism

Two findings from the gc coverage sweep.

1. Interpolating a struct, enum or exception payload once rendered a tagged
   pointer, because `__to_string` only knows integers and strings. That is now
   resolved by name, not by a runtime dispatcher: interpolation of a value
   whose type resolves calls its `T::to_string` (from `derive(Show)` or written
   by hand, #1392), and interpolating a declared aggregate with no renderer is a
   compile error (#1445).
2. A row variable joins a row with `+` (`with Log + e`); `with Log | e` is not
   syntax. A fully polymorphic pass-through (`with e`) works, and so does a
   function with a concrete label plus a row variable
   (`fixtures/effect_handle_call_evidence_row_variable_tail.vibe`). What does
   not work is discharging part of a callback's row: measured on the committed
   seed (`array-capacity-2026-09-20`), a helper
   `fn with_log(f: () -> Int with Log + e) -> Int with e` that handles `Log`
   around `f()` leaves a row-less caller of
   `with_log(() -> Int with Log { .. })` with `missing { Log }`. Supporting it
   needs the row variable to bind only the remainder in the checker and
   evidence for the split in the lowering.

### Addendum 25 (追記25): a self-discharging owner's closure parameter

A function that installs its own `handle .. with E` around a call to its
closure parameter, without `E` in its own row
(`run_with_handler(f: () -> Int with Ask) -> Int`), is not a needing function,
so nothing forwarded evidence to `f` and the program trapped with an
indirect-call signature mismatch (#1070, found by the LSP server's handler).
It was first fixed by a dedicated rule (`edp_handle_owner_cps`: the owner is
never used as a value, and every use of the parameter is a direct call inside
the owner's own handle). Type-directed closure evidence (addendum 34, V1) made
the general case fall out: `f`'s type carries `Ask`, so `f` takes `__ev_Ask`
and the owner's handle passes its dictionary like any other call. Pinned by
`fixtures/effect_local_closure_handle_owner_param.vibe` (gate 40ar).

### Addendum 27 (追記27): first-class resume — design (Phase 3a)

Before this, the checker refused both a non-tail direct `resume(..)` (#942)
and any value use of `resume`, so storing a continuation could be added as a
new permission with no existing behavior to migrate. The rules:

- inside a declared-effect arm the checker binds
  `resume : (OpResult) -> HandleResult`, the operation's declared result and
  the handle's type;
- the direct call `resume(v)` keeps the tail-only rule, so the evidence
  lowering's eligibility signal is unchanged;
- an arm that refers to `resume` as a value triggers suspend CPS for its
  handle; post-processing is written through the value
  (`let k = resume  let r = k(v)  r + 7`);
- the continuation is one-shot, checked dynamically.

The concrete step type, driver and splitting are described under "Suspend
CPS" above; addendum 29 generalized the per-site enum of the first slice to a
per-effect one.

### Addendum 28 (追記28): first-class resume — implementation (Phase 3a)

`suspend_cps_pass` runs before the evidence pass, so evidence lowering only
sees the handles it left. A triggered site that the pass cannot lower is a
hard compile error. The driver binds `resume` to a closure guarded by a
one-element `[false]` flag; a second call reports
`vibe: resume one-shot continuation called twice` on stderr and traps. It does
not throw an `Exception`, because an entry without `Exception` in its row has
no boundary to report one. Pinned by `fixtures/effect_resume_store_scheduler.vibe`
(store, suspend, resume from outside, run to completion),
`fixtures/effect_resume_value_postprocess.vibe`,
`fixtures/effect_resume_one_shot_trap.vibe`, `fixtures/err_resume_non_tail.vibe`
and `fixtures/err_effect_resume_store_ineligible.vibe` (gate 50).

### Addendum 29 (追記29): yield bubbling across calls (Phase 3b)

A suspending body may call a top-level function whose concrete row contains
the handled effect, recursion included:

1. the step type is per effect (`__ScpsStep_E`), shared by every site and
   clone;
2. `__scps_bubble_E(step, k)` re-wraps a callee's yield one level up and
   applies `k` to its `Done` value;
3. each such callee `f` gets a clone `__scps_cps_E_f` whose body went through
   the same split. The original `f` is unchanged. The clone carries no row, so
   the evidence pass does not count it as needing;
4. `let x = f(a)  REST` becomes
   `__scps_bubble_E(__scps_cps_E_f(a), (x) -> REST')`, and a tail call returns
   the clone's step directly.

The call policy reduces to the checker's row soundness: a callee whose
concrete row has neither `E` nor a row variable cannot perform `E`, so it is a
plain call. Upstream normalization (lambda hoisting plus trivial-wrapper
inlining in `lib/@vibe/compiler/normalize/desugar/trivial_wrappers.vibe`) can
turn a row-polymorphic wrapper applied to a capture-free closure into a direct
call, which this rule then accepts
(`fixtures/effect_resume_rowvar_wrapper_normalized_test.vibe`). Pinned by
`fixtures/effect_resume_call_bubbling_test.vibe`.

### Addendum 31 (追記31): owned captures, closure CPS, and the replay removal plan

Three verticals, landed in the order A, B, C.

#### Vertical A: owned-captures closure ABI (RC lane)

A closure environment owns its captures. Creation dups every capture (a no-op
for scalars and for string fat pointers); the class-7 drop releases every
owned slot recursively; a `let rec` self-reference stays weak (patched in
after creation, skipped on drop) to avoid a cycle; the per-invocation
prologue dup of #705 is unchanged, because it accounts for each call's use, not
for the environment's lifetime. This replaced #1097's per-site compensation
for a match payload captured by a closure. Without it a continuation that
escaped its frame read freed memory. Pinned by
`fixtures/rc_closure_owned_capture_escape.vibe` (gate 52). The bump lane and
the gc backend have no RC and are unaffected.

#### Vertical B: closure-CPS ABI

Calling a suspending closure through a value needs no wasm-level change: a
linear closure of arity k has one function type, and a step is an ordinary
tagged value, so the convention is decided statically from the row of the
function type and the checker already rejects a row mismatch.

1. A *CPS-mode* effect is one with at least one triggered handle site.
2. A closure literal with an explicit row that performs a CPS-mode effect is
   compiled once, in step form. Unlike a named function it has no second
   entry, since a value has one body.
3. A call through a value whose row concretely contains `E` — a parameter of
   the enclosing function, or a local bound to a step-split literal — is
   bubbled. A row variable or an unannotated intermediate local is refused.
4. Convention guard: a program that step-compiles a closure for `E` and also
   lowers some other `E` handle by evidence is a compile error
   (`fixtures/err_effect_closure_cps_mixed_convention.vibe`).
5. Top-level `fn` values keep the clone model of addendum 29; only literals
   in expression position are split. A capture-free literal argument that
   lambda hoisting turned into a top-level function is referenced through its
   clone.

Pinned by `fixtures/effect_closure_cps_param.vibe` (gate 53) and the
`spawn_suspend` tests in
`lib/@vibe/concurrent/experimental/suspend_test.vibe`.

#### Vertical C: replay removal (Phase 3d)

The compiler's own handles were all `Exception`, so bootstrap never depended
on replay. The remaining replay users were moved one by one: the CLI's
profiler timestamp became a direct builtin call (`Profiler::now_us()`,
addendum 32); the evidence pass plans a migration whenever a handle site for
the effect exists, even with no needing function, which covers a
self-discharging dispatcher such as the LSP server's handler; the remaining
fixtures moved with addendum 34. The removal itself is addendum 34, V2.

### Addendum 32 (追記32): the first replay consumers removed

`profiler_now_us` (`lib/@vibe/cli/dispatch.vibe`,
`lib/@vibe/compiler/entry/compiler/file_compile/file_compile.vibe`) calls the
builtin `Profiler::now_us()` instead of `perform Profiler::NowUs`. Under
replay the handler answered `resume(0)` and the whole CLI dispatch re-ran once
per timestamp. The builtin's own row keeps `Profiler` on every signature, so
the change is row-neutral. In `edp_try_plan_for_effect` an existing handle
site is itself a reason to plan, with eligibility still decided per site.

### Addendum 34 (追記34): type-directed closure evidence (V1) and replay removal (V2)

**V1 — closure values take the dictionary by type.** The four restrictions
#1070 had needed (single use, every call site proven, no value reference,
calls confined to the handle) all protected one property: a closure value must
not be called both with and without the dictionary. Making migration total by
type removes the need for each of them. Every function-typed value whose row
contains `E` takes `__ev_E` first; one row type means one arity. Annotated
closure literals with `E` in their row are migrated unconditionally
(`edp_sweep_row_lits_stmts`); calls through `E`-row parameters and locals pass
the lexically available dictionary; a migrated named function can flow into an
`E`-row closure position as it is. An unannotated literal belongs to the
enclosing row (#761), so it is not a closure value of this kind. When the
program holds such values, a failed migration of `E` is a hard error rather
than a partial one. Pinned by `fixtures/effect_closure_value_evidence_m2.vibe`
(the M2 duplication is gone) and
`fixtures/err_closure_value_evidence_ineligible.vibe` (gate 54). The
environment-slot and hidden-argument alternatives were rejected (see "Rejected
alternatives").

**V2 — the replay engine is deleted.** Four parts:

1. **Vacuous-handle elimination.** An effect with no `perform` anywhere in the
   program has its handles replaced by their bodies
   (`edp_program_user_performs`, `edp_erase_effect_handles`). The candidates are
   declared effects and every label a handle names, including builtin labels
   with no declaration (`edp_collect_handle_effect_names`); `Exception` is
   excluded. This is what discharges a host-row label pun such as a private
   `Env` handle around builtin calls: the arms could never run, and removing
   the handle is the only sound option (renaming the private effect would leak
   the row upward). Pinned by `fixtures/effect_vacuous_handle_erased.vibe`.
2. **Shadowed needing names.** Local binders that shadow a needing function
   are α-renamed (`__edpsh_N_<name>`), and the eligibility scan is scope
   tracked: a call to a `let`-bound closure literal is safe, while a parameter,
   `let mut` or pattern binder that shadows a global name is opaque.
   `fixtures/evidence_dict_needing_shadowed_by_local.vibe` now migrates.
3. **The perform side.** A `perform` that reaches codegen was not migrated,
   so no live handle can catch it: it compiles to its value (a builtin call for
   a host-mapped operation, else the payload) followed by a bare throw. Such
   sites are dead code in practice, emitted because codegen still compiles
   them. A handle that names a host operation (`Fs::ReadFile`) does intercept
   it, in both its `perform` and its builtin spelling (#1962, see the
   cheatsheet's "Effects" section). `test` / `bench` blocks and top-level
   expressions are site-bearing statements for collection, eligibility,
   renaming and apply, so a mock handler in a test runs through evidence.
4. **The handle side and the regions.** `compile_expr_tail6` lowers only
   `Exception` handles; a non-`Exception` handle reaching it can only be in a
   dead function and compiles to `unreachable`. A live one left after
   migration is a hard error from the evidence pass. `eff_reserve` is zero.

Coverage holes that replay had hidden were closed as they surfaced: `__to_string`
and `not` joined the pure list, raw host imports are inert, a perform-free
function with `E` in its row is inert (migrating it would give a test's direct
call no dictionary to pass), and a duplicated effect declaration reached
through two import spellings is planned once
(`edp_collect_effect_defs` deduplicates by name, and
`edp_rewrite_needing_fn` refuses to prepend a second `__ev_E`). Pinned by
`fixtures/err_effect_handle_replay_removed.vibe` (needle
`cannot be compiled here`, gate 55).

### Addendum 36 (追記36): loops and `let mut` on the suspending spine (#1230)

`let mut x = v` becomes `let x = [v]` with reads and writes through
`Array::get` / `Array::set` (`scps_cellify`), so every continuation shares one
cell instead of copying the value. `while c { body }` becomes a recursive
step-returning closure (`scps_split_while`) whose recursive call is appended to
the tail of the body (`scps_seq_append`) and registered as a CPS local, so the
closure-CPS path bubbles it. The native stack grows only across consecutive
iterations that do not suspend. Pinned by `fixtures/effect_resume_store_loop.vibe`.
Loop control is addendum 47; `return` in a loop is addendum 56.

### Addendum 37 (追記37): an escaping needing value is eta-wrapped

A value whose row contains `E` that flows into a parameter typed without a row
(`fn apply1(f: (x: Int) -> Int)`) would be compiled with `__ev_E` while the
callee calls it without one. The checker accepts this, because a closure
literal's `perform` is charged to the enclosing function (#761). The pass
rewrites `apply1(v)` to `apply1((__edpw_0) -> v(__edpw_0))` inside a needing
body or a handled body (`edp_etawrap_stmts`): the dictionary is captured by the
wrapper and the parameter sees a row-free closure. The evidence captured is
the one in scope at the escape, which is the right one because the handler
that discharges the charged `perform` encloses that point. Outside those
regions there is no dictionary to capture, so the shape stays an error, as does
a callee with labeled parameters. Pinned by
`fixtures/effect_needing_value_escape_wrapped_test.vibe`,
`fixtures/err_effect_needing_value_escape.vibe` and
`fixtures/effect_needing_value_annotated_test.vibe`.

### Addendum 39 (追記39): naming an immediately applied closure literal (#1385)

The evidence scan treats a call whose callee is not a bare name as opaque.
Lambda hoisting names an immediately applied literal, `(lit)()` becoming
`let fresh = lit; fresh()`, when its body performs **or** its declared row is
not empty (`dlh_row_is_effectful`), so a literal that consumes its row by
calling another row-carrying function is named too. That shape also arises
from trivial-wrapper inlining of a zero-argument wrapper. Naming does not hoist
the literal to the top level. Pinned by
`fixtures/effect_iife_needing_call_test.vibe` and
`fixtures/effect_trivial_wrapper_needing_call_test.vibe`.

### Addendum 40 (追記40): row-free closure parameters proven by argument flow (#1536 (a) v1)

A row-free function-typed parameter cannot be trusted from its type, because
a literal's `perform` is charged to its enclosing function (#761). But the CPS
clone `__scps_cps_E_f` is reached only through `f`'s by-name call sites. When
every such site passes, in that slot, a literal that contains no `perform`,
names no needing function, calls nothing opaque and nests no handle — or
forwards a parameter of its own caller proven the same way — the call through
the parameter is a plain call (`scps_inert_taint`, `scps_param_slot_inert`;
the proven parameter is renamed `__scps_inert_<site>_<name>` inside the clone).
One site passing a performing literal taints the slot. This is what lets
`AsyncIter::find`, `AsyncIter::any` and `AsyncIter::all` run in a suspending
body. Pinned by `fixtures/effect_closure_param_inert.vibe`,
`fixtures/effect_closure_param_inert_transitive_test.vibe` and
`fixtures/err_effect_closure_param_taint.vibe`.

### Addendum 41 (追記41): the eager Stream retarget is retired (#1954)

`Stream::next`, its Array-backed lowering and the synthetic suspend-CPS
retarget that once let `await(Stream::next(s))` appear in a suspending body no
longer exist. Guest iteration uses `AsyncIter`; byte conversion uses the
nominal `ByteStream`; host-owned reads use `HostStream` (#1955).

### Addendum 42 (追記42): a let chain at a sequence head floats onto the spine (#1536 (a) v3)

A statement-position `for` over an async iterator desugars to one expression
(`let __iter_src = ..; let mut ..; while ..`) sitting at the head of
`ESeq(<loop>, rest)`. The split floats it:
`ESeq(ELet(x, v, k), b)` becomes `ELet(nx, v, ESeq(k[x := nx], b))`, and a
nested `ESeq` head re-associates to the right. The binder is always renamed,
to a name minted by bumping a suffix until the spelling occurs nowhere in `k`
or `b` (`scps_seq_float_fresh`), so the widened scope cannot capture a free
name of `b` even when user code spells a generated name. This is what lets
`AsyncIter::collect`, `AsyncIter::fold` and `AsyncIter::count` run in a
suspending body. Pinned by `fixtures/effect_for_await_suspend_test.vibe`,
`fixtures/effect_seq_head_block_suspend_test.vibe` and
`fixtures/effect_seq_head_reserved_name_collision_test.vibe`.

### Addendum 43 (追記43): a selection at a sequence head distributes the rest (#1536 (a) v4)

A suspending `if` at a sequence head becomes `EIf(c, ESeq(t, b), ESeq(e, b))`;
a suspending `match` puts `b` under each arm. The condition or scrutinee stays
in place and runs once, and only the selected branch's tail runs. Pattern
binders are renamed per arm before `b` moves under them. Pinned by
`fixtures/effect_seq_head_if_suspend_test.vibe` and
`fixtures/effect_seq_head_match_suspend_test.vibe`.

### Addendum 44 (追記44): a direct selection input is named first (#1536 (a) v5)

When an `if` condition or a `match` scrutinee is itself a direct perform of
the handled effect, a concrete needing call, or a call of a step-typed CPS
local, it is bound once to a fresh name (`ELet(tmp, input, EIf(tmp, ..))`)
and the ordinary spine handles the rest. Compound inputs are addendum 48.

### Addendum 45 (追記45): a direct assignment right-hand side is named first (#1536 (a) v6)

`x = rhs` on the spine, with `rhs` one of addendum 44's direct shapes, becomes
`let fresh = rhs; x = fresh; rest`. The freshness probe also checks assignment
targets, so a user variable spelled like the generated name is not captured.
The operation, the assignment and the continuation each run once.

### Addendum 46 (追記46): a direct `while` condition is named per check (#1536 (a) v7)

When a `while` condition is a direct suspension, the loop closure binds it to
a fresh name on each check and selects on the resumed `Bool`: the operation
runs once per check, the body once per true, the continuation once after the
first false.

### Addendum 47 (追記47): `break` and `continue` on the CPS spine (#1536)

A loop body with `break` / `continue` gets its exit continuation as a closure
(`let k = (u) -> <rest>`) beside the loop closure; `break` becomes `k(())`,
`continue` becomes the loop closure's call, and the body's tail re-enters the
loop. Before rewriting, `scps_loop_normalize_ctl` distributes a transfer that
sits in a selection at a sequence head into each branch and drops the dead
statements after it. A transfer is any expression that always transfers
(`scps_is_ctl_terminator`): a spine whose tail transfers, or a selection all of
whose branches do, so a transfer preceded by a statement counts (addendum 56).
A surface `loop (p = e, ..) { .. }` reaches this pass already desugared to this
form. Pinned by `fixtures/effect_resume_store_loop_break_test.vibe`.

### Addendum 48 (追記48): compound inputs are linearized in evaluation order (#1536 (a) v8)

A suspension inside an operand, a call or constructor argument, a compound
`while` condition or a compound assignment (`+=`) is accepted:
`scps_anf_compound` names, in source order, everything evaluated before the
first suspension, then the suspension, and leaves the rest in place, so
nothing is reordered. Literals and identifiers are not named; a `let mut` read
is a cell read after `scps_cellify` and is named at its original position.
Callees are not named, because a by-name call turned into a call through a
local would become exactly the shape the pass cannot see. Positions that are
not always evaluated — branches, the right side of `&&` / `||` — are not walked
into (addendum 52 and 53 name them whole instead). The same slice fixed
`EAssignOp`'s field order in three places in this pass, where a `+=` across a
suspension wrote a raw local while reads went through the cell
(`fixtures/effect_assignment_op_rhs_suspend.vibe`).

### Addendum 49 (追記49): a selection that is a binding's value carries the binding into its branches (#1536)

`let x = if c { t } else { e }  REST` becomes
`if c { let x = t  REST } else { let x = e  REST }`, and the same for `match`
and for a `let mut` initializer. The condition or scrutinee runs once, before
the branches. Match-arm binders are renamed before the continuation moves
under them (`fixtures/effect_let_selection_match_capture_test.vibe`). A
selection that contains `break`, `continue` or `return` is not distributed.

### Addendum 50 (追記50): a block that is a binding's value moves the binding inside (#1536)

`let x = { a; v }  REST` becomes `a;  let x = v  REST`, and
`let x = { let y = e; v }  REST` becomes `let y' = e;  let x = v[y := y']  REST`,
with `y` renamed by the addendum-42 probe. `ESeq`, `EAssign` and `EAssignOp`
all count as statement prefixes. Both rewrites shrink the value, so re-splitting
converges; with addendum 49, branches that contain statements are accepted.
Pinned by `fixtures/effect_let_block_value_suspend_test.vibe`.

### Addendum 51 (追記51): the same two rewrites for an assignment's right-hand side (#1536)

`x = if c { t } else { e }  REST` and `x = { a; v }  REST` are distributed like
addenda 49 and 50. The rewrite happens in two places: before cellification
(`scps_float_direct_assign`) for a target the spine boxes, because after boxing
the value is a builtin argument and floating it would duplicate the other
arguments; and on the continuation spine for a target bound outside it. Pinned
by `fixtures/effect_assign_selection_suspend_test.vibe` and
`fixtures/effect_assign_outer_selection_suspend_test.vibe`.

### Addendum 52 (追記52): a selection inside a compound is named whole (#1536)

The ANF of addendum 48 does not walk into branches, but every position it does
reach is always evaluated, so a selection there can be bound whole:
`value = 1 + (if c { perform Op(1) } else { 0 })` becomes
`let h = if c { .. } else { 0 };  value = 1 + h`, which addendum 49 then
distributes. A selection containing a transfer is not named, since the
distribution would refuse it and naming would not converge. Pinned by
`fixtures/effect_compound_selection_suspend_test.vibe`.

### Addendum 53 (追記53): a non-tail `&&` / `||` is named whole (#1536)

A short-circuit expression in an always-evaluated position is bound whole and
handed to the let-short-circuit lowering, but only after asking that lowering
itself (`scps_let_shortcircuit_bind`) whether it accepts the expression; a
copy of its predicate could drift. The terminal of a short-circuit may be
compound, because the bindings it generates sit inside the selected branch.
The bypass is preserved. Refused: a selected right-hand side that returns,
breaks or continues (`fixtures/err_effect_let_shortcircuit_return_suspend.vibe`).
Pinned by `fixtures/effect_compound_shortcircuit_suspend_test.vibe` and
`fixtures/effect_shortcircuit_compound_rhs_test.vibe`.

### Addendum 54 (追記54): a `return` left in a split body is refused (#1536)

A split body is rewritten into step-returning pieces, so a `return` left in it
no longer leaves the function; it would hand its value to the driver as a step
and trap at run time. All three split sites — a handled body, a needing
function's clone, a closure literal — therefore refuse a body that still
contains `return` after the hoists of addenda 55–57 (`scps_body_has_return`).
A `return` inside a nested closure refers to that closure and is accepted
(`fixtures/effect_resume_store_loop_nested_return.vibe`).

### Addendum 55 (追記55): `return` is moved to the tail it denotes (#1536)

In a needing function's clone and in a closure literal, `return v` means "this
computation's value is `v`", which is what the tail already means. So
`return v; REST` becomes `v`, and a branch that returns receives the rest of
the sequence in its other branches (match arms renamed as in addendum 43). The
rewrite fires only where a branch actually returns. A `return` it cannot reach
stays and is refused by addendum 54, so incompleteness costs a refusal, never a
miscompile. Pinned by `fixtures/effect_return_in_split_body_test.vibe` and
`fixtures/effect_return_match_arm_split_test.vibe`.

### Addendum 56 (追記56): `return` inside a loop (#1536)

A loop body's tail is the next iteration, not the function's value, so the
loop records the value, sets a flag and `break`s, and the code after the loop
returns when the flag is set:

```text
let mut returned = false
let mut slot = 0
while c { .. slot = v; returned = true; break .. }
if returned { return slot } else { REST }
```

Nested loops place the same guard after each inner loop, carrying the exit out
one level at a time. While building it, a silent miscompile in `break` itself
was found and fixed: only a bare `break` / `continue` was recognized as a
transfer, so a transfer preceded by a statement after a resume fell through and
kept looping. Pinned by `fixtures/effect_return_in_loop_test.vibe`,
`fixtures/effect_return_nested_loop_test.vibe` and
`fixtures/effect_transfer_after_resume_test.vibe`.

### Addendum 57 (追記57): `return` in a handled body goes out through a cell (#1536)

In a handled body `return v` leaves the enclosing function, not the handle, so
the hoist of addendum 55 does not apply. The flag and slot live outside the
handle, the body records and finishes, and the code after the handle returns:

```text
let mut returned = false
let mut slot = 0
let r = handle { .. slot = v; returned = true; 0 .. } with { .. }
if returned { return slot } else { REST }
```

When the handle itself sits in a split body, the outer `return` is then an
ordinary spine `return` for addendum 55. Pinned by
`fixtures/effect_return_in_handle_body_test.vibe`.

### Addendum 58 (追記58): a `for` over a proven Array or String becomes a `while` (#1536)

Codegen decides at run time whether a `for` iterand is a `String` (#807), so
rewriting an unknown iterand into the indexed array form could turn a string
into a zero-iteration loop. The split therefore rewrites only an iterand
proved syntactically: a parameter annotated `Array[..]` or `String`, a binding
to an array or string literal, and (addenda 60, 63, 66) more. An array
becomes `let mut i = 0; while i < Array::length(xs) { let x = Array::get(xs, i);
i = i + 1; body }`, with the length re-read each iteration and the index
advanced before the body so `continue` progresses. A string iterates by
`String::length` / `String::char_code_at`, which is what codegen materializes
anyway. The rewrite runs at all three split sites. An unproved iterand is
refused (`fixtures/err_effect_for_unproved_iterand.vibe`). Pinned by
`fixtures/effect_array_for_suspend_test.vibe`.

### Addendum 59 (追記59): a first-order row-polymorphic callee is safe (#1536)

A callee declared `with e` can only have `e` instantiated through its
arguments. If no declared parameter type mentions a function type, anywhere
inside type arguments included, `e` can only be empty and the call cannot
perform the handled effect (`scps_callee_first_order`). An unannotated
parameter or an unknown callee is still refused.

### Addendum 60 (追記60): a `for` iterand that is a call (#1536)

A call iterand is proved by its callee's declared return type, read from the
`EFn` of the top-level definition (the binding annotation slot of
`edp_collect_fn_defs` is not the return type). The value is bound once before
the loop.

### Addendum 61 (追記61): a step-split literal passed to a plain parameter is refused (#1707)

A closure literal that performs a CPS-mode effect returns a step, so it may
only be passed to a parameter whose row contains that effect. Passed to a
parameter whose concrete row lacks it, the callee would use the step object as
a value. That is now a compile error. A row-variable parameter is exempt,
because `e` may be instantiated to include the effect
(`TaskGroup::run[T, rg, e](body: (..) -> T with e)`).

### Addendum 62 (追記62): inert local closure literals may be captured and called (#1536)

A name bound on the spine to a closure literal whose row neither contains the
effect nor is a row variable, that is not step-split, and whose body is itself
inert (`scps_is_inert_literal`) can be called and captured: the call cannot
perform and returns a plain value. The same predicate is threaded to both
gates, eligibility (`scps_calls_ok`) and argument inertness, including the
list and field helpers they call.

### Addendum 63 (追記63): more self-proving iterands, and a guard against local shadowing (#1714)

A literal iterand (`for x in [1, 2]`, `for c in "ab"`) proves itself, and a
name bound to a call is proved by the callee's return type. The callee lookup
reads module-level declarations, so a local binding of the same name would make
it answer about a different function — measured, a string was indexed as an
array and the loop silently answered 0. The guard (`scps_binds_name`,
consulted in the call-kind lookup) drops the proof when any binder in the
walked expression spells the callee's name; it over-refuses, never
over-accepts. Pinned by `fixtures/effect_for_proved_iterand_suspend_test.vibe`
and `fixtures/err_effect_for_shadowed_callee.vibe`.

### Addendum 64 (追記64): eligibility follows one lexical classification stack (#1718)

The eligibility and culprit-diagnostic walks share an immutable stack of
`(name, opaque | inert | CPS)` entries, pushed at every `let`, `let mut`,
`let rec`, closure parameter, match, `for` and loop binder, and seeded at the
handle and at every clone and literal entry. A name answers from its most
recent binder only; only after that does the walk consult generated prefixes,
builtins, constructors, needing functions and the callee-row lookups. Separate
additive name sets let an old inert or CPS proof outlive a newer opaque binder
of the same name, which accepted calls through an unrelated closure and
answered wrong values.

### Addendum 65 (追記65): needing names shadowed by locals in the suspend lowering (#1721)

The suspend pass runs before the evidence pass's α-rename, so a local that
shadows a needing function was retargeted to the top-level function's clone.
`scps_needing_for` drops shadowed names the same way the evidence pass does
(`edp_drop_shadowed_needing`), trading eligibility for correctness. The same
local-shadowing class was fixed in the checker's row inference (#1723: a local
binding wins over a same-named top-level `fn` when charging rows) and in the
prepass's callee parameter lookup (`scps_prepass_callee_params` consults the
lexical scope first).

### Addendum 66 (追記66): iterands proved through the builtin registry (#1536)

A call to a builtin with no top-level definition (`Array::concat`) is proved
from the builtin registry's signature (`lookup_registry_builtin`; an array or
string result), after the declaration lookup and behind the same shadowing
guard (`scps_call_kind`). Pinned by
`fixtures/effect_for_builtin_iterand_suspend_test.vibe`.

A call through a local binding (`for j in mk()`) is proved from the local
literal's own declared return type (#1727), except when the literal declares
none, when two binders of the name are live, or when the name is also a
top-level function, where the scope-blind guard of addendum 63 refuses it
(`fixtures/effect_for_local_binding_iterand_suspend_test.vibe`).

## References

- N. Xie, D. Leijen, [Generalized Evidence Passing for Effect
  Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/),
  ICFP 2021 — the tail-resumptive direct-call lowering.
- D. Leijen, [The Koka Programming Language: Effect
  Typing](https://koka-lang.github.io/koka/doc/book.html#sec-effect-types) —
  evidence vectors and row-typed effects.
- wasm_of_ocaml's selective CPS — choosing what to transform from static
  information.
- [pl-survey-2026-07.md](../reports/pl-survey-2026-07.md) — the survey this ADR
  started from.
