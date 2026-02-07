# TODO

## WASM-visible Primitive API Expansion

### Done (baseline)

- [x] Allow wasm type aliases in type positions: `i32`, `f32`, `f64`
- [x] Reserve `i32`/`f32`/`f64` as non-redefinable type names
- [x] Add `examples/std/wasm/types.xsh` (`I32`/`F32`/`F64` aliases)
- [x] Add initial opcode-style API set in `examples/std/wasm/opcodes.xsh`
- [x] Extend wasm codegen for numeric conversion builtins:
  `int_to_float`, `int_to_double`, `float_to_int`, `double_to_int`,
  `float_to_double`, `double_to_float`

### Next (remaining builtin instructions)

- [ ] Extend i32 integer opcodes:
  `i32_clz`, `i32_ctz`, `i32_popcnt`,
  `i32_div_u`, `i32_rem_u`,
  `i32_shr_u`, `i32_rotl`, `i32_rotr`,
  `i32_lt_u`, `i32_le_u`, `i32_gt_u`, `i32_ge_u`
- [ ] Extend f32 numeric opcodes:
  `f32_abs`, `f32_neg`, `f32_ceil`, `f32_floor`, `f32_trunc`, `f32_nearest`,
  `f32_sqrt`, `f32_min`, `f32_max`, `f32_copysign`
- [ ] Extend f64 numeric opcodes:
  `f64_abs`, `f64_neg`, `f64_ceil`, `f64_floor`, `f64_trunc`, `f64_nearest`,
  `f64_sqrt`, `f64_min`, `f64_max`, `f64_copysign`
- [ ] Add remaining conversion opcodes:
  `i32_wrap_i64`, `i64_extend_i32_s`, `i64_extend_i32_u`,
  unsigned conversion/truncation variants, reinterpret ops
- [ ] Define policy for memory-level opcodes exposure:
  load/store naming, alignment/offset API shape, and safety contract
- [ ] Add wasm-specific conformance tests for all opcode wrappers
  (interpreter parity + wasm backend parity)

### Notes

- API naming stays wasm-compatible by replacing `.` with `_`
  (example: wasm `i32.add` -> xsh `i32_add`).
- Keep CamelCase as the default user type style; permit lowercase
  wasm primitive spellings only for builtin wasm types.

## Language Spec / Runtime Backlog (RED-first)

- [x] Fix imported compatibility aliases that forward to generic functions
  (`unwrap_or`, `is_some`) across modules.
  Regression tests:
  `src/xsh/xsh_integration_test.mbt`
  ("xsh integration import alias forwards generic helper")
- [x] Align trait bounds with operator semantics in trait-bounded generic paths
  (`T: Eq` + `==` for `String`).
  Regression test:
  `fixtures/todo_trait_eq_string_operator_runtime.xsh`
- [x] Stabilize cross-module trait-bounded API calls
  (`cmp_eq`, `option_equals`).
  Regression tests:
  `src/xsh/xsh_integration_test.mbt`
  ("xsh integration cross-module trait-bound eq",
  "xsh integration cross-module option_equals")
- [x] Fix bool or-pattern exhaustiveness handling.
  Regression test:
  `fixtures/todo_pattern_or_bool.xsh`

### Trait spec decisions (locked)

- [x] Trait is nominal and marker-only in v0:
  no trait methods, associated types, or trait objects yet.
- [x] Bound syntax is conjunctive and canonical:
  `[T: A + B]` and inline `x: T: A + B` are equivalent forms.
- [x] Trait visibility/import model in v0:
  trait use across modules requires explicit export/import.
  (`import { Eq, cmp_eq } ...`, not implicit trait leakage)
- [x] Trait import rename policy in v0:
  renamed traits keep canonical source relation, and supertrait names are
  resolved through same-clause aliases when available.
- [x] Trait openness model in v0:
  `export trait Eq` is sealed, `export open trait Eq` allows external impls.
  `open trait Eq` (without `export`) is invalid syntax.
- [x] Subtype model remains internal for API compatibility checks:
  function subtyping uses variance + effects, and trait satisfaction is a
  subtype relation (`ConcreteType <: TraitName`).
- [x] Bound-change compatibility policy:
  tightening bounds is breaking (Major), loosening bounds is additive (Minor).

### From decisions to implementation (RED)

- [x] Enforce trait-bound-aware operator typing on type variables:
  using `==` requires `Eq`; `< <= > >=` requires `Ord`.
  Regression tests:
  `fixtures/err_type_eq_operator_requires_eq_bound.xsh`
  `fixtures/err_type_ord_operator_requires_ord_bound.xsh`
  `fixtures/trait_eq_operator_accepts_eq_bound_type_parameter.xsh`
  `fixtures/trait_ord_operator_accepts_ord_bound_type_parameter.xsh`
- [x] Add trait coherence checks:
  reject duplicate/overlapping impl candidates for the same trait target.
  Regression tests:
  `fixtures/err_type_trait_impl_duplicate_target_rejected.xsh`
  `fixtures/err_type_trait_impl_overlap_rejected_when_both_apply.xsh`
- [x] Include trait bound changes in function API semver classification:
  `classify_function_api_change`/`is_type_subtype` now reflect
  `FuncParam.bounds` and generic bound changes in function metadata.
  Regression tests:
  `src/checker/subtype_wbtest.mbt`
  ("api version bump is major when parameter bound is tightened",
  "api version bump is minor when parameter bound is loosened",
  "fn metadata version reflects generic parameter bound changes")
- [x] Add dedicated RED tests for trait semantics above.
- [x] Implement `export open trait` and sealed/open impl rules.
  Regression tests:
  `src/xsh/xsh_integration_test.mbt`
  ("xsh integration sealed exported trait rejects external impl",
  "xsh integration export open trait allows external impl",
  "xsh integration trait bound requires explicit trait import",
  "xsh integration explicit trait import enables trait-bounded call")
  `fixtures/err_parse_open_trait_requires_export.xsh`
  `fixtures/trait_export_open_declares_open_trait.xsh`
  `fixtures/trait_export_sealed_trait_local_impl.xsh`
- [ ] LSP auto-import for traits (`Eq`/`Ord` etc.) when bounds are unresolved.
- [x] Introduce trait hierarchy (`trait Ord: Eq`) and enforce supertrait checks.
  Regression tests:
  `fixtures/trait_hierarchy_ord_implies_eq_operator.xsh`
  `fixtures/trait_hierarchy_transitive_supertrait_operator.xsh`
  `fixtures/err_type_trait_supertrait_unknown.xsh`
  `fixtures/err_type_trait_supertrait_self_cycle.xsh`
  `src/checker/subtype_wbtest.mbt`
  ("trait subtype supertrait relation",
  "api version bump treats supertrait bound as looser")
- [x] Introduce MoonBit-style `derive(...)` for core-library traits.
  Regression tests:
  `fixtures/derive_struct_eq_marker_impl.xsh`
  `fixtures/derive_struct_ord_implies_eq.xsh`
  `fixtures/err_type_derive_unknown_trait.xsh`
- [x] Stabilize trait alias imports with bounds/supertraits.
  Regression tests:
  `src/xsh/xsh_integration_test.mbt`
  ("xsh integration trait alias import satisfies imported bound",
  "xsh integration trait alias keeps supertrait chain")
- [ ] Restrict API semver checks to exported symbols only.

- [ ] Fixture runner import support:
  `fixtures/*` currently uses `Runtime::eval_script` (no import resolution),
  so import-based RED fixtures stay with `"TODO": true`.
- [ ] Decide and implement separator consistency policy
  (enum/struct: `,` vs `;`, plus formatter normalization).
  RED fixture:
  `fixtures/todo_struct_comma_separator.xsh`
- [ ] Decide and implement `Int` boundary policy for min literal parsing
  (direct `-2147483648` support or explicit prohibition with diagnostics).
  RED fixture:
  `fixtures/todo_int_min_literal.xsh`
- [ ] Split wasm stdio profile explicitly
  (core-wasm vs component-wasm) and add compile-time conformance tests.
- [ ] Add optimization-oriented regression tests for recursion/string-heavy paths
  (stack safety, concat complexity hotspots).

### RED fixture rule

- Fixtures above are intentionally marked with `"TODO": true`.
- Current expected behavior: they fail.
- When implementation is fixed, remove `"TODO": true` and set exact
  `last`/`error_contains` assertions for Green.
