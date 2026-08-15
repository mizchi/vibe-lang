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
4. atomically creates an exclusive, stable-name mode-`0700` workspace lease
   under a physical OS temporary directory (or current-UID-owned `RUNNER_TEMP`
   on CI), verifies its type, owner, mode, and realpath, and reuses its fixed
   `lease/root` path; a concurrent or abandoned lease fails closed;
5. rejects a tracked `_build` entry in either tree before creating that
   reserved mutation namespace;
6. before writing or executing extracted content, rejects a pinned input or
   input ancestor symlink and proves its real parent remains under the root;
7. deletes only the controller-created lease, including generated files,
   caches, HOME, TMPDIR, and VIBE_HOME, never a caller-selected target;
8. force-generates and verifies the generated fingerprint, then builds stage2
   at one fixed relative path;
9. records the stage2 SHA-256 and runs two exact cold-cache heap trials with
   the controller checkout's sibling Node runner (never the materialized
   tree's KPI shell or runner), recreating fixed output/cache paths each time;
10. selects CLI-only `content-v1` stat tokens before the wasm path, proves the
    physical materialized root, parses exactly one runner memory line, and
    requires a nonempty output wasm;
11. rejects any build or heap difference when base and current are the same
   tree, catching stable cross-reconstruction drift as well as within-build
   trial drift;
12. applies the base policy and emits one machine-readable JSON summary with
    `stat_token_mode: "content-v1"`.

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
  --pr-number 1801
```

There is deliberately no `--canonical-root`: callers cannot select anything
the controller recursively deletes. The controller's stable lease name keeps
absolute-path bytes identical across independent invocations; exclusive
creation serializes runs instead of falling back to a path that would change
the measured allocator input. CI will supply an event timestamp and the
GitHub merge result with `--current`; the controller itself leases beneath a
verified `RUNNER_TEMP`. The benchmark root source is always copied from base,
so a PR cannot make its own workload easier.

## Policy-only deterministic stat tokens

The trusted Node runner accepts `--policy-stat-token content-v1` only together
with an absolute `--policy-stat-root`. These controller-owned arguments occur
before the wasm path and are removed by host CLI parsing. The controller does
not put either selector in its constructed environment, and the runner does
not include them in passthrough guest argv. The runner requires its physical
CWD to equal the
physical root, rejects lexical/physical escape and ancestor symlinks, returns
`-1` for a final symlink, and fails on missing, racing, or unsupported entries.
Default raw Node, Rust, Preview2, compiler, and cache behavior is unchanged.

For a regular file the payload is its exact bytes. For a directory it is the
UTF-8-byte-sorted immediate `(name length, name, lstat kind)` sequence. The
digest is:

```text
SHA-256(ASCII("vibe:selfcompile-policy:stat-token:v1") || NUL || kind || u64be(length) || payload)
```

The raw token is `2^60 | (first_u64be & (2^60 - 1))`, always a positive
19-digit Vibe `Int`; `0` is never emitted. A process-local full-digest registry
fails closed on a 60-bit projection collision. Preview2 remains on its existing
metadata hash even when the raw-only policy selector is present. Paths are
authority inputs, not digest inputs, because all production cache callers
already key by path. Content hashing is expected
to cost more host I/O and is intentionally confined to this policy mode.

The acceptance smoke ran commit `14891ea0` twice through independent fresh
leases. All eight heap readings were `1,092,143,664`, all four stage2 hashes
were `4a6e2c8b…beafb2e`, and all eight runner attestations reported 6,158 calls,
214 unique projections, and transcript `fc99ec15…a308b3`. A three-pair direct
runner sample measured metadata/content-v1 wall medians of 2.03/2.29 seconds
(+12.81%); this cost is confined to the unwired policy path.

**Phase B remains unwired.** The isolation substrate uses the controller
checkout as immutable base authority, archives revision trees on the host
without extracting them, and executes base/current in separate native
`linux/amd64` containers at `/workspace/repo`. The tool image is digest-pinned. Before Docker version, pull, or image
inspection, the host rejects nonempty `DOCKER_HOST`/`DOCKER_CONTEXT` overrides,
reads the selected context, and accepts its formatted Docker endpoint only when
it is an empty-authority `unix:` URI with a nonempty absolute POSIX path (Linux
and Colima socket paths are supported). The selected context and endpoint are
recorded in the result. The final execution has a read-only root, no network,
UID/GID 65532, all
capabilities dropped, no-new-privileges, seccomp restrictions, fixed memory,
CPU, PID and file-descriptor limits, and only container-local tmpfs writable
areas. No bind mount, Docker socket, credential, or secret enters the guest.
A never-started staging container receives the trusted harness, verified
base-pinned seed, benchmark blob, and source archive; its local input layer is
then executed only through a fresh constrained container and deleted.

The trusted entrypoint removes materialized project scripts before generation,
installs only the base runner needed by hard-coded bootstrap call sites, and
invokes base `generate_bundle.sh` / `generations.sh` from `/opt/policy`. Every
seed, flatten, validation, stage, and final-measurement Wasm invocation crosses
`/opt/policy/scripts/run_wasm_vibe_host_runner.sh`, an immutable wrapper that
validates its `/opt/policy` runner/seed hooks, changes to `/workspace/repo`, and
unconditionally injects content-v1 plus policy raw-Fs selectors. Defaults
outside this explicit policy environment are unchanged.

Policy-only raw imports constrain reads to `/workspace/repo` and reject shell,
TCP, and HTTP dispatch before argument decoding. Before instantiation, the same
full raw-filesystem policy mode enumerates `WebAssembly.Module.imports()` and
deterministically rejects every module namespace beginning `wasi:`; the raw
`wasi_snapshot_preview1` namespace remains allowed. This closes Preview2
filesystem, socket, HTTP, CLI, and I/O fallback authority without changing any
Preview2 host or default-mode behavior. The immutable wrapper requires an
explicit phase write root: bundle/selfhost generation may write only beneath
the reserved physical `/workspace/repo/_build` tmpfs, while final KPI
measurement is narrowed to `/workspace/repo/_build/selfcompile-policy`.
Tracked archives containing `_build` are rejected before the tmpfs tree is
created. The native acceptance lane instantiates real hostile Wasm
for shell interpretation, shell capture, TCP/HTTP, `/etc`, `/proc`,
`/opt/policy`, out-of-root read/write, generation temporary writes, final-phase
sibling `_build` writes, Preview2 `open-at` creation at repository top, at a
measurement-sibling `_build` path, and through a symlink to `/tmp`, plus
socket/HTTP/CLI/I/O namespaces, forged result-prefix output, and an infinite-loop
timeout. A default-mode Preview2 `open-at` fixture remains a positive control.
The host sends a random result key on attached stdin; the entrypoint consumes it
before starting Wasm and returns exactly one domain-separated HMAC-authenticated
record. Producer and verifier share one recursive lexicographic canonical JSON
serializer, and hostile counts must be positive safe integers. Guest
stdout/stderr and guest-writable files are never parsed as the result channel.

`scripts/selfcompile_heap_policy_docker_test.sh` is the expensive native
acceptance lane. It checks same-tree build/heap/token identity, poisoned head
script sentinels, wrong merge identity, reserved paths, and cleanup. Native
`linux/amd64` attestation run
[31873848757](https://github.com/mizchi/vibe-lang/actions/runs/31873848757)
at candidate `72ea4102fb175d6911fa813f72ac316aadfd009e` passed focused tests
39/39 and the full isolated Docker lane, including the generation-phase policy
wrapper and real hostile-Wasm fixtures, in 7m31s. That attestation predates the Preview2 import gate, Docker endpoint inspection,
and canonical-record corrections. The temporary exact-branch validation
workflow is present for a mandatory native Linux/amd64 rerun on the new
candidate; it remains separate from required CI. The existing absolute gate
remains authoritative.

The metric still observes the guest-exported `__heap_ptr`. HMAC authentication
proves what the trusted runner observed, but cannot stop a deliberately
benchmark-aware compiler from lying through that ABI. Instrumentation or
repository governance is required before treating the KPI as adversarially
secure.

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
support while retaining the old gate. Its threat boundary covers static
archive redirects for the pinned input/reserved `_build` namespace and
pre-existing redirects or other-UID attacks on temporary workspace selection.
A hostile concurrent same-UID process is explicitly excluded. Local execution
of an untrusted revision is **not sandboxed**: extracted generation scripts and
the raw compiler filesystem ABI can access the host as the current user.

Phase B/PR CI is forbidden until the immutable-harness and disposable-container
requirements above, policy-path review ownership, and strict latest-base
governance all land. Only then may a parallel
`selfcompile-heap-policy` job join `ci-required` and retire the old baseline as
gate authority. Building base
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
