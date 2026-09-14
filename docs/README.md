# docs/

Audience index for [#2002](https://github.com/mizchi/vibe-lang/issues/2002).
Paths are **current locations**. This file does not move anything; later PRs use
it as the inventory.

**Every document under `docs/` must appear in exactly one class table below**,
and `scripts/check_doc_classification.sh` (`pkf run check-doc-classification`)
enforces it: a new document in no table fails, a document in two tables fails,
and a row pointing at a file that is no longer there fails. Add the row in the
same change as the document.

`docs/language-tour/` is not in the tree. Its content was folded into
[user/reference/cheatsheet.md](user/reference/cheatsheet.md).

`docs/user/` (#2565) and `docs/internal/` (#2566, group by group) are real: a
row whose `Current path` already starts with `user/` or `internal/` sits at the
home its `Later home` column names. For the rows that do not yet, that column is
still a **destination label, not a path that exists yet**; a document goes where
the tree puts things today, and each group moves in one pass so the link
rewrites can be reviewed together.

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

| Current path | Later home | Notes |
| --- | --- | --- |
| [user/getting-started/install.md](user/getting-started/install.md) | `user/getting-started/` | |
| [../book/](../book/README.md) | stays at `../book/` | The Vibe Book. Canonical tour + language + systems. Children: [SUMMARY.md](../book/SUMMARY.md), [src/](../book/en/), [ja/](../book/ja/) |
| [user/tutorial/](user/tutorial/) | `user/tutorial/` | Pointer only. Chapters moved to `book/en/` and `book/ja/`. |
| [user/reference/cheatsheet.md](user/reference/cheatsheet.md) | `user/reference/` | Language reference. Absorbed `language-tour/`. |
| [user/reference/cli-commands.md](user/reference/cli-commands.md) | `user/reference/` | |
| [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) | `user/reference/` | LSP, DAP, editor query CLI |
| [user/reference/source-range-contract.md](user/reference/source-range-contract.md) | `user/reference/` | What a reported position MEANS (byte, ADR-0108). Written because [user/reference/editor-and-debugging.md](user/reference/editor-and-debugging.md) called byte offsets "char offsets"; enforced by `scripts/check_source_range_contract.sh` |
| [user/guide/when-to-use-effects.md](user/guide/when-to-use-effects.md) | `user/guide/` | Was `guide/`; the sibling `builtin-effect-migration.md` stays internal |
| [user/reference/vibe.md](user/reference/vibe.md) | `user/reference/` | Implemented language design outside pure syntax |
| [user/reference/syntax.md](user/reference/syntax.md) | `user/reference/` | Canonical implemented surface syntax. Was `spec/`; the rest of `spec/` is internal |
| [user/reference/stable-surface.md](user/reference/stable-surface.md) | `user/reference/` | Stable surface / SemVer. Takes effect at the `0.1.0` tag (ADR-0109) |
| [user/reference/host-abi.md](user/reference/host-abi.md) | `user/reference/` | Host ABI of generated wasm |
| [user/reference/http_server_contract.md](user/reference/http_server_contract.md) | `user/reference/` | Public `Http::*` contract |
| [user/reference/feature-levels.md](user/reference/feature-levels.md) | `user/reference/` | Generated-wasm feature levels. Was `wasm/` |
| [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) | `user/reference/` | Host execution contract (not [internal/design/host-runtime-contract.md](internal/design/host-runtime-contract.md)) |
| [user/getting-started/release-notes-0.1.0.md](user/getting-started/release-notes-0.1.0.md) | `user/getting-started/` | |

## 2. Maintainer / internal

Compiler contributors, release operators, CI, repository agents. Public in
the repo; not the user manual.

### Project

| Current path | Later home | Notes |
| --- | --- | --- |
| [internal/project/adding-modules.md](internal/project/adding-modules.md) | `internal/project/` | How to add/fix a library module in this repo |
| [internal/project/issue-triage.md](internal/project/issue-triage.md) | `internal/project/` | |
| [internal/project/release-roadmap.md](internal/project/release-roadmap.md) | `internal/project/` | |

### Operations / gates / bootstrap

| Current path | Later home | Notes |
| --- | --- | --- |
| [internal/operations/bootstrap.md](internal/operations/bootstrap.md) | `internal/operations/` | |
| [internal/operations/operation-gate.md](internal/operations/operation-gate.md) | `internal/operations/` | |
| [internal/operations/build-cache.md](internal/operations/build-cache.md) | `internal/operations/` | |
| [internal/operations/incremental-build.md](internal/operations/incremental-build.md) | `internal/operations/` | Design + measurement; not a user how-to |
| [internal/operations/ci-speed.md](internal/operations/ci-speed.md) | `internal/operations/` | |
| [internal/operations/coverage.md](internal/operations/coverage.md) | `internal/operations/` | Compiler coverage strategy |
| [internal/operations/selfcompile-heap-policy.md](internal/operations/selfcompile-heap-policy.md) | `internal/operations/` | |
| [internal/operations/pkfire-pkspec.md](internal/operations/pkfire-pkspec.md) | `internal/operations/` | |
| [internal/operations/BENCHMARKS.md](internal/operations/BENCHMARKS.md) | `internal/operations/` | Continuously-runnable regression signals |
| [internal/operations/wasm-opt-dogfood.md](internal/operations/wasm-opt-dogfood.md) | `internal/operations/` | |

### Design (ADR index + reviews + contracts)

| Current path | Later home | Notes |
| --- | --- | --- |
| [internal/design/adr.md](internal/design/adr.md) | `internal/design/` | Living ADR log |
| [internal/design/capability-authorization-surface.md](internal/design/capability-authorization-surface.md) | `internal/design/` | ADR-0088, proposed |
| [internal/design/compiler-parallelism.md](internal/design/compiler-parallelism.md) | `internal/design/` | ADR-0068 companion, proposed |
| [internal/design/concurrency.md](internal/design/concurrency.md) | `internal/design/` | ADR-0068, proposed. Not the user concurrency guide |
| [internal/design/effect-evidence-passing.md](internal/design/effect-evidence-passing.md) | `internal/design/` | ADR-0076, proposed |
| [internal/design/effect-taxonomy-entry-policy.md](internal/design/effect-taxonomy-entry-policy.md) | `internal/design/` | ADR-0084, proposed |
| [internal/design/effect-taxonomy-review.md](internal/design/effect-taxonomy-review.md) | `internal/design/` | Review, not the user effect tutorial |
| [internal/design/effect-wit-mapping.md](internal/design/effect-wit-mapping.md) | `internal/design/` | Compiler `--wit` mapping |
| [internal/design/effectset.md](internal/design/effectset.md) | `internal/design/` | ADR-0071, proposed |
| [internal/design/error-effect-policy.md](internal/design/error-effect-policy.md) | `internal/design/` | ADR-0073 |
| [internal/design/exception-effect.md](internal/design/exception-effect.md) | `internal/design/` | ADR-0085. User surface is the cheatsheet |
| [internal/design/host-runtime-contract.md](internal/design/host-runtime-contract.md) | `internal/design/` | ADR-0086 compiler-host contract |
| [internal/design/module-system-oracle.md](internal/design/module-system-oracle.md) | `internal/design/` | Executable ADR-0070 oracle |
| [internal/design/module-system-v2.md](internal/design/module-system-v2.md) | `internal/design/` | |
| [internal/design/perceus-reuse.md](internal/design/perceus-reuse.md) | `internal/design/` | ADR-0092, proposed |
| [internal/design/region-mutable-state.md](internal/design/region-mutable-state.md) | `internal/design/` | ADR-0090, current region storage and RC integration requirements |
| [internal/design/compiler-memory-experiments.md](internal/design/compiler-memory-experiments.md) | `internal/design/` | Measured memory experiments and adoption criteria |
| [internal/design/compiler-memory-baseline.json](internal/design/compiler-memory-baseline.json) | `internal/design/` | Raw compiler comparison and region/GC observations |
| [internal/design/compiler-retain-scratch.json](internal/design/compiler-retain-scratch.json) | `internal/design/` | Borrow inference and scratch measurements, controls and raw samples |
| [internal/design/compiler-free-var-scratch.json](internal/design/compiler-free-var-scratch.json) | `internal/design/` | Free-variable scope scratch comparison, controls and raw samples |
| [internal/design/compiler-free-var-callee.json](internal/design/compiler-free-var-callee.json) | `internal/design/` | Direct callee scan comparison, controls and raw samples |
| [internal/design/compiler-annotated-lambda-inference.json](internal/design/compiler-annotated-lambda-inference.json) | `internal/design/` | Annotated local lambda inference comparison, controls and raw samples |
| [internal/design/compiler-free-var-binding-lookup.json](internal/design/compiler-free-var-binding-lookup.json) | `internal/design/` | Callee binding lookup comparison, controls, fuel probe and raw samples |
| [internal/design/compiler-borrow-worklist.json](internal/design/compiler-borrow-worklist.json) | `internal/design/` | Fixed-point borrow inference comparisons, controls, retain counts and validation |
| [internal/design/compiler-bytes-effects.json](internal/design/compiler-bytes-effects.json) | `internal/design/` | Byte-range copying and effect reachability measurements, controls and validation |
| [internal/design/compiler-cache-capacity.json](internal/design/compiler-cache-capacity.json) | `internal/design/` | Pruned body-cache reuse, reserved byte-buffer measurements, controls and validation |
| [internal/design/compiler-callback-return.json](internal/design/compiler-callback-return.json) | `internal/design/` | Callback return ownership measurements, parser and cold/warm selfhost comparisons, controls and validation |
| [internal/design/compiler-module-cache.json](internal/design/compiler-module-cache.json) | `internal/design/` | Unified typing/lowering cache: cold/warm selfhost timings, allocator high-water, and filesystem operation counts |
| [internal/design/compiler-dce-symbols.json](internal/design/compiler-dce-symbols.json) | `internal/design/` | DCE spelling-ID experiment: cold/warm selfhost comparisons, allocation bounds, and CPU profiles |
| [internal/design/compiler-typeenv-symbols.json](internal/design/compiler-typeenv-symbols.json) | `internal/design/` | Immutable TypeEnv name indexes: cold/warm selfhost comparisons, CPU profiles, and transport compatibility |
| [internal/design/compiler-single-rebind.json](internal/design/compiler-single-rebind.json) | `internal/design/` | Reassignment lifetime and generated-name collision fixes, leak bounds, and cold/warm selfhost comparisons |
| [internal/design/registry-design.md](internal/design/registry-design.md) | `internal/design/` | ADR-0065 Phase 5 |
| [internal/design/resource-kind-parameters.md](internal/design/resource-kind-parameters.md) | `internal/design/` | ADR-0094, proposed |
| [internal/design/simd-data-structures.md](internal/design/simd-data-structures.md) | `internal/design/` | Measured proposal: SIMD-first data-structure foundation |
| [internal/design/vibex-runtime-contract.md](internal/design/vibex-runtime-contract.md) | `internal/design/` | ADR-0075, proposed |
| [internal/design/wasip3-effect-alignment.md](internal/design/wasip3-effect-alignment.md) | `internal/design/` | ADR-0089, proposed |
| [internal/design/zero-alloc-check.md](internal/design/zero-alloc-check.md) | `internal/design/` | ADR-0091, current conservative allocation verification |
| [internal/design/builtin-effect-migration.md](internal/design/builtin-effect-migration.md) | `internal/design/` | Compiler/language migration plan |
| [internal/design/mutability-control-review.md](internal/design/mutability-control-review.md) | `internal/design/` | Survey / fitness review |
| [internal/design/side-effect-consolidation.md](internal/design/side-effect-consolidation.md) | `internal/design/` | |
| [internal/design/decisions.md](internal/design/decisions.md) | `internal/design/` | Locked language decisions |
| [internal/design/builtin-ssot-design.md](internal/design/builtin-ssot-design.md) | `internal/design/` | |
| [internal/design/memory-contract.md](internal/design/memory-contract.md) | `internal/design/` | Linear / wasm-gc / RC |
| [internal/design/profiling.md](internal/design/profiling.md) | `internal/design/` | |
| [internal/design/rc-cutover-readiness.md](internal/design/rc-cutover-readiness.md) | `internal/design/` | ADR-0055 status |
| [internal/design/rc-port.md](internal/design/rc-port.md) | `internal/design/` | ADR-0055 design record |
| [internal/design/show-trait-design.md](internal/design/show-trait-design.md) | `internal/design/` | |
| [internal/design/simd-api-design.md](internal/design/simd-api-design.md) | `internal/design/` | |
| [internal/design/structured-shell-design.md](internal/design/structured-shell-design.md) | `internal/design/` | |
| [internal/design/test-example-capabilities.md](internal/design/test-example-capabilities.md) | `internal/design/` | Proposal, partial |
| [internal/design/uniform-value-repr.md](internal/design/uniform-value-repr.md) | `internal/design/` | ADR-0055 |
| [internal/design/wasi-p3-async.md](internal/design/wasi-p3-async.md) | `internal/design/` | |

### Compiler

| Current path | Later home | Notes |
| --- | --- | --- |
| [ast_binary_abi.md](ast_binary_abi.md) | `internal/compiler/` | |
| [checked-body-transport.md](checked-body-transport.md) | `internal/compiler/` | Checked-implementation-body artifact + normalized typed-IR codec. Its "shadow-only" framing is superseded: #2505 promotes this lane, and the #1958 it cites is closed |
| [checked-direct-expression-return-observation.md](checked-direct-expression-return-observation.md) | `internal/compiler/` | Checker observation note |
| [tracing-design.md](tracing-design.md) | `internal/compiler/` | Proposed internal spans |
| [internal/design/experimental-wasmfx-effect-backend.md](internal/design/experimental-wasmfx-effect-backend.md) | `internal/design/` | WasmFX feasibility probe. Tracked by #2221 |
| [internal/design/experimental-wasmtime-guest-profiler.md](internal/design/experimental-wasmtime-guest-profiler.md) | `internal/design/` | Guest-profiler integration. Tracked by #2207 |
| [vibec-component.md](vibec-component.md) | `internal/compiler/` | Compiler-core component split |
| [wasm/gc-value-abi.md](wasm/gc-value-abi.md) | `internal/compiler/` | wasm-gc value ABI |
| [wasm_threads_requirements.md](wasm_threads_requirements.md) | `internal/compiler/` | |
| [wit/](wit/) | `internal/compiler/` | [vibe-compiler-host.wit](wit/vibe-compiler-host.wit) |

### Reports / dated snapshots

Not normative.

| Current path | Later home | Notes |
| --- | --- | --- |
| [report/](report/) | `internal/reports/` | [blake3-vs-sha1-bench-2026-08-01.md](report/blake3-vs-sha1-bench-2026-08-01.md), [parser-simd-scan-2026-08-15.md](report/parser-simd-scan-2026-08-15.md) |
| [perf-snapshot-2026-08-07.md](perf-snapshot-2026-08-07.md) | `internal/reports/` | |
| [pl-survey-2026-07.md](pl-survey-2026-07.md) | `internal/reports/` | |
| [wasm/code-size-linear-vs-gc.md](wasm/code-size-linear-vs-gc.md) | `internal/reports/` | Measured 2026-08-15/16 |

## 3. Generated

Machine-produced. Do not edit by hand. Generator / freshness is noted where known.

| Current path | Later home | Notes |
| --- | --- | --- |
| [wasm/feature-matrix.json](wasm/feature-matrix.json) | `generated/` | Fetched by `scripts/wasm_feature_matrix_fetch.sh` |
| [wasm/feature-levels.expected.json](wasm/feature-levels.expected.json) | `generated/` | Oracle for feature-level checks |
| [wasm/host-runtime-contract.json](wasm/host-runtime-contract.json) | `generated/` | Machine-checked companion of [user/reference/host-runtime-contract.md](user/reference/host-runtime-contract.md) |

## 4. Archive

[archive/](archive/) only. Git history is the default archive; keep a file here
only while it is still cited.

| Current path | Notes |
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

Directories that were mixed before #2565, children classified above:

- `guide/` — internal `builtin-effect-migration.md` (`when-to-use-effects.md` is under `user/guide/`)
- `spec/` — internal only (`syntax.md`, `stable-surface.md`, `host-abi.md` are under `user/reference/`)
- `wasm/` — generated `*.json`; internal `gc-value-abi.md`, `code-size-linear-vs-gc.md` (`feature-levels.md`, `host-runtime-contract.md` are under `user/reference/`)
