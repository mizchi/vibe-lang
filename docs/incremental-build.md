# Incremental build design

Status: design and measurement plan. The current compiler has persistent loader
and type-environment caches, but the final build still merges and code-generates
the whole program. This document defines the user-visible target before changing
that architecture.

Related documents:

- [Build cache layering](build-cache.md)
- [Compiler parallelism](compiler-parallelism.md)
- [Bootstrap and generation builds](bootstrap.md)
- [Editor and LSP behavior](editor-and-debugging.md)
- [Component Model target](vibec-component.md)
- [Lean formal model](../formal/README.md)

## Goals and non-goals

The primary goal is to reduce the latency a user observes after an edit. Compiler
selfbuild is an important large-project workload, but is not a substitute for
measuring ordinary projects.

The first implementation step is measurement. It must not change cache keys or
claim file-level code generation is safe. Generated compiler bundles are neither
benchmark inputs to edit cases nor files that the benchmark may update.

## Roadmap invariants

These hold across every phase of the production roadmap (#1379). They are
constraints on *how* a slice may be built, not a list of work items; changing one
is an ADR-sized decision, not a slice-sized one.

**Identity**

- A physical file is an ingestion/cache shard. Type checking and codegen reuse are
  keyed on the **semantic module**, and eventually the declaration SCC — not on the
  file.
- **mtime is a hint, never a semantic identity.** Its only job is to let the
  compiler skip *recomputing* a content identity. A stat-token match may reuse a
  previously computed source fingerprint; it may not stand in for one.
- **Git commit/author/last-modified dates are never content identity.** For a
  tracked clean file, the blob OID is the strong identity candidate; dirty and
  untracked files fall back to stat + content hash. Behavior outside a Git
  repository must be identical.
- Do not conflate `source_fingerprint`, `implementation_fingerprint`,
  `interface_fingerprint`, `checked_env_fingerprint`, normalized typed-IR
  identity, and artifact-input identity. They answer different questions and
  invalidate on different edits.

**Safety**

- A **missing required recheck is a failure.** Conservative over-invalidation is
  permitted but must be *visible* — reported as residual, never silently accepted
  as conformance.
- The Lean model covers cache-key eligibility and required invalidation. It does
  not claim to prove the compiler's semantics; the current over-invalidation is
  not evidence of planner conformance.
- Publish an artifact only after a successful computation. Failure, cancellation,
  and crash publish nothing — no artifacts, no diagnostics.
- Malformed, truncated, stale, or torn cache state fails closed to a cold full
  check. Never implicitly upgrade an older transport.

**Process**

- Switching from observation to production reuse is staged: shadow first, then
  feature-flagged, then default — with cold/warm parity and the oracle bridge
  green before each step.
- Benchmarks and oracles use a temporary workdir and an isolated cache. They never
  edit a tracked fixture while running.
- Do not paper over missing provenance in a full trait observation by reparsing
  and reprinting source.

### Shadow-only checked module typing aggregate v1/v2 (#1550)

`CheckedModuleTypingArtifact` remains a bounded checker/artifacts experiment, not a
production incremental-build input. `CheckedProgram` remains transparent and
manually constructible in this slice. Consequently neither the schema nor the
`shadow_unattested_checked_module_typing_artifact_from_checked_program` builder
cryptographically or type-system-proves that checking succeeded. The builder
checks only metadata shape and byte agreement with a supplied
`CheckedExportedInterfaceArtifact` v1; manually constructed matching inputs can
produce an artifact. The codec embeds those exact canonical interface bytes and
validates them by strict decode/re-encode.

The v1 commit unit is exactly one semantic module and therefore one singleton
SCC. Multi-member declaration SCC production requires a later producer and
schema revision. Its ordered dependency rows contain only semantic locators and
exported-interface fingerprints, preserving import order and duplicate
occurrences. A separate recorded implementation closure contains the owner and
is sorted lexicographically by semantic locator; duplicate locators are invalid.
Dependency implementations appear in that closure only when actually embedded
or referenced, so interface assumptions and implementation freshness are never
conflated.

Own and closure implementation identities use a closed tag:
`provisional_token_stream_v1` or `validated_metadata_v1`. The former is explicit
conservative syntax identity, not normalized typed IR. All implementation and
dependency identities use the exact positive-length compact fingerprint shape;
the two hash components are bounded by 2147483646 and 2147483628 respectively.
Canonical empty diagnostics mean only a caller-attested successful typing-error
set with the fixed ordering and scope `path,start,end,code,message`; they are not
proof that checking ran. Non-empty structured diagnostics, warnings, and CLI/LSP
diagnostic completeness are ineligible. Checked body state is only
`ineligible:lossless_checked_body_unavailable_v1`—there is no TypeEnv target or
fabricated typed-IR/body reference.

V2 preserves the complete v1 encoding unchanged and adds two separately tagged
identities derived from the same already-ingested `ModuleJob.source`: exact
`compact_string_fingerprint(ingested_source)` and the provisional parser-visible
`provisional_token_stream_v1`. The v2 unattested builder requires observed and
recorded claims to agree and still validates the implementation-closure owner.
The opaque opt-in runtime producer derives both values only after successful
checking. Ordinary `check_module` makes no artifact construction attempt;
diagnosed opt-in checks also make none; successful opt-in checks make exactly
one. An explicit in-memory validator can compare retained v2 bytes with one
current `ModuleJob.path/source/dep_envs`. It recomputes both identities from the
already-ingested source and requires ordered dependency assumptions plus exactly
the singleton owner closure. Success returns an opaque freshness attestation
bound to the exact retained bytes; its snapshot accessor returns those bytes
without decoding or re-encoding. Only an opaque successful `ModuleOutcome` can
mint it—decoded or manually authored bytes cannot. V1, malformed, stale, missing,
diagnosed, or wider-closure inputs return `None`. The legacy `Bool` observation
is only a wrapper over this attestation path. Ordinary checks never enter this
validator. Its attempt counter is test observation, not production telemetry.

The aggregate and its complete-encoding fingerprint are shadow comparison data
only. They are not wired to TypeDb, the TypeEnv v5 transport and persistent cache
namespace v19, TDRE5, interface-v2, artifact-input traces, planner decisions,
reuse, CLI, or a persistent cache namespace. Decoded values establish canonical
bytes, not a checker invocation. Runtime retains v2 bytes only in an opaque,
in-memory successful `ModuleOutcome`; it does not publish or persist them.

## User-visible KPI contract

Measure these endpoints separately:

1. edit to the first accurate diagnostics;
2. edit to settled diagnostics for that revision;
3. edit to a runnable debug artifact;
4. edit to completion of a selected test;
5. edit to a runnable release artifact.

An editor/daemon request carries a source revision. A diagnostic or artifact for
an older revision must never be published as the result of a newer revision.
`stale_publish_count == 0` is a correctness gate, not a timing metric.

Each endpoint is measured cold and warm, with p50 and p95 reported independently
for small, medium, and compiler-sized projects. The edit matrix is:

| Case | Expected future invalidation |
|---|---|
| Exact no-op | No semantic work |
| Comment or whitespace only | No semantic work after canonical hashing |
| Private function body | Owning semantic unit; consumers keep typing results |
| Private signature | Dependent declarations in the same module/package |
| Export implementation, same interface | Consumer typechecking is reused |
| Export type/effect/contract | Complete reverse-dependency closure |
| Generic definition | Template and affected specializations |
| Import or `index.vpkg` | Module plan and affected reverse dependencies |
| Syntax error introduced/fixed | Affected diagnostics, with no stale publish |
| Root module | Worst-case reference case |

Wall time is advisory on shared runners. Deterministic work counters are suitable
for blocking gates: files read, modules parsed/rechecked/reused, interfaces
changed, functions code-generated, cache hits/misses by class, and invalidated
reverse dependencies. Artifact identity, diagnostics, guest heap, host RSS, and
bytes read/written are recorded alongside timings.

The initial executable baseline is `scripts/edit_cycle_kpi.mjs`. It measures the
one-shot `vibe check` path for cold, exact warm/no-op, comment-only, private-body,
and public-interface edits. It requests a disabled-by-default compiler sidecar
for deterministic `db_typecheck_fs` work counters: modules planned, rechecked,
reused, and parse operations. It intentionally does not yet measure LSP
residency, runnable artifacts, or complete invalidation/codegen counts. Its
purpose is to establish whether current persistent caches produce a measurable
user-visible effect before implementing a new artifact format.

### Initial local result (2026-08-02)

Ten repetitions with compiler SHA `7a2632fc5753` and runner SHA
`dac03e9834c9` produced:

| Case | median | p95 |
|---|---:|---:|
| Cold cache | 216.0 ms | 250.4 ms |
| Exact no-op, preserved cache | 218.2 ms | 283.7 ms |
| Comment edit | 216.7 ms | 238.7 ms |
| Private body edit | 229.5 ms | 246.7 ms |
| Public interface edit | 222.3 ms | 317.3 ms |

This tiny two-file, one-shot check shows no stable user-visible cache win: the
cases are within timing noise and process/runner startup dominates. This is a
useful negative baseline. The next measurement should retain the same cases but
use a resident process and a medium import graph; only after telemetry is added
can the timing be attributed to parse/typecheck/invalidation reuse. These local
numbers are advisory and are not a committed regression budget.

A follow-up run with compiler SHA `4ceba401a979` added deterministic
`db_typecheck_fs` work counters. Every run planned two modules:

| Case | rechecked | reused without body parse | parse operations |
|---|---:|---:|---:|
| Cold cache | 2 | 0 | 2 |
| Exact no-op, preserved cache | 0 | 2 | 0 |
| Comment edit | 2 | 0 | 2 |
| Private body edit | 2 | 0 | 2 |
| Public interface edit | 2 | 0 | 2 |

This confirms a real no-op cache win hidden by process startup, but also confirms
the current invalidation problem: even comment-only and private-body edits
recheck the leaf and its consumer. `modules_reused` means any successful module
that avoided a full body parse; it may come from in-memory or persistent state
and is not yet a per-cache-class hit count. The next implementation target is
therefore interface/implementation fingerprint separation, preceded by an
invalidation model/oracle rather than more wall-time tuning.

### Host filesystem ingestion telemetry

The edit-cycle KPI also requests a separate runner-owned sidecar for actual
host filesystem import work. It opts in only when both variables are supplied:

```text
VIBE_HOST_FS_SCOPE_OUT=<sidecar.json>
VIBE_HOST_FS_SCOPE_NONCE=<unique-non-empty-run-id-without-control-characters>
```

`viberun` deletes an old requested sidecar before it executes the core guest,
counts calls at the exact `vibe` host-import boundaries (`fs_read_file`,
`fs_read_bytes`, `fs_stat_token`, and `fs_exists`), and publishes the sidecar
atomically only after a successful guest completion (including explicit
`exit(0)`). The host's post-completion write is not a guest import and does not
contaminate these counters. Failed guests, missing nonces, invalid nonces, and
sidecar publication failures produce no successful observation.

The strict version-1 JSON object has `schema: "host_fs_scope"`, `version: 1`,
the caller nonce, and non-negative integer fields `read_file_calls`,
`read_file_returned_bytes`, `read_bytes_calls`,
`read_bytes_returned_bytes`, `stat_token_calls`, and `exists_calls`.
`read_*_returned_bytes` count bytes returned through that import (after
`fs_read_file`'s existing lossy UTF-8 conversion). This schema describes host
filesystem-import scope only: it does **not** claim compiler source hashes,
cache keys, cache hits, reuse decisions, or a compiler ingestion identity.

`scripts/edit_cycle_kpi.mjs` generates a fresh nonce and fails closed if this
sidecar is missing, malformed, has unexpected fields, contains invalid counts
or a control-character nonce, or has the wrong nonce. It records the result as
`host_fs_scope` alongside—not inside—the compiler-owned
`incremental_typecheck` telemetry. The feature is disabled by default and does
not change compiler source loading, persistent formats, cache keys, or reuse.

The opt-in persistent ingestion-stamp oracle similarly uses isolated gate-off
and gate-on cache histories for a copied package. It proves only that unchanged
and metadata-token-miss successful checks have equal observed invalidation
traces (apart from the freshness nonce) and equal check output bytes/text. It
retains malformed and content-token fallback checks. It also performs a
same-size in-place content mutation and restores the prior mtime: when the host
filesystem reproduces the exact inode/size/mtime token inputs, the oracle
requires the changed bytes to produce a stamp hit with no fingerprint-boundary
read or hash. Platforms that cannot reproduce the exact token report an
explicit capability skip. This adversarial evidence means metadata-token
equality is not a content identity and the stamp is unsafe as production
authority; it remains default-off and opt-in only. The oracle still does not
prove artifact equivalence.

## Trait generic provenance (bounded Phase 3)

The in-memory parser and checker retain bare trait-header parameter names and
positional method-generic rows for provenance. The header names append a sixth
field to transparent `STrait`; checker-retained `EnvTraitDef` appends method
rows seventh, without shifting its prior slots. This is an explicit source
migration for positional consumers. Persistent TypeEnv v3 transports those
trait definitions and method-generic rows, but remains a narrow environment
transport, not a complete clean/warm typed artifact or lossless `CheckedProgram`
claim.

## Dependency transport-environment typing reuse

TDRE5 TypeEnv reuse is enabled by default for the `vibe check` filesystem
check-only lane. Build, codegen, LSP, and direct FS typecheck consumers remain
conservative pending a compact exact-publication design: publishing the current
exact TDRE5A/TDRE5W texts on a fresh selfcompile exceeds the signed 2 GiB guest
heap boundary, while the conservative compile lane remains near 1.11 GB.
`VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE=1` is the strict emergency opt-out for
check-only reuse;
any other nonempty value is rejected. The legacy
`VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE` spelling accepts only empty or
`1` and is otherwise a compatibility no-op. An ordinary incremental
invalidation trace automatically forces reuse off so the trace stays
observation-only. For compatibility, explicitly combining legacy `1` with an
invalidation trace remains rejected.

TDRE5 aliases the exact logical
`ModuleJob` checker input to a previously checked TypeEnv: canonical owner path,
byte-exact owner source, the canonical effective typing-semantics seed (currently
checked versus unchecked `Exception` rows), `resolution_env_seed()`, and every
`(path, canonical TypeEnv-v5 transport text)` row in the exact ordered resolved
direct-dependency projection. The coordinator retains the full accumulated environment cache only
for graph coordination and upsert; it projects each `deps` occurrence in order,
preserves duplicate paths and first-match cache lookup, and fails closed if any
resolved row is missing. The same projected array is passed to `check_module`
and to TDRE5 lookup/publication, so ambient non-direct cache mutations are
semantically irrelevant and avoid quadratic canonical serialization. TDRE5 does
not replace exact transport text with a compact fingerprint. It validates and
republishes the decoded environment under the ordinary conservative fingerprint.
It does not use the
trace-only `vibe-module-interface:v2` observation as a production key, and
malformed, missing, stale, torn, or cross-spliced aliases, witnesses, and targets
fall back to a full check. The alias remains incompatible with the incremental
invalidation trace lane so the two identities cannot be confused.

The v5 TypeEnv codec round-trips every current `TypeEnv` variant, including
trait definitions, impls, generic impl bounds, trait-header parameters,
positional method-generic binders/bounds, and method `TypeExpr` metadata. The
checked-row cache isolation bumps the global persistent cache namespace from
v18 to v19 and replaces TDRE4 aliases/witnesses with disjoint TDRE5 namespaces
and `TDRE5A` / `TDRE5W` envelopes. Old entries are never reinterpreted. A
sidecar is still only an alias to a conservative
TypeEnv commit, not a `CheckedProgram` or lossless typed-IR transport.

A witness is published only after that module's canonical TypeEnv-v5 target and
when every direct dependency already has a validated witness for its conservative
fingerprint. Alias and witness both bind the logical input, target conservative
fingerprint, and exact canonical target text. Reuse reads the raw target,
strictly decodes it, requires an exact canonical re-encode, and verifies the
three-way alias/witness/target binding. Publication order is target, witness,
alias; diagnosed or failed modules publish none of those rows. The production
oracle covers natural dependency transport changes (public signatures,
traits, and impls), sidecar-integrity corruption of dependency rows/order,
ambient non-direct cache irrelevance, valid-but-wrong targets, cross-splicing,
missing/malformed/stale entries, diagnostic non-publication, and multi-level
reuse. Focused checker tests cover package/directory candidate selection,
reexports, duplicate paths/order, first-match cache shadowing, and missing-row
failure. The production oracle treats the default check environment as
reuse-on and uses the explicit disable flag as its conservative control. It
also covers trace forced-off behavior, strict environment diagnostics,
conservative compile output parity, and isolation from v16 entries.

## Artifact boundaries

Checker-time typed-occurrence observation can remove legacy offsets at
statement-owner granularity: each retained row is associated with its checked
statement path. A separate opt-in observation records one append-time role and
checker lane for every legacy row through the centralized identifier, call
result, dot projection, and dot field-name funnels. It distinguishes primary
checking, synthetic rewrites, and auxiliary resume-value rechecks without
post-hoc offset inference. The ordinary checker path allocates no capture and
the legacy `CheckedProgram` shape remains unchanged.

An additional opt-in, opaque successful-check observation is append-aligned
with the same legacy table and records each row's statement path, exact
post-desugar `core::expr_children` expression path, role, lane, and raw checker
type. Its versioned snapshot applies `final_subst` through the shared canonical
occurrence-type formatter. Expression root is `[]`; each child appends its
zero-based structural index. Paths are captured when legacy rows append, never
recovered from offsets, so duplicate offsets remain unambiguous. This contract
is complete-or-none: synthetic rewrites, auxiliary resume rechecks, or a
checker traversal/frame imbalance return `None` rather than claim a partial
path. It is observation-only—not an edit-stability guarantee, typed-IR claim,
persistent artifact, or production cache identity—and ordinary checker calls
allocate no capture state.

`CheckedStatementRootTypeObservation` is a separate successful-check-only,
opt-in root view. It captures the direct checker return type for each retained
expression-bearing `SLet`, `SLetMut`, `SLetPat`, `STest`, `SBench`, and
non-marker `SExpr`, recursively through modules, alongside its retained path
and closed statement kind. Its canonical snapshot applies `final_subst` via the
shared checked-type formatter. Marker or alignment failures return `None`, and
it deliberately has no typed-IR, cache/reuse, import, or production-path
connection.

`CheckedStatementRootTypeArtifact` is a strict opaque v1 transport for that
merged observation. It deep-copies each statement path, accepts only the six
closed root kinds, and freezes each type as final-substitution canonical text.
Its singular marker is `vibe-checked-statement-root-type-artifact:v1\n`;
decoding bounds untrusted counts and lengths by remaining input, rejects
noncanonical fields and malformed rows, and requires exact re-encoding. It
carries no checker-provenance attestation, typed IR, cache/reuse, interface,
trace, or import claim.

A physical file is a useful ingestion/cache shard, but is not always an
independent semantic or code-generation unit. Files in one package can share a
namespace, and declarations can form dependency cycles. Use two layers.

### Physical file artifact

- CST/tokens and recovering parse diagnostics;
- import header and declaration index;
- source spans, documentation, and source map;
- source and canonical semantic fingerprints.

### Semantic module or declaration-SCC artifact

- resolved bindings;
- inferred public type, trait, and effect schemes;
- evidence requirements;
- normalized typed generic IR;
- direct dependency assumptions;
- separate interface and implementation fingerprints.

The scheduler may ingest files independently, but typechecking and codegen reuse
must follow semantic declaration SCCs or module boundaries rather than assuming
that every file is isolated.

## Fingerprints and invalidation

Maintain at least two identities:

- **Interface fingerprint:** canonical exported names, types, layouts promised by
  the contract, trait bounds, and effect schemes.
- **Implementation fingerprint:** normalized implementation IR plus every
  optimization assumption that can affect generated code.

A dependency implementation change with an unchanged interface permits reuse of
a consumer's typing derivation. It does **not** imply unchanged program behavior;
the final linked artifact must still include the new implementation. An artifact
that embeds or specializes dependency code must include that dependency's
implementation fingerprint in its key.

Cache namespaces should eventually be versioned by phase (resolution, parser/AST,
type/interface, link plan, codegen/runtime) rather than invalidating every cache
class on every compiler-source change.

## Normalization and optimization boundary

Normalization used for identity must be deterministic and distinct from
profitability-driven optimization.

### Canonicalization and typed elaboration

Safe candidates for early caching are normalized paths/imports, alpha-normal or
stable symbol identities, canonical type-variable numbering, canonical ordering
of record fields/effect rows/constraints, resolved bindings, type/effect
elaboration, pattern desugaring, and source maps stored separately from the IR.
Comments and whitespace may be excluded from a semantic fingerprint while the
physical source fingerprint still tracks exact editor content.

### Context-independent local optimization

Initially allow only transformations whose assumptions are local and explicit:
closed pure constant folding, CFG simplification, unreachable local block
removal, local DCE that preserves exports, and proven beta/eta reductions.

Cross-module inlining, specialization, or dictionary/evidence elimination is
reusable only when all referenced implementation identities, normalized type
arguments, evidence ABI, target, and optimization mode are in the cache key.

### Whole-program barriers retained initially

Keep export-collision renaming, private namespace rewriting, entry-root DCE,
generic-instantiation closure, global function/type/table/effect index planning,
final representation/memory layout, Wasm section assembly, and whole-program
RC/escape optimization at the coordinator/link step until an independently
linkable fragment format is proven byte- and behavior-equivalent.

## Generics

The internal artifact retains generic schemes and typed generic bodies. A
specialization cache, if introduced, is keyed by:

```text
definition symbol + implementation fingerprint
+ normalized type arguments + evidence/dictionary ABI
+ target/backend + optimization ABI
```

The linker can choose specialization or a uniform dictionary/evidence-passing
representation. Erasing generic parameters in a current backend is not evidence
that a generic module can be represented safely as an independently reusable
Wasm file.

## Component Model decision

The Component Model is a promising package, distribution, host-integration, or
remote compiler-service boundary. It is not the primary internal incremental
artifact format.

WIT does not directly carry arbitrary parametric generic bodies, polymorphic
effect rows, unresolved relocations, specialization requests, or compiler typed
IR. Encoding these through resources, variants, or bytes would lose useful static
information and may add Canonical ABI lift/lower and ownership costs. A component
import can act like an operation dictionary only after the relevant value types
and ABI are concrete.

Use this initial pipeline:

```text
source
  -> typed generic module artifact (internal cache boundary)
  -> specialized/core object fragment
  -> deterministic whole-program linker
  -> core Wasm or wasm-gc
  -> optional Component Model wrapper (package/external boundary)
```

A Component Model experiment should be package-level, monomorphic, and limited
to WIT-admissible exports. Compare build latency, artifact size, runtime overhead,
and composition reuse against direct core-Wasm linking before expanding it.
Putting opaque typed IR in a component custom section is possible, but then the
component is only a container and provides little advantage over a versioned
content-addressed artifact.

## Lean model and proof obligations

The bounded Lean invalidation model lives in
`formal/VibeFormal/Compiler/Incremental.lean`, with proofs and executable
examples in `formal/VibeFormal/Proofs/IncrementalCorrect.lean`. It models
snapshots with distinct source ingestion, interface, and implementation
identities, direct imports, reverse-closure interface invalidation, and
owner-only typing invalidation for implementation-only edits and owner
invalidation for dependency-plan changes. Source-only edits are telemetry and
model no typing invalidation.
It also distinguishes matching consumer typing-cache assumptions from linked
artifact freshness: an unchanged imported interface may keep a consumer cache
key eligible while a changed dependency implementation still makes any artifact
that recorded that implementation stale. The model contains fingerprints, not
typing derivations, so language-level typecheck reuse safety remains a separate
proof obligation. This is a relational model-level contract, not yet an
executable invalidation planner; the model itself does not alter production
cache keys. The bounded observation bridge below compares its observation-only
exported-interface identities, source ingestion identities, provisional
canonical token-stream implementation identities, and telemetry, but cannot
compare production cache-key interface identities or normalized typed-IR implementation
identities because those do not yet exist.

A later conformance bridge must add production interface identities and
final-artifact inputs, then establish correspondence between the executable
planner and the Lean relation before cache-key changes are proposed.

### Current bounded observation bridge

`vibe check` remains unchanged unless both of these environment variables opt
in to the trace sidecar:

```text
VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT=<sidecar.json>
VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE=<unique-non-empty-run-id>
```

The sidecar is schema version 6 and is written **only after a successful
check**. It includes the nonce, canonical module path, direct dependencies,
`compact_string_fingerprint` of each module's **ingested source**, distinct
version-tagged `implementation_fingerprint`, `interface_fingerprint`,
`checked_env_fingerprint`, and `persistent_type_env_transport_fingerprint`,
the observed current TypeDb decision (`rechecked`
or `reused`), and aggregate work telemetry. The interface identity hashes a canonical
`vibe-module-interface:v2` serialization of exported inferred value/function
types (including effects), exported public type/trait/effect/effectset
declarations, and re-exports. For exported traits, schema 6 serializes
header-binder arity and positional association plus every method's positional
generic-binder row, bounds, and signature. Method binders explicitly shadow
trait-header binders; names outside either binder scope remain free/nominal
names. Header and method alpha-renames therefore preserve identity, while
binder arity, association, bounds, signatures, and free/nominal names do not.
Duplicate trait-header binders, missing/surplus method-generic rows, and
unbound/ambiguous bound ownership are encoded as deterministic
malformed-provenance markers rather than omitted.
Quantified variables are alpha-normalized; effect rows, bounds, derives, and
effectset members are lexically sorted/deduplicated. Bodies, comments, private
declarations, and ordinary imports are excluded. The compiler removes a pre-existing requested sidecar
before the check, rejects a missing nonce, and refuses to publish a partial
trace when an observation is missing. Callers must reject a missing sidecar or
a nonce mismatch as stale/failed rather than reusing old data.

`source_fingerprint` remains explicitly **not an interface or implementation
fingerprint**; it is ingestion telemetry only. `implementation_fingerprint`
remains the schema-v3 observation-only `vibe-module-token-stream:v1` hash over
a length-delimited sequence of each lexer's token kind and exact source lexeme.
It preserves every parser-visible syntax distinction, including fields that
today's unlocated AST or printer erases, while excluding comments and whitespace
between tokens, spans, and the module filesystem path. Literal/interpolation
lexemes remain exact, so formatting inside one lexical token may conservatively
change this identity. It is intentionally **not normalized typed IR** and makes
no optimization or artifact-freshness claim. `interface_fingerprint` is likewise
observation-only: it is computed from the successful typed environment for
rechecked modules and reconstructed from the existing cached environment plus
current source surface for reused modules. Schema 4 introduced
`checked_env_fingerprint`: a canonical, length-delimited
`vibe-module-checked-env:v1` serialization of the effective `TypeEnv` value
bindings. It uses the existing canonical type serializer's alpha-normalized
variables and sorted/deduplicated bounds/effects, with `str_lt` value-name
ordering and first-effective-binding deduplication. Traits, impls, type
definitions, effect declarations, and bodies are out of scope. It is a
trace-only format, explicitly not the production persistent TypeEnv codec.
Schema 5 additionally observes `persistent_type_env_transport_fingerprint` as
`compact_string_fingerprint(persistent_type_env_cache_text(env))`: the canonical
complete persistent TypeEnv v3 transport bytes for the checked or reused
environment. It covers transport state omitted by the value-only checked-env
observation, including trait and impl state. Schema 6 changes only the
trace-only interface observation: method-generic provenance is consumed from
the source `STrait` to canonicalize trait methods. The provenance is now also
retained in `EnvTraitDef` and the TypeEnv v3 transport, but no full checked
artifact exists yet. The transport remains TypeEnv-only—not a `CheckedProgram`,
typed IR, exported interface, cache key, or reuse decision.

These observation identities have intentionally different authorities.
`vibe-module-interface:v2` covers only the exported API surface. In particular,
`SImpl` has no exported/public bit, so impl declarations are excluded from that
interface identity rather than being silently treated as public declarations.
Impl bounds and targets are module-visible trait-resolution state and are
observed by the complete persistent TypeEnv v3 transport identity instead.
Neither identity establishes final linked-artifact freshness: the current
runnable-artifact lane continues to use its whole resolved source-group input
identity and compile configuration. Consequently an impl-only edit is expected
to preserve `interface_fingerprint`, change
`persistent_type_env_transport_fingerprint`, and invalidate linked artifacts
through their existing source-group identity. This distinction does not promote
either observation into a production key or reuse decision.

The token-stream, interface, checked-environment, and transport reconstructions
are not charged to the existing TypeDb `parse_operations` counter, so the `rechecked`/`reused`
report remains the current conservative cache-path observation rather than a
claim about total sidecar work. None of these fields is read by a production
cache lookup, incorporated into a cache key, changes a reuse decision, or
changes a persistent cache format. As with every compiler-source edit, the
regenerated whole-compiler `codegen_fingerprint.vibe` still invalidates existing
compiler artifacts; that ordinary versioning is not evidence that any observed
field became a cache-key input. Consequently current decisions remain
measurements of conservative behavior, not formal conformance assertions.

`formal/IncrementalOracleMain.lean` renders the committed deterministic corpus
at `formal/oracle/incremental-invalidation.tsv`; `formal/check-incremental-oracle.sh`
rejects corpus drift. `scripts/incremental_invalidation_oracle.mjs` runs an
isolated-cache, temporary three-module chain through no-op, comment-only,
private-body, public-interface, and dependency-plan edits. For every warm or
incremental snapshot it also runs an isolated clean-cache counterpart and
compares source, token-stream implementation, interface, checked-value-env, and
persistent-TypeEnv-transport identities module by module; TypeDb decisions are
deliberately excluded from that parity comparison. A private-body regression
proves that a private body can change token-stream identity while leaving
checked-value-env identity unchanged. Trait-header/method-generic cases prove
clean/warm parity, alpha-rename invariance under method-over-header scope, and
identity changes for binder association, arity, bounds, signatures, and free
nominal names. The interface observation deliberately continues to read method
generic rows from source `STrait`; the same provenance is independently retained
in TypeEnv v3. Issue #1379 additionally defines a narrow, length-delimited
`CheckedTypeDefsArtifact` v1 for retained `type_defs`, aligned declaration
binders, and the authoritative semantic `final_subst` chain. `SubstCached`
acceleration-bearing substitutions are rejected rather than normalized or
serialized: no invariant establishes that their maps are semantically equivalent
to the rest chain, and v1 excludes them until the `Map[Type]` codegen issue is
fixed. It is not a full
CheckedProgram/TypeEnv artifact, typed IR, cache key/reuse input, interface,
import contract, or trace schema; it leaves schema 6, interface v2, and
TypeEnv v3 unchanged. `TDEffect` operation declarations, `CtFn` effect text, and
accepted final `SubstEffBind` chains are therefore already inside that narrow
artifact. Effect-set declarations are retained separately as the opaque
`CheckedEffectSetDeclarationsObservation`, derived from a successful
`CheckedProgram` without reparsing source. Its deterministic length-delimited
snapshot preserves recursive module-name paths, export bits, declaration order,
and exact ordered/duplicate member text. A separate strict declaration-only
`CheckedEffectSetDeclarationsArtifact` v1 copies that checked-program-derived
observation without sorting, normalization, or deduplication and canonically
encodes the same fields. The artifact does not attest that a manually
constructed `CheckedProgram` passed checking. Its decoder is fail-closed on version/count/length/export-tag
errors, truncation, trailing bytes, and noncanonical encodings (exact
re-encode equality). It is not a CheckedProgram, TypeEnv, inferred/effective
row, typed IR, interface, cache identity, import contract, trace schema, or
reuse input; it changes no runtime or cache policy. Inferred/effective rows remain stringly
`Option[String]` state distributed across final environments, typed occurrences,
and final substitution; typed-occurrence offsets are unstable. A subsequent
narrow #1379 Phase 3 observation records only active root-level direct
`SLet`/`EFn` bindings: its deterministic owner locator is the root statement
index (not edit-stable), and it retains exact source annotation and direct-`EFn`
rows alongside the final substituted `CtFn` row, including a `CtFn` body retained
under a generalized `CtForAll` wrapper. Only the final root binding per name is
observed, and only when that final binding
is itself a direct `SLet`/`EFn`; `SLetMut`, nested lambdas, modules, callback
rows, handlers, and perform sites are excluded. Its length-delimited snapshot preserves raw source
`None` versus `Some("")`, order, and duplicates; it first erases/normalizes
only the effective row with the existing canonical checked-row semantics
(transitive `SubstEffBind`, unordered/deduplicated labels, the current
Error/Exception alias rule, and distinct typed `Exception[E]`). The opaque
observation is fail-closed when owner association is malformed. It has no
decoder or structured EffectRow and is not persistent transport, cache/trace/
interface/import/reuse state. A distinct opaque
`CheckedEffectiveEffectRowArtifact` v1 can deep-copy that existing observation
and strictly transport its exact six tuple fields with a versioned,
length-delimited codec. Its decoder accepts only canonical encodings and the
observer-guaranteed shape (nonnegative strictly increasing owners, unique names,
and annotation kind/presence consistency); it deliberately does not parse row
text or attest that decoded data was produced by checking. It likewise is not
persistent transport, cache/trace/interface/import/reuse state. Consequently
this slice does not claim full effect-row transport or a stable row-to-body
association. The independently opaque
`CheckedTypedOccurrenceExpressionPathArtifact` v1 transports the complete
append-aligned expression-path observation in capture order: retained statement
path, post-desugar `core::expr_children` path, role, lane, and the occurrence
type snapshot after `final_subst`. It deep-copies paths and strings, omits legacy
offsets, and accepts only known role/lane tags and nonnegative path components.
Its strict length-delimited decoder bounds untrusted counts by remaining input,
stops at the first failed parse, rejects integer overflow, truncation, trailing
bytes, and noncanonical equivalents, and requires exact re-encoding. Decoded
bytes do not attest checker success; synthetic/auxiliary checker traversal still
makes the successful-check observation complete-or-none. This artifact remains
post-desugar and capture-order-relative rather than source- or edit-stable, and
is not a complete expression tree, checked body, typed IR, import contract,
interface, cache identity, trace, or reuse input. A separate opaque
`CheckedExpressionStructureObservation` enumerates every expression supplied
through `CheckedProgram.checked_stmts`, including nodes with no legacy
typed-occurrence row, in statement order and depth-first preorder. Production
callers supply retained post-desugar statements, but this structural API does
not attest checker success, post-desugar provenance, or consistency with the
other `CheckedProgram` fields. Its statement paths use the existing
nested-module convention and its expression paths use `core::expr_children`
with root `[]`; each row exposes only the closed expression-constructor kind.
It fails complete-or-none on unlowered `SFnDecl`, cyclic state, or bounded
size/depth exhaustion rather than inventing declaration-only
value/requires/ensures coordinates or risking unbounded traversal. Payloads,
patterns, annotations, names, literals, source offsets, inferred types,
bindings, and effect rows are intentionally absent, so this is only a complete
body-coordinate skeleton—not a checked-body transport or typed IR. Its paths
are post-desugar artifact-local coordinates, not source- or edit-stable
identity, and the observation has no decoder or connection to imports,
interfaces, traces, caches, or reuse policy. A distinct opaque
`CheckedExpressionStructureArtifact` v1 deep-copies exactly that preorder
skeleton and transports only statement path, expression path, and the closed
constructor-kind vocabulary. Its strict length-delimited decoder rejects wrong
versions, unknown tags, negative or overflowing path components,
noncanonical counts and lengths, truncation, trailing bytes, and hostile
unavailable counts, then requires exact re-encoding. Decoded bytes do not
attest checker success or provenance. The artifact remains payload- and
type-free, post-desugar/artifact-local rather than source- or edit-stable, and
is not connected to full checked bodies, typed IR, imports, interfaces, traces,
caches, or reuse policy.
Trait/impl regressions prove impl-bound and impl-target edits change the
complete persistent TypeEnv v3 transport observation while leaving the
exported-interface observation unchanged; the bound case also leaves the
value-only checked-env observation unchanged. Exported type derives,
trait-supertrait edges, effect operation signatures, and effectset members are
separately covered by clean/warm interface-v2 parity and sensitivity checks.
An external
executable shadow planner treats source changes as ingestion telemetry, derives
owner typing invalidation from canonical token-stream implementation changes
and dependency-plan changes, and reverse-closes interface changes over the union of
the before/after dependency graphs. For the bounded corpus it compares that
plan with the relational model rows, requires every planned module to appear as
`rechecked`, and reports additional rechecks as conservative over-invalidation.
A missing required recheck fails the oracle.

With `VIBE_SHADOW_DECISION_DIFF_OUT=<path>` the oracle additionally publishes
that comparison as a versioned `incremental_shadow_decision_diff` v1 JSON
artifact (#1548): per bounded edit case, each module's shadow decision
(`recheck_required`/`typing_reusable`) against the current compiler decision
(`rechecked`/`reused`), classified as agreement or
`conservative_over_invalidation`. A requested stale artifact is deleted before
the run and the new one is published atomically only after every case
succeeded, so a failed run leaves nothing; a missing required recheck fails
the oracle before publication and is never a published row. The gate writes it
to `_build/ci-artifacts/incremental-shadow-decision-diff.json` and CI uploads
it, making the over-invalidation residual visible per run. The artifact
records current conservative behavior only — none of its fields is a
production cache key or reuse decision.

The historical private-body observation is emitted under the explicit
classification `private_dependency_edit_externally_unchanged`. That classifier
fails closed unless `app` has exactly `library` as its sole direct dependency in
both snapshots, the dependency's source and provisional token-stream
implementation identities change, its interface-v2 identity does not change,
and all of the consumer's own observed identities stay unchanged. The
persistent TypeEnv-v5 transport result for the dependency is reported as a
separate `changed`/`unchanged` observation rather than being treated as the
exported interface. Production TDRE5 may reuse the unaffected consumer; the
shadow classifier remains observation-only and does not authorize that reuse.
It does not change trace schema 6, cache namespace v19, TypeEnv-v5/TDRE5
transport, production artifact reuse, or default-gate wiring.

For this comparison, `source_fingerprint` is ingestion telemetry only;
`implementation_fingerprint` is the provisional owner-change trigger. It is
not normalized typed IR. The shadow planner is independently implemented bridge
code, not a proved extraction of the Lean relation or a production planner. It
rejects module-universe changes and dependencies outside the observed universe
rather than silently assigning them semantics.

Required properties are:

1. **Clean-build equivalence:** incremental build after edits has the same
   canonical diagnostics, artifact, and modeled execution trace as a clean build
   of the edited snapshot.
2. **Typecheck reuse safety:** unchanged imported interfaces preserve the
   validity of a consumer's cached typing derivation.
3. **Invalidation completeness:** every artifact whose recorded assumption
   changed is included in the invalidated set.
4. **Schedule determinism:** worker order and cache hit/miss choices do not alter
   the canonical result.
5. **Normalization correctness:** local normalization preserves typing,
   interface, and observable evaluation/effect traces.
6. **Generic compatibility:** specializing normalized generic IR is
   observationally equivalent to normalizing the corresponding specialization.

These remain conditional obligations. The current selfhost bridge observes
dependencies, source ingestion fingerprints, provisional canonical token-stream
implementation fingerprints, reuse decisions, and a versioned canonical
exported-interface fingerprint, and the bounded shadow planner performs the
comparison described above. It does not provide normalized typed-IR or
artifact-input identities, canonical-diagnostic trace equivalence, a
compiler-to-Lean proof, or production planner conformance.

### Bounded artifact-input compile trace

Artifact-input tracing is a separate compile-path slice: `vibe check` reaches
the check-only path and does not exercise persistent runnable-artifact
lookup/store. The current bounded implementation opts in only to the
`file_compile` persistent **pre-strip WASI bump** lane:

```text
VIBE_FS_COMPILE=1
VIBE_RC=0
VIBE_ARTIFACT_INPUT_TRACE_OUT=<sidecar.json>
VIBE_ARTIFACT_INPUT_TRACE_NONCE=<unique-non-empty-run-id>
```

It rejects a missing nonce and every incompatible early/special,
LSP/check-only, instrumented/RC/testmeta lane, deletes a requested old sidecar
before any CLI-mode return or validation, writes the wasm first, then writes the
trace as the final sidecar operation. A failed compile or validation therefore
leaves no trace to be mistaken for this run. Ordinary compile dispatch remains
unchanged when `VIBE_ARTIFACT_INPUT_TRACE_OUT` is empty; this wrapper does not
alter a production cache key, on-disk format, or reuse decision, and it does not
instrument `fs_compile`, module, or profiled lanes.

Strict schema version 2 records the nonce and scope disclaimer, exact
`compile_lane`, persistent artifact kind, entry path/name/mode, and the
unchanged production lookup identity under the explicit name
`production_artifact_input_fingerprint`. It also records the exact existing
`persistent_cache_version_tag()` (the embedded compiler codegen/cache tag,
**not** #1443's `.generated.stamp`), normalized effective compile
configuration, and only a fingerprint plus module/edge-occurrence counts for
an exact dependency plan. That plan is obtained from `module_plan_data_fs`,
therefore preserves planned module order/ranks and every dependency occurrence
(including duplicates); it is not source-group order.

The schema additionally records `resolution_env_seed()` and the loader's exact
`persistent_resolution_context_fingerprint_fs(entry_path,
grouped_source_paths(source_groups))` authority. Collecting that graph and
context evidence is explicit trace-only extra filesystem work after the
ordinary production compile. Because it is a post-compile recollection, the
sidecar is not an atomic snapshot of the bytes used to produce the wasm; a
concurrent filesystem or resolution-context change may describe a later
snapshot. It never changes cache namespace `v19`, artifact
fingerprints, artifact lookup/store/reuse decisions, interface-v2, TypeEnv-v5,
TDRE5, or trace schema 6. A separately named shadow fingerprint uses a versioned,
fixed-order, length-prefixed `vibe-artifact-input-observation:v2` preimage and
existing compact fingerprint. It is observation-only and is never passed to a
load/store/database reuse API. This remains neither a normalized implementation
identity nor a safe artifact boundary.

`pkf run test-artifact-input-trace` runs strict Node parser/schema tests.
`scripts/artifact_input_trace_oracle.mjs <stage2.wasm>` is the isolated
fresh-stage2 oracle used by `scripts/compiler_gate.sh`: it requires cold miss /
warm hit parity, dependency-content and exact plan sensitivity, config and
resolution-context shadow sensitivity without a corresponding production-key
claim, and failed/no-nonce plus LSP/check-only stale-sidecar removal.

## Delivery order

1. Record the current edit-cycle baseline and add cache/invalidation telemetry.
2. Observe source, canonical token-stream implementation, and interface
   identities; prove invalidation-plan properties in Lean and compare real traces
   with the oracle. **Promotion gate:** replace the provisional token-stream
   identity only after a
   normalized typed-IR serializer has deterministic round-trip/differential
   coverage and clean-build artifact parity; only then propose cache-key or
   reuse-policy changes.
3. Cache a minimal typed module/SCC artifact and require clean-build parity.
4. Add generic-template and specialization caches only after their assumptions
   are explicit.
5. Introduce deterministic object fragments and reduce whole-program barriers.
6. Run a package-level Component Model A/B experiment.
7. Apply the same KPI harness to compiler selfbuild and only then set regression
   budgets from repeated measurements on a stable runner.

### Checked expression leaf-payload direct-return artifact

Issue #1379 Phase 3 also provides an opaque
`CheckedExpressionLeafPayloadDirectReturnArtifact` v1 built only from one
complete `CheckedDirectExpressionReturnObservation`. It first reconciles every
observation coordinate with the bounded retained-node preorder and only then
filters to `EInt`, `EBool`, `EString`, `EIdent`, and `EUnit`, preserving exact
payload text and that run's final-substitution canonical direct-return type
text. Its strict length-delimited codec marker is
`vibe-checked-expression-leaf-payload-direct-return-artifact:v1\n`; decoded
bytes do not attest checking, types, provenance, bindings, typed IR, cache,
reuse, imports, interfaces, or trace behavior. This adds no runtime, CLI,
cache, import, interface, or reuse connection.
