# docs/

Audience index for [#2002](https://github.com/mizchi/vibe-lang/issues/2002).
Paths are relative to this file. The tree is laid out by primary reader:
`user/`, `internal/`, `generated/` (#2565, #2566), plus `spec/`
for the version-pinned release specifications — those are classified by reader
like everything else (`spec/0-1.md` is user documentation), but they do not
live under `user/` because they do not track `main`: one file describes one
released version and stops changing at its tag.

**Every document under `docs/` must appear in exactly one class table below**,
and `scripts/check_doc_classification.sh` (`pkf run check-doc-classification`)
enforces it: a new document in no table fails, a document in two tables fails,
and a row pointing at a file that is no longer there fails. Add the row in the
same change as the document.

`docs/language-tour/` is not in the tree. Its content was folded into
[user/reference/cheatsheet.md](user/reference/cheatsheet.md).

`book/` stays at the top level and `docs/user/` links to it rather than
containing it: it has its own gates (`scripts/check_book_links.sh`,
`scripts/vibe_md.sh check`, `scripts/check_tutorial_translation_parity.sh`) and
external links to The Vibe Book (decided in #2565).

**Users:** [user/getting-started/install.md](user/getting-started/install.md) · [The Vibe Book](../book/README.md) ·
[user/reference/cheatsheet.md](user/reference/cheatsheet.md) · [user/reference/cli-commands.md](user/reference/cli-commands.md) ·
[user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md)

**Maintainers:** [internal/project/adding-modules.md](internal/project/adding-modules.md) · [internal/operations/bootstrap.md](internal/operations/bootstrap.md) ·
[internal/operations/operation-gate.md](internal/operations/operation-gate.md) · [internal/design/adr.md](internal/design/adr.md) ·
[internal/project/issue-triage.md](internal/project/issue-triage.md)

This file is the audience router. It is not one of the three classes below.

Classification is by primary reader (#2002). A public wasm/effect/package
contract stays user-facing even if maintainers also read it. An ADR, design
review, gate, or dated report stays internal even when it explains a public
feature.

## 1. User documentation

Install, learn, write, build, test, package, debug, deploy.

| Path | Notes |
| --- | --- |
| [user/getting-started/install.md](user/getting-started/install.md) | |
| [../book/](../book/README.md) | The Vibe Book. Canonical tour + language + systems. Children: [SUMMARY.md](../book/SUMMARY.md), [src/](../book/en/), [ja/](../book/ja/) |
| [user/reference/cheatsheet.md](user/reference/cheatsheet.md) | Language reference. Absorbed `language-tour/`. |
| [user/reference/cli-commands.md](user/reference/cli-commands.md) | |
| [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) | LSP, DAP, editor query CLI |
| [user/reference/source-range-contract.md](user/reference/source-range-contract.md) | What a reported position MEANS (byte, ADR-0108). Written because [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) called byte offsets "char offsets"; enforced by `scripts/check_source_range_contract.sh` |
| [user/guide/when-to-use-effects.md](user/guide/when-to-use-effects.md) | |
| [user/reference/vibe.md](user/reference/vibe.md) | Implemented language design outside pure syntax |
| [user/reference/syntax.md](user/reference/syntax.md) | Canonical implemented surface syntax |
| [user/reference/stable-surface.md](user/reference/stable-surface.md) | Stable surface / SemVer. Takes effect at the `0.1.0` tag (ADR-0109) |
| [user/reference/host-abi.md](user/reference/host-abi.md) | Host ABI of generated wasm |
| [user/reference/http_server_contract.md](user/reference/http_server_contract.md) | Public `Http::*` contract |
| [user/reference/feature-levels.md](user/reference/feature-levels.md) | Generated-wasm feature levels |
| [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) | The `vibe.*` core imports a generated program needs from its runner. The compiler's own host boundary is [internal/design/compiler-host-boundary.md](internal/design/compiler-host-boundary.md) |
| [user/getting-started/release-notes-0.1.0.md](user/getting-started/release-notes-0.1.0.md) | What changed since `v0.0.1` and why you would care |
| [spec/0-1.md](spec/0-1.md) | The `0.1.0` release specification: identity, artifacts, conformance, boundaries. **Pinned** — it describes one version and does not track `main`. Restates no definition a living document owns |

## 2. Maintainer / internal

Compiler contributors, release operators, CI, repository agents. Public in
the repo; not the user manual.

### Project

| Path | Notes |
| --- | --- |
| [internal/project/adding-modules.md](internal/project/adding-modules.md) | How to add/fix a library module in this repo |
| [internal/project/issue-triage.md](internal/project/issue-triage.md) | How an issue gets its kind, priority and `blocker` labels, and what each milestone holds |
| [internal/project/release-roadmap.md](internal/project/release-roadmap.md) | Version ladder, what promotes an rc, and what 0.1.0 and 0.2.0 hold |

### Operations / gates / bootstrap

| Path | Notes |
| --- | --- |
| [internal/operations/bootstrap.md](internal/operations/bootstrap.md) | Seed pin, stage0–stage3, and the bootstrap bump procedure |
| [internal/operations/operation-gate.md](internal/operations/operation-gate.md) | Which gate to run when, and the stop criteria |
| [internal/operations/build-cache.md](internal/operations/build-cache.md) | The persistent build cache: layout, identity hashes, publication, GC |
| [internal/operations/incremental-build.md](internal/operations/incremental-build.md) | Design + measurement; not a user how-to |
| [internal/operations/ci-speed.md](internal/operations/ci-speed.md) | CI job layout and its measured cost model |
| [internal/operations/coverage.md](internal/operations/coverage.md) | Compiler coverage strategy |
| [internal/operations/selfcompile-heap-policy.md](internal/operations/selfcompile-heap-policy.md) | |
| [internal/operations/pkfire-pkspec.md](internal/operations/pkfire-pkspec.md) | pkfire: install, Taskfile layout, cache, git hooks |
| [internal/operations/BENCHMARKS.md](internal/operations/BENCHMARKS.md) | Continuously-runnable regression signals |
| [internal/operations/wasm-opt-dogfood.md](internal/operations/wasm-opt-dogfood.md) | The vibe optimizer against binaryen `wasm-opt`: method and measured sizes |

### Design (ADR index + reviews + contracts)

| Path | Notes |
| --- | --- |
| [internal/design/adr.md](internal/design/adr.md) | Living ADR log |
| [internal/design/async-host-contract.md](internal/design/async-host-contract.md) | #2832: every async host import read off the emitters — what the values mean, who owns a handle, what completion looks like, and how a cancelled wait is released (`future.cancel-read` / `stream.cancel-read` / `subtask.cancel`). The synchronous sibling is [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |
| [internal/design/capability-authorization-surface.md](internal/design/capability-authorization-surface.md) | ADR-0088, partial: the capability grant ladder; L1 and L3 are connected for `vibe run` |
| [internal/design/capability-host-contract.md](internal/design/capability-host-contract.md) | ADR-0088's host half (#2825 step 1), partial (withholding landed; `vibe.capabilities` and the grant globals are not built): what a host does with a capability import it withholds |
| [internal/design/component-lazy-dispatch.md](internal/design/component-lazy-dispatch.md) | The `vibe build --component` / `viberun --commands` contract: manifest, result frame, which wrap a command gets |
| [internal/design/host-contract-artifact-lazy-cli.md](internal/design/host-contract-artifact-lazy-cli.md) | ADR-0112, proposed and unimplemented, no open owner: the residual `vibe:host` WIT, the self-describing build artifact (`vibe.entry`), and the `vibe-commands-v2` requirement column, as one declaration with three readers |
| [internal/design/component-build-convention.md](internal/design/component-build-convention.md) | ADR-0113, proposed; only the command kind exists, no open owner: what `vibe build --component` derives from an export surface, the admitted boundary types, and transparent vibe-to-vibe import |
| [internal/design/compiler-parallelism.md](internal/design/compiler-parallelism.md) | ADR-0068 companion: the compiler's parallel frontend. Phases 0–1 done, the pre-warm driver built but unwired, phases 3–4 unscheduled |
| [internal/design/concurrency.md](internal/design/concurrency.md) | ADR-0068, partial: the structured-concurrency specification (core stable, suspendable lane experimental). The user concurrency guide is the book's [17_concurrency](../book/en/17_concurrency.vibe.md) |
| [internal/design/effect-evidence-passing.md](internal/design/effect-evidence-passing.md) | ADR-0076, accepted: handler lowering (evidence passing, suspend CPS, `try_table`) |
| [internal/design/effect-taxonomy-entry-policy.md](internal/design/effect-taxonomy-entry-policy.md) | ADR-0084, partial: effect classes and entry admission |
| [internal/design/effect-wit-mapping.md](internal/design/effect-wit-mapping.md) | Compiler `--wit` mapping |
| [internal/design/effectset.md](internal/design/effectset.md) | ADR-0071, partial: effect sets |
| [internal/design/exception-effect.md](internal/design/exception-effect.md) | ADR-0085. User surface is the cheatsheet |
| [internal/design/compiler-host-boundary.md](internal/design/compiler-host-boundary.md) | ADR-0086: what a runner must provide for the compiler's own `cli_main`. Not the generated-program contract, which is [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |
| [internal/design/module-system-oracle.md](internal/design/module-system-oracle.md) | Executable ADR-0070 oracle |
| [internal/design/perceus-reuse.md](internal/design/perceus-reuse.md) | ADR-0092 (partial): the Perceus plan, constructor reuse and release |
| [internal/design/region-mutable-state.md](internal/design/region-mutable-state.md) | ADR-0090, current region storage and RC integration requirements |
| [internal/design/compiler-memory-experiments.md](internal/design/compiler-memory-experiments.md) | Measured memory experiments and adoption criteria |
| [internal/design/compiler-memory-baseline.json](internal/design/compiler-memory-baseline.json) | Raw compiler comparison and region/GC observations |
| [internal/design/compiler-retain-scratch.json](internal/design/compiler-retain-scratch.json) | Borrow inference and scratch measurements, controls and raw samples |
| [internal/design/compiler-free-var-scratch.json](internal/design/compiler-free-var-scratch.json) | Free-variable scope scratch comparison, controls and raw samples |
| [internal/design/compiler-free-var-callee.json](internal/design/compiler-free-var-callee.json) | Direct callee scan comparison, controls and raw samples |
| [internal/design/compiler-annotated-lambda-inference.json](internal/design/compiler-annotated-lambda-inference.json) | Annotated local lambda inference comparison, controls and raw samples |
| [internal/design/compiler-free-var-binding-lookup.json](internal/design/compiler-free-var-binding-lookup.json) | Callee binding lookup comparison, controls, fuel probe and raw samples |
| [internal/design/compiler-borrow-worklist.json](internal/design/compiler-borrow-worklist.json) | Fixed-point borrow inference comparisons, controls, retain counts and validation |
| [internal/design/compiler-bytes-effects.json](internal/design/compiler-bytes-effects.json) | Byte-range copying and effect reachability measurements, controls and validation |
| [internal/design/compiler-cache-capacity.json](internal/design/compiler-cache-capacity.json) | Pruned body-cache reuse, reserved byte-buffer measurements, controls and validation |
| [internal/design/compiler-callback-return.json](internal/design/compiler-callback-return.json) | Callback return ownership measurements, parser and cold/warm selfhost comparisons, controls and validation |
| [internal/design/compiler-module-cache.json](internal/design/compiler-module-cache.json) | Unified typing/lowering cache: cold/warm selfhost timings, allocator high-water, and filesystem operation counts |
| [internal/design/compiler-dce-symbols.json](internal/design/compiler-dce-symbols.json) | DCE spelling-ID experiment: cold/warm selfhost comparisons, allocation bounds, and CPU profiles |
| [internal/design/compiler-typeenv-symbols.json](internal/design/compiler-typeenv-symbols.json) | Immutable TypeEnv name indexes: cold/warm selfhost comparisons, CPU profiles, and transport compatibility |
| [internal/design/compiler-single-rebind.json](internal/design/compiler-single-rebind.json) | Reassignment lifetime and generated-name collision fixes, leak bounds, and cold/warm selfhost comparisons |
| [internal/design/registry-design.md](internal/design/registry-design.md) | ADR-0065 Phase 5 |
| [internal/design/resource-kind-parameters.md](internal/design/resource-kind-parameters.md) | ADR-0094, proposed: steps 0–2 landed, the remainder is #3143 |
| [internal/design/simd-data-structures.md](internal/design/simd-data-structures.md) | Measured record of the SIMD-first data-structure epic (#2340) |
| [internal/design/vibex-runtime-contract.md](internal/design/vibex-runtime-contract.md) | ADR-0075, partial: the `.vibex` runtime contract, per phase |
| [internal/design/wasip3-effect-alignment.md](internal/design/wasip3-effect-alignment.md) | ADR-0089, partial: implemented except Decision 1's JSPI and subtask backends (#3147) |
| [internal/design/zero-alloc-check.md](internal/design/zero-alloc-check.md) | ADR-0091, current conservative allocation verification |
| [internal/design/side-effect-consolidation.md](internal/design/side-effect-consolidation.md) | Measured basis of ADR-0100 / ADR-0101: mutation authority and collection naming |
| [internal/design/memory-contract.md](internal/design/memory-contract.md) | Linear / wasm-gc / RC |
| [internal/design/profiling.md](internal/design/profiling.md) | `vibe run --mem` / `--mem-sample` / `--alloc-site`, `vibe bench`, guest CPU profiles |
| [internal/design/rc-cutover-readiness.md](internal/design/rc-cutover-readiness.md) | ADR-0055 status |
| [internal/design/simd-api-design.md](internal/design/simd-api-design.md) | Current SIMD surface: fused builtins and inline-wasm kernels |
| [internal/design/test-example-capabilities.md](internal/design/test-example-capabilities.md) | Implemented (#1508, ADR-0088): the effect rows of tests, benches and examples |
| [internal/design/uniform-value-repr.md](internal/design/uniform-value-repr.md) | ADR-0055: value tagging, object headers, drop classes, RC allocator |
| [internal/design/wasi-p3-async.md](internal/design/wasi-p3-async.md) | Async lowering and ABI on WASI 0.3; open work in §6.2 |

### Compiler

| Path | Notes |
| --- | --- |
| [internal/compiler/ast_binary_abi.md](internal/compiler/ast_binary_abi.md) | Binary encoding of the surface AST (`selfhost_ast_v1`, behind `VIBE_EXPERIMENTAL_AST_CACHE`) |
| [internal/compiler/checked-body-transport.md](internal/compiler/checked-body-transport.md) | Opt-in checked-module artifact lane (`VIBE_CHECKED_MODULE_CACHE`, default off): format, consumers, cost measurements, parity gate |
| [internal/compiler/checked-direct-expression-return-observation.md](internal/compiler/checked-direct-expression-return-observation.md) | Checker observation note |
| [internal/compiler/tracing-design.md](internal/compiler/tracing-design.md) | Internal span tracing: host-side stage 0 implemented; guest `effect Trace` proposed |
| [internal/design/experimental-wasmfx-effect-backend.md](internal/design/experimental-wasmfx-effect-backend.md) | WasmFX feasibility probe. Tracked by #2221 |
| [internal/design/experimental-wasmtime-guest-profiler.md](internal/design/experimental-wasmtime-guest-profiler.md) | Wasmtime guest CPU profiling, implemented for core modules (#2207); component and continuation probes have no owner |
| [internal/compiler/vibec-component.md](internal/compiler/vibec-component.md) | Compiler-core component split |
| [internal/compiler/gc-value-abi.md](internal/compiler/gc-value-abi.md) | wasm-gc value ABI |
| [internal/compiler/wasm_threads_requirements.md](internal/compiler/wasm_threads_requirements.md) | Which Wasmtime thread surfaces vibe can rely on, and the measurements behind it (#488) |

### Reports / dated snapshots

Not normative.

| Path | Notes |
| --- | --- |
| [internal/reports/blake3-vs-sha1-bench-2026-08-01.md](internal/reports/blake3-vs-sha1-bench-2026-08-01.md) | |
| [internal/reports/cloudflare-workers-fit-2026-09-04.md](internal/reports/cloudflare-workers-fit-2026-09-04.md) | |
| [internal/reports/compiler-cache-streaming-2026-10-01.md](internal/reports/compiler-cache-streaming-2026-10-01.md) | Recursive cache encoder byte contracts and controlled allocation measurements |
| [internal/reports/compiler-data-reservation-2026-09-16.md](internal/reports/compiler-data-reservation-2026-09-16.md) | Wasm data buffer reservation: paired microbenchmarks and cold/warm compiler timings |
| [internal/reports/compiler-data-reservation-2026-09-16.json](internal/reports/compiler-data-reservation-2026-09-16.json) | Raw samples and artifact provenance for the data buffer reservation measurements |
| [internal/reports/compiler-file-split-memory-2026-10-01.md](internal/reports/compiler-file-split-memory-2026-10-01.md) | Source-split allocation attribution, local fixes and measured optimization follow-ups |
| [internal/reports/dependency-interface-views-2026-10-01.md](internal/reports/dependency-interface-views-2026-10-01.md) | Immutable dependency-view ownership, cache parity and controlled allocation measurements |
| [internal/reports/effect-name-membership-2026-10-02.md](internal/reports/effect-name-membership-2026-10-02.md) | Effect name indexes, shared AST traversal storage and controlled CPU/allocation comparisons |
| [internal/reports/user-function-index-2026-10-02.md](internal/reports/user-function-index-2026-10-02.md) | User-prefix lookup through the existing sorted table, backend invariants and controlled compiler measurements |
| [internal/reports/native-wasm-cache-2026-10-02.md](internal/reports/native-wasm-cache-2026-10-02.md) | Repeated native compilation in validation, code-cache measurements and runner regressions |
| [internal/reports/batched-source-embedding-2026-10-02.md](internal/reports/batched-source-embedding-2026-10-02.md) | Source embedding process overhead, byte-identical products and paired cold/warm generation measurements |
| [internal/reports/checker-environment-snapshots-2026-10-02.md](internal/reports/checker-environment-snapshots-2026-10-02.md) | Full compiler name-lookup bottleneck, canonical snapshots, allocation tradeoff and paired cold/warm validation |
| [internal/reports/effect-callable-body-index-2026-10-02.md](internal/reports/effect-callable-body-index-2026-10-02.md) | Effect callable-body scans, ambiguity-preserving name index, entry resets and controlled CPU/allocation comparisons |
| [internal/reports/async-effect-environment-index-2026-10-02.md](internal/reports/async-effect-environment-index-2026-10-02.md) | Async-effect environment lookup hotspot, entry-local canonical snapshot and paired CPU/allocation comparisons |
| [internal/reports/formal-substitution-index-2026-10-02.md](internal/reports/formal-substitution-index-2026-10-02.md) | Completed substitution read indexes for formal publication, lookup preservation and paired CPU/allocation comparisons |
| [internal/reports/parser-simd-scan-2026-08-15.md](internal/reports/parser-simd-scan-2026-08-15.md) | |
| [internal/reports/perf-snapshot-2026-08-07.md](internal/reports/perf-snapshot-2026-08-07.md) | |
| [internal/reports/pl-survey-2026-07.md](internal/reports/pl-survey-2026-07.md) | |
| [internal/reports/resolved-array-callees-2026-10-02.md](internal/reports/resolved-array-callees-2026-10-02.md) | Array mutation/capacity operation identities, backend parity and source-controlled allocation measurements |
| [internal/reports/resolved-mutlist-callees-2026-10-01.md](internal/reports/resolved-mutlist-callees-2026-10-01.md) | MutList operation identities, transport, shadow regression and controlled compiler measurements |
| [internal/reports/code-size-linear-vs-gc.md](internal/reports/code-size-linear-vs-gc.md) | Measured 2026-08-15/16 |

### Research / other languages

Not normative. Surveys of other languages and the proposals drawn from them.

| Path | Notes |
| --- | --- |
| [research/other-languages/](research/other-languages/) | Bend, Vx, Mojo, MoonBit verification (mizchi/veri); proposal for second-class borrow modes and a `v128` kernel subset. Index: [README.md](research/other-languages/README.md) |

## 3. Generated

Machine-produced. Do not edit by hand. Generator / freshness is noted where known.

| Path | Notes |
| --- | --- |
| [generated/feature-matrix.json](generated/feature-matrix.json) | Fetched by `scripts/wasm_feature_matrix_fetch.sh` |
| [generated/feature-levels.expected.json](generated/feature-levels.expected.json) | Oracle for feature-level checks |
| [generated/host-runtime-contract.json](generated/host-runtime-contract.json) | Machine-checked companion of [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |

## Inventory coverage

Answered by `scripts/check_doc_classification.sh`, not by a list kept here. A
list of names copied from `ls docs/` is a **proxy** for "every document is
classified", and it drifted within three weeks of being written: two documents
were in no class table, one archived file was missing from the archive table,
and `docs/internal/` had been created while the text above said it did not
exist. The gate walks the tree instead, so this section cannot go stale.

A class table's rows sit under the directory the class names; a new document
goes into that directory and gets its row in the same change.
