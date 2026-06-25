# Method-bearing traits — implementation plan (#641)

Status: design + spike complete (2026-06-25). Implementation not started.

vibe traits are currently **marker-only**: a `trait` declaration carries a name +
supertraits but no method signatures, and `impl` bodies are parsed and discarded.
This blocks `Iterator` (#636), generalized `?`/`let*` via a `Try` trait (#635),
and structural `derive` beyond `Eq` (#638). This plan adds method-bearing traits
(method signatures + dispatch) as the shared foundation.

Related: #641 (this), #636, #635, #638. Prior art: MoonBit 0.10.0 polymorphic
trait methods (<https://www.moonbitlang.com/updates/2026/06/08/moonbit-0-10-0-release>),
Haskell type classes (dictionary passing), Swift protocol witness tables, Roc abilities.

## Current state (file:line)

- AST: `vibe/compiler/core/ast.vibe` — `STrait(Bool, String, Array[String])` (exported,
  name, supertraits; **no methods**); `SImpl(Array[String], Array[(String, Array[String])],
  String, String)` (type_params, type_bounds, trait, type; **no method bodies**).
  `EFn(type_params, bounds, params, ret, effect, body)` is the existing carrier for
  type params + bounds. `SEffectDef(...)` is the precedent for a decl that stores a
  list of `(name, param-types, ret-type)` signatures.
- Parser: `vibe/compiler/syntax/parser_base.vibe` — `parse_trait_stmt` and
  `parse_impl_stmt` call `skip_braced_body`, throwing the `{ ... }` block away.
  `parse_effect_stmt` is the working precedent for parsing a `{ sig; ... }` block.
- Checker: `vibe/compiler/checker/checker_stmt.vibe` records `EnvTraitDef` /
  `EnvTraitImpl` markers (no methods). `vibe/compiler/checker_trait.vibe`
  `satisfies_bound` / `check_bounds_satisfied` are exported but **never called**
  (bounds are tracked, not enforced). Resolution primitives exist in
  `vibe/compiler/core/types.vibe`: `instantiate`, `subst_apply`, `trait_supers`,
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
constraint** (product `wasm/vibe/vibe.wasm` is ~943 KB; thousands of method call
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

### Phase 1 — method signatures + dispatch
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

Per `docs/selfhost-bootstrap.md`, compiler source cannot use new syntax until the
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
- Gate: `scripts/test_selfhost_typecheck_fixtures.sh`, then `scripts/selfhost_only_gate.sh`
  (authoritative seed→stage1→stage2→stage3 fixpoint + normalize round-trip). Regenerate
  the flat bundle (`scripts/generate_selfhost_bundle.sh`) after AST changes.

## Risks / open items

- Checker dictionary-materialization ordering between `desugar.vibe`, `lower.vibe`,
  and `checker/` (Plan G-3 plumbing — model proven, automation pending).
- Supertrait method inheritance (`trait Ord: Eq`) — needs `trait_is_subtrait` walking;
  out of Phase 1's first slice.
- Generic impls (`impl [T: Eq] Eq for Array[T]`, `EnvTraitImplGen`) — dictionaries that
  themselves need dictionaries; deferred.
- Bundle regeneration after AST changes is a process gotcha (gate checks bundle sync).
