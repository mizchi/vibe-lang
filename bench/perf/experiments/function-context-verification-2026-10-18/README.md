# Bounded context verification experiment (2026-10-18)

The [report](../../../../docs/internal/reports/function-context-verification-2026-10-18.md) and [raw record](../../../../bench/perf/analysis/function-context-verification-2026-10-18.json) describe a host-only change on main `8f7f95477ded1dc62d743d900a8635e7fdccaed2`. This is a historical fixed-corpus experiment, not a latest-main bootstrap/thread promotion gate. Keep all builds, tests and measurements sequential. Use fresh output directories and an idle machine.

`baseline_controls.py`, `build_validate.py` and `compare.py` are the exact executed drivers. `prepare_reproduction.py` is a convenience supplied after measurement that stages the same inputs and source authorities; it is not relabelled as an executed measurement driver. The compiler and three guest images are unchanged; the native runners differ and each build receipt must match its selected runner.

## Prepare the historical corpus and current-engine baseline

Use Python3.12+,Node24.7.0,the repository Rust toolchain and pinned seed in a fresh disposable checkout of `8f7f95477`. Retain this archive directory outside that checkout as an absolute `context_archive` path. Run from the repository root. The old experiment workspace is reused below only to retain the frozen corpus and generation layout expected by the archived drivers; no old timing is used as a fresh before/after sample.

```sh
set -e
bash scripts/ensure_seed.sh
bash scripts/ensure_viberun.sh
previous_lab=_build/function-worker-parent-memory-3483-20261018
context_lab=_build/function-context-verification-3483-20261018
python3 bench/perf/selfbuild_baseline.py prepare "$previous_lab/baseline" --ref eeba680337dae422362c465439bd60f5d53da040
python3 bench/perf/selfbuild_baseline.py clock "$previous_lab/baseline"
python3 bench/perf/selfbuild_baseline.py bootstrap "$previous_lab/baseline" --rounds 3
python3 bench/perf/selfbuild_baseline.py images "$previous_lab/baseline"
python3 bench/perf/selfbuild_baseline.py matrix "$previous_lab/baseline" --rounds 3
bash scripts/generations.sh build --stage3 --out-dir "$previous_lab/decoder-candidate/generation"
cmp "$previous_lab/decoder-candidate/generation/stage2.wasm" "$previous_lab/decoder-candidate/generation/stage3.wasm"
bash scripts/build_taskgroup_functions.sh "$previous_lab/decoder-candidate/generation/stage2.wasm" "$previous_lab/decoder-candidate/final-images"
python3 "$context_archive/prepare_reproduction.py" before "$context_lab" \
  --workspace "$previous_lab/baseline" \
  --compiler "$previous_lab/decoder-candidate/generation/stage2.wasm" \
  --images "$previous_lab/decoder-candidate/final-images"
cp "$context_archive/baseline_controls.py" "$context_lab/baseline_controls.py"
cp "$context_archive/build_validate.py" "$context_lab/build_validate.py"
cp "$context_archive/compare.py" "$context_lab/compare.py"
python3 "$context_lab/baseline_controls.py" > "$context_lab/before-controls.log" 2>&1
printf '0\n' > "$context_lab/before-controls.exit"
```

The twelve controls use current-main engines with the frozen older corpus. They establish pre-change behavior and actual command/phase RSS observations, not an interleaved A/B result. Both guest caches and native JIT state are controlled. The archived `compiler-generation.json` and preceding decoder `compiler-final-image-proof.json` retain the actual reused producer/fixpoint and final image proof. Reproduction regenerates that compiler rather than trusting a path to a stale artifact.

## Candidate, detecting negative control and correctness

Apply only the compressed measured implementation patch. Gzip preserves its exact context bytes. Both touched files were formatted before the source-bound builds and measurements.

```sh
set -e
gzip -dc "$context_archive/measured-implementation.patch.gz" > "$context_lab/candidate.patch"
git apply "$context_lab/candidate.patch"
python3 "$context_archive/prepare_reproduction.py" candidate "$context_lab"
python3 "$context_archive/prepare_reproduction.py" negative "$context_lab"
negative_result=0
CARGO_TARGET_DIR="$PWD/runtime/viberun/target" cargo test --release \
  --manifest-path "$context_lab/negative-crate/Cargo.toml" \
  context_verification_has_bounded_read_requests > "$context_lab/negative-test.log" 2>&1 || negative_result=$?
test "$negative_result" -ne 0
printf '%s\n' "$negative_result" > "$context_lab/negative-test.exit"
grep -F 'context_verification_has_bounded_read_requests ... FAILED' "$context_lab/negative-test.log"
grep -F 'context read request exceeds 64 KiB' "$context_lab/negative-test.log"
python3 "$context_lab/build_validate.py" > "$context_lab/build-validate.log" 2>&1
printf '0\n' > "$context_lab/build-validate.exit"
```

Compilation of the buffered negative control must succeed before the selected test fails for the actual read-request bound. A compile failure or unrelated test failure is not detecting evidence. `negative-buffered-source.rs.gz` and `negative-test.log` retain the exact original mutant and observation. The final exact-64MiB acceptance assertion was added afterward to a different unit test; the selected bounded-read test and verifier helper are unchanged. The convenience wrapper applies the same helper-only buffering mutation to the final source.

`build_validate.py` binds all compiler/library/runtime/script and generated inputs before each step. It checks generated freshness, ten lowering-service unit tests, the current source runner, three rebuilt function images, the full public function suite, three lowering images and the full public lowering suite. Candidate guest images must equal the preserved baseline; its new native runner must differ and match the new receipt. Context edits, truncation and appended bytes refuse before a deliberately missing first product can be read, preserving previous output.

## Fresh interleaved A/B and A/A

```sh
set -e
python3 "$context_lab/compare.py" stage
python3 "$context_lab/compare.py" run > "$context_lab/comparison.log" 2>&1
printf '0\n' > "$context_lab/comparison.exit"
```

There are132 complete samples: ordinary, same-driver serial and process workers1/2/4 on compiler/CLI, three cold/warm rounds per lane, plus12 additional identical-before A/A controls. Pair order reverses in the middle round. Every process starts fresh; each round/lane has its own guest cache. Native JIT is primed on another input. Lane,cache and output paths have equal lengths. Every final artifact must match the frozen corpus's ordinary reference; all12 A/A guest-memory pairs must match. Source, input, driver and image hashes are checked before `verified_complete` is written. Do not edit sources, build, profile or run other heavy checks while this matrix is active.

RSS is sampled as a simultaneous process-tree sum every20ms. Shared mappings may count repeatedly. The extra p4 timelines record current command lines at each sample, including process exec changes. `process-observations.json.gz` retains all132 comparison process receipts,12 before-control timelines and24 p4 comparison timelines. The interval after the last observed worker includes verification, product consumption and finalization; it is not an exact verifier allocation span. Fixed64KiB scratch does not imply an equal reduction in whole-build peak RSS.

The complete matrix is followed by reporting, required release checks, normal hooks and exact-head hosted CI/review. No source/library API, wire protocol, native thread backend, targetRC0 selfbuild support, seed publication or default is enabled here.

## Separate current-main correctness validation

Main advanced to `8f999be77878bb2119cbf9c1f2fb944012ed51f1` (#3502/context7) after the historical matrix. `current-main-validation.json`, its generation/source authority and the three current-main test logs record a fresh fixpoint, matching image receipts and successful real public suites on that base. The native verifier implementation is unchanged. These are correctness observations, not new performance samples.

To reproduce this proof, use a separate fresh checkout of `8f999be77`, apply the two-file measured implementation patch, and copy `current_validate.py` into a fresh `_build/function-context-verification-3483-20261018/` before running it from the root. The script creates its own `current-main/`, regenerates sources, builds stage1/2/3, checks stage2 == stage3 and receipts, then runs both public suites with the explicitly built compiler. Do not reuse an already populated proof directory or combine its timings with the historical context6 matrix.

Rust test transcripts are stored as `.log.gz` to preserve their exact original bytes, including terminal blank lines. Use `gzip -dc` to inspect them. The raw record binds both compressed and uncompressed SHA-256 values; no transcript is whitespace-normalized.
