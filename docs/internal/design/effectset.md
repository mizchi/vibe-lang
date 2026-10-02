# ADR-0071: Operation-level effect rows and `effectset`

Status: partial. Rows name operations, `effectset` declares a closed,
transparent set of them, and the checker, handlers, package contracts and WIT
generation all expand it. What is not implemented is the normalized
operation identity the Decision describes (`OperationRef`): rows are still
compared as label strings. Accepting this ADR needs that identity; see
"Implementation status" below.

Related: ADR-0050 (handlers), ADR-0075 (`.vibex` runtime contract), ADR-0076
([effect-evidence-passing.md](effect-evidence-passing.md)), ADR-0084
([effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md)), ADR-0085
([exception-effect.md](exception-effect.md)), #3143.

## Context

An effect declaration is a finite set of operations. When a row could only
name a whole effect, a function that only reads `Env` had to require all of
`Env`, so its type and its package contract claimed more authority than it
used. The smallest unit a row should track is an operation, and a set that is
reused deserves a name — without becoming a new nominal effect or a separate
kind of declaration.

## Decision

A row item is one of:

- an effect name — shorthand for every operation the effect declares;
- a qualified operation, `Effect::Op` — one operation (a host capability
  builtin is an operation too: `Fs::read_file`, #1343);
- an `effectset` name — its declared members, expanded recursively;
- a row variable (`e`) — the open tail of a polymorphic row.

Items are joined with `+` (`with A + B`, #1429).

```vibe
effect Config {
  Get(String) -> String
  Keys() -> Array[String]
  Put(String, String) -> Unit
}

// A qualified effectset must be a subset of its effect.
effectset Config::Read = { Config::Get, Config::Keys }

// Name one operation directly ...
fn lookup(key: String) -> String with Config::Get {
  perform Config::Get(key)
}

// ... or reuse a named set.
fn describe(key: String) -> String with Config::Read {
  lookup(key)
}

// An unqualified effectset may span effects, host operations included.
effectset ReadCaps = { Config::Read, Fs::read_file }
```

Rules:

- An `effectset` body lists effect names, operations and other effectsets. It
  is always **closed**: no row variable, difference, complement or wildcard.
  Order and duplicates carry no meaning. A cycle is a definition error
  (`effectset cycle: A -> B -> A`).
- A **qualified** effectset `E::Name` may only contain operations of `E`. A
  set spanning effects is unqualified.
- Operations and qualified effectsets share one member namespace per effect:
  declaring `effectset Env::Read` next to an operation `Env::Read` is refused
  as ambiguous.
- An effectset is a **compile-time alias**. It has no runtime identity, no
  handler and no continuation of its own: `perform` names an operation, and a
  handler arm names an operation of a declared effect.
- A function's required row must be a subset of its declared row after
  expansion. A function that needs fewer operations fits in a context that
  allows more; calling something that needs `Config::Put` from a function
  declared `with Config::Read` is a type error.
- A generic effect may be instantiated in a row (`with State[Int]`, #1340). A
  row item takes exactly one type argument; a second one is a parse error.
- `Exception` participates like any operation-level row element; its kinds
  (`Exception[E]`) are ADR-0085's subject.

### Handlers

`handle body with { E::Op(..) => .. }` removes `E`'s operations from the
body's row and adds the rows of its arms. A handler covers its effect's
operations exhaustively (ADR-0050), so discharging the effect name and
discharging each of its operations are the same thing; the checker publishes
both spellings so that a callee declared with an operation-level row
(`with Ask::Get`) is discharged by `handle .. with Ask`
(`fixtures/effect_handle_operation_level_discharge.vibe`).

### Package contracts and WIT

An `effectset` may be exported and imported through an `index.vpkg` contract
like an `effect` (`fixtures/contract_effectset_vpkg_main.vibe`). Contract
signature matching expands effectsets on both sides before comparing, so a
contract written `with AskAll` and an implementation written `with Ask::Get`
agree when the sets agree (`fixtures/contract_effectset_signature_alias_main.vibe`).

WIT generation expands every exported signature's row and resolves each
operation to its effect before choosing imports, so an effectset alias or a
lone qualified operation reaches the effect's interface instead of falling
through to the host-capability comment (`fixtures/wit_gen_effectset.vibe`,
golden `fixtures/wit_gen_effectset.golden.wit`). See
[effect-wit-mapping.md](effect-wit-mapping.md).

### Diagnostics

A missing requirement is reported as an operation-level difference, and the
fix-it grants the missing operation rather than widening to the whole effect:

```text
effect row mismatch for 'asks': missing { Ask::Get } (declared { Ask::Other }, requires { Ask::Get, Ask::Other })
  hint: add 'with Ask::Get + Ask::Other' to 'asks'
```

That is the operation-level diagnostic contract pinned by
`fixtures/err_effect_op_level_partial_row_bare_perform.vibe` (#1161). The same
holds for host operations: a function declared `with Fs::read_file` that also
writes is told `missing { Fs::write_file }`. No fix-it ever extends an
effectset's own definition, because that would widen every consumer of the
set.

### Provider axis and consumer axis

An effect name is the **provider** axis: which host or WASI provider
implements it, and so the unit of host imports, WIT interfaces and bindings.
A row is the **consumer** axis: the least authority a caller needs. Finer
consumer granularity is expressed with operation rows and effectsets, not by
splitting a provider label (`Http` into `HttpServer` / `HttpClient`), which
would fragment the implementation contract.

## Normalized identity (decided, not implemented)

The intended normal form, which checking, unification, contract hashes,
diagnostics and codegen would all consume after expansion:

```text
OperationId  = (EffectDefId, OperationIndex)
OperationRef = (OperationId, NormalizedEffectArguments)
EffectRow    = ({OperationRef...}, optional RowVariable)
```

`EffectDefId` includes package and module identity, so two packages that each
declare `effect State` are different, as are two instantiations of one
generic effect. `NormalizedEffectArguments` keeps type arguments
(`State[Int]`), region arguments and logical resource arguments
(`S3[Posts]`) as separate kinds; ADR-0075 makes a resource-qualified operation
the smallest unit of authority, so `S3[Posts]::get_object` and
`S3[Uploads]::get_object` would be different references.

Today rows are comma-joined label strings and comparison is by label:

- operation identity is the spelling `Effect::Op`, not a definition id, so two
  same-named effects from different packages are not told apart;
- generic effects compare by base name (`State[Int]` and `State[String]` are
  the same row element). `Exception[E]` is the one exception: its kinds are
  compared (`exception_kinds_compatible`, ADR-0085);
- there is no `OperationRef` type in the compiler; resource-kind metadata on it
  is #3143.

## Rejected alternatives

- **A new `facet` declaration kind.** It would look like it has its own type
  and handler semantics, heavier than what it is: an alias for a set of
  operations.
- **Separate `EnvRead` / `EnvWrite` effects.** Handlers, mocks and WIT
  interfaces would split, and the fact that both are subsets of one algebraic
  signature would be lost.
- **A nominal effectset.** A full `Env` handler would need a separate
  subtyping or evidence rule to satisfy `Env::Read`; transparent expansion
  makes it plain set inclusion.
- **Aliases over whole-effect atoms.** An alias could not express least
  authority below the effect, which is the point of this ADR.

## Implementation status

Fixtures and gates cite these steps by number.

1. **Parser and printer** — landed. Operation row items and both effectset
   forms parse and round-trip (`SEffectSet`;
   `fixtures/effect_row_operation_item.vibe`, gate 40m).
2. **Resolver checks** — cycles and qualified-name collisions are refused
   independently of declaration order (`es_detect_cycle`,
   `es_qualified_collision`; `fixtures/err_effectset_cycle.vibe`,
   `fixtures/err_effectset_operation_collision.vibe`, gate 40o). Operation
   identity by definition id is not implemented (see above).
3. **Checker expansion and containment** — landed for function rows,
   function-typed parameter rows and local closures. Expansion happens once,
   before statement checking (`es_expand_stmts_effect_rows`), so the argument
   compatibility check and the transitive call-graph check both see expanded
   rows (`fixtures/effect_effectset_expansion.vibe`,
   `fixtures/effect_effectset_param_expansion.vibe`, gates 40n / 40p). A
   `let f = () -> T with E { .. }` written inside a function body is a node of
   the call graph like a top-level function (#1361,
   `fixtures/err_local_closure_effect_leak.vibe`). Builtin calls authorize
   against operation labels as well as effect labels
   (`builtin_call_op_label`, #1343, `fixtures/effect_builtin_operation_row.vibe`).
   Generic effect instantiations are checked at every `perform` and handle site
   (#1340, `fixtures/effect_generic_row_instantiation.vibe`,
   `fixtures/err_generic_effect_perform_arity.vibe`,
   `fixtures/err_generic_effect_row_targ.vibe`); row containment for them is
   by base name, except `Exception[E]`.
4. **Handlers** — landed: a handle discharges the effect name and every
   qualified operation of it (`collect_handle_effects`;
   `fixtures/effect_handle_operation_level_discharge.vibe`, gate 40q).
5. **Contracts, WIT, diagnostics** — landed: contract passthrough (gate 40r),
   signature matching with expansion (`ctr_expand_sig_row`, gate 40s), WIT
   generation with expansion (`wit_es_collect_into` / `wit_es_expand_into`,
   gate 40t) and operation-level diagnostics. Not landed: a semver surface
   diff by operation. The contract surface diff (#731,
   `contract_surface_lines`) compares signature lines as written, so it does
   not expand effectsets and does not attribute an operation added to an
   effect to the functions whose `with E` it widens.
6. **Codegen / evidence** — the evidence lowering resolves effectset and
   qualified-operation rows to effect names itself
   (`edp_resolve_effect_names_into`). Row-polymorphic evidence, which would key
   an evidence vector on `OperationId`, is not implemented; see the "Open"
   section of [effect-evidence-passing.md](effect-evidence-passing.md).

Regression contract still to be met by the normalized identity:

- `State::Read[Int]` and `State::Read[String]` are different operation sets;
- same-named effects and operations from different packages do not collide;
- adding an operation to an effect is reported by the surface diff as a
  widening of every exported function declared `with` that effect.

## Bootstrap gotcha

Several compiler comments cite this section for placing a helper in the same
file as its caller. The workaround is no longer needed. The failure it
avoided — `scripts/generate_bundle.sh` reporting `unknown name: <fn>` when one
commit added a function and a cross-file import of it — came from building the
flatten tool out of the committed snapshot of the previous generation's merged
source. Since #1443 the pinned seed resolves the live tree itself
(`VIBE_EMIT_MERGED_SOURCE`) and the five generated files are not tracked
([bootstrap.md](../operations/bootstrap.md)). What still needs a seed bump
first is new **syntax** used by the compiler's own source.

## References

- D. Hillerström, S. Lindley, [Liberating Effects with Rows and
  Handlers](https://homepages.inf.ed.ac.uk/slindley/papers/links-effect.pdf) —
  rows whose elements are operation specifications (Links).
- D. Leijen, [The Koka Programming Language: Effect
  Typing](https://koka-lang.github.io/koka/doc/book.html#sec-effect-types) —
  extensible, scoped rows and row polymorphism.
- The formal model of expansion and containment: [formal/README.md](../../../formal/README.md).
