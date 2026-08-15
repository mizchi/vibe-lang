# Selfcompile heap delta policy

Status: **Phase A substrate; not a required CI check yet.** The existing
absolute gate in `ci.yml` remains authoritative until Phase B lands from a
base revision that already contains this controller.

## Why compare base and current in one run

`bench/perf/heap_baseline.txt` is useful investigation history, but one old
absolute number plus a percentage accumulates unrelated growth until a later
change trips it. The delta policy instead reconstructs the latest target base
and the PR merge tree, builds them sequentially at one canonical path, and
measures each twice with cold state. A lower result becomes the next PR's base
automatically; CI never rewrites a baseline.

The base revision's `bench/perf/selfcompile_heap_policy.json` is the authority
for a run. Editing that policy cannot make the same PR pass. Its emergency cap
is `1,105,822,775` bytes, exactly the maximum enforced by the existing gate;
Phase A does not raise or rebaseline it. The tolerance is zero. A difference
between either pair of trials is an error rather than tolerated noise.

`bench-data` snapshots and `heap_baseline.txt` remain reporting/history only
after Phase B. They are never enforcement inputs to the comparative policy.

## Normalized reconstruction

`scripts/selfcompile_heap_policy.mjs`:

1. resolves full base/head/current identities and synthesizes `merge-tree`;
2. rejects a supplied current merge result whose tree is not that merge tree;
3. reads policy and benchmark input from the base revision;
4. archives base and current sequentially into the same canonical root;
5. deletes that root, generated files, caches, HOME, TMPDIR, and VIBE_HOME
   between revisions;
6. force-generates and verifies the generated fingerprint, then builds stage2
   at one fixed relative path;
7. records the stage2 SHA-256 and runs two exact cold-cache heap trials
   through `scripts/selfcompile_kpi.sh`, using `VIBE_KPI_WORK_DIR` for fixed
   output and cache paths;
8. rejects any build or heap difference when base and current are the same
   tree, catching stable cross-reconstruction drift as well as within-build
   trial drift;
9. applies the base policy and emits one machine-readable JSON summary.

The controller scrubs inherited `VIBE_*`, credentials, `NODE_OPTIONS`, and
other ambient state by constructing a small environment from scratch. The
pinned seed is verified/fetched by the existing generation scripts. Missing
revisions, conflicts, stale merge results, generation/build failures,
malformed output, and nondeterminism fail closed.

Local shape (expensive: two clean generation builds and four compiles):

```bash
node scripts/selfcompile_heap_policy.mjs \
  --repo . \
  --base origin/main \
  --head HEAD \
  --synthesize-merge \
  --pr-number 1801 \
  --canonical-root /tmp/vibe-selfcompile-policy/root
```

CI supplies an event timestamp and the GitHub merge result with `--current`.
The benchmark root source is always copied from base, so a PR cannot make its
own workload easier.

## One-shot growth budgets

Stable growth above zero requires exactly one newly added file under
`bench/perf/selfcompile_heap_budgets/`. Existing, edited, deleted, stacked,
expired, wrong-PR, or wrong-base records cannot authorize growth. A budget on
a non-growing PR is rejected. Unused bytes do not carry forward, and no budget
can override the emergency cap.

Budget schema 1 has exactly these fields:

```json
{
  "schema": 1,
  "id": "pr-1801-feature-name",
  "pull_request": 1801,
  "base_commit": "0123456789abcdef0123456789abcdef01234567",
  "max_increase_bytes": 8000000,
  "expires_at": "2026-09-01T00:00:00.000Z",
  "issue": "https://github.com/mizchi/vibe-lang/issues/1800",
  "feature": "short feature name",
  "rationale": "why this measured growth is necessary"
}
```

The filename must be `<id>.json`; unknown fields fail. Expiry must be after the
run timestamp and no more than 30 days after the base commit. A merged record
is an inert audit record because only a file absent from base can be consumed.
There is intentionally no budget or exception for parser binder authority
work.

## Two-phase rollout and repository authority

Phase A lands policy, controller, tests, documentation, and fixed-workdir
support while retaining the old gate. Phase B must execute the controller
from the trusted base checkout, add a parallel `selfcompile-heap-policy` job to
`ci-required`, then retire the old baseline as gate authority. Building base
and current sequentially is expected to add roughly two clean stage2 builds
plus four KPI compiles, so the job should run in parallel rather than doubling
`compiler-gate`'s critical path.

As of Phase A, GitHub's main ruleset requires no review and does not require
branches to be current with main. Therefore explicit metadata is validated,
but CI alone cannot attest that a person reviewed it, and stale-green TOCTOU
remains possible. Before calling budget approvals “repository-reviewed,”
repository authority must separately require approval/ownership for policy
and budget paths and strict latest-base checks (or a merge queue). Policy code
does not pretend to manufacture those permissions.
