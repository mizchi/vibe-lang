# Function-worker metadata transfer and lifetime (2026-10-18)

Function snapshots repeated the same long function identities in sorted vectors, return/capture summaries and origin maps. The candidate writes those names once, then references the checked immutable name pool within each private worker. Compiler context bytes fall **48.8%**, CLI context bytes **10.8%**. Four-worker peak RSS also falls, but whole-build wall changes remain below the prespecified 5% noise threshold. Keep the route opt-in; native threads and bootstrap integration remain incomplete.

The [raw record](../../../bench/perf/analysis/function-worker-transfer-2026-10-18.json) retains 204 unprofiled complete builds (12 actual bootstrap, 72 initial route controls, 120 alternating comparisons), exact input/image authority, guest counters, real I/O counts, 60 CPU-profile summaries and retained-file hashes. [Archived drivers and the measured overlay](../../../bench/perf/experiments/function-worker-transfer-2026-10-18/README.md) reproduce the experiment.

## Scope and authority

The before archive is main `45184a3263405459e9597e35c9e5036de9f1e31e`, tree `9593ee1b799ce6effc425836728095dfbe3d8167`. The candidate uses the recorded dirty implementation overlay on that base. Final wire-reuse/protocol test assertions, reporting and formatting were added afterward. The context runtime file changed only in block layout; all three runtime images were rebuilt and are byte-identical to the measured artifacts ([equivalence proof](../../../bench/perf/experiments/function-worker-transfer-2026-10-18/formatted-image-proof.json)). Other runtime image sources still match. These samples are not relabeled as a later Git-head measurement.

Both selected compiler generations have stage2 == stage3 and SHA-256 `ebc0d34b19a20224953d0e29b53a80fbdc93321ebba61180e2af5e0d9fb34628`. The core compiler executable is unchanged: this optimization is in the separate function-build/worker units. The pinned seed is `aaa5a9d5…1d4b422a112c22dc9`; runner source stamp is `f693a669787defb6ad104bb3b2d135c6d9beb279fb1ed049551a8447bb594989`. Full hashes and producer manifests are in the record.

The machine is a Ryzen 7 7700, 16 logical CPUs, 64 GiB WSL2/ext4, Node 24.7.0. Cold/warm here distinguish isolated guest parsed-source caches; native JIT is primed on a different input and OS pages remain warm. Each lane runs cold then warm in fresh processes. Pair order reverses in the middle round; before/after cache and output paths have equal lengths. Checked-module, body and final-artifact caches are off. All twelve identical-artifact ordinary A/A pairs have exactly matching guest allocation/frontier/reserved-page counters.

The supported native workloads are the filesystem compiler closure `compiler/tests/codegen_lexer_test.vibe` (`__no_entry__`) and split CLI `cli/entry.vibe` (`cli_main`), emitted target RC1. Parent/worker engines use bump; the coordinator uses RC. Existing workers are separate processes. Actual flat bootstrap still does not install this executor and emits target RC0; library codec tests in both modes do not establish native target-RC0 support.

## Whole-build comparison

Each cell is the median of three alternating complete samples, before → after. The raw record retains every sample, min/max and paired directions without outlier removal. `o0` is ordinary compilation, `s0` the same-driver serial control. RSS is the maximum simultaneous process-tree sum sampled every 20 ms; shared mappings may be counted repeatedly. It is not a sum of independent child peaks.

| Corpus / route | Cold wall, s | Warm wall, s | Cold peak RSS, MiB | Warm peak RSS, MiB |
| --- | ---: | ---: | ---: | ---: |
| compiler / o0 | 5.882 → 5.945 | 3.956 → 4.011 | 1123.3 → 1123.2 | 646.8 → 646.6 |
| compiler / s0 | 6.084 → 6.199 | 4.092 → 4.122 | 1173.9 → 1173.7 | 696.6 → 696.6 |
| compiler / p1 | 7.660 → 7.567 | 5.242 → 5.189 | 1435.4 → 1431.2 | 960.4 → 952.3 |
| compiler / p2 | 7.304 → 7.154 | 4.790 → 4.761 | 1484.8 → 1465.6 | 1008.8 → 987.5 |
| compiler / p4 | 7.036 → 6.975 | 4.690 → 4.668 | 1618.6 → 1571.9 | 1132.2 → 1092.2 |
| split-cli / o0 | 15.896 → 15.883 | 11.653 → 11.742 | 2985.2 → 2985.7 | 2032.0 → 2032.1 |
| split-cli / s0 | 16.148 → 16.203 | 11.688 → 11.659 | 3039.3 → 3039.3 | 2086.0 → 2086.1 |
| split-cli / p1 | 20.289 → 19.981 | 14.810 → 14.905 | 3277.1 → 3269.2 | 2329.7 → 2326.1 |
| split-cli / p2 | 19.139 → 19.063 | 13.985 → 13.966 | 3386.5 → 3348.5 | 2440.1 → 2396.5 |
| split-cli / p4 | 18.897 → 18.667 | 13.668 → 13.566 | 3733.8 → 3669.2 | 2790.3 → 2723.9 |

Four-worker RSS reductions are compiler **46.7 MiB cold / 40.0 MiB warm**, CLI **64.6 MiB cold / 66.4 MiB warm**. Wall changes across worker configurations range from about −2.1% to +0.6%; they are inconclusive under the 5% rule. A smaller packet is not claimed as a whole-build speedup. Every comparison artifact matches the original ordinary reference; compiler artifact `2054f9f7…faa110bc`, CLI `8b12a09a…959ae98`.

### Actual bootstrap baseline

The separately refreshed real compiler bootstrap through stage3 is 193.768 s cold / 146.592 s warm; portable CLI through stage2 is 149.676 s / 103.154 s (N=3 each, packaging excluded). Warm regenerates and validates source; it is different from the previous prebuilt-source warm protocol. Every compiler fixpoint passes. These are baseline observations, not after-change gains: the actual bootstrap does not yet select function workers.

## Wire size, copies and owned memory

| Quantity | Compiler before → after | CLI before → after |
| --- | ---: | ---: |
| Shared context, bytes | 5,735,096 → 2,936,061 | 50,419,987 → 44,990,116 |
| Four jobs, bytes | 7,903,887 → 7,903,887 | 13,253,101 → 13,253,101 |
| Four products, bytes | 6,524,791 → 6,524,791 | 8,793,591 → 8,793,591 |
| Actual four-worker context/job reads, MiB | 29.42 → 18.74 | 204.98 → 184.26 |
| Warm parent guest allocation, MiB | 764.4 → 762.9 | 2609.6 → 2606.8 |
| Each worker allocation reduction, MiB | 8.04 | 15.56 |

The I/O observations are fresh-nonce native host sidecars from exact captured-job replays. Every counter equals one context read plus assigned input bytes, and every product reproduces the captured real-build hash. They measure wire/host-to-guest copy volume, not simultaneously retained buffers. All twenty guest-memory control groups match their three profiled repeats exactly; allocation, frontier and reserved pages remain distinct from RSS.

The CLI runtime-literal payload remains **39,253,373 bytes**. The candidate does not truncate it, change literal IDs or alias mutable packet storage. Each worker still reads a private packet and owns its decoded heap. The metadata pool shares only already checked immutable Strings inside that heap; mutable Array/Bytes remain non-Send. The parent retains its original lowered plan through validation and canonical replay. Clearing references or buffer length does not reclaim a bump frontier.

The initial guest-to-host context Vec is consumed by `fs::write` and dropped before workers run. A separate context-verification Vec is reread after the worker wave and lives through result consumption. Each product is read into a host Vec, copied to a reusable guest buffer, decoded and retained until all products validate. Those lifetimes are separate; the context is not retained as the initial host Vec throughout the worker interval.

## Separate CPU and phase diagnostics

There are 20 parent runs and 64 exact worker replays, including 60 guest epoch CPU profiles and 16 real worker I/O controls. Guest sample percentages exclude host/JIT work and include overlapping ancestors. They are not elapsed-time reductions. Context decode remains about 15% of aggregate compiler-worker guest samples and 29% of CLI-worker samples; large literal UTF-8 checks, string-table hashing and layout fingerprints remain.

The original diagnostic cached the first observed command name, which can precede `exec`. The corrected eight RSS replays retain the actual command at every sample. Their output/image hashes match; use these for phase attribution. The unprofiled comparison totals were never changed. Corrected warm p4 observations:

| Corpus / lane | Peak while workers run, MiB | Peak after last worker, MiB |
| --- | ---: | ---: |
| compiler / a0 | 1132.7 | 914.9 |
| compiler / b0 | 1098.1 | 910.2 |
| split-cli / a0 | 2792.0 | 2366.4 |
| split-cli / b0 | 2726.8 | 2358.2 |

At the after-worker peaks, only the native parent and Node frontend remain. The remaining parent floor already exceeds the contemporaneous ordinary RSS allowance; reusing worker threads alone does not remove it. Phase observations are separate diagnostic replays, not extra promotion walltime samples.

## Bounds and next work

Context and queued job wire limits remain separate 64 MiB bounds; supported function jobs remain 1/2/4. A product is capped at 256 MiB, so four product files have a 1 GiB wire ceiling. That does not bound the decoded guest live set: products, merge intermediates and finalization scratch can coexist in the bump parent. Resource admission and completed-output backpressure remain required in #3484; phase/parent lifetime must be addressed before #3485 integration.

The #3486 gate still fails: p4 is slower than contemporaneous ordinary and serial controls, memory exceeds 110% of ordinary, and forced p1 exceeds the 5% overhead allowance. Keep defaults serial. The old absolute bootstrap budgets and this transport improvement do not establish a parallel-execution win.

Continue #3483 with measured parent/result ownership. `codegen/transport/body_codec.vibe::bcc_read_string` currently constructs a one-byte String and parts entry for every byte, then joins them: it is linear, but allocates many intermediates. Measure that allocation before selecting an owned bulk-copy replacement. Also measure releasing the post-wave host verification buffer earlier and sizing/reusing parent packet buffers. A larger immutable literal/plan representation or a prepare/emit/finalize Store boundary needs an explicit ownership/diagnostic contract; do not remove validation, use unsafe Send casts, or assume dropping bump references frees memory.

Language/library feedback: bounded String-to-Bytes append and a portable capacity query would avoid private raw-layout/Int-ABI helpers. The boundary test found that a hand-tagged spare-capacity Int doubled the apparent capacity on bump. The fix follows the caller representation of Int 1; bump, RC and shadow tests pin exact-capacity refusal. A public primitive should own these details and refuse before mutation. No new public API or shared-memory guarantee is frozen by this change.

## Correctness and validation

Context format6 interns metadata only after ordinary checked `all_fn_names_list`. References preserve canonical positions and are index-checked; names shorter than 16 bytes or absent from the pool stay inline. Job literal references keep their separate original pool and format2. Old images require rebuilding. The original before wire4/receipt3 mismatch is preserved in the record; candidate wire6 matches its receipt.

Targeted tests pass in emitted modes bump, RC and shadow RC (two files, nine tests per mode). They pin owned strings after the encoded buffer is overwritten, stale actual wire versions, invalid pool indices, hostile/truncated jobs, range/metadata parity and unchanged output. The public CLI suite compares and executes seven cases at jobs1/2/4 and preserves old outputs on unsupported settings, aliases, stale ABI/version, invalid source and a real worker trap. An independent native producer probe observes actual context bytes and detects a deliberately stale receipt, preventing publisher/frontend constants from hiding wire drift. Six diagnostic-integrity tests also pass.

The old producer fails the new metadata-reference runtime regression. The pre-fix bump capacity check accepts a write that must refuse; the final boundary tests pass. All six actual compiler-bootstrap fixpoints and the candidate stage2 == stage3 pass; the selected compiler hash is unchanged. Required `pkf run release-check`, normal commit hooks and exact-head CI completion are recorded on the implementation PR rather than inferred from these targeted checks.
