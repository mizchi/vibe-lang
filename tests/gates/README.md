# Compiler-gate lanes

`scripts/compiler_gate.sh` is a thin aggregator. The sections it used to
hold live in independently runnable lane scripts:

| lane | entry | owns |
|---|---|---|
| `bootstrap` | `tests/gates/bootstrap/run.sh` | prechecks, seed→stage3 fixpoint, incremental oracles |
| `early` | `tests/gates/early/run.sh` | sections 4–39 (packages, typecheck, effects smoke) |
| `mid` | `tests/gates/mid/run.sh` | section 40 family (SIMD, RC, wasm-gc, evidence-dict), plus 114 and 127 |
| `late` | `tests/gates/late/run.sh` | sections 41–126, less 114 and 127 |
| `selftests` | `tests/gates/selftests/run.sh` | every gate companion `*_test.sh`, serially |

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

These names are a first cut toward the 11 lanes in #2001. Split a coarse
lane by adding a directory, a `run.sh`, a registry `lane` column change,
and a CI matrix entry. Do not add a lane that `ci-required` does not wait
on, and do not leave a lane out of a caller that ENUMERATES lanes --
`scripts/check_gate_lane_coverage.sh` rejects that, because an enumeration
pins the set at the moment it was written and the omitted lane then runs
nowhere while the caller still passes (#2650).

**Lanes are balanced by wall time, and the balance is cache-sensitive.**
`selftests` was carved out of `late` because one script in it,
`check_gate_self_tests.sh`, was 208s of a 419s CI run. Moving it then cost
135s back: it had been compiling things on its way through and leaving the
persistent build cache warm for section 114, which went 15.8s -> 150.7s
with nothing about it changed. 114 and 127 moved to `mid` for that reason,
appended at the END so mid's own sections warm the cache first. Measure
before and after moving work between lanes; the section's own cost is not
the whole story.
