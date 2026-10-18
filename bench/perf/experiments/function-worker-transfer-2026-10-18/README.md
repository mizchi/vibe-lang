# Function-worker transfer experiment (2026-10-18)

These are the exact archived drivers for the [report](../../../../docs/internal/reports/function-worker-transfer-2026-10-18.md), not a latest-main promotion command. Run from the repository root in a fresh workspace with Python 3.12+, Node 24.7.0, the pinned seed and the repository Rust runner. All measurements are sequential; do not overlap builds, tests or profiles.

The before corpus is archived main `45184a3263405459e9597e35c9e5036de9f1e31e`. The measured candidate is that commit plus `measured-implementation.patch`. The final PR adds ownership/protocol test assertions, reporting and formatting after this overlay. The context file formatter changes only block layout; all three rebuilt runtime images match the measured artifacts byte for byte, recorded in `formatted-image-proof.json`. To reproduce the exact candidate, apply the included patch to the recorded base in a fresh checkout. The image builder deliberately uses the recorded default lab location below.

```sh
bash scripts/ensure_seed.sh
bash scripts/ensure_viberun.sh
transfer_lab=_build/function-worker-transfer-3483-20261018
python3 bench/perf/selfbuild_baseline.py prepare "$transfer_lab/baseline" --ref 45184a3263405459e9597e35c9e5036de9f1e31e
python3 bench/perf/selfbuild_baseline.py clock "$transfer_lab/baseline"
python3 bench/perf/selfbuild_baseline.py bootstrap "$transfer_lab/baseline" --rounds 3
python3 bench/perf/selfbuild_baseline.py images "$transfer_lab/baseline"
python3 bench/perf/selfbuild_baseline.py matrix "$transfer_lab/baseline" --rounds 3
VIBE_BUILD_CACHE_DIR="$PWD/$transfer_lab/candidate-build-cache" bash scripts/generations.sh build --stage3 --out-dir "$PWD/$transfer_lab/candidate-generation"
python3 bench/perf/experiments/function-worker-transfer-2026-10-18/build_images.py
python3 bench/perf/experiments/function-worker-transfer-2026-10-18/compare.py stage "$transfer_lab/baseline" "$transfer_lab/candidate-images" "$transfer_lab/candidate-generation/stage2.wasm" "$transfer_lab/comparison"
python3 bench/perf/experiments/function-worker-transfer-2026-10-18/compare.py run "$transfer_lab/baseline" "$transfer_lab/candidate-images" "$transfer_lab/candidate-generation/stage2.wasm" "$transfer_lab/comparison" --rounds 3
python3 bench/perf/experiments/function-worker-transfer-2026-10-18/diagnostics.py "$transfer_lab"
python3 bench/perf/experiments/function-worker-transfer-2026-10-18/rss_phases.py "$transfer_lab"
```

The drivers preserve existing output directories and require three rounds. Before and after share one frozen corpus, use equal-length lanes and isolated parsed-source caches, and prime native code on another input. The complete matrix checks every final artifact against the original reference. `o0` is an identical-artifact ordinary control; `s0` is the same parent with serial emission; `p1/p2/p4` are the public separate-process worker route. The report separately verifies all twelve ordinary A/A guest-memory pairs.

Diagnostics require a completed comparison. Captures retain actual context/job bytes and original product hashes; every replay must reproduce its product. CPU profiles are guest epoch samples, excluding host work. Their walltimes are not promotion samples. Real worker filesystem sidecars use fresh nonces and must count exactly one context read plus assigned job reads. Guest frontier, reserved pages and simultaneous process-tree RSS are reported separately.

`diagnostics.py` retains the original RSS replay with a first-observed command cache. `rss_phases.py` supersedes its **process classification** with actual command lines at every sample, following `exec`. Both sets of raw observations remain; the latter supplies phase attribution. Neither replaces or relabels the unprofiled comparison.

The original producer emits context wire4 while its receipt reports3. The before lane preserves that discrepancy. The candidate's actual wire6 matches its receipt; the final regression suite independently observes a real producer and detects stale receipt metadata. Do not edit old receipts to make an incompatible frontend accept them.
