# Function preparation Store lifetime

The [report](../../../../docs/internal/reports/function-parent-lifetime-2026-10-19.md)
and [analysis](../../analysis/function-parent-lifetime-2026-10-19.json) separate
the final filesystem/target-RC1 process experiment from actual target-RC0 serial
bootstrap controls. The process route reduces peak RSS; whole-wall speedup and
default multithreaded selfbuild remain unproven.

`evidence.tar.xz` preserves **3,174 exact raw records**. `archive.json` binds its
SHA-256 and the uncompressed index hash; `evidence-index.json.gz` lists every
member's original byte count and SHA-256. Tar owners and timestamps are normalized;
member bytes, whitespace, EOFs and file modes are preserved. Every member was
read back and independently verified after compression.

Primary evidence includes the 144 final formatted-source filesystem comparisons,
24 actual serial bootstrap controls, 16 parent/64 worker diagnostic replays,
66 raw CPU profiles and complete per-profile/pooled counters, producer fixpoints,
image/source authorities, raw logs, receipts, negative controls and public/native
verification. Initial pre-format trials and the 36 same-binary observation-scope
controls retain separate directories and identities. They are not pooled with
the final measurements.

The archive also retains the original final full source snapshot at
`records/after-format-validation-v1/candidate-sources.tar.gz`, original formatting
backup/patch and owned main-integration backup. Baseline sources are Git commit
`8bed6e9e61bb178af06cdb7fbae62d9bc19c6c7e`. Large Wasm/native binaries,
caches, checkout copies and context/job/product payloads are omitted explicitly
in the index; original authorities/receipts bind their identities. Original local
artifacts remain intact. Fixed-corpus p4 raw RSS timelines are retained;
actual-pipeline process records retain the online simultaneous aggregate peak
and per-process observations, rather than a complete per-tick tree timeline.

The readable Python files preserve measured/verification orchestration and the
post-measurement curator. Historical drivers require their original preparation
proofs and layout. A fresh run must rebuild source-bound producers/runners/images,
verify stage2 == stage3 and current receipts, and write new result identities;
historical successful markers must never stand in for freshly executed checks.
The archive verification below does not execute any archived code.

## Run a fresh comparison

`reproduce.py` was added after the recorded experiment. Its `sources` command
reconstructs clean equal-length `a0`/`b0` checkouts from the pinned baseline and
the authenticated final source snapshot. It verifies every recorded candidate
source hash; this records source reconstruction only. `engines` runs the normal
seed/generated/native-runner builders, compiler stage2/stage3 fixpoints and
matching ABI2/ABI3 helper-image builds. It never installs historical success
markers or rewrites native source stamps. Missing tools or failed steps stop
the recipe with their logs intact.

Use Python 3.12+, the repository Rust toolchain, Node, Wasmtime and the pinned
seed, on an idle host. Run from the repository root; keep this experiment and
the checkout containing the baseline Git object available. The following creates
a **new** workspace and new measurements. No files in an existing workspace are
replaced. Run each command sequentially, without edits or other heavy work.

```sh
set -e
replay="$PWD/bench/perf/experiments/function-parent-lifetime-2026-10-19/reproduce.py"
fresh="$PWD/_build/reproduce-parent-lifetime-filesystem"
python3 "$replay" sources "$fresh" --repo "$PWD"
python3 "$replay" engines "$fresh"
python3 "$replay" matrix "$fresh"
```

The fresh filesystem matrix has 144 builds, both A/A controls, explicit serial
controls and public process jobs 1/2/4, with N=3 alternating cold/warm pairs.
Equal-length lane paths, explicit target RC1, isolated parsed-source caches,
disabled other compiler caches, primed native JIT and warm OS pages match the
documented workload. Each output is compared across routes, guest-memory A/A
observations are checked, and source/image identities are rechecked. It retains
the online simultaneous RSS peak, raw process records and native phase traces;
the original archive additionally retains detailed p4 timelines and CPU replays.

Actual target-RC0 serial bootstrap controls use a separate fresh workspace,
preserving the filesystem experiment and its fixture/cache state:

```sh
set -e
replay="$PWD/bench/perf/experiments/function-parent-lifetime-2026-10-19/reproduce.py"
actual="$PWD/_build/reproduce-parent-lifetime-bootstrap"
python3 "$replay" sources "$actual" --repo "$PWD"
python3 "$replay" engines "$actual"
python3 "$replay" bootstrap "$actual"
```

This runs all 24 alternating compiler-through-stage3 and portable-CLI-through-stage2
controls, includes source/seed/stage work and cold merge-tool regeneration,
checks every compiler fixed point and per-lane artifact identity, and records
monotonic spans/process metrics. Setup and helper packaging stay outside these
ordinary serial regression timings. It does not select a threaded bootstrap
backend. Fresh toolchain/machine/artifact identities belong to the new run;
never overwrite or relabel the historical records as newly measured results.

`smoke` runs a tiny-input 24-build command/equivalence check, clearly marked as
functional verification rather than performance evidence. Its optional
`--engines` accepts explicitly selected receipt-checked existing images only
for smoke verification. Full `matrix`/`bootstrap` replay requires newly completed
normal setup. Full new performance matrices and image rebuilds were not rerun
merely to validate this post-measurement convenience tool; the retained original
measurements and producer proofs keep their original identities.

[Reproduction-tool verification](reproduction-validation/result.json) records
fresh reconstruction of 2,456 baseline and 2,522 candidate source files, 24
tiny-input builds using the retained exact-source images, artifact/A/A equivalence,
and seven acceptance/refusal controls. Changed source, an unrecorded module,
workspace overwrite, reuse of filesystem state for actual bootstrap and retained
images requested as fresh performance inputs are refused. These post-measurement
records are separate from the original 3,174-member archive.

## Verify the retained bytes

Run from the repository root:

```sh
python3 - <<'PY'
import gzip, hashlib, json, tarfile
from pathlib import Path
p = Path('bench/perf/experiments/function-parent-lifetime-2026-10-19')
receipt = json.loads((p / 'archive.json').read_text())
assert hashlib.sha256((p / receipt['archive']).read_bytes()).hexdigest() == receipt['archive_sha256']
raw = gzip.decompress((p / receipt['index']).read_bytes())
assert hashlib.sha256(raw).hexdigest() == receipt['raw_index_sha256']
index = json.loads(raw)
assert len(index['entries']) == receipt['entries'] == 3174
with tarfile.open(p / receipt['archive'], 'r:xz') as archive:
    assert archive.extractfile('manifest.json').read() == raw
    for row in index['entries']:
        data = archive.extractfile(row['member']).read()
        assert len(data) == row['bytes']
        assert hashlib.sha256(data).hexdigest() == row['sha256']
print('all 3174 original raw records verified')
PY
```

The final normal full release gate passes on frozen tree `b34e56881c9a3b2ec64e073ceb5e8e28baae360d`; see [raw signoff records](release-attempts/v8/manifest.json).
This is separate from the retained original-source performance measurements.
