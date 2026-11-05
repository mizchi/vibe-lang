# Invocation-scoped RC target flags (#1953)

First measurable migration slice: a flag-only `Config` effect, an immutable
CSV snapshot at the RC boundary, and an explicit-flags located parser. The
remaining configuration inventory is in
[`compiler-invocation-config.md`](../../../../docs/internal/design/compiler-invocation-config.md).
#1953 remains open for the FS/cache lane, authority reads and checker policies.

Measured on 2026-11-05 JST, WSL2 Linux, Ryzen 7 7700, Node 24.7.0. Baseline is
`421b3892a9a5c65f2132c42f2260f2b310430a56`. Candidate is this PR's staged compiler
source; the raw record includes its index tree and artifact digests. Experiment
files and an additional reentrancy regression case were added after the
measurements, outside the compiler manifest; the compiler implementation stayed
fixed.

## Own-source selfbuild

Each compiler compiled its own version's source. Three cold/warm pairs per
configuration, AB/BA/AB order, fresh Node processes, isolated caches. Snapshots
moved through the **same literal root, compiler, output and cache paths**.
This measures the cost of adopting the source change, including its input
graph. Outputs are stable within each version; the two versions legitimately
generate different compiler programs.

| Input | Cache | Baseline heap frontier (B) | Candidate (B) | Change | Median wall (s) |
| --- | --- | ---: | ---: | ---: | ---: |
| Standard KPI | cold | 1,125,799,168 | 1,125,941,096 | +0.0126% | 7.794 → 7.569 |
| Standard KPI | warm | 643,677,584 | 643,719,216 | +0.0065% | 4.728 → 4.713 |
| Compiler CLI | cold | 2,465,445,152 | 2,484,292,600 | +0.7645% | 17.055 → 17.066 |
| Compiler CLI | warm | 1,397,902,616 | 1,415,704,560 | +1.2735% | 10.980 → 11.171 |

Flags: `VIBE_FS_COMPILE=1`, `VIBE_RC=0`, `VIBE_IMPORT_ABI=raw`,
`VIBE_INTERNAL_TRUSTED_SOURCE=1`, `VIBE_WASM_MEMORY_STATS=1`. Other cache-policy
flags use their defaults. The frontier comes from the host runner's
`heap_ptr`; it includes the heap base. It is neither process RSS nor a
standalone live-heap measurement. There is a measurable CLI allocation cost;
these walltime samples do not establish a compiler speed improvement.

## Same-input flat RC lane

Both artifacts compiled the same candidate flat compiler source, RC enabled,
without the FS lane. Three fresh processes per artifact, AB/BA/AB order, other
compiler/test jobs stopped. Startup is included in walltime.

| Metric | Baseline | Candidate |
| --- | ---: | ---: |
| Allocated bytes | 3,468,386,716 | 3,468,386,772 (+56 B) |
| Median walltime | 37.755 s | 37.817 s |
| Output bytes | 8,453,772 | 8,453,772 |

All six outputs have SHA-256
`b82b7e81ad1b3a6b6f7947b8ae19c29234642d5fdf194bd9dc45d7a946165126`.
The RC-built compiler was also executed: it compiled a flag-guarded probe,
whose output returned the expected `11` under `VIBE_CFG=alpha`.

The ordinary bump-built distribution decreased from 5,572,340 to 5,555,297 B
(-17,043 B, -0.306%). Candidate stage1, stage2 and stage3 are identical:
`2fe071926e3460166a6a53bd71759bbd48f6fd9c421d06b8cffd197c67242c3a`.

## Reproduce

Build baseline and candidate in separate worktrees using the pinned seed and
`bash scripts/generations.sh build --out-dir _build/config --stage3`. Run
`bash scripts/ensure_generated.sh` in both trees so each snapshot has its five
matching generated SDK files. Keep compiler sources fixed during builds and
measurements. Commit or stage candidate changes first: the own-source driver
copies the **index**, and refuses unstaged changes. Use fresh output directories.

```sh
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OWN_SOURCE_OUTPUT
python3 bench/perf/experiments/invocation-config-1953/measure_flat.py \
  CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 --output FLAT_OUTPUT
```

`measure_own_source.py` removes only the temporary snapshots and per-pair
caches it creates after saving logs, measurements and final output binaries.
[`results.json`](results.json) contains all 30 measurements. Configuration
isolation tests include a poisoned ambient flag set, nested handlers and
exception unwinding, and an outer compiler paused at its flag request while its
handler runs successful and failing inner compiles; forcing the configured RC
entry back to the ambient
parser makes the tests fail. A separate differential probe matched output
bytes or diagnostics across baseline, ordinary candidate and compile-only
candidate in ten flag/trust cases (both production allocator selections).
