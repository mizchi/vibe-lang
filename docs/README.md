# docs/

Audience index for [#2002](https://github.com/mizchi/vibe-lang/issues/2002).
Paths are relative to this file. The tree is laid out by primary reader:
`user/`, `internal/`, `generated/`, `archive/` (#2565, #2566).

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
[user/tutorial/README.md](user/tutorial/README.md) ·
[user/reference/cheatsheet.md](user/reference/cheatsheet.md) · [user/reference/cli-commands.md](user/reference/cli-commands.md) ·
[user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md)

**Maintainers:** [internal/project/adding-modules.md](internal/project/adding-modules.md) · [internal/operations/bootstrap.md](internal/operations/bootstrap.md) ·
[internal/operations/operation-gate.md](internal/operations/operation-gate.md) · [internal/design/adr.md](internal/design/adr.md) ·
[internal/project/issue-triage.md](internal/project/issue-triage.md)

This file is the audience router. It is not one of the four classes below.

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
| [user/tutorial/](user/tutorial/) | Pointer only. Chapters moved to `book/en/` and `book/ja/`. |
| [user/reference/cheatsheet.md](user/reference/cheatsheet.md) | Language reference. Absorbed `language-tour/`. |
| [user/reference/cli-commands.md](user/reference/cli-commands.md) | |
| [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) | LSP, DAP, editor query CLI |
| [user/reference/source-range-contract.md](user/reference/source-range-contract.md) | What a reported position MEANS (byte, ADR-0108). Written because [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) called byte offsets "char offsets"; enforced by `scripts/check_source_range_contract.sh` |
| [user/guide/when-to-use-effects.md](user/guide/when-to-use-effects.md) | Its former sibling `builtin-effect-migration.md` is internal ([internal/design/](internal/design/builtin-effect-migration.md)) |
| [user/reference/vibe.md](user/reference/vibe.md) | Implemented language design outside pure syntax |
| [user/reference/syntax.md](user/reference/syntax.md) | Canonical implemented surface syntax |
| [user/reference/stable-surface.md](user/reference/stable-surface.md) | Stable surface / SemVer. Takes effect at the `0.1.0` tag (ADR-0109) |
| [user/reference/host-abi.md](user/reference/host-abi.md) | Host ABI of generated wasm |
| [user/reference/http_server_contract.md](user/reference/http_server_contract.md) | Public `Http::*` contract |
| [user/reference/feature-levels.md](user/reference/feature-levels.md) | Generated-wasm feature levels |
| [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) | The `vibe.*` core imports a generated program needs from its runner. The compiler's own host boundary is [internal/design/compiler-host-boundary.md](internal/design/compiler-host-boundary.md) |
| [user/getting-started/release-notes-0.1.0.md](user/getting-started/release-notes-0.1.0.md) | |

## 2. Maintainer / internal

Compiler contributors, release operators, CI, repository agents. Public in
the repo; not the user manual.

### Project

| Path | Notes |
| --- | --- |
| [internal/project/adding-modules.md](internal/project/adding-modules.md) | How to add/fix a library module in this repo |
| [internal/project/issue-triage.md](internal/project/issue-triage.md) | |
| [internal/project/release-roadmap.md](internal/project/release-roadmap.md) | |

### Operations / gates / bootstrap

| Path | Notes |
| --- | --- |
| [internal/operations/bootstrap.md](internal/operations/bootstrap.md) | |
| [internal/operations/operation-gate.md](internal/operations/operation-gate.md) | |
| [internal/operations/build-cache.md](internal/operations/build-cache.md) | |
| [internal/operations/incremental-build.md](internal/operations/incremental-build.md) | Design + measurement; not a user how-to |
| [internal/operations/ci-speed.md](internal/operations/ci-speed.md) | |
| [internal/operations/coverage.md](internal/operations/coverage.md) | Compiler coverage strategy |
| [internal/operations/selfcompile-heap-policy.md](internal/operations/selfcompile-heap-policy.md) | |
| [internal/operations/pkfire-pkspec.md](internal/operations/pkfire-pkspec.md) | |
| [internal/operations/BENCHMARKS.md](internal/operations/BENCHMARKS.md) | Continuously-runnable regression signals |
| [internal/operations/wasm-opt-dogfood.md](internal/operations/wasm-opt-dogfood.md) | |

### Design (ADR index + reviews + contracts)

| Path | Notes |
| --- | --- |
| [internal/design/adr.md](internal/design/adr.md) | Living ADR log |
| [internal/design/capability-authorization-surface.md](internal/design/capability-authorization-surface.md) | ADR-0088, proposed |
| [internal/design/compiler-parallelism.md](internal/design/compiler-parallelism.md) | ADR-0068 companion, proposed |
| [internal/design/concurrency.md](internal/design/concurrency.md) | ADR-0068, proposed. The user concurrency guide is the book's [17_concurrency](../book/en/17_concurrency.vibe.md) |
| [internal/design/effect-evidence-passing.md](internal/design/effect-evidence-passing.md) | ADR-0076, proposed |
| [internal/design/effect-taxonomy-entry-policy.md](internal/design/effect-taxonomy-entry-policy.md) | ADR-0084, proposed |
| [internal/design/effect-taxonomy-review.md](internal/design/effect-taxonomy-review.md) | Review, not the user effect tutorial |
| [internal/design/effect-wit-mapping.md](internal/design/effect-wit-mapping.md) | Compiler `--wit` mapping |
| [internal/design/effectset.md](internal/design/effectset.md) | ADR-0071, proposed |
| [internal/design/error-effect-policy.md](internal/design/error-effect-policy.md) | ADR-0073 |
| [internal/design/exception-effect.md](internal/design/exception-effect.md) | ADR-0085. User surface is the cheatsheet |
| [internal/design/compiler-host-boundary.md](internal/design/compiler-host-boundary.md) | ADR-0086: what a runner must provide for the compiler's own `cli_main`. Not the generated-program contract, which is [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |
| [internal/design/module-system-oracle.md](internal/design/module-system-oracle.md) | Executable ADR-0070 oracle |
| [internal/design/module-system-v2.md](internal/design/module-system-v2.md) | |
| [internal/design/perceus-reuse.md](internal/design/perceus-reuse.md) | ADR-0092, proposed |
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
| [internal/design/resource-kind-parameters.md](internal/design/resource-kind-parameters.md) | ADR-0094, proposed |
| [internal/design/simd-data-structures.md](internal/design/simd-data-structures.md) | Measured proposal: SIMD-first data-structure foundation |
| [internal/design/vibex-runtime-contract.md](internal/design/vibex-runtime-contract.md) | ADR-0075, proposed |
| [internal/design/wasip3-effect-alignment.md](internal/design/wasip3-effect-alignment.md) | ADR-0089, proposed |
| [internal/design/zero-alloc-check.md](internal/design/zero-alloc-check.md) | ADR-0091, current conservative allocation verification |
| [internal/design/builtin-effect-migration.md](internal/design/builtin-effect-migration.md) | Compiler/language migration plan |
| [internal/design/mutability-control-review.md](internal/design/mutability-control-review.md) | Survey / fitness review |
| [internal/design/side-effect-consolidation.md](internal/design/side-effect-consolidation.md) | |
| [internal/design/decisions.md](internal/design/decisions.md) | Locked language decisions |
| [internal/design/builtin-ssot-design.md](internal/design/builtin-ssot-design.md) | |
| [internal/design/memory-contract.md](internal/design/memory-contract.md) | Linear / wasm-gc / RC |
| [internal/design/profiling.md](internal/design/profiling.md) | |
| [internal/design/rc-cutover-readiness.md](internal/design/rc-cutover-readiness.md) | ADR-0055 status |
| [internal/design/rc-port.md](internal/design/rc-port.md) | ADR-0055 design record |
| [internal/design/show-trait-design.md](internal/design/show-trait-design.md) | |
| [internal/design/simd-api-design.md](internal/design/simd-api-design.md) | |
| [internal/design/structured-shell-design.md](internal/design/structured-shell-design.md) | |
| [internal/design/test-example-capabilities.md](internal/design/test-example-capabilities.md) | Proposal, partial |
| [internal/design/uniform-value-repr.md](internal/design/uniform-value-repr.md) | ADR-0055 |
| [internal/design/wasi-p3-async.md](internal/design/wasi-p3-async.md) | |

### Compiler

| Path | Notes |
| --- | --- |
| [internal/compiler/ast_binary_abi.md](internal/compiler/ast_binary_abi.md) | |
| [internal/compiler/checked-body-transport.md](internal/compiler/checked-body-transport.md) | Checked-implementation-body artifact + normalized typed-IR codec. Its "shadow-only" framing is superseded: #2505 promotes this lane, and the #1958 it cites is closed |
| [internal/compiler/checked-direct-expression-return-observation.md](internal/compiler/checked-direct-expression-return-observation.md) | Checker observation note |
| [internal/compiler/tracing-design.md](internal/compiler/tracing-design.md) | Proposed internal spans |
| [internal/design/experimental-wasmfx-effect-backend.md](internal/design/experimental-wasmfx-effect-backend.md) | WasmFX feasibility probe. Tracked by #2221 |
| [internal/design/experimental-wasmtime-guest-profiler.md](internal/design/experimental-wasmtime-guest-profiler.md) | Guest-profiler integration. Tracked by #2207 |
| [internal/compiler/vibec-component.md](internal/compiler/vibec-component.md) | Compiler-core component split |
| [internal/compiler/gc-value-abi.md](internal/compiler/gc-value-abi.md) | wasm-gc value ABI |
| [internal/compiler/wasm_threads_requirements.md](internal/compiler/wasm_threads_requirements.md) | |
| [internal/compiler/wit/](internal/compiler/wit/) | [vibe-compiler-host.wit](internal/compiler/wit/vibe-compiler-host.wit) |

### Reports / dated snapshots

Not normative.

| Path | Notes |
| --- | --- |
| [internal/reports/blake3-vs-sha1-bench-2026-08-01.md](internal/reports/blake3-vs-sha1-bench-2026-08-01.md) | |
| [internal/reports/cloudflare-workers-fit-2026-09-04.md](internal/reports/cloudflare-workers-fit-2026-09-04.md) | |
| [internal/reports/parser-simd-scan-2026-08-15.md](internal/reports/parser-simd-scan-2026-08-15.md) | |
| [internal/reports/perf-snapshot-2026-08-07.md](internal/reports/perf-snapshot-2026-08-07.md) | |
| [internal/reports/pl-survey-2026-07.md](internal/reports/pl-survey-2026-07.md) | |
| [internal/reports/code-size-linear-vs-gc.md](internal/reports/code-size-linear-vs-gc.md) | Measured 2026-08-15/16 |

## 3. Generated

Machine-produced. Do not edit by hand. Generator / freshness is noted where known.

| Path | Notes |
| --- | --- |
| [generated/feature-matrix.json](generated/feature-matrix.json) | Fetched by `scripts/wasm_feature_matrix_fetch.sh` |
| [generated/feature-levels.expected.json](generated/feature-levels.expected.json) | Oracle for feature-level checks |
| [generated/host-runtime-contract.json](generated/host-runtime-contract.json) | Machine-checked companion of [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |

## 4. Archive

[archive/](archive/) only. Git history is the default archive; keep a file here
only while it is still cited.

| Path | Notes |
| --- | --- |
| [archive/adr/](archive/adr/) | Historical individual ADRs; living log is [internal/design/adr.md](internal/design/adr.md) |
| [archive/advanced-graph.md](archive/advanced-graph.md) | |
| [archive/bench_advanced_graph_report.md](archive/bench_advanced_graph_report.md) | |
| [archive/build-optimization-analysis.md](archive/build-optimization-analysis.md) | |
| [archive/codegen/](archive/codegen/) | [vibe-output-analysis.md](archive/codegen/vibe-output-analysis.md), [wasm-gc-vs-selfhost-analysis.md](archive/codegen/wasm-gc-vs-selfhost-analysis.md) |
| [archive/compiler_language_incidents.md](archive/compiler_language_incidents.md) | Cited from [user/reference/vibe.md](user/reference/vibe.md) |
| [archive/moonbit-retirement.md](archive/moonbit-retirement.md) | Cited recovery record (`moonbit-host-final-2026-06-23`) |
| [archive/mut-effect-plan.md](archive/mut-effect-plan.md) | |
| [archive/report/](archive/report/) | Dated evaluations |
| [archive/release-notes-0.3.0.md](archive/release-notes-0.3.0.md) | A release that was never cut (renumbered by ADR-0109). Kept as the record of 2026-06 to 2026-07-17; carries a status banner, so a delete candidate by the AGENTS.md rule |
| [archive/review-by-x-markdown.md](archive/review-by-x-markdown.md) | |
| [archive/spec/](archive/spec/) | Retired spec notes |
| [archive/wasmtime-v43.md](archive/wasmtime-v43.md) | |

## Inventory coverage

Answered by `scripts/check_doc_classification.sh`, not by a list kept here. A
list of names copied from `ls docs/` is a **proxy** for "every document is
classified", and it drifted within three weeks of being written: two documents
were in no class table, one archived file was missing from the archive table,
and `docs/internal/` had been created while the text above said it did not
exist. The gate walks the tree instead, so this section cannot go stale.

A class table's rows sit under the directory the class names; a new document
goes into that directory and gets its row in the same change.
