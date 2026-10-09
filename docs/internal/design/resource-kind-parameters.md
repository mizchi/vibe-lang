# ADR-0094: Resource-kind parameters — declaration syntax and internal representation

Status: proposed. Steps 0–2 of the implementation order below have landed:
operation-level authorization of builtins, the standard provider policy, and
`resource` declarations with the `Process::Root` singleton kind. Steps 3–6 —
the bounded effect parameter, `TDEffect`'s `param_kinds` slot, and
resource-qualified authority — have not. [#3143](https://github.com/mizchi/vibe-lang/issues/3143)
owns the remaining operation-identity and classifier work; this ADR is
accepted when #3143's done criteria hold, or rewritten to what ships.

Date: 2026-08-02

Related: ADR-0071 (effectset / operation-level rows), ADR-0075 (vibex runtime
contract), ADR-0084 (effect classes), ADR-0088 (capability authorization
surface), #1343, #3143, #2656.

## Context

[ADR-0084](effect-taxonomy-entry-policy.md) separates capability effects from
algebraic effects at the type level by whether an effect carries a
resource-kind parameter. The one point it left open was the **declaration
syntax** for that parameter: `effect Fs[R: Fs::Root]` in its text is notation,
not a decision. This ADR decides the syntax and the matching internal
representation.

The decision is constrained by how the compiler represents effects, and these
facts still hold on main:

1. **Builtin effects have no `TDEffect`.** A host effect is represented only by
   the third slot of the builtin's `CtFn`, an `Option[String]`. No declaration
   of `Fs` exists anywhere: it is the `Some("Fs")` literals in
   `core/builtin_registry.vibe` (`("Fs::read_file", CtFn(..., Some("Fs")), ...)`)
   and in the `builtins_*.vibe` lookup chains.
2. **An effect's type parameters are bare identifiers.**
   `parse_effect_stmt_with_binder_context` (`lib/@vibe/parser/parser_base.vibe`)
   parses the binder with bounds disabled, so `effect Fs[R: Fs::Root]` is a
   parse error and `_` is not a parameter name. Function and impl binders
   accept trait bounds; effect binders do not.
3. **`TaskGroup`'s escape checks match type-argument counts literally.**
   `is_region_tagged_ty` (`checker/checker_builtin_arg_head_rest.vibe`) tests
   `Array::length(targs) == 2` for `TaskGroup` and `== 3` for `TaskHandle` /
   `Sender` / `Receiver`, and `checker/` has a dozen such comparisons. A type
   argument added to one of these types silently falls out of every branch.
4. **Row labels are strings, and generic instantiation lives in the label
   text** (`"State[Int]"`, ADR-0071 / #1340). `row_label_base` cuts the base
   name at `[`. Row containment is instantiation-insensitive.
5. **`wit_gen` classifies by declaration, which is the inverse of ADR-0084,
   and is independent of the checker.** `wit_collect_effect_defs` walks the
   AST's `SEffectDef` statements only: an effect with a declaration becomes an
   imported WIT interface, one without becomes a "host capability" comment.
   ADR-0084 says the opposite (a declared algebraic effect is exactly what must
   not reach the boundary). Changing the checker's representation does not fix
   this; `wit_gen`'s own rule has to change.

## Decision

### 0. Granularity has two independent axes

Every decision below assumes this separation. Conflating the axes lets the
needs of one break the representation of the other.

| axis | unit | whose granularity | what it carries |
|---|---|---|---|
| **provider** | effect name (`Fs` / `Http` / `Socket`) | the **implementation contract**: which WASI / host provider implements it | the host import bundle, WIT interface, binding, resource kind |
| **consumer** | operation (`Http::request`) | **least privilege**: what a caller declares in `with` | `with ...` rows, `effectset`, ADR-0088's `allows` |

- The provider axis is not split for the consumer's sake. Splitting `Http` into
  separate `HttpServer` / `HttpClient` / `HttpIncoming` effects fragments one
  host HTTP provider's contract into three, while the raw import layer stays
  `Http`, so the labels disagree layer by layer.
  `checker/builtin_sigs/builtins_net.vibe` was in that state; its builtins now carry the
  single provider label `Http`. (The `effect HttpServer` / `HttpClient` /
  `HttpIncoming` declarations in `lib/@vibe/http/http_effect.vibe` are
  something else: user algebraic effects for in-process mocking.)
- Consumer granularity is ADR-0071's **operation-level row**: `with
  Http::request` (egress) and `with Http::listen` (serve) are written
  separately, and a bundle is an `effectset` such as
  `effectset Http::Client = { Http::request, Http::response_status, ... }`.
  An effectset is a transparent compile-time alias with no runtime identity,
  so it does not touch the provider contract.
- A resource-kind parameter, the subject of this ADR, is a **third** axis: it
  names *which instance* of a provider (`SrcTree` in `Fs[SrcTree]`) and is
  orthogonal to the operation axis. That is why ADR-0071 keeps
  `NormalizedEffectArguments` as separate kinds — type arguments, region
  arguments and logical resource arguments.

### 1. Declaration syntax: a **bounded parameter** in the type-parameter list

```vibe skip
// doctest-skip: the decided syntax; effect binders do not accept bounds yet (step 3)
effect Fs[R: Fs::Root] {
  read_file(String) -> Bytes
}

// a singleton resource kind is taken with `_` when the name is not needed
effect Stdout[_: Process::Root] {
  write_stream(String) -> Unit
}
```

- No new bracket group and no new sigil. ADR-0071 / #1340 already gave
  `effect State[S]` a type-parameter list; this lets it carry a bound.
- **Whether a parameter is a resource parameter or an ordinary type parameter
  is decided by the kind of the name its bound points at**, not by whether it
  has a bound. If `Fs::Root` in `R: Fs::Root` is declared as a resource kind,
  `R` is a resource parameter; if it is a trait, `R` is an ordinary bounded
  type parameter. The distinction is made at registration, not in the syntax.
- `_` is accepted as a parameter name (an unbound resource parameter).
- **Rejected alternatives**: a separate bracket (`effect Fs[T] for Fs::Root`)
  would spread to the row syntax and double the surface; a sigil (`[%R]`)
  splits resource parameters visually from type parameters and contradicts
  ADR-0071's "one row grammar".

### 2. Internal representation: a **fourth slot on `TDEffect`**; `CtFn` unchanged

```text
TDEffect(name, ops, params, param_kinds)
                    ^^^^^^  ^^^^^^^^^^^ Array[String], parallel to params:
                    |                   "" = ordinary type parameter,
                    |                   otherwise the resource kind's path
                    the existing Array[String] (#1340), in declaration order
```

- **Resource parameters are not split into a separate array**, so declaration
  order survives. The chosen syntax writes both kinds in one positional list;
  with separate arrays `effect E[R: K, T]` and `effect E[T, R: K]` would be the
  same representation, and an explicit instantiation `E[X, Y]` could not say
  which argument is the resource. `params` stays the ordered list of all
  parameters, and `param_kinds` is indexed the same way.
- **The consumers must branch on `param_kinds`.** `effect_tparams`,
  `effect_fresh_targs` and `subst_type_params` keep their signatures, but a
  resource parameter is not an inference variable: it is a logical resource
  identity (`SrcTree` in `Fs[SrcTree]`). `effect_fresh_targs` must not give it
  a fresh `CtVar`; a resource argument resolves to a declared resource whose
  kind is checked against the declaration. Without that branch `Fs[SrcTree]`
  and `Fs[AnythingElse]` unify and the kind check does nothing. So step 3
  below is one unit: the slot, the registration, and the branch in all three
  consumers.
- The slot is appended **last**, the convention of `TDStruct` (#829) and
  `TDEffect` (#1340), so existing positional matches keep working.
  `TDEffect` has three slots on main (`core/types_env_cache.vibe`).
- No ordering rule is imposed on the parameters; the representation keeps the
  order.
- **`CtFn`'s `Option[String]` is not widened.** Making the row structured data
  touches hundreds of `CtFn` matches across the compiler and belongs with
  ADR-0071's `OperationRef` normalization. A resource argument rides in the
  label text like a generic instantiation (`"Fs[SrcTree]"`), which
  `row_label_base` already handles.

### 3. Builtins use the standard provider policy, not a synthesized `TDEffect`

Synthesizing a `TDEffect` for builtin effects is rejected because of what the
checker would then do. Once `effect_is_declared` answers `true` for a builtin,
handler-arm and perform validation (#813 / #828) applies to host effects: a
`handle body with Fs { ... }` has its arm names, payload arities and
**exhaustiveness** checked, and a partial `with Fs` handler is rejected as
non-exhaustive. But a builtin operation lowers to a direct host import call,
and its handler arm never runs (vacuous-handle elimination). Type-checking code
that never executes would reject existing programs. Synthesizing a `TDEffect`
also would not change `wit_gen`, which reads `SEffectDef` statements only
(context item 5).

Instead, `core/standard_effect_policy.vibe` holds the standard provider and
entry-execution policy, keyed by effect name. The registry is keyed by
operation, so provider metadata is not copied onto every operation row. This
is the current execution policy; it does not assign a semantic class to
ordinary user effects.

### 4. The prospective admission model stays separate from today's policy

ADR-0084's capability / algebraic / core-ambient admission model and
`formal/VibeFormal/Effect/Taxonomy*.lean` describe the target. Today's policy
lookup provides only:

- whether a standard host provider exists, and its default resource kind;
- entry-boundary handling of `Error` / `Exception[E]`;
- runtime scheduling of `Async`;
- the test/bench default row and the entry-cache-safe lists.

Whether a module happens to have a `TDEffect` must never decide standard
policy.

### 5. The resource argument is **implicit** for now; the surface does not change

`perform Fs::read_file(...)` and `with Fs` are unchanged. An omitted resource
argument expands to the default singleton (`Fs[Process::Root]`), so existing
code, including the compiler's own sources, needs no change and no bootstrap
bump.

## Implementation order

| step | what | state |
|---|---|---|
| 0 | Builtin calls authorize by operation label too: `with Fs::read_file` / `with Http::request` admit the builtin, so `Http` no longer has to be granted whole | **landed** (#1343, #1359) |
| 1 | Standard provider / entry-execution policy (`core/standard_effect_policy.vibe`) | **landed** (#1496) |
| 2 | ADR-0075 Phase 2: `resource Name : Owner::Kind` declarations and the `Process::Root` singleton kind | **landed** (#1343, PR #1465) |
| 3 | Bounded effect parameters and `_`; `TDEffect`'s `param_kinds` slot and its registration; the kind branch in the three consumers | not started — #3143 |
| 4 | `wit_gen`'s declaration/provider classification (context item 5) | the entry/runtime filtering uses `is_entry_runtime_managed_effect`; the inversion itself is unchanged, and no open issue owns it |
| 5 | The entry's closed-row check (ADR-0084 Phase 3) | the entry-row admission rule has landed (ADR-0084, #1683); the exact closed-row check has not — see [vibex-runtime-contract.md](vibex-runtime-contract.md) |
| 6 | Enforcement, with `Entry.requires ⊆ ComposedHost.provides` as preflight | `vibe run` refuses a required capability its launcher flags withhold (#2828, ADR-0088 L3); resource-qualified requirements wait on step 3 and #3143 |

### Step 1: the policy table

`core/standard_effect_policy.vibe` has independent private owners for
`(label, provider default resource kind)`, the ordered test/bench defaults
(`test_bench_default_effects`) and the ordered entry-cache-safe labels
(`entry_cache_safe_effects`), plus narrow predicates for the `Exception` and
`Async` entry/runtime behaviour (`is_exception_effect_name`,
`is_runtime_scheduled_effect`, `is_entry_runtime_managed_effect`). They keep
the existing output and order without giving ordinary effects a string class.
`verify_standard_effect_policy_coverage` (`core/builtin_registry.vibe`) checks
that every registry effect label has policy metadata; its scope is the
registry rows, since the checker's lookup chains are not enumerable. Moving
the remaining name-keyed special cases into these owners was #1963; a lint in
`scripts/review_lint.vibex` refuses a new bare effect-name comparison outside
them.

### Step 2: `resource` declarations

`resource Posts: S3::Bucket` parses to `SResource(name, kind)`
(`lib/@vibe/ast/index.vpkg`; `parse_resource_stmt` in
`lib/@vibe/parser/parser.vibe`) and goes through the printer and the checker.
`Process::Root` exists as `predeclared_resources` / `is_singleton_resource_kind`
in `core/standard_effect_policy.vibe`, which gave the name the policy's
default-resource-kind column already pointed at its first definition.

- The surface is ADR-0075's: `resource Posts : S3::Bucket`. There is no
  `= <literal>` form, because ADR-0075 keeps physical names and credentials out
  of the guest, and a literal would put a physical name in guest source.
- The checker enforces two identity rules: a name is declared once
  (predeclared names included), and **a resource of a singleton kind cannot be
  declared** — `resource Home : Process::Root` would give the process a second
  name, the alias ADR-0075 otherwise catches at bind time.
- The kind is not checked against a registry, because there is no syntax for
  declaring a resource kind yet, so ADR-0075's own `S3::Bucket` has nowhere to
  be declared. The parser's rule that a kind is a qualified `Owner::Kind` path
  is the only well-formedness rule.
- `resource` is a contextual keyword, recognized only when an identifier
  follows (no statement starts with two identifiers, so the lookahead is
  exact).
- The canonical spelling is `resource Posts: S3::Bucket`, with no space before
  the colon, which is what the CST formatter produces for every annotation; a
  printer emitting ` : ` would make `vibe normalize` and `vibe fmt` disagree,
  as happened in #1429.
- `export resource` is refused. **The `.vibex`-root restriction is not
  enforced**: the checker does not know whether it is looking at an entry file,
  so a private `resource` in a library module is accepted.

## Consequences

- Adding a resource kind as a type argument to an existing type is forbidden
  unless every literal arity check (context item 3) changes in the same
  commit; otherwise the type silently falls out of the checks.
- Row containment stays instantiation-insensitive, so `with Fs` authorizes
  `Fs[Anything]`. Resource-level least privilege takes effect only with
  ADR-0071's `OperationRef` normalization (#3143); this ADR fixes the
  representation first.
- The surface does not change, so the compiler's own sources are untouched by
  steps 0–3.

## References

- [effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md) (ADR-0084)
- [capability-authorization-surface.md](capability-authorization-surface.md) (ADR-0088)
- [effectset.md](effectset.md) (ADR-0071), [vibex-runtime-contract.md](vibex-runtime-contract.md) (ADR-0075)
