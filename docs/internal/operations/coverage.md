# Coverage strategy

Coverage is measured with one instrumentation (`VIBE_COVERAGE=1`, below) used
two ways: on a **compiled program** (`vibe test --coverage` /
`vibe run --coverage`, and the suite built on them), and on an **instrumented
compiler** compiling other programs. No MoonBit host is involved; everything
runs from the pinned seed (or an explicit stage2) and the Node/Rust runner.

## Per-file coverage: `vibe test --coverage` / `vibe run --coverage`

Coverage of what a **test** exercises — the test file and its imports — comes
from `vibe test --coverage`. It compiles the test file with instrumentation,
runs it, and reports which functions and branches the tests reached, per file
and in aggregate.

```bash
bash scripts/vibe_test.sh --coverage path/to/foo_test.vibe   # one file
bash scripts/vibe_test.sh --coverage lib/@vibe/builtin       # every *_test.vibe under a directory
```

A test that never passes a negative input leaves the `n < 0` arm unreached,
so it reports 3/4 branches:

```
ok   foo_test.vibe  [cov fn 3/3, branch 3/4]
[vibe-test] 1 passed, 0 failed (1 files)
[vibe-test] coverage: functions 3/3 (100.00%), branches 3/4 (75.00%) over 1 file(s)
```

`vibe run --coverage` measures one program while running it:

```bash
bash scripts/vibe_run.sh --coverage path/to/prog.vibex [-- args...]
```

The program's output goes to stdout, the `[vibe-cov]` summary to stderr, and
the JSON to `_build/vibe_run/<name>.cov.json`. Per-file test JSON is
`_build/vibe_test/coverage/<file>.json`
(`{total,hit,missed,rate,hit_fns,missed_fns,branch{...}}`). Both work by
passing `VIBE_COVERAGE=1` to the FS compile lane, which then compiles with
instrumentation (`compile_file_fs_mode_coverage`) — the same instrumentation
the compiler-side measurement below uses.

`vibe compile --coverage` does **not** instrument: measured 2026-08-20, the
output `.wasm` and its `.funcmap` are byte-identical with and without the flag.
The `.funcmap` (`NAME<TAB>INDEX`) is written by every FS compile and is
consumed by failure stack annotation (`scripts/vibe_test.sh`), not by coverage.
`VIBE_TEST_COVERAGE=1` is not a supported control either; use
`bash scripts/vibe_test.sh --coverage`.

### All `@vibe/builtin` tests

```bash
pkf run coverage-wasm-std
```

selects every `*_test.vibe` under `@vibe/builtin` and runs it through the same
`--coverage` path, printing per-file and aggregate function/branch coverage and
writing per-file JSON to `_build/vibe_test/coverage/`. Any compile or test
failure fails the task, and so does selecting zero files.

`VIBE_WASM_STD_COVERAGE_FILTER` and `VIBE_WASM_STD_COVERAGE_EXCLUDE` narrow the
selection with **POSIX extended regular expressions** (`grep -E`). PCRE/Rust
regex constructs such as `\d` and `(?i)` are rejected rather than
reinterpreted, and an invalid pattern fails the run instead of reporting an
empty corpus. `VIBE_TEST_CLI_WASM` selects the compiler, following the same
contract as `scripts/vibe_test.sh`.

## Two tracks, never one number (#1556)

The two uses of the instrumentation have different denominators, and neither
contains the other. Looking at only one hides exactly what the other is good
at.

| track | measures | run with | sees / cannot see |
|---|---|---|---|
| **in-process** | branches the **compiled test programs** execute | `pkf run coverage` (`branch_union` of `scripts/coverage_suite.sh`) | sees stdlib and `@vibex` well. **Cannot see compiler passes**, structurally |
| **self-compile** | branches the **compiler** executes while compiling a corpus of real programs | `pkf run coverage-corpus` (`merged.json` of `scripts/coverage_corpus.sh`) | sees parser/checker/codegen. Cannot see stdlib, which the compiler only emits calls to |

```bash
pkf run coverage-tracks              # both, side by side
pkf run coverage-tracks -- --check   # check each against its floor
```

Measured 2026-08-13, same checkout:

```
[coverage-tracks] in-process    branches 26894/46469 (57.88%)  min 57.0%
[coverage-tracks] self-compile  branches 10703/26738 (40.03%)  min 0.0%
```

**Only the in-process track has a floor** (57%,
`VIBE_TRACK_MIN_IN_PROCESS_RATE`). Its denominator is the test suite itself,
which grows but does not change with configuration, so it works as a ratchet.
The self-compile rate is a function of **how many programs the compiler was
fed** — `VIBE_COV_MAX` alone moves it — so a floor there would pass or fail
according to how long someone was willing to wait. Its floor stays 0
(`VIBE_TRACK_MIN_SELF_COMPILE_RATE`) until the corpus is a committed file list
rather than "examples + fixtures, cut off by an env var".

When one track has no report, `coverage-tracks` says `NOT MEASURED in this
run`, and `--check` **fails**: a track that could not be measured is not
treated as passing, because when something regresses the track with no number
is the most suspect.

**Why in-process cannot see compiler passes.** `vibe test --coverage`
instruments and runs the wasm **obtained by compiling the test**. The compiler
passes that ran **while compiling** it ran inside a different, uninstrumented
binary (stage2), so they count zero branches however thoroughly a fixture or
gate exercises them. A compiler pass appears in this track only when some test
calls it **in process**. Control measurement (2026-08-13):

| entry | what it exercises | result |
|---|---|---|
| `query/grep_test.vibe` | calls `grep_scan_source` directly | 264/587 of grep.vibe's branches counted |
| `tests/import_private_ctor_collision_test.vibe` | private-constructor namespacing, **at compile time** | the program has 8 branches, and none of `import_alias_rewrite`'s functions |

So `cli_adapter.vibe 0/250` means "**not called in process**", not
"untested". Reading `top_branch_union_gaps` as a list of untested code leads to
writing in-process wrappers for code that is already verified — work that only
moves the number. To see compiler passes, read the self-compile track; to see
the stdlib, read in-process.

## The suite: `pkf run coverage`

`pkf run coverage` (= `coverage-suite`, `scripts/coverage_suite.sh`, against a
stage2 built for the checkout) runs every `*_test.vibe` as its own
instrumented binary. In CI it is the `coverage-suite` job: main only, eight
shards.

Each entry carries its whole import closure, so one compiler function appears
in the denominator once per entry. The report's `entry_weighted.function` and
`entry_weighted.branch` are therefore **entry-weighted** figures, kept as stable
comparison values and never to be read as unique source coverage. Adding one
test entry adds its whole closure to their denominator, so a larger suite can
lower them while covered functions and branches both increase; they are not
gated by default (`VIBE_SUITE_MIN_POINT_RATE` / `VIBE_SUITE_MIN_BRANCH_RATE`
set a floor for an explicit diagnostic experiment only).

The primary figures are the unions:

- `function_union` unions each entry's `hit_fns` / `missed_fns` by
  source-qualified function ID, so a function reached by any entry counts once.
- `branch_union` does the same for branches (#1556). A branch's global index is
  specific to each entry's program and cannot be compared across entries, but
  its **ordinal within its owner function** is the order that function's body
  was lowered in, so `(source-qualified owner, ordinal)` names the same source
  branch in every entry. Per-entry JSON exposes it as `branch.per_fn[fn].mask`
  (one `'1'`/`'0'` per branch, by ordinal), and the report ORs the masks.
- When one source function lowers to different branch counts in different
  entries (specialization, dictionary passing), the union widens to the largest
  shape seen.
- Only the names synthesized per entry (`_start`, `__test_<name>`,
  `__bench_<name>`) are qualified by entry path (`union_key`). They carry no
  source qualification, so two entries with a same-spelled `test` block would
  otherwise collapse into one name (`hashmap_test.vibe` and
  `sortedmap_test.vibe` both have `test "empty map"`, with 2 and 4 branches).
  Names such as `Array::map` / `T::equals` are genuinely shared and stay
  unqualified; only the synthesized class is always "same name, different
  function", because test and bench blocks are never imported.
- If any coverage JSON without masks is mixed in, `branch_union.exact` is
  `false`, the value is shown as a **lower bound**, and the ratchets that depend
  on it are skipped rather than failing on a number that was not measured.

`branch_union.rate` is the #1556 branch-coverage KPI. The ratchets and their
defaults are in `scripts/coverage_suite.sh`: `VIBE_SUITE_MIN_BRANCH_UNION_RATE`
(the KPI floor), `VIBE_SUITE_MIN_BRANCH_UNION_HIT` and
`VIBE_SUITE_MIN_FUNCTION_UNION_HIT` (absolute union counts),
`VIBE_SUITE_MIN_FN_HIT` / `VIBE_SUITE_MIN_BRANCH_HIT` (absolute entry-weighted
counts), and `VIBE_SUITE_MIN_LINE_RATE` (the share of entries that pass). A
union's source universe can still grow when a test first imports a module, so
the function union is ratcheted by count; its rate is reported, and gated only
when `VIBE_SUITE_MIN_FUNCTION_UNION_RATE` is set.

```bash
pkf run coverage                       # the suite, with its ratchets
pkf run coverage-suite-next-branches   # suggest entries for unreached branches
pkf run coverage-suite-branch          # the suite plus those suggested entries
pkf run coverage-suite-branch-gate     # the same, with explicit floors
```

## The compiler's own coverage (self-compile track)

```bash
bash scripts/coverage_fn.sh                  # default workload: the compiler compiling itself
bash scripts/coverage_fn.sh path/to/foo.vibe # workload: compiling foo.vibe (FS mode)
VIBE_COV_SHOW_MISSED=1 bash scripts/coverage_fn.sh        # also list unexecuted functions
VIBE_COV_SHOW_BRANCH_GAPS=1 bash scripts/coverage_fn.sh   # functions with the most unreached branches
```

`VIBE_COV_SEED` selects the compiler that builds the instrumented compiler (the
pinned seed by default) and `VIBE_COV_DIR` the output directory
(`_build/coverage/selfhost-fn/`: `compiler_cov.wasm`, the instrumented
compiler, and `report.json`).

One workload exercises a skewed subset: self-compile reaches
parser/checker/codegen, but the printer only runs under `normalize` and Perceus
RC only under `VIBE_RC=1`. Results from **one instrumented binary** run over
several workloads can be OR-merged exactly, because function and branch ids
agree; binaries compiled separately cannot.

```bash
bash scripts/coverage_merge.sh                 # compile + normalize + rc
bash scripts/coverage_merge.sh extra1.vibe ... # plus an FS compile of each file
bash scripts/coverage_corpus.sh                # one instrumented compiler over examples + fixtures
VIBE_COV_MAX=200 bash scripts/coverage_corpus.sh
```

`coverage_corpus.sh` (also `pkf run coverage-corpus`) bundles, besides the
plain compiles and an RC-stress set:

- **cache-orch**: repeatedly compiles a project with a source manifest and
  multi-import examples while selectively invalidating
  `.vibe/build/cache/vibe_selfhost_*` entries, which lights up the
  persistent-cache read paths a single compile can never reach;
- **a generated error corpus** (`scripts/coverage_gen_errcorpus.sh` →
  `_build/errcorpus/`): deliberately ill-typed and mis-parsing programs, which
  reach the diagnostic functions. A failed compile still dumps its bitmap on
  abort, so pick an entry name that exists in the file (a test file uses the
  sentinel and `_start`).

Output goes to `_build/coverage/selfhost-corpus/` (`acc.json`, the running
union, `merged.json`, `fails.txt`). The corpus only measures **compiling**:
running the generated wasm executes a different, uninstrumented binary.

`coverage_corpus.sh` checks that the generated compiler sources and its required
inputs exist and are current, but does not regenerate them; when they are
missing or stale it says to run `bash scripts/ensure_generated.sh`.

Black-box compiles saturate: past a broad corpus, more whole-program compiles
add almost nothing, because what is left are defensive arms, per-token parser
errors, multi-stage cache states and similar. The remaining levers call the
compiler's functions **directly**:

```bash
bash scripts/coverage_corpus.sh          # base acc.json + compiler_cov.wasm
bash scripts/coverage_testexec.sh        # run the compiler's own *_test.vibe with coverage
bash scripts/coverage_unittests.sh       # the compiler's root unit tests, through exact-path exposure
bash scripts/coverage_drivers.sh         # registered direct-call drivers (scripts/coverage/cov_*.vibe)
bash scripts/coverage_manifestcache.sh   # manifest-header cache: cold / warm / partial invalidation
bash scripts/coverage_multimodule.sh     # private-name and alias-collision multi-module projects
bash scripts/coverage_features.sh        # trait / effect / mut capture / pattern breadth
```

These merge into the corpus `acc.json` by `(function name, local branch
index)`: across binaries the global ids differ, but the same source function
lowers its branches in the same order.

**Drivers reach functions through exact-path exposure** (#1633). A driver in
`scripts/coverage/` imports the one compiler `.vibe` file that defines what it
calls; the production export/private namespacing plan decides the final target
name, and the shadow-aware import rewriter updates the driver's references
before entry-based DCE from the driver entry. Missing, duplicate,
out-of-closure, type/constructor, mutable-global, extern, method and collision
requests fail with a diagnostic. The internal mode
(`VIBE_EMIT_COVERAGE_DRIVER_SOURCE=1` + `VIBE_COVERAGE_DRIVER_PATH`) is invoked
only by `coverage_drivers.sh`; it does not widen normal import visibility or
change `VIBE_EMIT_MERGED_SOURCE` output. Because the target is named, it is
always clear which function was measured. The emitting compiler is the
`compiler_cov.wasm` the corpus run built from current source; the pinned seed
only compiles the emitted source with coverage. `scripts/coverage_driver.sh`
(singular) runs just the `cov_driver.vibe` entry of the same suite
(`VIBE_COV_DRIVER_FILTER=driver`).

The merge checks the command status and the `base now total` schema, and fails
the whole coverage run unless `total > 0`, the denominator is unchanged, the
hit count did not decrease, and the written file's stat matches.

## Mechanism

Compiling with `VIBE_COVERAGE=1` makes codegen:

- insert, at the entry of every user function, a store that sets that
  function's hit flag (one byte per function in a reserved region below the
  heap), and embed a `vibe_cov` custom section with `cov_base` / `cov_count`
  and the function names;
- insert the same kind of one-byte store at the start of every `if`
  then/else and every `match` arm (catch-all included, when there is at least
  one conditional arm). Branch ids are numbered in codegen traversal order, and
  a `vibe_cov_branch` custom section records `base` / `count` and each branch's
  owner function.

Running the instrumented binary fills both bitmaps. When `VIBE_COV_OUT` names a
report path, the runner reads them from memory after the run and writes the
report, aggregating branches per owner function (`branch.per_fn`, with the
functions holding the most unreached branches in `branch.top_gaps`).
`VIBE_COV_RAW=1` adds the id-level bitmaps (`raw.fn_bitmap` /
`raw.branch_bitmap`) and the static name/owner tables.

- A build without `VIBE_COVERAGE` is **byte-identical** to an uninstrumented
  one; the gate's stage2 == stage3 fixpoint holds that, so coverage cannot
  affect the bootstrap.
- Branches are `if` / `match` only; `&&` / `||` short-circuits are not
  counted. There is no line coverage.

Low-level use:

- `VIBE_COVERAGE=1 cli_main <src> <out.wasm> <entry>` produces an instrumented
  wasm;
- `VIBE_COV_OUT=<report.json>` passed to the runner dumps the bitmaps after the
  run.

`report.json` is
`{total, hit, missed, rate, hit_fns[], missed_fns[], branch: {total, hit, missed, rate, per_fn{}, top_gaps[]}}`,
where `per_fn[fn]` is `{total, hit, mask}` and `mask` holds one `'1'`/`'0'`
per branch in owner-ordinal order — the only key that identifies a branch
across programs (#1556).
