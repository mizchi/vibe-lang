# Compiler-gate lanes

`scripts/compiler_gate.sh` is a thin aggregator. The sections it used to
hold live in independently runnable lane scripts:

| lane | entry | owns |
|---|---|---|
| `bootstrap` | `tests/gates/bootstrap/run.sh` | prechecks, seed→stage3 fixpoint, incremental oracles |
| `early` | `tests/gates/early/run.sh` | sections 4–39 (packages, typecheck, effects smoke) |
| `mid` | `tests/gates/mid/run.sh` | section 40 family (SIMD, RC, wasm-gc, evidence-dict) |
| `late` | `tests/gates/late/run.sh` | sections 41–104 |

`tests/gates/registry.tsv` is the fail-closed inventory (#2001 Phase 0).
`scripts/check_gate_registry.sh` rejects duplicate ids, missing lane
scripts, unregistered section banners, and missing fixture paths.

```sh
bash scripts/compiler_gate.sh              # every lane, bootstrap first
bash scripts/compiler_gate.sh --list
COMPILER_GATE_LANE=early bash scripts/compiler_gate.sh
VIBE_STAGE2_WASM=path/to/stage2.wasm \
  COMPILER_GATE_LANE=mid bash scripts/compiler_gate.sh
```

These four names are a first cut toward the 11 lanes in #2001. Split a
coarse lane by adding a directory, a `run.sh`, a registry `lane` column
change, and a CI matrix entry. Do not add a lane that `ci-required` does
not wait on.
