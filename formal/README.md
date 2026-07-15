# Vibe formal model

This directory contains small Lean 4 models of Vibe's effect system and
parallel compiler scheduler. Their sources of truth are
[ADR-0071](../docs/effectset.md) and
[ADR-0068](../docs/concurrency.md), not the current string-based checker or
synchronous eager `Task` implementation.

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

## Epistemic status

`lake build --wfail` proves the theorems about these Lean models and rejects
unfinished `sorry` declarations. It does **not** yet prove that the selfhost
compiler implements either model. Effect rows need an implementation bridge
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
