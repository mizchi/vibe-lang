# docs/

Audience index for [#2002](https://github.com/mizchi/vibe-lang/issues/2002).
Paths are **current locations** at `7e3ca3ebc`. This file does not move anything;
later PRs use it as the inventory.

`docs/language-tour/` is not in the tree. Its content was folded into
[cheatsheet.md](cheatsheet.md).

Proposed later homes (`docs/user/…`, `docs/internal/…`, `docs/generated/`) are
labels from #2002, not directories in this commit.

**Users:** [install](install.md) · [The Vibe Book](../book/README.md) ·
[tutorial (pointer)](tutorial/README.md) ·
[cheatsheet](cheatsheet.md) · [CLI](cli-commands.md) ·
[editor](editor-and-debugging.md)

**Maintainers:** [adding modules](adding-modules.md) · [bootstrap](bootstrap.md) ·
[operation gate](operation-gate.md) · [ADRs](adr.md) ·
[triage](issue-triage.md)

This file is the audience router. It is not one of the four classes below.

Classification is by primary reader (#2002). A public wasm/effect/package
contract stays user-facing even if maintainers also read it. An ADR, design
review, gate, or dated report stays internal even when it explains a public
feature.

## 1. User documentation

Install, learn, write, build, test, package, debug, deploy.

| Current path | Later home | Notes |
| --- | --- | --- |
| [install.md](install.md) | `user/getting-started/` | |
| [../book/](../book/README.md) | `user/book/` | The Vibe Book. Canonical tour + language + systems. Children: [SUMMARY.md](../book/SUMMARY.md), [src/](../book/src/), [ja/](../book/ja/) |
| [tutorial/](tutorial/) | `user/tutorial/` | Pointer only. Chapters moved to `book/src/` and `book/ja/`. |
| [cheatsheet.md](cheatsheet.md) | `user/reference/` | Language reference. Absorbed `language-tour/`. |
| [cli-commands.md](cli-commands.md) | `user/reference/` | |
| [editor-and-debugging.md](editor-and-debugging.md) | `user/reference/` | LSP, DAP, editor query CLI |
| [guide/when-to-use-effects.md](guide/when-to-use-effects.md) | `user/guide/` | `guide/` is mixed; sibling is internal |
| [vibe.md](vibe.md) | `user/reference/` | Implemented language design outside pure syntax |
| [spec/syntax.md](spec/syntax.md) | `user/reference/` | Canonical implemented surface syntax. `spec/` is mixed |
| [spec/stable-surface.md](spec/stable-surface.md) | `user/reference/` | Stable surface / SemVer. Takes effect at the `0.1.0` tag (ADR-0109) |
| [spec/host-abi.md](spec/host-abi.md) | `user/reference/` | Host ABI of generated wasm |
| [http_server_contract.md](http_server_contract.md) | `user/reference/` | Public `Http::*` contract |
| [wasm/feature-levels.md](wasm/feature-levels.md) | `user/reference/` | Generated-wasm feature levels. `wasm/` is mixed |
| [wasm/host-runtime-contract.md](wasm/host-runtime-contract.md) | `user/reference/` | Host execution contract (not [host-runtime-contract.md](host-runtime-contract.md)) |
| [release-notes-0.1.0.md](release-notes-0.1.0.md) | `user/getting-started/` | |

## 2. Maintainer / internal

Compiler contributors, release operators, CI, repository agents. Public in
the repo; not the user manual.

### Project

| Current path | Later home | Notes |
| --- | --- | --- |
| [adding-modules.md](adding-modules.md) | `internal/project/` | How to add/fix a library module in this repo |
| [issue-triage.md](issue-triage.md) | `internal/project/` | |
| [release-roadmap.md](release-roadmap.md) | `internal/project/` | |
| [known-issues.md](known-issues.md) | `internal/project/` | Resolved CI seed-fallback postmortem. Delete candidate |

### Operations / gates / bootstrap

| Current path | Later home | Notes |
| --- | --- | --- |
| [bootstrap.md](bootstrap.md) | `internal/operations/` | |
| [operation-gate.md](operation-gate.md) | `internal/operations/` | |
| [build-cache.md](build-cache.md) | `internal/operations/` | |
| [incremental-build.md](incremental-build.md) | `internal/operations/` | Design + measurement; not a user how-to |
| [ci-speed.md](ci-speed.md) | `internal/operations/` | |
| [coverage.md](coverage.md) | `internal/operations/` | Compiler coverage strategy |
| [selfcompile-heap-policy.md](selfcompile-heap-policy.md) | `internal/operations/` | |
| [pkfire-pkspec.md](pkfire-pkspec.md) | `internal/operations/` | |
| [BENCHMARKS.md](BENCHMARKS.md) | `internal/operations/` | Continuously-runnable regression signals |
| [wasm-opt-dogfood.md](wasm-opt-dogfood.md) | `internal/operations/` | |

### Design (ADR index + reviews + contracts)

| Current path | Later home | Notes |
| --- | --- | --- |
| [adr.md](adr.md) | `internal/design/` | Living ADR log |
| [capability-authorization-surface.md](capability-authorization-surface.md) | `internal/design/` | ADR-0088, proposed |
| [compiler-parallelism.md](compiler-parallelism.md) | `internal/design/` | ADR-0068 companion, proposed |
| [concurrency.md](concurrency.md) | `internal/design/` | ADR-0068, proposed. Not the user concurrency guide |
| [effect-evidence-passing.md](effect-evidence-passing.md) | `internal/design/` | ADR-0076, proposed |
| [effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md) | `internal/design/` | ADR-0084, proposed |
| [effect-taxonomy-review.md](effect-taxonomy-review.md) | `internal/design/` | Review, not the user effect tutorial |
| [effect-wit-mapping.md](effect-wit-mapping.md) | `internal/design/` | Compiler `--wit` mapping |
| [effectset.md](effectset.md) | `internal/design/` | ADR-0071, proposed |
| [error-effect-policy.md](error-effect-policy.md) | `internal/design/` | ADR-0073 |
| [exception-effect.md](exception-effect.md) | `internal/design/` | ADR-0085. User surface is the cheatsheet |
| [host-runtime-contract.md](host-runtime-contract.md) | `internal/design/` | ADR-0086 compiler-host contract |
| [module-system-oracle.md](module-system-oracle.md) | `internal/design/` | Executable ADR-0070 oracle |
| [module-system-v2.md](module-system-v2.md) | `internal/design/` | |
| [naming-convention-migration.md](naming-convention-migration.md) | `internal/design/` | ADR-0083, proposed, Phase 0 not started |
| [perceus-reuse.md](perceus-reuse.md) | `internal/design/` | ADR-0092, proposed |
| [qualified-constructor-migration.md](qualified-constructor-migration.md) | `internal/design/` | ADR-0096 |
| [region-mutable-state.md](region-mutable-state.md) | `internal/design/` | ADR-0090, proposed |
| [registry-design.md](registry-design.md) | `internal/design/` | ADR-0065 Phase 5 |
| [resource-kind-parameters.md](resource-kind-parameters.md) | `internal/design/` | ADR-0094, proposed |
| [vibex-runtime-contract.md](vibex-runtime-contract.md) | `internal/design/` | ADR-0075, proposed |
| [wasip3-effect-alignment.md](wasip3-effect-alignment.md) | `internal/design/` | ADR-0089, proposed |
| [zero-alloc-check.md](zero-alloc-check.md) | `internal/design/` | ADR-0091, proposed |
| [guide/builtin-effect-migration.md](guide/builtin-effect-migration.md) | `internal/design/` | Compiler/language migration plan |
| [mutability-control-review.md](mutability-control-review.md) | `internal/design/` | Survey / fitness review |
| [side-effect-consolidation.md](side-effect-consolidation.md) | `internal/design/` | |
| [spec/decisions.md](spec/decisions.md) | `internal/design/` | Locked language decisions |
| [spec/builtin-ssot-design.md](spec/builtin-ssot-design.md) | `internal/design/` | |
| [spec/iterable-touch-points.md](spec/iterable-touch-points.md) | `internal/design/` | Maintainer checklist |
| [spec/memory-contract.md](spec/memory-contract.md) | `internal/design/` | Linear / wasm-gc / RC |
| [spec/profiling.md](spec/profiling.md) | `internal/design/` | |
| [spec/rc-cutover-readiness.md](spec/rc-cutover-readiness.md) | `internal/design/` | ADR-0055 status |
| [spec/rc-port.md](spec/rc-port.md) | `internal/design/` | ADR-0055 plan |
| [spec/show-trait-design.md](spec/show-trait-design.md) | `internal/design/` | |
| [spec/simd-api-design.md](spec/simd-api-design.md) | `internal/design/` | |
| [spec/structured-shell-design.md](spec/structured-shell-design.md) | `internal/design/` | |
| [spec/test-example-capabilities.md](spec/test-example-capabilities.md) | `internal/design/` | Proposal, partial |
| [spec/uniform-value-repr.md](spec/uniform-value-repr.md) | `internal/design/` | ADR-0055 |
| [spec/wasi-p3-async.md](spec/wasi-p3-async.md) | `internal/design/` | |

### Compiler

| Current path | Later home | Notes |
| --- | --- | --- |
| [ast_binary_abi.md](ast_binary_abi.md) | `internal/compiler/` | |
| [checked-direct-expression-return-observation.md](checked-direct-expression-return-observation.md) | `internal/compiler/` | Checker observation note |
| [tracing-design.md](tracing-design.md) | `internal/compiler/` | Proposed internal spans |
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
| [builtin_contract_table.generated.md](builtin_contract_table.generated.md) | `generated/` | `scripts/gen_builtin_contract_table.mjs` no longer exists (retired MoonBit host). Historical snapshot. Delete candidate once a live builtin table exists |
| [wasm/feature-matrix.json](wasm/feature-matrix.json) | `generated/` | Fetched by `scripts/wasm_feature_matrix_fetch.sh` |
| [wasm/feature-levels.expected.json](wasm/feature-levels.expected.json) | `generated/` | Oracle for feature-level checks |
| [wasm/host-runtime-contract.json](wasm/host-runtime-contract.json) | `generated/` | Machine-checked companion of [wasm/host-runtime-contract.md](wasm/host-runtime-contract.md) |

## 4. Archive

[archive/](archive/) only. Git history is the default archive; keep a file here
only while it is still cited.

| Current path | Notes |
| --- | --- |
| [archive/adr/](archive/adr/) | Historical individual ADRs; living log is [adr.md](adr.md) |
| [archive/advanced-graph.md](archive/advanced-graph.md) | |
| [archive/bench_advanced_graph_report.md](archive/bench_advanced_graph_report.md) | |
| [archive/build-optimization-analysis.md](archive/build-optimization-analysis.md) | |
| [archive/codegen/](archive/codegen/) | [vibe-output-analysis.md](archive/codegen/vibe-output-analysis.md), [wasm-gc-vs-selfhost-analysis.md](archive/codegen/wasm-gc-vs-selfhost-analysis.md) |
| [archive/compiler_language_incidents.md](archive/compiler_language_incidents.md) | Cited from [vibe.md](vibe.md) |
| [archive/DONE.md](archive/DONE.md) | Delete candidate |
| [archive/moonbit-retirement.md](archive/moonbit-retirement.md) | Cited recovery record (`moonbit-host-final-2026-06-23`) |
| [archive/mut-effect-plan.md](archive/mut-effect-plan.md) | |
| [archive/report/](archive/report/) | Dated evaluations |
| [archive/review-by-x-markdown.md](archive/review-by-x-markdown.md) | |
| [archive/spec/](archive/spec/) | Retired spec notes |
| [archive/TODO.md](archive/TODO.md) | Moved from repo-root `TODO.md`. Delete candidate |
| [archive/wasmtime-v43.md](archive/wasmtime-v43.md) | |

## Inventory coverage

Top-level names from `ls docs/` at the parent commit, excluding this router:

`BENCHMARKS.md`, `adding-modules.md`, `adr.md`, `archive`, `ast_binary_abi.md`,
`bootstrap.md`, `build-cache.md`, `builtin_contract_table.generated.md`,
`capability-authorization-surface.md`, `cheatsheet.md`,
`checked-direct-expression-return-observation.md`, `ci-speed.md`,
`cli-commands.md`, `compiler-parallelism.md`, `concurrency.md`, `coverage.md`,
`editor-and-debugging.md`, `effect-evidence-passing.md`,
`effect-taxonomy-entry-policy.md`, `effect-taxonomy-review.md`,
`effect-wit-mapping.md`, `effectset.md`, `error-effect-policy.md`,
`exception-effect.md`, `guide`, `host-runtime-contract.md`,
`http_server_contract.md`, `incremental-build.md`, `install.md`,
`issue-triage.md`, `known-issues.md`, `module-system-oracle.md`,
`module-system-v2.md`, `mutability-control-review.md`,
`naming-convention-migration.md`, `operation-gate.md`, `perceus-reuse.md`,
`perf-snapshot-2026-08-07.md`, `pkfire-pkspec.md`, `pl-survey-2026-07.md`,
`qualified-constructor-migration.md`, `region-mutable-state.md`,
`registry-design.md`, `release-notes-0.1.0.md`, `release-roadmap.md`, `report`,
`resource-kind-parameters.md`, `selfcompile-heap-policy.md`,
`side-effect-consolidation.md`, `spec`, `tracing-design.md`, `tutorial`,
`vibe.md`, `vibec-component.md`, `vibex-runtime-contract.md`,
`wasip3-effect-alignment.md`, `wasm`, `wasm-opt-dogfood.md`,
`wasm_threads_requirements.md`, `wit`, `zero-alloc-check.md`

Mixed directories, children classified above:

- `guide/` — user `when-to-use-effects.md`; internal `builtin-effect-migration.md`
- `spec/` — user `syntax.md`, `stable-surface.md`, `host-abi.md`; remaining files internal
- `wasm/` — user `feature-levels.md`, `host-runtime-contract.md`; generated `*.json`; internal `gc-value-abi.md`, `code-size-linear-vs-gc.md`
