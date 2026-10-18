# Owned function-product string decoding (2026-10-18)

The function-product decoder constructed a one-byte String and a parts-array entry for every name byte before joining them. The linear function route now uses the existing owned bulk string copy for result metadata and worker guard templates. The portable codec keeps its byte-wise default, including GC. VBC6/context6/job2 and callback ABI2 are unchanged.

In separate parent allocation diagnostics, result decoding falls from **70.6 → 28.3 MiB (−60.0%)** for compiler and **68.9 → 42.8 MiB (−37.9%)** for split CLI. Four-process whole-build peak RSS falls, most clearly for compiler. Every wall change is below the prespecified 5% threshold; this experiment establishes no whole-wall speedup. Keep the route opt-in and #3483 open.

The [raw record](../../../bench/perf/analysis/function-worker-decoder-2026-10-18.json) retains all **216 unprofiled samples** (12 actual bootstrap baseline,72 baseline route controls,132 alternating comparisons including12 fresh A/A controls), exact source/image authority,16 separate phase-probe runs, baseline CPU/memory summaries and control evidence. [Archived drivers](../../../bench/perf/experiments/function-worker-decoder-2026-10-18/README.md) reproduce the measurements. Diagnostic walltimes are excluded from promotion samples.

## Source and measurement scope

The frozen source is main `eeba680337dae422362c465439bd60f5d53da040`, tree `4b23bf782d338daaf84bb50cfd844cfc50911306`, archive SHA-256 `2550542b2921e98f0acfab9300e5cd7b94417a91824c01a4d246f68849d7f634`. It includes #3508's corrected bump SIMD BLAKE3 and ABI2 refusal of stale images. Earlier #3506 worker measurements used the old incorrect bump digest and retain that qualification; they are not a corrected-hash comparison for this optimization.

The candidate is the exact archived implementation overlay plus two recorded new test files on that base. All maintained implementation files were already formatted before the source-bound generation/image builds and measurements. Reporting/archive files, the docs audience-index row and a documentation-count floor tightening are added afterward; they do not relabel these as later Git-head measurements. All runtime/library sources remain identical, and all three final rebuilt images match byte for byte ([final source/image proof](../../../bench/perf/experiments/function-worker-decoder-2026-10-18/final-image-proof.json)). The build authority binds every relevant source/generated input and rechecks them throughout generation, targeted tests and image construction.

The before compiler is `ebc0d34b19a20224953d0e29b53a80fbdc93321ebba61180e2af5e0d9fb34628`; after is `9715fe9d46cec3181b252750d19ba8755f7e1334ba2a2ff0faa44ea27e8b911b`. Both have stage2 == stage3. The core executable changes because the portable decoder now carries an explicit copier; ordinary before/after outputs over the same frozen corpus remain identical. The native runner is unchanged (`b9e5e4dce33d3f42c73c0b5858d7862237260069a3a52edd3cb010228da53e66`). The raw record binds all parent/worker/coordinator hashes and receipts.

Reference host: Ryzen 7 7700,16 logical CPUs,64 GiB WSL2/ext4, Node 24.7.0. Native JIT is primed on another input. Cold/warm distinguish fresh/reused private parsed-source caches; each compile starts a fresh process and OS pages remain warm. Pair order reverses in the middle round. Lane,cache and output paths have equal lengths; all 12 new identical-compiler A/A guest-memory pairs agree exactly. Checked-module,body and final-artifact caches are off. No source edits, other builds or CPU profiles overlap unprofiled measurements.

Native corpus: filesystem compiler closure `compiler/tests/codegen_lexer_test.vibe` and split `cli/entry.vibe`, emitted target RC1. Parent/worker engines are bump; the coordinator is RC. These workers are **processes**, not native threads. Actual bump-target bootstrap still does not select this executor. Bump/RC/shadow codec tests do not establish public worker support for target RC0.

## Whole-build comparison

Values are medians,N=3, before → after. Raw samples retain min/max and every paired direction without outlier removal. `o0` is ordinary; `s0` is the same parent with serial emission; `p1/p2/p4` are the public process-worker frontend.

RSS is the maximum simultaneous process-tree sum sampled every20ms. Shared mappings may be counted repeatedly. It is distinct from guest allocation/reservation and is not a sum of independent child maxima.

| Corpus / route | Cold wall,s | Warm wall,s | Cold peak RSS,MiB | Warm peak RSS,MiB |
| --- | ---: | ---: | ---: | ---: |
| compiler / o0 | 6.095 → 6.067 | 4.032 → 4.130 | 1124.0 → 1123.8 | 646.8 → 646.8 |
| compiler / s0 | 6.275 → 6.148 | 4.195 → 4.289 | 1174.5 → 1174.1 | 696.8 → 696.8 |
| compiler / p1 | 7.801 → 7.754 | 5.326 → 5.233 | 1430.1 → 1412.5 | 952.5 → 932.8 |
| compiler / p2 | 7.408 → 7.304 | 4.976 → 4.893 | 1462.7 → 1435.7 | 988.9 → 960.2 |
| compiler / p4 | 7.317 → 7.184 | 4.760 → 4.671 | 1564.0 → 1511.8 | 1093.4 → 1042.8 |
| split-cli / o0 | 16.342 → 16.353 | 11.977 → 11.953 | 2985.3 → 2986.1 | 2032.6 → 2032.3 |
| split-cli / s0 | 16.837 → 16.778 | 12.040 → 12.100 | 3040.3 → 3040.2 | 2086.3 → 2086.3 |
| split-cli / p1 | 20.784 → 20.722 | 15.193 → 15.376 | 3270.2 → 3244.7 | 2310.2 → 2291.5 |
| split-cli / p2 | 19.727 → 19.615 | 14.198 → 14.294 | 3352.4 → 3345.5 | 2391.6 → 2392.9 |
| split-cli / p4 | 19.263 → 19.167 | 14.029 → 13.827 | 3688.3 → 3664.3 | 2725.2 → 2712.6 |

For p4, compiler RSS falls **52.2 MiB cold /50.6 MiB warm**; CLI **24.0 MiB cold /12.6 MiB warm**. CLI p2 warm RSS is slightly higher (+1.3 MiB); this is not an across-the-board RSS win. All absolute before/after wall changes are under 5%, with mixed paired directions: no wall-speedup claim. The candidate p4 route is still slower and consumes more RSS than its contemporaneous ordinary control.

All 132 comparison outputs match the original ordinary reference by subject: compiler `2054f9f7cb71c1526ecadc4f83767d8e5d2694354eb5b4a61b3edaf4faa110bc`, CLI `8b12a09acad25549e0e5858dab36902d84ff821de47bfe68a939da71f959ae98`. Shared context,job and product wire bytes are unchanged.

### Actual bootstrap baseline

The separately refreshed compiler bootstrap through stage3 is **199.994s cold /151.943s warm**, portable CLI through stage2 **154.128s /105.727s** (N=3 each). Peak simultaneous RSS medians are compiler3474.0/3474.5 MiB and CLI3478.8/3480.9 MiB. Packaging,installation and native-runner compilation are excluded. Source regeneration/validation is included; Node/JIT processes are fresh. All compiler fixpoints and per-subject hashes pass. These are baseline observations, not after-change bootstrap gains.

## Separate allocation diagnostics

The original and candidate parent-entry copies record checked bump-frontier boundaries around context encoding,hashing,job encoding,result buffering/decoding/validation,merge,replay and publication. There are eight runs per version: one cold plus three warm for each subject. Every final artifact matches the unprofiled reference; all three warm **absolute spans** agree exactly within each version.

| Warm allocation,MiB | Compiler before → after | CLI before → after |
| --- | ---: | ---: |
| Product decode | 70.627 → 28.275 | 68.899 → 42.764 |
| Worker group,inclusive | 162.660 → 120.307 | 207.060 → 180.926 |
| Execute total,inclusive | 189.004 → 146.652 | 256.302 → 230.167 |
| Main before execute | 537.002 → 537.080 | 1947.034 → 1947.162 |
| Main after execute | 36.933 → 36.933 | 331.148 → 331.148 |

**Never add inclusive worker-group/execute totals to their children.** These are allocation/frontier deltas,including capacity reservation,not RSS reductions. Not all decoder allocation is removed: bodies and metadata arrays still need owned storage. Small preparation changes remain visible rather than being removed from the record.

The executor callback correctly rejects a Profiler effect: it has an Exception-only contract. The diagnostic therefore uses an isolated source copy and an exported pure marker. After compilation,only its validated `i64.const0` Wasm body is replaced with a read of the exported mutable i32 heap global,multiplied by the caller's representation of Int 1. Every other function body and section payload is unchanged. Main explicitly grants the real Profiler and requires exact equality with that observer. Native final heap_peak independently calibrates the raw-byte unit and bounds the printing gap below 1 MiB. Archived source/Wasm patches and hashes bind this diagnostic-only transformation; no production effect row or compiler escape hatch is widened.

## Ownership,validation and remaining work

A checked span reaches the copier only after length/bounds validation. The private linear helper takes a temporary packed Bytes view,then `String::concat` allocates the owned result; the view cannot escape. VBC6 preserves raw bytes,including NUL and invalid UTF-8,unlike the checked AST string reader. The portable default and existing trailing-byte behavior are preserved. Each worker and the parent still owns its decoded heap; mutable arrays/bytes do not become Send and no guest pointers are shared between Stores.

Current-compiler tests pass in bump,RC and shadow,including native execution of the ownership/allocation oracle. Portable codec tests pass on GC. Tests overwrite the complete input before re-encoding every decoded field,cover truncated frames and invalid/overlong lengths,and prove no unchecked span reaches the callback. Replacing only the optimized adapter with the byte-wise portable reference in an isolated source copy makes the long-name allocation budget fail at the expected test. This detecting control is retained with its source and log.

The public CLI suite passes seven cases with ordinary == jobs1/2/4 and correct execution: long identifiers,noncommutative arithmetic,builtin shadowing,nested closures,exceptions and a large Unicode string. Receipt/wire probes and changed-byte/native-failure tests preserve prior complete outputs. VBC6/context6/job2 and ABI2 remain unchanged; artifact receipts bind the newly built images.

#3483 remains open. The parent still retains its original lowered plan,completed products and merge/replay scratch. Clearing references does not reclaim a bump frontier. The context writer still reserves 64 MiB; reducing reservation alone must not be reported as equal physical RSS savings. Rust's initial context Vec is moved into `fs::write` and released before workers; its separate post-wave verification Vec remains in scope through result consumption. Bound that verification lifetime next,then remeasure merge/packet ownership and the large CLI literal pool. Numeric #3486 budgets still fail; native threads (#3484),actual target-RC0/stage/install integration (#3485) and default selection remain pending.

Language/library feedback: a supported owned bulk Bytes-to-String operation,with explicit raw-byte versus checked UTF-8 behavior and documented lifetime,can eventually replace private raw-layout helpers. The internal codec copier hook here does not freeze such a language/library API. Optional structured per-job metrics at TaskGroup join would also avoid widening worker callback effects merely to observe them; it is a proposal,not an implemented capability.

The full local `pkf run release-check` passes all 125 tasks (88 ran, 37 cached). The final metadata-only documentation floor is checked with the explicit measured compiler, and rebuilt runtime images remain byte-identical. Normal commit hooks and exact-head hosted CI/review outcomes are recorded on the implementation PR rather than inferred from these measurements.
