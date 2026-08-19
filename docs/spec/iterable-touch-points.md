# Adding a built-in iterable: touch-point checklist

When ADR-0044 Phase 3 is extended (e.g. adding `Set`, `Tuple`, `Path`,
or any new primitive type as a built-in `Iterable`), the following
places **all** need updating in lock-step. Forgetting any of them
typically produces a "silent" failure: the code compiles but
`Iterator::fold(value, ...)` either returns the initial accumulator
unchanged (wasm-gc) or traps at `call_ref` (with HOF-typed lambdas).

The HOF gap fix (commit `7faa294`, 2026-05-25) traced one round of this
back from `iterator_test` failures — two helpers were left at
"Array + Named" while the language had grown String / Bytes / Map.

## Required edits

### 1. Prelude — `src/checker/prelude.mbt`

Add the iter-helper definitions next to the existing String / Map ones:

```moonbit
#|let YourType::iter_length = (xs: YourType) -> Int { ... }
#|let YourType::iter_get = (xs: YourType, index: Int) -> ElemType { ... }
```

Also add the names to the `iter_method_names` allow-list in the same
file so the checker keeps them through DCE.

### 2. Monoify root-tag recognition — `src/frontend/monoify.mbt`

**Both** of the following functions match on `Type::*` and decide
which `iter_*` helper to dispatch to. They must stay in sync — when
either returns `None` for your type, monoify produces the
eqref-erased generic version of `Iterator::fold` etc., which then
mismatches concrete-typed closures at the wasm-gc `call_ref` site:

```moonbit
fn MonoifyContext::iterable_root_tag_from_expr(...) -> String? {
  match self.expr_types.get_expr_type(expr.span()) {
    Some(@core.Type::Array(_)) => Some("Array")
    Some(@core.Type::Named(name~, ..)) => Some(name)
    Some(@core.Type::String) => Some("String")
    Some(@core.Type::Bytes) => Some("Bytes")
    Some(@core.Type::Map(_, _)) => Some("Map")
    Some(@core.Type::YourType) => Some("YourType")   // ← add here
    _ => None
  }
}

fn monoify_iter_root_from_type(ty: @core.Type) -> String? {
  // mirror of the above; same arms must be present
}
```

### 3. wasm-gc codegen — `src/codegen/wasm_gc_codegen.mbt`

- `is_gc_builtin_name`: add `name.has_prefix("YourType::")` if the
  type has a Capital-Name namespace and prelude functions follow
  the `YourType::method` convention. Otherwise the helper functions
  get treated as ordinary user fns (fine) but builtin-style calls
  (`YourType::length`) won't be recognized.
- Add the actual `compile_yourtype_iter_length_gc` / `compile_yourtype_iter_get_gc`
  helpers if the type isn't already implementable in terms of
  existing operations.
- `__index` (string-literal key case) — when `your_type[i]` is a
  meaningful expression at the source level, decide whether it should
  emit the char-code-at-style or the substring-style result and route
  accordingly. Mirror in `infer_expr_kind_gc`'s `__index` branch so
  the inferred result kind matches.

### 4. linear codegen — `src/codegen/wasm_codegen_builtin_collection.mbt`

Same as #3 but for the linear backend:

- `__index` / `__set_index` dispatch on `obj_type` tag (your type
  needs a tag from `src/codegen/wasm_codegen_types.mbt`).
- Builtin handlers for `YourType::length`, `YourType::iter_length`,
  `YourType::iter_get` if not already covered by a generic path.

### 5. Type checker iteration glue — `src/checker/typecheck_expr.mbt`

- Confirm `for-in` over the new type lowers correctly. Phase 2 of
  ADR-0044 routed every iterable through `iter_require[C: Iterable]
  / iter_length / iter_get`, so as long as `impl Iterable for YourType`
  is declared and the helpers exist, this should "just work".
- If your type needs custom element-type inference (e.g. Map yielding
  K rather than V), follow the existing Map precedent and document
  the choice on the impl.

### 6. Tests

Add a test mirroring `iterator_supports_string_iterable` in
`@vibe/builtin/iterator_test.vibe` — exercises `Iterator::fold` /
`any` / `find` / `map` against the new type. **Run with both backends**:

```bash
vibe test @vibe/builtin/iterator_test.vibe                  # linear
VIBE_TEST_BACKEND=gc vibe test @vibe/builtin/iterator_test.vibe  # wasm-gc
```

Silent-fail caveat: a wasm-gc miss often manifests as the test
*passing* the compile phase and *running* but returning the initial
accumulator unchanged (Iterator::fold returns init because the body
loop never executed). Always assert the *value*, not just the absence
of trap.

## Why this is fragile

The dispatch lives in **5 separate code locations** (`prelude.mbt`, two
monoify helpers, wasm-gc codegen, linear codegen) with no shared
"registered iterable" table. Each addition is purely additive and
silently breaks if any one is missed.

Refactor target: factor these into a single
`registered_iterables : Array[IterableRegistration]` table consumed
by all five sites — see also the "dual codegen" structural issue
referenced in the wasm-gc HOF gap report. Out of scope for the
maintenance docs.
