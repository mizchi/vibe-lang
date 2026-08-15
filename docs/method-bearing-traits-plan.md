# Method-bearing traits — implementation plan (#641)

Status: **largely landed — the "current state" claims below are historical.**
Phase 1 landed 2026-06-26; bound enforcement + dictionary passing have since
landed too (`desugar_trait_dict`, #1503 trait-instance resolution closed as
implemented). Traits are no longer marker-only: `lib/@vibe/core/map.vibe`'s
`trait Hash { hash_key(Self) -> String }` ships method-bearing impls and
`derive(Hash)` generates `Type::hash_key` (#694). This document is kept as
the design record; read statements about "current" compiler behavior as
describing 2026-06, not today. (The duplicate marker `Hash` in
`lib/@vibe/prelude/builtin_traits.vibe` is tracked by #1844.)

## Build gotcha (read before iterating on the compiler)

`scripts/generations.sh build` and `generate_bundle.sh` copy the
**committed** `lib/@vibe/compiler/_cli_adapter_module_source.vibe` by default
(`build_adapter_module_source`, gated on `VIBE_REGEN_MODULE_SOURCE`).
Editing compiler source files therefore has **no effect** on a build until the
flat module source is regenerated. Always build/regenerate with:

```bash
VIBE_REGEN_MODULE_SOURCE=1 bash scripts/generations.sh build
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh   # to refresh the committed copy
```

`scripts/compiler_gate.sh` regenerates and checks sync, so it catches a
stale committed module source — but a plain `build` will silently use the old one.

vibe traits are currently **marker-only**: a `trait` declaration carries a name +
supertraits but no method signatures, and `impl` bodies are parsed and discarded.
This blocks `Iterator` (#636), generalized `?`/`let*` via a `Try` trait (#635),
and structural `derive` beyond `Eq` (#638). This plan adds method-bearing traits
(method signatures + dispatch) as the shared foundation.

Related: #641 (this), #636, #635, #638. Prior art: MoonBit 0.10.0 polymorphic
trait methods (<https://www.moonbitlang.com/updates/2026/06/08/moonbit-0-10-0-release>),
Haskell type classes (dictionary passing), Swift protocol witness tables, Roc abilities.

## Current state (file:line)

- AST: `lib/@vibe/compiler/core/ast.vibe` — `STrait(Bool, String, Array[String])` (exported,
  name, supertraits; **no methods**); `SImpl(Array[String], Array[(String, Array[String])],
  String, String)` (type_params, type_bounds, trait, type; **no method bodies**).
  `EFn(type_params, bounds, params, ret, effect, body)` is the existing carrier for
  type params + bounds. `SEffectDef(...)` is the precedent for a decl that stores a
  list of `(name, param-types, ret-type)` signatures.
- Parser: `lib/@vibe/parser/parser_base.vibe` (#753 で lib/@vibe/compiler/syntax から移設) — `parse_trait_stmt` and
  `parse_impl_stmt` call `skip_braced_body`, throwing the `{ ... }` block away.
  `parse_effect_stmt` is the working precedent for parsing a `{ sig; ... }` block.
- Checker: `lib/@vibe/compiler/checker/checker_stmt.vibe` records `EnvTraitDef` /
  `EnvTraitImpl` markers (no methods). `lib/@vibe/compiler/checker_trait.vibe`
  `satisfies_bound` / `check_bounds_satisfied` are exported but **never called**
  (bounds are tracked, not enforced). Resolution primitives exist in
  `lib/@vibe/compiler/core/types.vibe`: `instantiate`, `subst_apply`, `trait_supers`,
  `trait_is_subtrait`, `type_implements_trait`.
- Codegen: records store each field as a uniform i64
  (`codegen/expr/compile_expr_tail4.vibe`); a closure value is itself a uniform i64
  (`codegen/expr/compile_lambda.vibe`); calling a closure read from a field already
  works (`emit_closure_resolve` + `emit_closure_call_tail`, `codegen/expr/compile_call.vibe`).
- The comment at `vibe/prelude/lazy_iter.vibe:8-12` ("codegen does not yet support
  storing closures in struct fields") is **stale** — see spike G-1.

## Dispatch strategy: uniform / dictionary passing (decided, wasm-size measured)

vibe uses a uniform 62-bit-tagged value representation; generic function bodies are
**not duplicated per type**. Measured by compiling generic instantiations with the
seed compiler:

| generic body | K=1 | K=5 | 1→5 delta |
|---|---|---|---|
| small (2 tuple stmts) | 3891 B | 3942 B | +51 B (~13 B / instantiation) |
| large (40 tuple stmts, body ~1575 B) | 5466 B | 5517 B | +51 B (~13 B / instantiation) |

Enlarging the body 27× left the K=1→5 delta unchanged (+51 B): bodies are shared,
each instantiation adds only its call site. **wasm size is therefore not a
constraint** (product `clients/wasm/vibe.wasm` is ~943 KB; thousands of method call
sites add tens of KB). Dispatch is chosen by implementation cost, not size, and
the uniform representation aligns naturally with **dictionary passing** (a dict is
one value threaded through shared code). Monomorphization is not pursued.

## Spikes (all pass on the seed compiler)

Guarded by `fixtures/trait_dict_passing_substrate_test.vibe`.

- **G-1 — closures in struct fields.** Non-capturing, multi-method (dictionary-shaped),
  and capturing/heap closures stored in a struct field, read and called, with correct
  values. The lazy_iter.vibe blocker is dissolved.
- **G-2 — `Self` resolution / impl desugar target.** `let Point::measure = (self: Point)
  -> Int { ... }` and a `Self`-in-return method (`-> Point`) type-check, compile, run.
  `Self` is a desugar-time textual substitution to the target type; concrete-receiver
  calls need zero new codegen.
- **G-3 — dictionary passing through a generic function.** A generic
  `MeasurableDict[T]` witness (generic structs are supported) threaded into a generic
  function and a HOF (`Array::fold`), with `Point::measure` referenced as a first-class
  value to build the witness. Correct values.

Conclusion: the dictionary-passing model is sound end-to-end on the current runtime.
The remaining work is compiler plumbing (parse/store signatures, desugar impl methods,
auto-synthesize and thread the witness), not a language/runtime unknown.

## Phase split

### Phase 1 — method signatures + dispatch — LANDED (2026-06-26)

Shipped a smaller slice than originally drafted: **no AST change**. `impl` methods
are expanded at parse time into `let Type::method = (params) -> ret { body }`
qualified free functions (`parse_impl_methods` in `lib/@vibe/parser/parser.vibe`); the trait
declaration stays a marker. Concrete-receiver calls resolve by name, so no checker
or codegen change was needed. The seed was bumped so the toolchain understands the
syntax. Deferred to PR-2/PR-3: bound enforcement, dictionary passing, and passing a
qualified method (`Point::measure`) as a first-class HOF value.

### PR-2 blocker found (bound enforcement is NOT just "wire up the dead check")

`check_bounds_satisfied` / `satisfies_bound` (`checker_trait.vibe`) are dead, and
the obvious hook is: capture the final subst in `check_program`
(`checker_stmt.vibe:441`), walk `collect_subst_bounds_pairs` (`core/types.vibe:1237`),
`subst_apply` each bounded var, and for concrete (non-`CtVar`) results call
`type_implements_trait`, emitting ``no impl `Trait` for `Type` `` (the message
`fixtures/err_type_trait_call_bound_violation.vibe` expects).

BUT `type_implements_trait` **ignores generic impls**: both
`type_implements_check_env` and `type_implements_check_super` (`core/types.vibe`)
fall through `EnvTraitImplGen(_,_,_,_,rest)` without matching. So `impl [T] Eq for
Array[T]` is invisible, and naive enforcement would false-positive ``no impl `Eq`
for `Array[..]` `` on the compiler's own generic-over-container code, breaking the
selfbuild. PR-2 must therefore be split:
- **PR-2a**: harden `type_implements_trait` to match `EnvTraitImplGen` (unify the
  generic impl's target constructor against the resolved type, e.g. `Array[T]` vs
  `Array[Int]`), with `fixtures/typecheck` coverage for both pass and fail.
- **PR-2b**: enforce bounds in `check_program` only after PR-2a (skip unresolved
  `CtVar` results — those propagate to the eventual concrete call site).

Only check concrete resolutions; bounds on still-polymorphic vars are inherited,
not violated.

Original full design (for reference / superseded parts):
1. AST: extend `STrait` with a method-signature list (model on `SEffectDef`) and
   `SImpl` with `(method_name, EFn-body)` pairs. Update all match sites.
2. Parser: parse the trait `{ sig; ... }` block and impl `{ method(...) -> ret { body } }`
   block (clone `parse_effect_stmt`); keep body-less forms valid (back-compat).
3. Printer: emit both blocks so `normalize` round-trips.
4. Desugar: impl method → `let Type::method = ...` qualified free function (G-2 form).
   Concrete-receiver calls `Type::method(x)` then resolve through the existing path.
5. Checker: store methods in `EnvTraitDef` / `EnvTraitImpl`; wire up the dead
   `check_bounds_satisfied`; for bounded generics `[T: Trait]`, synthesize the witness
   dict and thread it as a hidden argument (G-3 form). Phase 1 scope: single bound,
   non-supertrait, non-generic-impl.
6. Codegen: dictionary = record of closures (substrate proven). Linear backend first;
   wasm-gc backend mirrors it in a follow-up.

Recommended surface (consistent with existing `[T: Bound]` placement; ADR-0020 §3
keeps calls `C::method(x)` / pipe-first — no `recv.method()`):

```vibe
trait Measurable {
  measure(Self) -> Int
  scale(Self, Int) -> Self
}
impl Measurable for Point {
  measure(self) -> Int { self.x + self.y }
  scale(self, k) -> Point { Point::{ x: self.x * k, y: self.y * k } }
}
```

### Phase 2 — per-method type parameters (MoonBit 0.10.0 equivalent)
Allow method-local binders, reusing the function-level `[X: Bound]` machinery
(`EFn` type_params/bounds, already in place):

```vibe
trait Logger { write_object: [X: Show](Self, X) -> Unit }
```

The witness for `X: Show` is resolved at the call site via the Phase 1 mechanism.
No trait objects exist in vibe, so the Rust "no generic methods on dyn traits"
restriction does not apply. Start after Phase 1 lands.

## Bootstrap sequencing

Per `docs/bootstrap.md`, compiler source cannot use new syntax until the
seed understands it.

1. **PR-1** (parser/AST/printer/desugar, no compiler-source usage of method syntax):
   a pure superset — all existing body-less traits/impls still parse, and the current
   seed can still build the compiler. Concrete-receiver dispatch works end to end.
2. **Bootstrap bump**: adopt PR-1 stage2 as the new seed.
3. **PR-2** (checker resolution): impl-method desugar + bound enforcement. Source-only,
   buildable by the PR-1 seed.
4. **PR-3** (dictionary threading + wasm-gc backend). Source-only.
5. Later: migrate prelude (`builtin_traits.vibe`, `lazy_iter.vibe`) and compiler source
   to method syntax, each behind its own bump.

## First PR (smallest shippable slice) + tests

PR-1: parse + store signatures/bodies, print them, desugar impl methods to
`Type::method`, so a program with `trait`/`impl` method blocks compiles and runs via
concrete-receiver calls. No dictionary passing or bound enforcement yet.

Tests / gate:
- Runtime fixture under `fixtures/` (target syntax → runs to a sentinel).
- Extend `fixtures/typecheck/trait_with_methods.vibe` to cover signature storage.
- Parser/printer round-trip case (guards normalize idempotency).
- Substrate guard already committed: `fixtures/trait_dict_passing_substrate_test.vibe`.
- Gate: `scripts/compiler_gate.sh`
  (authoritative seed→stage1→stage2→stage3 fixpoint + normalize round-trip). Regenerate
  the flat bundle (`scripts/generate_bundle.sh`) after AST changes.

## PR-3 implementation plan — dictionary passing (the big one)

Goal: make `T::method(x)` work inside a `[T: Trait]` generic, dispatching to the
right impl at the concrete call site. PR-1 made `impl` methods into `Type::method`
free functions and PR-2 enforces bounds; PR-3 lets a *type-variable* method call
resolve.

### Confirmed constraints (investigated 2026-06-26)
- `T::show` inside `[T: Show]` currently fails `unknown name: T::show` — a type
  variable has no resolvable qualified method.
- The main pipeline is type-erased: `compile_source_wasi_only`
  (`entry/source_compile/wasi_only/preprocess_compile.vibe:93`) runs
  parse → `expand_interp_stmts` → `check_program` → `strip_generic_type_params`
  (`preprocess_strip.vibe:9`) → codegen. **`monoify.vibe` is NOT in this path**, and
  type params are stripped, so generic bodies are shared at one uniform-i64 ABI.
  ⇒ **monomorphization is not viable; dictionary passing is the only fit** (matches
  the plan's measured decision).
- Traits are **marker-only** (`STrait` has no method signatures) — PR-1 deferred
  this. The checker therefore has no trait→method-signature link to type `T::method`.
- The target encoding is proven: `fixtures/trait_dict_passing_substrate_test.vibe`
  (spike G-3) shows a hand-written `MeasurableDict[T]` witness threaded through a
  generic function + HOF runs correctly. PR-3 = generate that automatically.

### Four components (each non-trivial; do in order, each its own commit + gate)
1. **Trait method signatures in the AST** (the deferred PR-1 change). — **LANDED
   (component 1, this branch).** `STrait` now carries
   `Array[(String, Array[TypeExpr], TypeExpr)]` (modeled on `SEffectDef`);
   `parse_trait_methods` (`lib/@vibe/parser/parser_base.vibe`) parses the `{ sig; ... }`
   block, `syntax/printer.vibe` emits it (idempotent under `VIBE_NORMALIZE=1`),
   and every `STrait` match/construct site was updated to the new arity. Storage
   in `EnvTraitDef` was **deferred to component 2** (where it is consumed) to keep
   the commit bisectable — `checker_stmt.vibe` currently ignores the methods field.
   A `trait Measurable { measure(Self)->Int; scale(Self,Int)->Self }` program
   compiles, runs, and round-trips through normalize against the rebuilt stage2.
2. **Checker resolution of `T::method`.** — **LANDED (component 2, this branch).**
   `EnvTraitDef` now stores method signatures; `checker.vibe`'s `EIdent`
   "unknown name" fallback resolves a qualified `head::method` when `head` is a
   bounded type variable whose bounds include a trait declaring `method`, typing
   it with `Self := head` (`resolve_trait_method_ident` + `subst_self_in_type`,
   helpers `trait_method_sig` / `subst_bounds_for` in `core/types.vibe`). The
   syntactic lowering below means no checker obligation list is needed.
3. **Witness threading + 4. materialization.** — **LANDED (components 3+4,
   this branch; `lib/@vibe/compiler/desugar_trait_dict.vibe`).** A pre-check pass
   `desugar_trait_dicts` synthesizes a witness struct `TraitDict { m: (Self)->R; ... }`
   per method-bearing trait, prepends a hidden `__dict_Trait_T: TraitDict[T]`
   parameter to each `[T: Trait]` generic, rewrites `T::method(args)` →
   `(__dict_Trait_T.method)(args)`, and at each concrete call site synthesizes
   `TraitDict::{ method: C::method, ... }` from the receiver's inferred concrete
   type `C`. The witness threading is purely syntactic (driven by the `EFn`
   bounds), so it needs no checker-recorded obligation list. The pass is INERT
   unless a method-bearing trait is declared (so the selfbuild is untouched) and
   idempotent (it runs once per pipeline; the single-file path desugars before
   generic-stripping, the FS-compile path at the codegen convergence point
   `compile_wasi_module_linked_impl`).

   Receiver-type inference for call-site dict synthesis is best-effort/syntactic
   (`infer_arg_type_name`): primitive literals, struct literals (matched to a
   `struct` decl by field-name set since the parser discards the `Name::` prefix),
   and locals/params whose concrete type is tracked in a small per-function
   `var_types` environment. A receiver whose type is not syntactically
   determinable leaves the call unrewritten — a loud arity error, never a
   miscompile.

   Verified end-to-end against the rebuilt stage2 (single-file `_start` and
   FS-compile test blocks): `[T: Measurable](x: T) { T::measure(x) }` and
   `{ T::measure(T::scale(x, 2)) }` dispatch correctly for both an `Int` impl
   and a `Point` struct impl, with both literal and let-bound receivers.
   Fixture: `fixtures/trait_method_dict_passing_test.vibe`.

   **generic→generic witness forwarding — LANDED.** When a bounded generic
   calls another bounded generic with its own type parameter `T` as the
   receiver, the caller forwards its own `__dict_Trait_T` parameter instead of
   synthesizing a new dict (`synth_dicts` + `find_dict_for_trait`; parameters
   typed as a type variable are tracked in `var_types`).

   **supertrait method inheritance — LANDED (single chain).** A method-bearing
   `trait B: A` flattens A's methods into `BDict` (`flatten_traits`), so
   `[T: B]` dispatches both B's and A's methods through one witness. Two pieces
   were needed: (1) the checker resolves inherited methods via
   `trait_method_sig_deep` (walks supertraits) — required on the FS-compile path
   where `check_program` runs on the un-desugared `T::a_method`; (2) flattened
   methods are ordered **supertraits-first** so an inherited method keeps the
   SAME field index in every dict that contains it (`MeasurableDict{measure:0}`
   and `SizedDict{measure:0,…}`). The latter matters because codegen resolves
   `dict.field` by a global first-match field-name search
   (`compile_expr_tail4.vibe`), not by the object's static type, so a shared
   field name must sit at a consistent index. Gate step 14 covers an `Int` and
   `Point` impl, forwarding, and a `Sized: Measurable` chain (sum = 340).

   Still deferred (next slices): multiple bounds per parameter / multiple
   supertraits (the supertraits-first index invariant only holds for a single
   chain; a diamond can place a shared method at different indices), generic
   impls (`impl [T: Eq] Eq for Array[T]` — dicts of dicts), `Type::method` as a
   first-class HOF value, and the wasm-gc backend mirror. A type-directed field
   access in codegen would remove the index-consistency constraint entirely.
   Activation needs no seed bump (the compiler source uses no trait-method
   syntax); `scripts/compiler_gate.sh` stays green.

   Note: a pre-existing source-cache bug (`build_persistent_sources_cache_text`,
   cf. #630–#634) traps on certain file byte-sizes via the FS-compile persistent
   cache, independent of traits — `fixtures/trait_method_dict_passing_test.vibe`
   can hit it, so the authoritative regression is the gate's temp-dir `_start`
   program, not the fixture.

### Scope for the first working slice
Single bound, single type param, non-supertrait, non-generic-impl, concrete call
sites only. Defer: multiple bounds, supertrait method inheritance (needs
`trait_is_subtrait` + nested dicts), generic impls (dicts that need dicts), and
passing `Type::method` as a first-class HOF value.

### Bootstrap + validation
Components 1–4 are all source changes the current (PR-2) seed can build (they don't
make the *compiler source* use trait methods), so no bump until activation. Each
component must keep `compiler_gate.sh` green; build with
`VIBE_REGEN_MODULE_SOURCE=1` (see the build gotcha above). Add a `vibe test`
fixture mirroring G-3 but with `T::method` (not a hand-written dict) once component 4
lands.

## Downstream features unblocked (this branch)

- **#638 derive(Ord/Show) for structs — LANDED.** `derive(...)` parses any name
  (multiple allowed); `SStruct` carries the derive list; `desugar_derives`
  generates structural `Type::compare` (-1/0/1 lexicographic) and
  `Type::to_string` free functions; the checker pre-binds their signatures for
  the FS-compile path. `Eq` stays a no-op marker. Gate step 15. Deferred: enums,
  Hash, Default.
- **#636 Iterator — FOUNDATION LANDED.** Method-bearing traits with a type
  parameter are now expressible and dispatchable: `trait Iterator[T] {
  next(Self) -> Option[T] }` parses (the `[T]` header is consumed and erased),
  and a `[I: Iterator]` generic dispatches `I::next` through the witness dict.
  The element type `T` is relaxed to `CtUnknown` at resolution
  (`relax_unknown_named` in checker.vibe) so it unifies at the call site (the
  uniform representation erases it). A functional iterator
  `next(Self) -> Option[(T, Self)]` threads its state and is driven to completion
  by a generic helper. **`for x in it { ... }` over a struct iterator now
  desugars to the next-driven driver loop** (`build_iter_for` in the desugar
  pass): `for` whose iterable infers to a struct type with a `next` method is
  rewritten to `let mut __iter_cur = it; while ... match C::next(__iter_cur) {
  Some((x, rest)) => { __iter_cur = rest; body }, None => stop }`; array-`for`
  (iterable infers to None / a primitive) is left untouched for the existing
  array codegen, and nested iterator-`for`s shadow the `__iter_*` names
  correctly. **The `Iterable` trait is also supported:** `for x in e` where
  `e`'s type has no `next` but has an `iter` method
  (`Iterable[T] { iter(Self) -> Iterator }`) is rewritten to drive `R::next` on
  `e.iter()` (R = the iter method's return type, from a `fn_returns` registry of
  top-level function return types). Verified on both pipelines (gate step 16: an
  iterator `for`, an Iterable `for`, and a generic `iter_sum` dispatch sum to 30;
  fixture `fixtures/trait_iterator_test.vibe` covers struct-literal, let-bound,
  and Iterable iterables). Closures-in-struct-fields (the other lazy_iter
  blocker) are exactly the dict encoding (spike G-1).
  **Lazy combinators on the trait — LANDED (as library code).** A lazy `Stream`
  (a struct holding a `pull` closure plus its state) with `impl Iter for Stream`
  is a first-class iterator; `map`/`filter` are lazy (they wrap the source's
  pull) and `fold`/`sum`/`count` are eager consumers driven by the `for`
  desugar. No compiler support beyond the trait machinery — this is the
  trait-based replacement for `prelude/lazy_iter.vibe`'s `() -> Option[T]`
  function iterator. Gate step 17 + fixture
  `fixtures/lazy_iter_combinators_test.vibe` (chained `map |> filter |> fold`).
  `for await x in <pull closure>` still works (the existing `() -> Option[T]`
  model). **Deferred:** migrating the actual `prelude/lazy_iter.vibe` to the
  trait (needs the seed bump that activates trait-method syntax, since the
  prelude is seed-compiled); unifying `for await` with the struct-trait iterator
  (needs an async `next` / AsyncIterator — effect integration); and
  generic-context `for x in <type-param iterator>`. `for` requires the functional
  `next(Self) -> Option[(T, Self)]` convention (immutable structs thread state);
  the stateful `next(Self) -> Option[T]` form needs mut fields. Storing the
  trait's type params in `STrait` (instead of erasing at parse) would let the
  element type be a fresh unification var rather than `CtUnknown`, recovering
  full element-type safety.
  **`prelude/lazy_iter.vibe` migration — LANDED (#636).** The prelude is now the
  trait-based `LazyIter[T]` (a struct holding a `pull` closure + `state`, with
  `impl Iterator for LazyIter`); `lazy_iter_arr` / `map` / `filter` are lazy and
  `collect` / `fold` / `count` are eager consumers driven by the `for` desugar.
  Exported combinator signatures are unchanged, so `prelude/lazy_iter_test.vibe`
  (which uses the `|>` pipeline) passes verbatim. Two compiler fixes made the
  imported-prelude shape work:
  1. **Generic-struct `for`-iterator (`desugar_trait_dict.vibe`).** `seed_var_types`
     now records the head name of a `TyApp` param annotation (`src: LazyIter[T]`),
     not just a bare `TyName`, so `for x in src` over a generic iterator type
     classifies (infer → `LazyIter`, dispatch `LazyIter::next`).
  2. **Qualified method names across imports (`import_alias_rewrite.vibe`).** A
     qualified impl method `let LazyIter::next = ..` is a non-exported `let`, so
     the import namespacer used to path-suffix it (`LazyIter::next$path`),
     orphaning it from the (exported) `LazyIter` type — the `for` desugar's
     `Type::next` lookup then missed and the loop silently fell back to array
     iteration and trapped. Now a qualified `Head::member` whose `Head` is an
     **exported** type is left un-suffixed (it is public API, referenced by the
     type's name); methods on a *private* type keep the old whole-name renaming
     (the type itself is renamed and its call sites are rewritten through the
     same value map, so they stay consistent — verified no regression). Gate
     step 18 (`cross-import trait-iterator`) guards this: the iterator type +
     `impl ::next` + a `for`-driver live in an imported module, mirroring the
     prelude.
  **`for await` unification — LANDED (#636).** `for await x in s` now shares one
  type-directed desugar with sync `for` instead of a parse-time special case. The
  parser wraps the iterable in a `__await_iter` marker (the checker unwraps it so
  it never sees a non-function; the dict-passing desugar strips it), and the
  desugar — which has the type information the parser lacks — picks the loop:
  - a struct `C` whose `C::next` returns `Future[Option[(T, Self)]]` (an
    `AsyncIterator` / `Stream[T]`, per docs/spec/wasi-p3-async.md §2.4) drives an
    `await`-wrapped next loop. `await` is the M1a builtin and unwraps the ready
    future synchronously on the linear backend, so this runs today;
  - a struct `C` with a sync `C::next -> Option[(T, Self)]` drives the plain
    iterator loop (same as sync `for`); and
  - anything else (a pull closure `() -> Option[T]` such as `stdin_stream`, or a
    call with an unknown return type) drives the pre-existing pull-to-`None`
    loop, so the WASI byte-stream path is unchanged.
  The desugar (`desugar_trait_dict.vibe`) now also runs even when no
  method-bearing trait is declared (a `for await` predates the trait machinery),
  with the sync-`for` iterator classification gated on a trait being present so
  trait-free `for` loops are untouched. `collect_fn_returns` records `TyApp`
  return heads too, so a call-valued iterable (`for await x in mkstream(..)`) and
  an async-vs-sync `next` are distinguishable. Gate step 19 (`for-await
  unification`): one program drives an async iterator (`60`) and a pull closure
  (`10`) through `for await`, summing to `70`. Parity sweep vs the seed shows no
  regression (the WASI `stdin_stream` for-await path is byte-identical).

## Risks / open items

- Checker dictionary-materialization ordering between `desugar.vibe`, `lower.vibe`,
  and `checker/` (Plan G-3 plumbing — model proven, automation pending).
- Supertrait method inheritance (`trait Ord: Eq`) — needs `trait_is_subtrait` walking;
  out of Phase 1's first slice.
- Generic impls (`impl [T: Eq] Eq for Array[T]`, `EnvTraitImplGen`) — dictionaries that
  themselves need dictionaries; deferred.
- Bundle regeneration after AST changes is a process gotcha (gate checks bundle sync).

## #736 — `Iterable[T]` (indexed protocol) と Iterator combinators — LANDED (2026-07-04)

「Deferred: map/filter/fold combinators と Iterable trait」の残りが着地した。

- `vibe/prelude/iterator.vibe` が method-bearing `trait Iterable[T] {
  iter_length(Self) -> Int; iter_get(Self, Int) -> T }` を宣言し、
  `Iterator::fold/iter/find/any/all/r#map/filter/flatmap` は
  `C::iter_length(xs)` / `C::iter_get(xs, i)` の witness dispatch に移行。
  旧 ADR-0044 name-coupling(bare `iter_length` がマージ先に偶然存在する
  ことに依存、selfhost では一度もコンパイルできなかった)を置き換える。
- builtin impl は同ファイル内: Array(要素)/ String(char code)/
  Map(key。`Map::keys` 経由 — per-access 割り当ての perf 追い込みは残課題)。
- 必要になった機構修正 2 件:
  (1) merge の private-rename が builtin 型への impl メソッド
  (`Array::iter_length` 等、head がどのモジュールにも宣言されない)を
  改名して witness から orphan 化 → 「head がローカル宣言の private 型の
  ときだけ rename」に変更 (import_alias_rewrite.vibe)。
  (2) `infer_arg_type_name` に `EMap → "Map"` を追加(map literal 束縛の
  witness 解決)。
- `for x in <user型>` の indexed protocol 対応: classify に
  `classify_indexed_for_loop` を追加(`C::iter_length` + `C::iter_get` が
  存在する user 型のみ、trait 宣言が無いプログラムでも分類)。
  @vibe/core の List が `for x in list_of3(..)` で回せるようになった。
- allowlist 追加: vibe/prelude/iterator_test.vibe、lib/@vibe/core/list_test.vibe。

### 同日フォローアップ — method-style 呼び出しと dot-import (2026-07-04)

- **`xs.length()` / `xs |> length` の receiver-method 解決 — LANDED**。
  desugar_trait_dict: called-EDot は receiver 型が infer でき
  `Tn::method` が top-level fn として存在すれば qualified call に書き換え
  (同名 struct FIELD は field-stored-function call を維持)。bare callee は
  「lexical に解決できない(top-level fn に無い)」場合のみ arg0 の型で
  `Tn::name` を試す。checker: 未解決 bare callee を EDot 形に再チェック
  (user 型 receiver は per-module env に qualified が無くても EDot と同じ
  寛容さで通し、merged codegen が解決する。builtin/scalar receiver は
  従来どおり `unknown name` を報告)。list_type_import_test が PASS →
  allowlist 追加。
- **bare `import . { x }` の compiler trap 修正**: `path_has_relative_prefix`
  が素の `.` / `..` を相対と認識せず、`.` が "" に正規化されて最初の
  候補が `.vibe`(ワークスペースの store ディレクトリ!)になり、
  fs_read が EISDIR で diag なしに trap していた。
- **`Map::values` は selfhost builtin に存在しない**(host 時代の遺物)。
  vibe/collection/map.vibe の `values` を keys+get で再実装。
  collection の index_import_test / map_test / maps_facade_test が PASS →
  allowlist 追加(collection のテストが selfhost gate で回るのは初)。

## #1189 — dot 呼び出しの採否とソース正規形 (2026-07-28, ADR-0081)

上の「同日フォローアップ (2026-07-04)」で着地した `xs.length()` / `l.total()`
method-style resolve が、#1189 (「UFCS を入れるか、`Array::push(arr,x)` を
`arr.push(x)` と書けるようにするか」) の実質的な前提を変えていた —
**dot 呼び出しは既に一部着地済み**で、#1189 は「導入するか」ではなく
「どこまで表記として推奨するか」の問題だった。`eval/call-style/` に読解
ベースの評価ハーネスを作りサブエージェントに読ませたところ (findings:
`eval/call-style/findings/2026-07-28-r1.md`)、型注釈が薄い抜粋では
`Type::method(recv, ...)` / `recv |> Type::method(...)` は呼び出し箇所から
receiver の型を復元できたが、`recv.method(...)` は復元できなかった —
この非対称性は checker 通過後の内部 desugar (このファイル上の EDot
resolve) では解消されない。**ディスク上のソーステキストが dot 形のまま
残る限り、型検査を回さない読み手 (grep・diff・部分抜粋・AI) には効かない**。

決定 (ADR-0081, docs/adr.md): dot 形は入力として許可したまま、復元可能な
範囲でソースを `Type::method(recv, args)` へ書き戻す方向に倒す。**実装場所は
`vibe fmt` ではなく `vibe normalize`** — `lib/@vibe/compiler/fmt/format.vibe`
は AST を一切持たないトークン列レベルの整形機 (空白/改行のみ決める) で、
構造変換ができないと着手時に判明したため訂正した。`vibe normalize`
(`lib/@vibe/compiler/normalize/normalize.vibe`) は実際に AST へパースして
再印字する経路で、ADR-0074 の `map {..}` → `Map::from_pairs([..])` 正規化と
同じ「糖衣構文を canonical spelling で再印字する」前例がある。

**実装済み (2026-07-28, #1194)**: `normalize_dot_calls`
(`lib/@vibe/compiler/normalize/normalize.vibe`、`normalize_stmts` パイプラインに
組み込み済み、`normalize/index.vpkg` で export)。このファイルの
`infer_arg_type_name` / `var_types` / `collect_struct_field_sets` /
`collect_fn_returns` / `struct_set_member` の**縮小版を独立実装として
移植**した (フル型検査ではなく構文的推論のみ)。`desugar_trait_dict.vibe`
から直接 import しなかった理由はパッケージ層順の制約: codegen が
normalize の `lift_match_scrutinees` / `uniquify_shadowed_bindings` を
呼ぶ既存依存が既にあり (このファイルの通り)、逆方向の import
(normalize → codegen/common_base) は import cycle になる。このファイル側の
resolve ロジック自体に変更は無い — ロジックを変更する際は
`normalize_dot_calls` 側の対応する縮小版も見直すこと。**既知の制約**:
`vibe normalize` はファイル単体スコープなので、receiver の型が別ファイルで
宣言されインポートされているだけの場合は書き換えない (実務上の大半の
ケースがこれに該当する — 安全側の制約であり bug ではない)。テスト:
`lib/@vibe/compiler/tests/normalize_dot_calls_test.vibe`。
