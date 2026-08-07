# Vibe formal model

This directory contains small Lean 4 models of Vibe's effect system and Error
policy, executable capability/resource contracts, parallel execution/compiler
scheduling, and module system. Their sources of truth are
[ADR-0071](../docs/effectset.md) and
[ADR-0073](../docs/error-effect-policy.md),
[ADR-0068](../docs/concurrency.md),
[ADR-0075](../docs/vibex-runtime-contract.md),
[ADR-0084](../docs/effect-taxonomy-entry-policy.md),
[ADR-0085](../docs/exception-effect.md), plus
[ADR-0070](../docs/module-system-oracle.md). The current string-based effect
checker and synchronous eager `Task` implementation are not sources of truth.
The module model is additionally locked to selfhost loader refinement tests.

## Verified in Phase 1

- resolved effect rows expand to operation identities while retaining generic
  type and region arguments;
- executable normalization preserves the relational meaning of a row;
- order and duplicate operations do not change extensional row equality;
- the executable subset check decides `required ⊆ declared`;
- handling an effect removes only that effect's body operations, then adds the
  requirements of handler arms;
- a resolved `effectset` is transparent and is equivalent to direct operation
  syntax, and whole-effect shorthand agrees with direct enumeration.

The model starts after name resolution. Undefined names, qualified-effectset
membership, namespace collisions, and cycle rejection remain resolver proof
obligations for a later phase. Open row variables, type safety, evidence
passing, and compiler-to-Wasm simulation are also out of scope for Phase 1.

## Verified checked Error policy properties

- checked Error is the adopted executable static policy and rejects a
  transitive bare throw from an empty declared row;
- an admitted checked empty-row term cannot finish by raising Error or by
  performing an undeclared capability operation;
- handling Error removes the static Error requirement under the checked policy
  and converts the modeled exceptional outcome to normal return;
- an Error-declaring checked entry finishes through the runtime boundary as
  either success or a diagnosed Error failure, never as an undeclared
  capability operation;
- ambient Error remains as a rejected comparison witness: it admits a
  transitive bare throw from an empty declared row;
- a deliberately broken checker that drops capability requirements admits a
  concrete undeclared `Fs` operation, preserving a negative witness.

This is a policy model for #944, not yet the full Vibe type-and-effect calculus.
ADR-0073 decides that explicit `with Exception` is a semantic row element, but
the higher-order typing and subtyping proofs remain coupled to #939. The model
also abstracts from payload types, divergence, traps, stack unwinding,
finalizers, and backend exception representation.

## Verified effect-taxonomy and entry-authority properties

The taxonomy model treats capability requirements, ordinary algebraic
operations, and language-reserved typed exceptions as a disjoint sum. It proves
that:

- executable entry, host, row-subset, well-formedness, and spawn checks agree
  with their relational definitions;
- a runnable `.vibex` entry contains no undischarged algebraic operation;
- every runnable capability has an exact host provider and retains its logical
  resource identity as an `OperationRef` argument;
- an operation carrying a resource argument cannot be reclassified as
  algebraic;
- algebraic handlers preserve capability/core requirements, while typed
  exception handlers remove only the exact normalized exception kind;
- child authority is a subset of parent authority, capabilities require
  fork-safe host evidence, and algebraic handler evidence is task-local by
  default.

Executable examples distinguish `SourceRoot` from `CacheRoot`, reject an
undischarged `Logger`, and retain a deliberately broken capability-only
projection that incorrectly accepts `Logger`. This is a taxonomy-level contract
for ADR-0084, not yet a correspondence proof for builtin metadata, the selfhost
checker, WIT projection, provider lowering, or runtime evidence transfer. Those
bridges remain implementation and differential-test obligations.

The metadata classifier closes the gap between resolved `OperationRef` values
and the disjoint taxonomy row. Unique declaration metadata is required;
capabilities carry exactly one resource id, algebraic operations carry none,
and core exceptions carry exactly one normalized type id. The executable
classifier is proved equivalent to its declarative relation, and successful
row classification preserves both well-formedness and row length. Unknown,
duplicate, and malformed metadata fail the complete row. Negative witnesses
show why argument shape must not override declaration class and why `filterMap`
must not silently discard classification failures.

The 15-case executable taxonomy corpus in
`formal/oracle/effect-taxonomy.tsv` records normalized declaration catalogs,
resolved operation rows, and their accepted requirement rows or fail-closed
rejection. `TaxonomyOracleMain.lean` renders the corpus from the Lean model, and
`formal-check` rejects a stale committed snapshot. This is currently a
contract-level Oracle: a selfhost differential bridge remains unavailable until
the compiler exposes the declaration metadata required by the classifier.

The taxonomy-to-capability bridge connects this model to the existing ADR-0075
contract rather than defining another unrelated preflight. It projects exact
capabilities to operation authority plus resource claims, and provider evidence
to host authority plus bindings. The refinement theorem proves that successful
full-row entry/spawn admission implies successful projected ADR-0075 preflight.
The implication is intentionally one-way: examples show that skipping taxonomy
admission drops `Logger`, while dropping resource claims admits a provider with
the right operation/resource id but the wrong nominal resource kind.

## Verified call-typing properties

The typed-core slice for #990 starts from resolved function signatures and
models primitive types, arbitrarily nested nominal generic types, type
variables, positional arguments, and fully-labeled arguments. It proves that:

- nominal type equality retains both the constructor identity and every type
  argument;
- every accepted call carries evidence that argument resolution used the
  declared parameter contract;
- after generic inference, every accepted actual argument equals its
  instantiated parameter type;
- repeated occurrences of one type variable share a single substitution,
  including when they occur below a nominal type constructor;
- the reported return type is the unique instantiation of the signature return
  pattern;
- call arity is exact, and a call uses either positional arguments or labels
  consistently rather than mixing the two modes;
- fully-labeled arguments resolve by ABI label rather than source order, while
  unknown and duplicate labels are rejected;
- builtin signatures use the same call relation as user functions rather than
  a separate per-position allowlist;
- `Map::set` is a functional update returning `Map[K,V]`, and source aliases
  such as `Int64Array = Array[Int]` are normalized before core typing.

The 25-case executable corpus in `formal/oracle/call-typing.tsv` locks positive
and negative witnesses for #938, #981, #983, #985, #986, and #1001. Deliberately
broken head-only and unchecked-argument predicates demonstrate that the corpus
detects type-argument erasure, inconsistent repeated-variable inference, and
argument-resolution bypass.

This slice begins after parsing, name resolution, signature collection, and
generic-bound checking. It does not yet model function values, type-and-effect
subtyping, optional parameters, implicit coercions, evaluation, or Wasm
representation. The embedded Vibe sources are
bridge fixtures. `examples/selfhost-call-oracle.sh` feeds them to the current
selfhost checker and reports semantic drift, but passing the Lean corpus check
alone does not prove implementation correspondence. In particular, the `?` /
`let*` railway desugaring from #941 is outside this call-only slice; a plain
`Result`/`Option` call mismatch is retained as a nominal-head witness without
claiming to model that closed issue's desugaring path.
Remaining checker correspondence gaps, including nominal mismatches and mixed
argument modes, are tracked in #1001; report mode preserves them as explicit
counterexamples until the implementation agrees with the Oracle.

## Verified compiler scheduler properties

- direct imports have a strictly smaller rank, so the modeled dependency graph
  cannot contain a self edge or import cycle;
- a module is ready only while unpublished and after every direct dependency
  has a terminal result;
- a worker receives only its module id and dependency-result snapshot, never
  the coordinator-owned result store;
- if a worker satisfies the canonical-result contract, every scheduler step
  preserves store correctness;
- any two schedules that both reach a complete state have the same result
  store, independent of ready-job completion order;
- a pure canonical linker/emitter therefore produces the same output for both
  schedules;
- the concrete diamond example runs independent frontend/backend jobs in both
  orders, while a deliberately wrong worker fails the correctness contract.

`JobResult` is intentionally abstract: it may be a successful module artifact
or canonical diagnostics. Expected compiler diagnostics must be returned as a
value; an unexpected runtime/trap failure remains outside this model.

The scheduler proof is conditional on `JobCorrect` and both executions reaching
`Complete`. It does not yet prove fairness, termination of a concrete worker
pool, cancellation/finalizer behavior, bounded-channel linearizability, atomic
cache publication, or correspondence with the selfhost compiler. Those require
separate transition/conformance models and implementation differential tests.

## Verified incremental invalidation properties

`Compiler/Incremental.lean` is a bounded snapshot model, separate from the
production compiler cache. A snapshot has independent source-ingestion,
interface, and implementation identities plus direct consumer-to-import
dependencies. It specifies that every changed interface's reverse closure is
invalidated, implementation changes invalidate their owner, source-only changes
are ingestion telemetry with no modeled typing invalidation, and owner
import-plan changes are invalidated. It also proves that a cache entry's
recorded interface/import fingerprint assumptions continue to match when those
identities and the dependency plan are unchanged. The model contains no typing
derivation, so this is cache-key eligibility rather than a language-level typing
soundness proof.

The examples cover an exact no-op, a comment-only source edit, a private body
edit, a public interface edit, an added import, and a transitive consumer. A private implementation edit
invalidates the owner for typing but leaves the consumer's recorded typing-cache
assumptions matched; it nevertheless makes a linked artifact stale when that
artifact recorded the changed implementation. Unrelated implementations are not
part of an artifact entry and do not affect its freshness.

`TypingInvalidated` and `ReverseClosure` remain relational specifications, not
an extracted executable planner or a completeness proof for one. The bounded selfhost observation bridge emits direct dependencies,
ingested-source telemetry, observation-only canonical token-stream implementation and
exported-interface identities, current `rechecked`/`reused` decisions, and
aggregate telemetry. `IncrementalOracleMain.lean` renders the
model corpus. An independently implemented JavaScript shadow planner derives a
bounded plan from before/after observations, compares it with those corpus rows,
requires planned modules to be observed as rechecked, and reports surplus
rechecks as conservative over-invalidation.

Source identity is ingestion telemetry only. The canonical token-stream implementation
identity is a provisional observation, not normalized typed IR or an artifact
identity. Schema-4's canonical checked-value-environment fingerprint is likewise
an observation of the existing effective `TypeEnv`, not a new model identity or
planner input. The Lean model and corpus therefore remain unchanged: they already
model the source/interface/implementation relation, while this slice only adds
clean-vs-warm observation parity and no production cache-key/reuse semantics.
The bridge therefore does not establish a compiler-to-Lean proof, artifact
freshness, or production planner conformance. The new observation is not
incorporated into a production cache key, persistent format, or reuse decision;
as with any compiler-source change, regenerated `codegen_fingerprint.vibe`
still performs the existing whole-compiler artifact-cache invalidation.
Artifact inputs and canonical diagnostic trace equivalence remain future
refinements.

## Verified async execution properties

The async model is a backend-independent labeled transition system for task and
nursery lifecycle state. It proves that:

- cancellation can become terminal only at dispatch, suspend, or blocked-wait
  cancel points;
- requesting cancellation is idempotent and cannot change a terminal task;
- terminal task state and its repeated `join` result remain stable over every
  accepted finite trace;
- a child can spawn only into an open nursery;
- nursery close requires every owned child to be terminal;
- once a nursery is closed, its selected cause remains stable over every later
  accepted finite trace;
- the first observed child failure starts sibling cancellation without being
  overwritten by later failures;
- explicit cancellation of one child is compatible with a successful nursery
  close after all children converge.

Executable examples witness cancellation before first dispatch, completion
winning before a later cancel point, fail-fast sibling cancellation, and
successful close after explicit child cancellation.
Negative examples show that the transition relation rejects spawn into a closed
nursery and close while a live child remains.

The model deliberately omits heaps, OS threads, backend queues, host waitables,
channel buffers and linearization, infinite traces, fairness, and termination.
It treats task terminalization as one logical transition; it therefore does not
yet prove that the concrete #817 unwind implementation executes each registered
finalizer exactly once. It also does not prove trace refinement for the current
synchronous eager `Task` prototype or future cooperative, JSPI/Worker, WASI, and
shared-everything backends. These are implementation bridge obligations, not
properties established merely by `lake build`.

## Verified parallel-refinement properties

The parallel model overlays physical worker slots on the async lifecycle oracle
without adding a second public task semantics. It proves that:

- each physical step projects to an accepted async event, and every finite
  physical trace projects to an accepted async trace;
- running logical tasks and worker assignments remain in one-to-one
  correspondence over every accepted parallel trace;
- a worker may claim only an idle slot and a ready, non-cancelled task;
- two workers can run two independent tasks concurrently, while a second claim
  of an already-running task is rejected;
- completion releases its worker slot while leaving the terminal task in the
  async world;
- under the task-local heap-owner contract, distinct workers cannot access the
  same owned location.

The model serializes physical events as an interleaving. This is adequate only
under the stated no-shared-mutable-location contract; it is not a proof of a
weak-memory or atomic instruction model. The heap-owner map is an abstract
premise, so concrete deep copy, fresh allocation, arena transfer, and Wasm load
and store enforcement remain refinement obligations. Worker fairness,
preemption, host-worker failure, channels, finalizer execution, and actual
backend trace extraction are also not yet proved. Each physical transition
currently carries an explicit same/add/remove-running witness; deriving those
witnesses from a concrete runtime transition and composing task ids with the
compiler scheduler model remain future bridge proofs.

## Verified executable capability-contract properties

The capability model separates semantic operation authority, logical resource
claims, provider lowering, host satisfaction, and physical worker assignment.
It proves that:

- resource identities are normalized effect arguments distinct from type and
  nursery-region arguments;
- executable Bool checks for binding satisfaction, host preflight, and spawn
  delegation agree with their relational definitions;
- successful preflight accounts for every entry requirement, while a missing
  semantic operation prevents `main` from starting;
- child authority is a subset of parent authority and, transitively, host
  authority; a stronger host cannot implicitly grant an operation absent from
  the parent;
- forked child requirements must also belong to the host's fork-safe subset;
- logical resource identity and kind both participate in binding satisfaction,
  so a binding for another bucket does not satisfy the claim;
- provider lowering leaves only unhandled source operations or operations
  required by the provider itself, rather than treating S3 as an Http subtype;
- a physical worker can perform only operations in its currently owned task's
  authority, and those operations remain within the root host authority.

Executable examples cover an S3-read contract, missing provider, wrong bucket
binding, S3-to-Http lowering, read-to-write escalation rejection, and migration
of one task between two physical workers.

The path-scope extension models normalized glob segments as literals, `*`, and
a trailing `**`. Its executable overlap checker is exact for this restricted
grammar: it returns true if and only if a normalized path exists that matches
both patterns. A valid policy permits an overlap within one scope domain only
when both grants carry extensionally equivalent operation authority.
Consequently, every grant matching one domain/path has equivalent authority,
independent of source order or operation-list order.

`overlapWitness` materializes a canonical diagnostic path. A returned
`some path` is proved to match both patterns, while `none` is equivalent to an
empty semantic intersection. Examples pin `src/*` plus `src/generated` to the
witness `src/generated` and disjoint `src/**`/`cache/**` to `none`.

`ScopedEntryContract` composes this invariant with the existing ADR-0075
preflight. Examples reject `read src/**` plus `write src/generated/**`, accept
same-authority overlap and disjoint `src/**`/`cache/**` grants, and retain a
broken first-match evaluator whose result changes when rule order is reversed.
The domain is generic so planning can validate logical resource ids and apply
can validate resolved physical-root ids with the same contract.

The current model does not prove provider implementation semantics, policy
generation, provider-chain termination/ambiguity, manifest/WIT serialization,
concrete path normalization and symlink/case-folding semantics, BindingLock
projection, evidence-vector correspondence, or concrete Wasm worker isolation.
Those are explicit compiler/runtime/provider refinement obligations in
ADR-0075.

## Verified module-system properties

- `index.vpkg` is the only package boundary and nearest-boundary ownership is
  deterministic;
- nested packages cannot directly import parent implementations, nor can a
  parent bypass a nested package facade;
- ownerless sources are public compatibility space, without allowing an
  ownerless importer to bypass an owned package facade;
- implicit build roots are direct production siblings only;
- test/bench companions are not roots, hash inputs, or import targets, while an
  explicitly-run companion inherits its nearest package scope;
- private/draft sources are explicit-only, inherit their nearest package scope,
  and become hash inputs when reached;
- conflicting index spellings and symlink sources make a workspace invalid.

The model classifies an explicit-only source from a supplied reachability
witness. It does not yet prove the filesystem loader's recursive graph walk;
`contract_vpkg_test.vibe` is the current refinement guard for that bridge.

## Verified typing and discipline properties (#1238)

Seven slices of the #1238 roadmap, each modelling a rule the selfhost checker
already enforces. Every slice carries at least one negative witness — a term
the rule must reject — so a vacuous model cannot pass.

**Function variance** (`Typing/FunctionVariance.lean`, #939). Effectful
function values are not implicitly subsumed into pure function types, at any
nesting depth. The negative witnesses pin both directions: a function taking a
pure callback cannot stand where an effectful-callback taker is expected
(reading the argument position covariantly reproduces the #939 bug one level
down), and a function returning an effectful result cannot stand where a pure
return is expected. `FnShape` is a recursion independent of the shared `Ty`, so
the model does not perturb the `Call.lean` / `Oracle.lean` differential data.

**Resume discipline** (`Effect/ResumeDiscipline.lean`, #942, ADR-0050). A
resume token names an operation *and an activation*. Rejected: resume at top
level (falls out of `live [] = []`, i.e. "no resume outside a handler"), double
resume of one token, a token from a different activation, and resume after the
arm has returned — the last one being the evidence that the scope is a dynamic
extent, not a lexical one.

**Match exhaustiveness** (`Typing/MatchExhaustive.lean`, #940). Stated by
*witness* rather than by decision procedure. Rejected: a missing constructor,
and a gap in a nested position — `Wrap(left)` covers the outer scrutinee
completely, so a checker that compares only the outer layer calls it exhaustive.
That is the reason exhaustiveness must recurse.

**Or-pattern binders** (`Typing/OrPatternBinders.lean`, #951). Binder agreement
is stated through a lookup function, so it does not depend on the order the
alternatives are written. `agree_representative` shows every alternative agrees
with one representative, which is what justifies checking the body once in one
environment and reserving one slot per binder.

**Trait coherence** (`Typing/TraitCoherence.lean`, #952). Stated by membership,
so it does not depend on table assembly order. Candidate uniqueness implies
*dictionary* uniqueness — the property elaboration actually relies on. Partial
table inheritance is one-directional (merging can only add conflicts, never
repair them), which is why the check must run after the merge.

**Spawn capture** (`Parallel/SpawnCapture.lean`, #1081). Models the implemented
`TaskGroup` semantics (`checker_spawnable.vibe`'s `sp_spawnable_ok`), **not**
the `Spawn[r]` capability handler of #818 — that design was closed
`not_planned`. Rejected: an endpoint from a different nursery, and a non-Send
value. `endpoint_legality_is_relative` carries what "same-nursery" means: one
and the same endpoint is legal in its own region and illegal in another.

**Channel delivery** (`Parallel/ChannelDelivery.lean`, #1081). The close
protocol of the bounded MPMC channel: close does not touch the buffer, a closed
channel still delivers what it buffered (**`None` means "finished", not
"closed"**), termination is stable, and an empty-open channel is distinguished
from an empty-closed one — the former is precisely the state where `recv_wait`
suspends.

Limits. These are static-rule models; none of them proves the corresponding
selfhost pass implements the rule. Channel *linearizability* needs a history
model rather than this state model and is a separate slice. `Future`/`await`
suspension is not covered here at all.

## Epistemic status

`lake build --wfail` proves the theorems about these Lean models and rejects
unfinished `sorry` declarations. It does **not** yet prove every selfhost
implementation transition. Effect rows need an implementation bridge
such as a JSON oracle plus differential tests, followed by a simulation proof
for the evidence-passing lowering. That lowering is no longer hypothetical —
#817 landed it (replay retired, evidence passing is what the compiler does
today), so the simulation now has a concrete implementation to be a simulation
*of*. Parallel compilation needs a worker-count/order differential oracle for
module results, diagnostics, cache entries, and emitted Wasm bytes.

## Check

```sh
cd formal
lake build --wfail
```

From the repository root, the equivalent project task is:

```sh
pkf run formal-check
pkf run formal-incremental-check
```

`formal-incremental-check` is the focused build for the invalidation model;
`formal-check` remains the complete formal gate. This command also executes `OracleMain.lean` and `TaxonomyOracleMain.lean`, and
rejects stale committed `formal/oracle/call-typing.tsv` and
`formal/oracle/effect-taxonomy.tsv` snapshots. It also tests the call-typing
bridge's report, strict, and checker-error behavior against a deterministic fake
checker. To inspect the generated corpora directly:

```sh
cd formal
lake env lean --run OracleMain.lean
lake env lean --run TaxonomyOracleMain.lean
```

To compare the committed call-typing Oracle with the current selfhost checker:

```sh
pkf run formal-selfhost-oracle
pkf run formal-selfhost-oracle -- --strict
```

The default is report-only because open implementation bugs may be intentional
Oracle mismatches while being fixed. `--strict` exits 1 on any semantic drift.
Both modes exit 2 when the checker cannot run. The comparison task is manual
and non-gating; the Formal workflow still runs only for `formal/**` changes and
does not build the selfhost compiler.
