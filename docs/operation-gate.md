# Compiler Operation Gate

Status: accepted from 2026-06-12.

This document pins the gates and decision criteria for operating the vibe
compiler. Long-term policy and bootstrap-bump details follow
[bootstrap.md](bootstrap.md).

## Cutover Baseline

Adopted baseline:

- source commit: `39eab0519952ca72599b0b7064d00e3fbd2ac302`
- seed tag: `selfhost-cutover-base-2026-06-12`
- seed artifact: `bootstrap/seed/compiler.wasm`
- seed sha256: `f9da8e285fe0c71c33670a2b9a13a49088dee3ec9a46d2175e975968c6b4b26b`
- source of truth: `lib/@vibe/compiler/` and `lib/@vibe/cli/`
- MoonBit `src/`: at cutover, the legacy bootstrap / fallback / host-runner
  layer. Removed later in #594 (2026-06-23) — recovery point is tag
  `moonbit-host-final-2026-06-23` (`59ef040`)

Local cutover sign-off on 2026-06-12:

| gate | value |
| --- | ---: |
| stage0 -> stage1 -> stage2 -> stage3 | green |
| stage2 == stage3 | true |
| generation peak wasm memory | 843 pages / 55,246,848 bytes |
| TOTAL compile ratio | 1.143x |
| TOTAL check ratio | 0.116x |
| compile peak RSS ratio | 1.402x |
| check peak RSS ratio | 0.920x |
| corpus REAL gaps | 0 |
| full-gate | green |

## Development Mode

Put compiler / checker / codegen behavior changes in `lib/@vibe/compiler/`.
CLI command behavior, adapters, the bundle, and the component entry use
`lib/@vibe/cli/` and `lib/@vibe/compiler/` as the source of truth. The old
MoonBit `src/` tree was removed in #594; the current bootstrap boundary is
only the committed seed (`bootstrap/seed/`).

A normal feature or bugfix proceeds in this order:

1. Add a test under `lib/@vibe/compiler/` and confirm Red.
2. Fix the implementation in `lib/@vibe/compiler/` or `lib/@vibe/cli/` and
   make it Green.
3. If needed, sync the bundle with `scripts/generate_bundle.sh`.
4. Pass `pkf run full-gate`.
5. Also pass `pkf run release-check` only when the change affects
   compatibility or shipped artifacts.

If the problem looks like a bootstrap-side failure (the compiler cannot
compile itself, and so on), isolate the cause to `lib/@vibe/compiler/`,
`lib/@vibe/cli/`, the bootstrap scripts, or seed management. The old MoonBit
host (`src/`) no longer exists, so the break-glass path is a checkout of tag
`moonbit-host-final-2026-06-23` — if you use it, keep that work separate from
ordinary feature commits and confirm the policy explicitly.

Keep a bootstrap bump separate from ordinary feature commits. If compiler
source itself starts using new syntax, first produce a seed that understands
that syntax, then migrate the source.

### Perceus / RC codegen

`pkf run test` (`compiler_gate.sh`) is the pre-commit main check, but it is
not the full RC net. Step 40d measures leaks; step 40f runs `VIBE_RC=shadow`
on the #715 shape corpus; step 40f2 smokes three checked-artifact tests.
A dup/drop *under*-provision (the first cut of #1964) still reproduced the
compiler byte-identically and stayed green on the previously existing steps
40d and 40f — only `scripts/unit_test_runner.sh` trapped, when compiled
tests ran `check_program` over nontrivial input.

Changes under `lib/@vibe/compiler/perceus/` or RC-relevant codegen require
a full `scripts/unit_test_runner.sh` run before push, not just the gate.

## Operation Gate

Use the following for ongoing compiler operation decisions.

```bash
pkf run full-gate
```

The old `pkf run selfhost-trial-gate` compatibility alias was removed in
#850 Phase B (it had no remaining callers).

That task checks the following together:

- `generation-gate`: fixed seed -> stage1 -> stage2 -> stage3
- `post-generation-gate` (`scripts/gate.sh --post-generation` -> `trial_gate.sh`):
  the full sign-off set

The old host-comparison lanes (`test-selfhost-corpus-gate` / `perf-kpi` /
`rss-kpi` / component parity) were retired with their scripts when the
MoonBit host was retired (#594). The matching tasks were deleted from the
Taskfile (dead-task cleanup).

Stage generation is pinned at the front of the gate. Running a
post-generation lane first and then generation can segfault the host
runner's Node/Wasm execution, so the Taskfile uses a
`generation-gate` -> `post-generation-gate` dependency chain.

In a short investigation loop, it is fine to run only the pieces you need,
on their own.

```bash
pkf run release-gates   # = scripts/compiler_gate.sh
pkf run generation-gate
```

### Do not enumerate fixtures — pick them up with a glob (#1587)

Do not manage execution of fixtures that contain test blocks with a
hand-written list. `compiler_gate.sh` once had three copies of the same
loop, each with a `for fx in \` plus backslash-continued list. That shape
breaks in two ways.

1. A PR that adds a fixture **always contends for the same last line of the
   list**.
2. Committing a fixture and forgetting to add it to the gate leaves it
   **never executed while still looking like coverage** — adjacent to
   "silently wrong".

This is now unified on `run_test_block_fixtures <label> <glob>`, and callers
must pass a glob (`fixtures/derive_*_test.vibe` and so on). A fixture that
follows the convention starts running the moment it is added. If the glob
matches nothing, the gate fails (the worst outcome is silently running zero
files).

A third state — a fixture that no lane picks up — is closed by
`scripts/check_fixture_execution.sh`. Among `fixtures/**/*.vibe`, every file
that contains a `test` block must satisfy one of:

- it appears in `scripts/unit_test_runner.sh --list` (the `*_test.vibe`
  naming convention; **this is the cheapest**)
- it has a verdict row in `fixtures/typecheck/expected.tsv` (this lane has
  a per-row expected verdict, so a glob cannot replace it; instead we check
  **completeness**)
- something under `scripts/` / `lib/` / `examples/` / `.github/` refers to
  it by name (a bespoke check with its own expected value)
- it is listed in `scripts/fixture_execution_exceptions.txt` **with a
  reason**

If none of those hold, the gate fails and prints four ways to fix it. It is
pure shell and takes ~2s, so it runs at the **front** of `compiler_gate.sh`,
before selfbuild. Standalone: `pkf run check-fixture-execution`.

> When this check landed, 10 files were in the "no lane picks this up"
> state (one #641 Phase 1 acceptance fixture and nine struct fixtures under
> `fixtures/runtime/`). The latter had test blocks **after** the `__DATA__`
> marker, so they were not even valid source
> (`line 13:1: top-level expressions are not allowed`). All of them were
> renamed to `*_test.vibe` and placed on the unit lane.

## Cold FS Compile Memory Observation (#1553)

The full CLI's FS compile can approach wasm32 linear-memory limits only on a
cold persistent-cache run. Measure it separately from the normal operation
loop; each invocation uses a unique temporary run directory for its compiler
cache, output, and logs, and prints deterministic guest `pages` and `heap_ptr`
values (RSS is diagnostic only). `--warm` snapshots its persistent cache into
that isolated run directory and serializes snapshot updates with a lock. Set
`VIBE_FS_HEAP_KEEP_RUN_DIR=1` to retain a run's diagnostics; cold runs can
optionally use `VIBE_FS_HEAP_LOCK_DIR=/path/to/lock` for host-resource
exclusion:

```bash
pkf run measure-fs-heap -- --cold --base path/to/stage2.wasm
# Optional 3.5 GiB (= 57344 wasm pages) failure threshold:
pkf run measure-fs-heap -- --cold --gate --base path/to/stage2.wasm
# Optional byte parity check, at the cost of a second cold compile:
pkf run measure-fs-heap -- --cold --verify-parity --base path/to/stage2.wasm
```

The real measurement is deliberately opt-in rather than an always-on CI lane:
a cold whole-CLI run is materially more expensive than the existing
single-input `selfcompile-kpi` gate. The normal `compiler-gate` does run the
cheap fake-runner protocol self-test, which verifies environment sanitization,
per-run cache isolation, cleanup, locking, and fail-closed parsing without
performing a full-CLI compile. Promote the real `--cold --gate` invocation only
after recording repeated cold-run duration/resource data and a reviewed
threshold rationale. At that point, add it to the existing `compiler-gate` CI
job using that job's already-built stage2 artifact; do not add a second stage
build solely for this measurement. The mark labels are observable call
boundaries, not claims about separately unobservable normalize or link work.

## Stop Criteria

If any of the following happens, pause compiler operation and isolate the
cause.

- stage2 cannot be reproduced from the fixed seed.
- the corpus REAL gap grows.
- TOTAL compile > 2.5x, TOTAL check > 1.33x, or peak RSS > 2.0x reproduces.
- the runner-layer wasmtime/cwasm dependency diverges from portable wasm
  correctness.
- implementing a new feature or CLI change cannot be completed in the
  selfhost source alone (`lib/@vibe/compiler/` / `lib/@vibe/cli/`) and
  would require reviving the retired MoonBit host.
