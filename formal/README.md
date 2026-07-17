# Vibe formal model

This directory contains small Lean 4 models of Vibe's effect system and Error
policy, parallel compiler scheduler, and module system. Their sources of truth are
[ADR-0071](../docs/effectset.md) and
[ADR-0073](../docs/error-effect-policy.md),
[ADR-0068](../docs/concurrency.md), plus
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
ADR-0073 decides that explicit `with { Error }` is a semantic row element, but
the higher-order typing and subtyping proofs remain coupled to #939. The model
also abstracts from payload types, divergence, traps, stack unwinding,
finalizers, and backend exception representation.

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

## Epistemic status

`lake build --wfail` proves the theorems about these Lean models and rejects
unfinished `sorry` declarations. It does **not** yet prove every selfhost
implementation transition. Effect rows need an implementation bridge
such as a JSON oracle plus differential tests, followed by a simulation proof
for the evidence-passing lowering planned in issue #817. Parallel compilation
needs a worker-count/order differential oracle for module results, diagnostics,
cache entries, and emitted Wasm bytes.

## Check

```sh
cd formal
lake build --wfail
```

From the repository root, the equivalent project task is:

```sh
pkf run formal-check
```
