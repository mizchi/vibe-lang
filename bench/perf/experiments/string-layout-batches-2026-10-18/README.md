# String-layout fingerprint experiment

The [report](../../../../docs/internal/reports/string-layout-batches-2026-10-18.md)
and [analysis](../../analysis/string-layout-batches-2026-10-18.json) describe
the completed fixed-corpus experiment on main `403d735929db48325c23252630725a0d16b5ab69`.
The four CLI worker ranges improve; whole-compile walltime/RSS promotion remains
unproven. Actual target-RC0 bootstrap and native threads are separate work.

`evidence.tar.xz` contains 1,057 exact raw records: the original source/image
authorities, 72 before controls, 132 interleaved comparisons, 48 isolated range
replays, 78 CPU profiles, logs, receipts and negative controls. Individual gzip
envelopes were removed before solid XZ compression; the underlying source,
JSON, log, whitespace and EOF bytes are preserved. `archive.json` binds the
archive and index hashes; `evidence-index.json.gz` is its readable raw-entry
index. The original per-file compression manifest is retained inside the tar
as `expanded-manifest.json`.

The measured drivers are individually readable. `archive_fingerprint.py` and
`pack_fingerprint.py` performed post-measurement historical packaging and
expect the original log inventory, including an initial failed GC experiment.
`reproduce_gc_before.py` is a convenience added afterward and separately
smoke-tested; it is not relabelled as an original measurement driver. It checks
the entire frozen input set, including ignored generated files, before and
after the control. A separately retained generated-input mutation is refused
before any compiler invocation; the original measured corpus is unchanged.

## Verify the retained bytes

Run from the repository root:

```sh
python3 - <<'PY'
import gzip, hashlib, json, tarfile
from pathlib import Path
p = Path('bench/perf/experiments/string-layout-batches-2026-10-18')
record = json.loads((p / 'archive.json').read_text())
assert hashlib.sha256((p / record['archive']).read_bytes()).hexdigest() == record['archive_sha256']
index_bytes = gzip.decompress((p / record['index']).read_bytes())
assert hashlib.sha256(index_bytes).hexdigest() == record['raw_index_sha256']
index = json.loads(index_bytes)
assert len(index['entries']) == record['entries'] == 1057
with tarfile.open(p / record['archive'], 'r:xz') as t:
    assert t.extractfile('manifest.json').read() == index_bytes
    for row in index['entries']:
        data = t.extractfile(row['member']).read()
        assert len(data) == row['bytes']
        assert hashlib.sha256(data).hexdigest() == row['sha256']
print('all 1057 original raw records verified')
PY
```

Wasm binaries and the 39 MB literal payload are omitted. Producer/engine,
input, source-overlay and artifact hashes are retained. The frozen source and
pinned seed regenerate the inputs; raw profiles do not expose literal text.

## Reproduce the measurements

Use a fresh disposable checkout of `403d73592`, Python 3.12+, Node 24.7.0,
the repository Rust toolchain, Wasmtime and the pinned seed. Preserve this
archive outside that checkout as an absolute `fingerprint_archive` path.
Run every build, test, measurement and profile sequentially on an idle host.
The commands write new evidence; historical timings are never reused as fresh
samples. The drivers refuse missing/stale authority or incomplete results.

```sh
set -e
lab=_build/function-worker-live-set-3483-20261018
mkdir -p "$lab/recorded"
cp "$fingerprint_archive/"*.py "$lab/"
tar -xJf "$fingerprint_archive/evidence.tar.xz" -C "$lab/recorded"
bash scripts/ensure_seed.sh
python3 "$lab/setup_baseline.py" > "$lab/setup-baseline.log" 2>&1
python3 "$lab/matrix.py" > "$lab/matrix.log" 2>&1
python3 "$lab/diagnostics.py" > "$lab/diagnostics.log" 2>&1
python3 "$lab/reproduce_gc_before.py" --workspace "$lab/baseline" --out "$lab"

git apply "$lab/recorded/measured-implementation.patch"
bash scripts/ensure_generated.sh > "$lab/candidate-generated.log" 2>&1
bash scripts/generations.sh build --stage3 --out-dir "$PWD/$lab/candidate-generation" \
  > "$lab/candidate-generation.log" 2>&1
bash scripts/build_taskgroup_functions.sh "$PWD/$lab/candidate-generation/stage2.wasm" \
  "$PWD/$lab/candidate-images" > "$lab/candidate-images.log" 2>&1
cp "$lab/recorded/records/fingerprint-candidate-source.json" "$lab/"
cp "$lab/recorded/gc-fingerprint-probe.vibe" "$lab/"
python3 "$lab/validate_candidate.py" > "$lab/validate-candidate.log" 2>&1
python3 "$lab/fingerprint_compare.py" > "$lab/fingerprint-compare.log" 2>&1
python3 "$lab/worker_replay_compare.py" > "$lab/worker-replay-compare.log" 2>&1
python3 "$lab/gc_graph_candidate_control.py" > "$lab/gc-graph-candidate-control.log" 2>&1
python3 "$lab/summarize_fingerprint.py" > "$lab/summarize-fingerprint.log" 2>&1
```

The compiler and worker image receipts must match the selected native runner;
context7/job2/callbackABI2, engine allocation and emitted target flags remain
explicit. The ordinary and same-driver serial controls precede a promotion
decision. The 12 A/A pairs must agree on guest memory, all fixed-corpus outputs
must match, and every replay/profile product must match its captured original.
No code edits or heavy background work may overlap the timings.

The GC controls deliberately compile then reproduce the full-import graph's
active-data-segment failure (#3512). The exact extracted fingerprint definitions
plus all scalar/legacy tests pass through Node and Wasmtime GC. Keep these
scopes distinct; a successful extracted probe does not clear the full-import
GC defect. Five-byte overflow mutants must compile and then fail the actual
byte/substring test on both bump and RC.

The final summary refuses incomplete matrices or profiles. Preserve the new
workspace and its hashes separately. Its results belong to the newly recorded
machine/toolchain; do not overwrite or relabel the historical archive.
