# Vibe formal model

This directory contains a small Lean 4 model of the Vibe effect system. The
source of truth for Phase 1 is [ADR-0071](../docs/effectset.md), not the current
string-based checker representation.

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

## Epistemic status

`lake build --wfail` proves the theorems about this Lean model and rejects
unfinished `sorry` declarations. It does **not** yet prove that the selfhost
compiler implements this model. That correspondence needs an implementation
bridge such as a JSON effect-row oracle plus differential tests, followed by a
simulation proof for the evidence-passing lowering planned in issue #817.

## Check

```sh
cd formal
lake build --wfail
```

From the repository root, the equivalent project task is:

```sh
pkf run formal-check
```
