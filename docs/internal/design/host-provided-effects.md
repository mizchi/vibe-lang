# ADR-0124: host-provided user effects — `extern effect`, contract-driven import injection, and the residual entry requirement

Issue: [#2656](https://github.com/mizchi/vibe-lang/issues/2656). Related:
ADR-0075 ([vibex-runtime-contract.md](vibex-runtime-contract.md), provider
composition and `Entry.requires ⊆ ComposedHost.provides`), ADR-0084
([effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md), effect
classes and entry admission), ADR-0088
([capability-authorization-surface.md](capability-authorization-surface.md),
`allows` and the resolution ladder; its Non-goals name this issue), ADR-0089
D4/D5 ([wasip3-effect-alignment.md](wasip3-effect-alignment.md)), ADR-0094
([resource-kind-parameters.md](resource-kind-parameters.md), `param_kinds`),
ADR-0112 / ADR-0113
([host-contract-artifact-lazy-cli.md](host-contract-artifact-lazy-cli.md),
[component-build-convention.md](component-build-convention.md)).

ADR-0088 lets a program grant standard host providers (`Console`, `Fs`, ...),
`Exception`, `Async` and its own `effectset`s on an entry row. It cannot grant
an effect the program declares whose operations something outside the program
provides, and it cannot name a user effect the entry body handles itself. The
issue lists three open points. This record decides all three, each from a
measurement of the tree at `cdbdb1da1` (main), checked with a stage2 compiler
built from that commit, on viberun and the node runner.

All three decisions are implemented: decision 1 in #4036, decision 2 in #4056
(`vibe run --provide`) and #4075 (`vibe test --provide`), decision 3 in #4067.
What pins each is under Acceptance; what is not implemented yet is tracked in
#4082.

## The tree before this decision (measured at `cdbdb1da1`)

### Entry admission already classifies through `OperationRef`

Since #3143 (PR #3992) `is_entry_admitted_effect`
(`lib/@vibe/compiler/core/standard_effect_policy.vibe`) lowers a row label to an
`OperationRef` (`standard_operation_ref`) and classifies it against a catalog
(`classify_operation`, `lib/@vibe/compiler/core/operation_ref.vibe`). A
capability, the core exception effect and the runtime effect are admitted; an
algebraic effect and an effect with no catalog entry are not. The catalog is
`standard_effect_catalog()`, built from one table,
`standard_host_provider_resource_defaults`. A user effect has no row in it, so
the classifier answers `None` and admission refuses it. The classifier already
fails closed on a duplicate catalog entry (`effect_catalog_lookup_unique`).

So the hook the first design point needs exists. What is missing is a catalog
row that comes from a declaration rather than from that table.

### No declaration form marks an effect host-provided

Each candidate spelling, checked with `vibe check` (exit status 1 for every
refused one):

| spelling | answer today |
| --- | --- |
| `extern effect S3 { get_object(String) -> Bytes }` | `line 1:8: expected let but got ident` |
| `provider effect S3 { .. }` | `top-level expressions are not allowed; move it into fn main` and `unknown name: provider` |
| `#host` before `effect S3 { .. }` | `unknown # directive: host` |
| `effect S3 with Http { .. }` | `expected { but got with` |
| `effect S3[R: S3::Bucket] { .. }` (ADR-0094's bound) | `expected ',' or ']' in type params` |
| `resource Posts : S3::Bucket` | accepted (`SResource`, #1465), and nothing reads it yet |
| `effect S3 { .. }` plus `fn main allows Console + S3` | `entry point 'main' cannot discharge { S3 }: no host provider or runtime handler owns this effect`, hint `wrap the operation in handle ... with S3 { ... }` (#1683) |

`extern` is already a reserved word (it is in the keyword list of
`lib/@vibe/compiler/core/wasm_import_binding.vibe`), and the parser dispatches
it to `parse_extern_let_stmt` only (`lib/@vibe/parser/parser.vibe`), which is
why `extern effect` stops at `effect` with "expected let". `extern let
%name: T` (`SExternLet`) is the one existing use: a runtime-boundary symbol.
Its binder cannot be referenced from a user expression (`%s3_get(1)` in a
`.vibex` answers `unexpected token: %`), so the word has no user-facing meaning
to collide with.

The representation the checker builds for a declared effect is
`TDEffect(String, Array[(String, Array[Type], Type)], Array[String])` (name,
operation signatures, type parameters;
`lib/@vibe/compiler/core/types_env_cache.vibe`), from the AST statement
`SEffectDef(Bool, String, Array[String], Array[(String, Array[TypeExpr], TypeExpr)])`
(`lib/@vibe/ast/index.vpkg`). Neither carries an owner. ADR-0094 has already
decided that `TDEffect` gains a fourth slot, `param_kinds`, and has not built it.

### The runners inject a fixed set of host imports

Both runners build their import object from a fixed list:

- **viberun** registers each host function with `Linker::func_wrap`
  (`runtime/viberun/src/host_imports.rs`) and links typed foreign modules by
  import-module prefix: `vibe:wasm:<path>` (a core module) and
  `vibe:component:<path>` (a component, bridged through the canonical ABI)
  (`runtime/viberun/src/foreign_link.rs`). Anything else is wasmtime's generic
  refusal. Measured on a hand-assembled core module that imports
  `S3.get_object : () -> i64`:
  ``viberun: unknown import: `S3::get_object` has not been defined``, exit 1,
  before any guest code runs.
- **the node runner** (`scripts/wasm_vibe_host_runner.js`) wraps its import
  object in a `Proxy` whose `get` returns `fallbackModule` for any module name
  it does not list, and `fallbackModule` answers every call with `0n`. The same
  module **instantiates, runs, and the import answers `0`**: exit 0, and with
  `VIBE_DEBUG_IMPORTS=1` the only trace is `[fallback import]
  unknown.get_object(0 args)`. A variant whose `_start` traps exactly when the
  answer is `0` exits 1, which confirms the zero. The runner already refuses
  `vibe:component:<path>` before this fallback for the same reason, in
  `linkForeignWasmModules` (`scripts/wasm_vibe_host_runtime.js`: "left to the
  runner's fallback stub, every call would silently answer 0"). The `vibe`
  module's own proxy throws on an unknown field
  ([capability-host-contract.md](capability-host-contract.md)); an unknown
  *module* does not reach that proxy.

That is ADR-0088 §4's state as the issue describes it: #2828 (the remaining
work #2332 recorded) connected the L3 preflight for standard providers, and
injection is still unconditional. A user effect lowered to a host
import today would be refused on viberun and silently answered `0` on node.

### The perform walk, with and without the user effect on the row

`check_perform_effects_expr_tx_in`
(`lib/@vibe/compiler/checker/effects/checker_effects_perform_effects_expr_tx_in.vibe`)
is the transitive perform walk. It charges a perform, and a call through a
callee's declared row, against the declared row of the enclosing context; a
`handle` adds the effects its arms name to its body's declared row (the
`EHandle` arm). `file_tests_cacheable`
(`lib/@vibe/compiler/checker/effects/checker_effects_expr.vibe`) runs the same
walk over a `test` body with an EMPTY declared row, and reads "zero errors" as
"reaches no effect a handler does not discharge". `collect_unhandled_entry_ops`,
the lexical scan #1961 used, no longer exists in the tree.

Each program below declares `effect Db { Get(Int) -> Int }`; `app` is
`fn app() -> Int with Db { perform Db::Get(1) }`. Column (a) is the entry
written `fn main allows Console { .. }`, so the walk runs without `Db` on the
row. Column (b) is the same body under `fn main allows Console + Db { .. }`;
the admission error on the `Db` label itself (`cannot discharge { Db }`, at the
row) appears in every (b) cell and is not repeated.

| # | body | (a) row without `Db` | (b) row with `Db`, besides admission |
| --- | --- | --- | --- |
| r1 | `handle { perform Db::Get(1) } with { Db::Get(n) => resume(n + 41) }` | clean; runs, prints `42` | nothing |
| r2 | `perform Db::Get(1)` outside, `handle { 0 }` beside it | `cannot discharge { Db::Get }` at the perform | `cannot discharge { Db::Get }` at the perform |
| r3 | `handle { app() } with { Db::Get(..) => .. }` | clean; runs, prints `42` | nothing |
| r4 | `app()` outside any handler, `handle { app() }` beside it | `cannot discharge { Db }` at the outside call | **nothing** |
| r9 | `let f = () -> Int with Db { .. }`, `f()` outside the handler | `cannot discharge { Db }` at `f()` | `cannot discharge { Db::Get }` at the perform in the lambda |
| r10 | the same lambda, `f()` inside the handler | clean | `cannot discharge { Db::Get }` at the perform in the lambda |
| r11 | `call_it(g = () -> { perform Db::Get(1) })`, `call_it` declared `with Db`, no handler | `cannot discharge { Db }` at the call | `cannot discharge { Db::Get }` at the perform |
| r12 | `run(g = get1)` with `fn run[e](g: () -> Int with e) -> Int with e`, no handler | `cannot discharge { Db }` at the call | **nothing** |
| r14 | `handle { get1() } with { Log::Emit(..) => .. }` (a handler for another effect) | `cannot discharge { Db }` at `get1()` | **nothing** |
| r5 / r8 | an unannotated lambda that performs `Db`, called outside / inside the handler | `cannot discharge { Db::Get }` at the perform in the lambda, both | the same, both |

Three readings:

1. **Under a row WITHOUT the user effect, the walk sees through calls.** r4,
   r11 and r12 are refused where the unhandled call is, through the callee's
   declared row, a callback parameter's row and a row variable instantiated by
   a named function. That is the property the lexical scan lacked.
2. **Under a row WITH the user effect, it does not.** r4(b), r12(b) and
   r14(b) report nothing: the `Db` on the row satisfies the call, and the
   walk's entry-specific branch (the `EEUndischargedEntryEffect` arm) fires only
   for a direct `perform` (r2). Before decision 3, only admission stood between
   those programs and a run that reaches an unhandled `Db`. The same row also
   over-refuses r10, which is clean without `Db` on the row. Relaxing admission alone would
   ship exactly the trap the issue warns about.
3. **The walk is conservative, never permissive, on what it cannot see.** An
   unannotated lambda is charged at its definition under the entry's row (r5,
   r8), so r8 is a false refusal, already today. A handler whose arms name no
   known operation would set `body_in_handle` and silence every check inside
   it, but a wildcard arm does not parse: `handle { 0 } with { _ => resume(0) }`
   answers `handler-set arms must name a fully qualified operation such as
   Exception::Throw(_)`. A callee with no row that performs `Db` is refused at
   the callee (`effect row mismatch for 'app': missing { Db::Get }`), so it
   never reaches the entry unaccounted.

## Decision

### 1. `extern effect` declares a host-provided effect; its class is read from the declaration

```vibe skip
// doctest-skip: the decided syntax; `extern effect` does not parse yet (#2656)
extern effect Kv {
  get(String) -> String
  put(String, String) -> Unit
}

fn main allows Console + Kv {
  Kv::put("k", "v")
  println(Kv::get("k"))
}
```

- **Spelling.** `extern effect Name { ops }`, optionally `export extern effect`.
  `extern` already means "supplied outside the program" and is reserved; the
  parser's `extern` dispatch gains an `effect` arm next to `let`. A provider
  declaration next to `resource` was the alternative. It is rejected because a
  `resource` names a logical identity (ADR-0075) and a provider is a
  binding-time choice (plan / apply), not something the source names: the
  source says the effect is host-provided, the launcher says by whom.
- **Representation.** `SEffectDef` and `TDEffect` each gain an owner slot,
  an enum `EffectOwner { ProgramHandled; HostProvided }`, not a `Bool`. It
  rides the same migration as ADR-0094's `param_kinds`: both add a slot to
  every `TDEffect` site, so they land as one change, and a new slot (unlike a
  new statement variant) turns every site that forgot it into a build error
  instead of a walker whose `_ => ()` arm silently skips the declaration. An
  imported effect's `TDEffect` carries the slot, so the class follows the
  declaration across packages, which is ADR-0094's rule that classification
  comes from metadata and never from "is it declared in this module".
- **Catalog.** `standard_effect_catalog()` becomes the standard rows plus one
  row per declared effect in scope: `HostProvided` gives
  `CapabilityClass(kind)`, `ProgramHandled` gives `AlgebraicClass`. Admission
  keeps calling `classify_operation`; only the catalog it is handed changes.
  `standard_effect_policy.vibe` stays the one table, and it lists only the
  standard providers.
- **Resource kind, and ADR-0094.** With no resource parameter, an `extern
  effect` is a capability on the singleton `Process::Root`, exactly as `Fs` is
  today, so this does not wait for ADR-0094. Once `param_kinds` exists,
  `extern effect S3[B: S3::Bucket] { .. }` declares its kind through the bound,
  and the label lowering (`standard_operation_ref`'s successor) reads a bound
  parameter as a `ResourceArgument`: `allows S3[Posts]` with `resource Posts :
  S3::Bucket` classifies as `CapabilityRequirement(.., "S3::Bucket", "Posts")`.
  An omitted argument of a non-singleton kind has no default and is refused,
  naming the `resource` to write.
- **What is refused at the declaration.** A name that is a standard provider
  (`extern effect Fs`), extending today's `EEProviderOperationCollision`; a
  type parameter that is not a resource (`extern effect Kv[V]`), because the
  host boundary has no generics (the WIT generator,
  `lib/@vibe/compiler/codegen/wit/wit_gen.vibe`, refuses a type parameter); and
  an operation whose parameter or result type the boundary cannot carry (§2).
  Each message names the edit. Row labels name an effect by its bare name, so
  two packages that both declare `extern effect S3` in one program are
  refused when the program is linked, naming both packages and asking for one
  to be renamed (`refuse_shared_extern_effect_names`,
  `lib/@vibe/compiler/linker/merge/merge.vibe`; a package's contract and its
  implementation are one declaration; two modules outside any package that
  each declare one are two). The import namespace of §2 is
  package-qualified regardless, so a provider binding never depends on which
  package a name came from.
- **Operations are on the capability track.** An `extern effect`'s
  operations are spelled `snake_case` and called as ordinary functions
  (`Kv::get(k)`), the way `Fs::read_file` is, because they are functions the
  host implements and not records a handler receives (#1458, the cheatsheet's
  "Effect classes and how operations are spelled"). `perform Kv::get(k)` is
  accepted exactly where `perform Fs::read_file("x")` is (it checks clean
  today), so the two tracks do not diverge for host effects. A call lowers to
  the import of §2 directly, as a standard provider's call does.
- **It is not handled in the program.** A standard provider cannot be handled
  in-program today either: `handle { Fs::read_file("nope.txt") } with {
  Fs::ReadFile(p) => .. }` answers `handle of effect 'Fs' cannot be compiled
  here: this handle cannot see what one call in its body performs`. An `extern
  effect` follows the same rule, and a handle naming it is refused with the
  edit "bind a provider at launch instead". A test mocks a host effect by
  binding a mock provider (§2), which keeps the division this record draws:
  the source says the effect is host-provided, the launcher says by whom.
  Making host effects handleable would route every call through evidence
  passing, which is a separate decision for standard providers and extern
  effects together.
- `entry_user_effect_operations` (the set the entry walk treats as "must be
  handled") collects every `SEffectDef` today; it collects only
  `ProgramHandled` ones after this.

### 2. A host-provided effect becomes contract-driven imports that a launch-time provider satisfies, refused before `main` when none is bound

- **The import is the contract.** Each operation of an `extern effect` in the
  entry's residual requirement (§3) is one core import, module
  `vibe:effect:<effect id>`, field the operation name, with the vibe-raw ABI the
  `vibe.*` host imports use (tagged `i64`, packed string). `<effect id>` is the
  declaring package's `name` from its `index.vpkg` plus `/` plus the effect
  name (`@acme/kv/Kv`), or `./Kv` for a declaration outside any package, so two
  packages' `S3` cannot meet in one import namespace. This follows ADR-0112's rule
  "Required is the import section": the host refuses by import name, and here
  the grant label is the module name itself (one module per effect), so the
  `used` rows ADR-0112 needs for many-to-one `vibe.*` fields are unnecessary.
  The prefix scheme is the one the runners already dispatch on
  (`vibe:wasm:`, `vibe:component:`).
- **The provider.** A WebAssembly component exporting the interface the
  existing WIT generator derives from the declaration (it already
  maps a declared effect to `import <kebab E>: interface { <kebab op>:
  func(..) }`; [effect-wit-mapping.md](effect-wit-mapping.md)), bound at
  launch: `vibe run --provide Kv=./kv_provider.component.wasm`, or `vibe test
  --provide` for the test binaries a test run starts. viberun links it
  through the component bridge it has for `vibe:component:<path>`, range checks
  included. That is ADR-0113's "host capabilities are the same mechanism with
  the runner as provider", and it lets the provider itself be a vibe component.
  An embedding host can define the same import names directly; that is the
  same contract with a different provider.
- **Preflight (ADR-0088 L3).** Before instantiation the runner lists the
  `vibe:effect:` imports and requires, per effect, a bound provider whose
  exports cover every imported field at the imported type. Otherwise it
  refuses before the first instruction of `main` with ADR-0075's structured
  diagnostic: the effect, the missing operations, and the flag that binds a
  provider. It never leaves this to wasmtime's generic "unknown import".
- **The node runner refuses the namespace.** It does not run components, so
  it refuses a module with any `vibe:effect:` import in `linkForeignWasmModules`,
  the way it refuses `vibe:component:` now, naming viberun. The measurement
  above is why this is part of the decision and not a follow-up: without it,
  every host operation answers `0` on node.
- **What crosses.** An operation's types must be in the intersection of
  ADR-0089 D4/D5's nominal rules (what the WIT generator maps) and what the
  component bridge carries today: integers (`Int` as `s64`, `Int32`, `UInt32`)
  and `String`, at most one result, `Unit` for none. The issue's
  `get_object(String) -> Bytes` waits until the bridge carries `list<u8>`, and
  is refused at the declaration until then, naming the admitted types.
  `Future[T]` and `HostStream` (D4/D5) wait on the async host contract (#2832).
  A host failure reaches the program as its exception, as for standard
  providers (#2966).
- **Grades.** A bound provider is the grant. `allows Kv?` resolves `Granted`
  when a provider is bound and `NotGranted` otherwise, through the same
  launcher-grant path `perform?` reads for standard providers: `vibe run`
  adds one `Granted` row per `--provide` to the table it hands the compile,
  and `perform? Kv::get(..)` lowers against it. A `NotGranted` call is erased
  before its arguments are visited, so the operation is never imported and the
  preflight has nothing to refuse. A `--provide` spelled like a standard
  provider grants nothing, so it cannot undo a `--deny-*`. The grade moves to
  the instantiate-time branch with the standard providers' (#2825; the
  withheld-capability stub of
  [capability-host-contract.md](capability-host-contract.md) applies
  unchanged).

### 3. The entry row is admitted against the body's residual requirement

Let `R` be the entry's written row after `effectset` expansion.

1. **Classify.** Every label in `R` must classify against the program catalog
   (§1); an unknown label, a row variable, and a duplicate definition are
   refused as today. `R` splits into `C` (capability, exception and runtime
   labels) and `A` (labels whose class is algebraic). `A` holds a bare label
   naming an effect the program declares without `extern` and without a
   resource parameter, and an operation label naming an operation such an
   effect declares (`entry_label_is_algebraic`,
   `checker/effects/checker_effects_entry_residual.vibe`). Two spellings stay
   in `C` even though a declaration matches them: an effect with a resource
   parameter is a capability by its declaration (#3143), and a bare label the
   host policy admits is the host's grant whatever the program declares under
   that name (`lib/@vibe/cli/entry.vibe` declares `effect Profiler` and grants
   `Profiler` on `main`).
2. **Residual walk.** The residual requirement is the set of labels the
   perform walk reports missing when it runs over the body with an EMPTY
   declared row, the probe `file_tests_cacheable` already runs over a `test`
   body: what reaches the entry with no handler in the way. The entry is
   admitted only when the residual is covered by `C`. The diagnostics come
   from the ordinary entry check run with `R` minus `A` as the declared row,
   which for every `A`-effect is the same as the empty row, so every
   `A`-effect operation that reaches the entry outside a handler, directly or
   through a callee, a callback row or a row variable, gets the ordinary "wrap
   in `handle`" diagnostic at its site: r2, r4, r9, r11, r12 and r14 in column
   (a). The walk is never run with `A` on the row, because r4(b), r12(b) and
   r14(b) show that walk admits an unhandled call.
3. **Root-provider audit.** Each label in `A` must be discharged by a `handle`
   in the entry's own body, an arm naming that effect or operation. An `A`
   label the body never handles is refused as vacuous ("remove `Db` from
   `allows`; nothing in `main` handles it"), the same stance ADR-0088 takes on a
   `perform?` whose `NotGranted` arm could never run.
4. **Contract.** `A` is recorded as the entry's handled set (ADR-0075's
   `P.handles` of the root provider) and never reaches `Entry.requires`, the
   import list, the WIT world or the preflight. `Entry.requires` is the
   residual requirement, which by step 2 contains no `A`-effect, so an
   `extern effect` gets a `vibe:effect:` import only when the body reaches it.
   That is `Outstanding' = (Outstanding - handles) ∪ requires` with the entry
   as the first provider.

So `fn main allows Console + Db { handle { app() } with { Db::Get(n) => .. } }`
(r3) is admitted with `Db` recorded as handled at the root; r4 under the same
row is refused at `app()` with the edit that fixes it; and r8 stays a false
refusal exactly as it is without `Db` on the row, because the rule changes
which row the walk sees and not what the walk does. `test` / `bench` /
`example` rows follow the same rule (ADR-0088's one policy for every entry).

## Consequences

- Admission stays one classifier over one catalog. The catalog gains rows from
  declarations; the name table does not grow.
- The node runner's unknown-module fallback is no longer reachable for a
  host-provided effect. It stays reachable for any other module name the
  compiler might emit, and still answers `0` there.
- An `extern effect` whose operations take `Bytes`, a list or a record cannot
  be declared until the component bridge carries the type.
- Allowing a program-handled effect on `allows` adds no authority. It records
  which effects the root handles, which is what a reviewer of an entry row asks.

## Non-goals

- Resource-qualified host effects beyond what ADR-0094's `param_kinds` brings.
- The plan / apply phase and a persisted binding lock (ADR-0088 L2, no owner).
- Providers composed from providers (`S3 → Http`) beyond one launch-time
  binding per effect.
- Async host operations (#2832).

## Not implemented yet (#4082)

Each fails closed today:

- extern effects on the wasm-gc backend: the program is refused at build time;
- package-qualified ids: the import module is `vibe:effect:./<Effect>` for
  every extern effect. Two packages declaring one under the same name in one
  program are refused at link time (§1), so they cannot share a provider
  binding.

## Acceptance

ADR-0124 is `accepted`. Each condition is pinned on main:

1. `extern effect` parses, `TDEffect` carries the owner slot, and
   `fn main allows <extern effect>` is admitted through `classify_operation`
   over a catalog row built from the declaration, with no name list added to
   `standard_effect_policy.vibe` -- the `err_extern_effect_*` and
   `extern_effect_entry_ok` typecheck fixtures (#4036, #4056).
2. viberun links a `vibe:effect:` import to a provider bound with `--provide`,
   refuses before `main` when none is bound, and the node runner refuses the
   namespace -- `scripts/test_wasm_import_gate.sh` step 15 and its self-test,
   for `vibe run` (#4056) and `vibe test` (#4075).
3. The residual rule admits r1 and r3 under `allows Console + Db`, refuses r2,
   r4, r9, r11 and r12 at the unhandled site, and refuses an `allows Db` the
   body never handles -- the `entry_allows_*` / `err_entry_allows_*` typecheck
   fixtures with their messages in `fixtures/typecheck/expected.tsv`, and
   `fixtures/entry_allows_handled_effect_test.vibe` on both backends (#4067).
