# Reuse formal representatives within one publication

## Change

`callee_formal_bindings` computes `formal_var_reps(s)` once for its whole call
table. Previously each call recomputed the same representatives through the
completed substitution. Both the substitution and formal records are read-only
throughout the publication. An empty call table returns an empty result directly.

The shared array is local to this invocation. Another publication recomputes it,
so changes in substitution, binder spelling and collisions remain visible.
Display substitution and binder-qualified marked publication retain their own
existing rules. Substitution authority, cache formats and global state are
unchanged. This addresses #3644, a bounded follow-up to #2833.

## Measurement

Baseline: main after #3643, `db57c14018898115768f9978ff7251610b86ae17`.
Both compiler variants were rebuilt from the pinned seed and reached identical
stage2/stage3 bytes within each variant. The ordinary images remove only the
custom `name` section from those named fixed-point images.

Three alternating AB/BA pairs per corpus ran sequentially on an idle WSL host
with Node 24.7.0. A/B compiler, cache and output paths have equal length. Every
cold trial has a private empty cache; warm trials use the same cache in a fresh
process. The flat input is frozen from the baseline generation and disables the
persistent artifact cache. FS controls compile the same candidate source tree
with both compiler variants. Checked-module/body caches are disabled in this
controlled matrix; the separate default KPI uses the unmodified script's defaults.

| Corpus | Baseline median | Candidate median | Wall delta |
|---|---:|---:|---:|
| Actual flat compiler, uncached, emitted RC=0 | 79.104 s | 45.662 s | -42.28% |
| FS compiler closure, cold, emitted RC=0 | 6.977 s | 6.992 s | +0.22% |
| FS compiler closure, warm, emitted RC=0 | 4.597 s | 4.617 s | +0.45% |
| FS CLI, cold, emitted RC=1 | 19.763 s | 19.721 s | -0.21% |
| FS CLI, warm, emitted RC=1 | 14.503 s | 14.472 s | -0.21% |

Flat baseline times range from 78.512 to 79.571 s; candidate times range from
45.652 to 45.816 s. All three flat pairs improve. FS wall differences are
inconclusive; no FS speedup is claimed.

All 30 ordinary outputs are byte-identical within their corpus. Each flat
output is also the exact ordinary baseline compiler. Six separate CPU-profile
runs preserve the same output. Their median inclusive sampled time under
`callee_formal_bindings` falls from 32.590 s (41.36%) to 0.073 s (0.16%).
The representative computation's inclusive sampled time falls from 32.533 s
to 0.031 s. These parent/child costs overlap and must not be added. Profiled
elapsed times are not used as benchmark walltime.

Flat bump allocation falls from 3,099,819,836 to 3,080,179,596 B (-19,640,240 B,
-0.63%). Reserved pages remain 48,802. This is primarily a CPU optimization;
allocation volume is not live memory, reserved capacity or peak RSS.

Three additional alternating pairs through the ordinary
`scripts/selfcompile_kpi.sh` entry show 1,022,547,624 -> 1,021,292,024 B
(-1,255,600 B, -0.12%); both reserve 18,663 pages. Wall medians are 7.950 and
7.940 s and do not establish a speedup. The committed heap baseline and its
10% tolerance are unchanged.

## Validation

The seven selected formal/effect-row/import/nominal suites pass 148 blocks per
mode on bump, RC and shadow: 444 executions. The publication test file also
passes on GC with `VIBE_NODE_STACK_SIZE=131072` (the default host stack is too
small for this GC compilation). Both compilers are passed explicitly.

The four publication tests pass against the original implementation, read
through a native source overlay. A second overlay removes the representative
information while keeping display substitution intact: the new partial-argument
test fails at runtime. This proves the test detects a lost formal in a partly
unresolved type. Tests also cover changed substitutions, renamed binders,
clashes, retained prior results, empty tables and the existing 255/256 threshold.
The four source-layout/binder-authority preflight tests pass.

Full sign-off before commit uses `pkf run release-check`; its outcome is recorded
in the PR. The normal AST-required pre-commit hook remains enabled.

## Reproduce

The [raw record](../../../bench/perf/analysis/formal-representative-reuse-2026-10-27.json)
contains source and artifact hashes, generation receipts, all timing samples,
profile summaries, default-KPI controls and a replay program. Rebuild the two
source snapshots from the pinned seed, retain the ordinary compilers as
`a/compiler.wasm` and `b/compiler.wasm`, and the baseline flat input as `flat.vibe`
under a fresh `_build/formal-reps-replay-2026-10-27` directory. Use this PR's
compiler sources for the fixed FS controls. The replay refuses changed compiler,
input or implementation bytes and refuses to overwrite an existing timing record.
Run with Python, Node 24.7.0 and the repository wrapper runner available:

```bash
python3 - <<'REPLAY'
import json
from pathlib import Path
record = json.loads(Path("bench/perf/analysis/formal-representative-reuse-2026-10-27.json").read_text())
exec(compile(record["reproduction_python"], "formal-representative-replay", "exec"))
REPLAY
```
