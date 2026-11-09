# LSP semantic reuse: workload and invalidation inventory

This is the first bounded step of [#1960](https://github.com/mizchi/vibe-lang/issues/1960).
It measures the actual editor entries, compares current-state answers against
fresh servers, and fixes one cache refusal bug found by that comparison.
Retained editor semantic state is still pending.

## Deleted dependencies must invalidate resolved paths

After a successful check, deleting an imported ordinary `.vibe` file left a
resolved path in the module-header cache. A warm diagnostic consequently said
`dep.vibe does not exist` over the whole import line. A cold check instead
reported `cannot resolve import './dep.vibe'` at the import path. The default
Node LSP exposed this difference in all three baseline rounds.

`package_index_dep_is_current` now rejects any missing resolved dependency,
including ordinary files, before checking package resolution winners. Both
the header and persistent dependency-list readers already use that validator.
Refusal returns to normal import resolution, which produces the same located
diagnostic as a cold check. Successful warm reuse remains available; no cache
format or mode changes. The regression suite covers imports, re-exports,
unchanged cache contents on refusal, dependency-list refusal, and recovery
after restoring the file. Bootstrap runs it with the just-built stage2.

## Workload

The selected action is repeated typed hover in a small document. Correctness
observations also include diagnostics, references, declaration locations and
`doc-at`. Each engine runs the same edit sequence in a retained server, then
answers each current state in a new server with an empty guest disk cache.
Three independent rounds alternate engine order. Requests and compiler work
are serial. Disk text and open-buffer text are distinct inputs.

The 19 states cover no-op, unsaved type edits, doc edits, moved locations,
UTF-16 columns after an emoji, parse failure/recovery, close/reopen with reset
versions, dependency public/private/doc/location changes, an unsaved dependency,
dependency deletion/recovery, and a changed buffer import with unchanged disk
imports. Snapshots compare messages and locations as well as values. Only the
exact server PID in its own temporary basename and the common project prefix
are normalized. Concrete standalone type/doc answers and identifier ranges
are checked too, so two empty answers cannot satisfy the oracle.

`verify_receipt.mjs` mutates real captured answers: stale diagnostics, hover,
references, symbols and docs, plus missing fields. It first requires each stale
answer to differ from the current one, then requires the oracle to reject it.
These are oracle tests, not claims about faulty compiler variants.

Full raw transcripts, timing samples, source strings, hashes, selected settings
and server exits are retained in the requested output directory. The committed
`results.json` summarizes the source-bound run. Latencies are advisory; this
work does not enable reuse or claim a speedup. Guest allocation, linear-memory
reservation and native RSS are different metrics and are not inferred from LSP
latency.

### Recorded results

Baseline `0acb61cef626426cf2120e20ced4db41a132bef2`, compiler
`16a1571946394c5459af948531a468bfda8515ae749fb1bba29bc1bae17fecf0`;
candidate compiler
`f4f8ad806c484d2fe7349c33f720d64d53707af805e7b3d1025b51bea969b677`.
Both are seed-built stage2/stage3 fixpoints. The same probe hash and literal
project/cache paths were used for both editor measurements.

- Before: 114 comparisons, three failures, all Node dependency deletion.
- After: 114 comparisons, zero differences; 20 captured-answer mutations
  rejected in each revision's oracle verification.
- Targeted loader/source/persistent-cache suites: 47 tests in each of bump and
  RC modes, through the exact candidate compiler.
- Disk-adapter fixture: three more tests in each mode. Valid dependency rows
  use real files, and the stale-package control uses an existing wrong root
  so an absent file cannot satisfy its refusal assertion.

No-op medians over three independent sessions (milliseconds):

| Entry | Repeated hover, before / after | Document update through diagnostics, before / after |
| --- | ---: | ---: |
| Default Node | 124.030 / 123.939 | 409.421 / 411.707 |
| Selfhost | 0.282 / 0.303 | 0.667 / 0.692 |

These entries have different dependency and documentation coverage, detailed
below. The large latency gap suggests measuring a resident provider behind the
default transport before building another cache. It is not evidence that the
selfhost entry is ready to replace the default, or that this fix speeds up
hover. The selfhost entry still recomputes its single-file query.

Compiler-cost medians, same frozen inputs, 24 serial A/B samples:

| Closure | Cache | Wall seconds, before / after | Heap-pointer delta |
| --- | --- | ---: | ---: |
| Compiler KPI | cold | 9.148 / 9.265 | +5,688 B |
| Compiler KPI | warm | 4.785 / 4.759 | +3,096 B |
| CLI | cold | 19.387 / 19.502 | -2,600 B |
| CLI | warm | 10.744 / 10.687 | +192 B |

All generated Wasm outputs match across compilers and temperatures. Allocation
differences have magnitude below 0.001%; wall changes range from -0.56% to
+1.28% and do not establish a speedup or regression. Heap pointers include the
static base and cumulative bump allocation; this is not an RSS/peak-memory
measurement. Exact samples and output hashes are in [results.json](results.json).

## Existing boundaries and the facts an editor must retain

| Boundary | Existing implementation | Editor requirements / remaining work |
| --- | --- | --- |
| Default editor entry | `runtime/vibe lsp` starts `clients/js/lsp_server.js`; each typed hover starts a compiler subprocess | Keep Node's workspace graph and filesystem diagnostics while removing repeated compiler startup; changing the default to `--selfhost` does not preserve those features. |
| Resident editor entry | `lib/@vibe/lsp/lsp_server.vibe` handles single-file queries in process | Its row is `Stdin + Console`; it cannot read dependencies. Process residency alone does not establish project semantic reuse. |
| Hover / references / docs | `query/type_at.vibe`, `binding_at.vibe`, `doc_at.vibe` consume source strings | Capture exact current bytes and positions, original module path, compiler/session identity and configuration. A public-interface match does not authorize old docs or source spans. |
| Production import walk | `plan_import_graph_fs_with_config` and `run_module_typecheck_walk` order dependencies and publish checked modules | Feed the current buffer's import graph, including all open dependency overlays. Do not derive the graph from the old disk entry and replace its text afterwards. |
| Shared query preparation | `query/project_context` already collects ingested sources, retains `RippleDb` plus dependency sources/environments and projects imports | `query_project_context_fs` starts collection from disk. Its replacement edit is applied after collection, so it is not a complete LSP overlay boundary for changed imports or unsaved dependencies. |
| Persistent typing transport | Existing module records and dependency-env aliases/witnesses preserve exact input/target/namespace validation | Use that production validation; a trace interface fingerprint or a hash alone is not permission to reuse an editor result. Refuse malformed, stale or incomplete facts. |
| Backend body replay | Real-entry replay and relocation have landed under #2825 | They produce executable bodies, not current-buffer binding tables or source locations. No second body cache is needed for this workload. |

The experiment records important coverage limits rather than promoting them
to semantic guarantees:

- Imported hover currently reports `?` in both entries. Imported docs are
  absent, and references stay within the querying document. Cold/replay equality
  here does not prove dependency-aware navigation.
- The Node entry detects a breaking **disk** dependency edit through its plain
  check fallback. Its separate single-file hover still reports `?`.
- The selfhost entry does not diagnose that dependency's changed signature or
  deletion. Neither entry propagates an open dependency's unsaved type edit to
  this root. Equal fresh results share these limitations.
- The default Node hover omits `///` docs even when `doc-at` returns the current
  doc. The selfhost hover includes them.
- There is no retained editor artifact to corrupt yet. Existing bootstrap
  incremental/typing-reuse oracles retain their stale alias/witness/target and
  configuration controls; those are not presented as LSP artifact coverage.

## Next implementation boundary

The shared filesystem query preparation now ingests the current `.vibe` or
`.vibex` entry before collecting its import graph. This also fixes the label
codemod's replacement recheck: added imports are collected, removed imports
are no longer walked, and shared import prefixes are recomputed. An ordinary
entry can be queried before its first save. Original paths and physical source
mapping remain intact; source edits are never written to the user's file.
Unedited disk queries retain the existing closure-cache path. A replacement
reads the actual original bytes before authorizing the edit, including when
timestamps and size are preserved; even a no-op replacement collects its own
text. An unsaved package contract is explicitly refused. The bootstrap gate
runs the project-context and label recheck suites with its own stage2.

Compiler-cost check for this preparation step, using the same input snapshot
and 24 isolated serial A/B compiles (three rounds, cold and warm):

| Closure | Cache | Wall seconds, before / after | Heap-pointer delta |
| --- | --- | ---: | ---: |
| Compiler KPI | cold | 8.238 / 8.275 | +2,344 B |
| Compiler KPI | warm | 4.312 / 4.371 | -664 B |
| CLI | cold | 17.357 / 17.505 | -2,720 B |
| CLI | warm | 9.577 / 9.622 | -5,976 B |

All generated Wasm outputs match across compilers and temperatures. Absolute
heap-pointer differences are below 0.001%; wall changes range from +0.45% to
+1.37% and do not establish a speedup. This is cumulative bump allocation plus
static base, not RSS or live/peak memory. [Exact source/artifact identities and
samples](current-entry-results.json) record this step separately from the
earlier editor workload above.

The unedited-query disk comparison shares the loader's stat-validated source-text memo to
avoid another whole-file allocation. A typed grep over a 1,048,633-byte input
keeps one non-empty typed result and two actual host reads of the entry, the
same as the base compiler. An extra-read control records three. Twelve serial
cold/warm query samples (three alternating A/B rounds, fresh Node processes,
identical literal paths) keep the same result. This prevents added copying,
not a claimed editor speedup. See read_probe.py for the executable protocol.

The read probe requires two explicit compiler artifacts and a new output
directory under `_build`. Set `BASELINE_STAGE2` to the compiler built from
`a497c68ea911ecf3a261253498308a0f5f753bcc` in a clean base checkout; the
candidate below is built by the reproduction commands later in this file:

```bash
python3 bench/perf/experiments/lsp-semantic-1960/read_probe.py \
  "$BASELINE_STAGE2" _build/lsp1960/stage2.wasm _build/query-entry-read-check
```

It pins a non-empty `Array[Int]` capture and its physical range, compares exact
answers, counts actual host reads in separate debug runs, and times three
cold/warm A/B rounds. An artifact with an extra entry read fails before timing;
the failed receipt records the actual three reads. The committed extra-read
control uses an unmerged draft artifact, not a released performance baseline.

Next, layer all open dependency buffers over source reads and propagate that
provider through nested ingestion and import validation. This entry-only
boundary is not yet connected to the LSP transport and does not make imported
hover or unsaved dependency diagnostics complete. Capture configuration once
with the session/request rather than letting a retained environment outlive
its compiler or target namespace.

Then use a resident query provider behind the default transport and measure the
same workload. Keep filesystem diagnostics and workspace features. Only retain
a checked query snapshot once the overlay/provider can supply complete input
identities; a rejected identity must recompute fresh, and locations/docs must
be refreshed even when dependency public types are reusable. Bound per-document
state and discard it on close/session replacement. No native threads or retired
backend transport project is a prerequisite.

## Reproduce

Use the repository's supported Node toolchain and build the native runner:

```bash
cargo build --locked --release --manifest-path runtime/viberun/Cargo.toml --bin viberun -j 1
bash scripts/ensure_generated.sh
VIBE_PREBUILT_MODULE_SOURCE=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generations.sh build --stage3 --out-dir _build/lsp1960
cmp _build/lsp1960/stage2.wasm _build/lsp1960/stage3.wasm
node bench/perf/experiments/lsp-semantic-1960/probe.mjs \
  _build/lsp1960/stage2.wasm _build/lsp1960-run
node bench/perf/experiments/lsp-semantic-1960/verify_receipt.mjs \
  after _build/lsp1960-run/receipt.json
```

The output directory must be new. The probe requires an explicit compiler,
drops inherited `VIBE_*`/`NODE_*` selectors and selects the real native runner.
No compiler fallback or scripted timing provider exists. Any current-state
comparison failure produces a failed receipt and exits nonzero. Baseline
verification uses `before` instead of `after` and requires the three named
deletion failures; it cannot certify a candidate.

The compiler-cost comparison uses the existing
`../invocation-checked-cache-1953/measure_integration.py` with `--same-source`:
three alternating A/B rounds, cold and warm, compiler KPI and CLI closures,
the same literal input/compiler/cache/output paths, and byte-identical output.
The shared predicate adds filesystem existence probes on warm edges; that
cost must be measured rather than assumed free.
