# Checker browser baseline

This is an **opt-in observation baseline** for Issue #1440. It has two fixed,
ownerless Vibe roots and no `index.vpkg`, package extraction, public API, or
checker ABI:

- `parser_only.vibe` lexes and parses a fixed small program.
- `current_checker.vibe` lexes, parses, and invokes the current checker on the
  same fixed program.

The accompanying `full_compiler` case is intentionally rooted at the existing
`lib/@vibe/compiler/cli_adapter.vibe` / `cli_main` self-host compiler root.
That is the buildable whole-compiler root verified by the repository's
self-build flow. A root that merely imports `@vibe/compiler` was investigated
and is not used because it is not buildable as a standalone baseline input.

## Run

Supply a stage2 compiler built from the source being measured:

```bash
node scripts/measure_checker_browser_baseline.mjs _build/gen/stage2.wasm
```

The default report is ignored at
`_build/checker_browser_baseline/report.json`. Use `--out`, `--samples N`
(`N >= 2`), or `--keep-work` when inspecting an isolated run.

## Report schema and authority

Schema version 1 has fixed ordered cases:

1. `parser_only`, `current_checker`, and `full_compiler` when they build;
2. explicit unavailable rows for `checker_engine_only`,
   `checker_engine_plus_artifacts`, and `full_compiler_check`.

Every available source closure comes only from a fresh
`VIBE_MODULE_PLAN=1` version-1 sidecar and its numbered ingested `.src`
companions. The collector does **not** derive a closure from import text or
`compiler_sources_manifest.tsv`. It records canonical plan order, declared
dependency occurrences (including duplicates), ingested source byte counts and
SHA-256 digests, categories, and a manifest annotation. Compiler-relative
manifest paths are resolved under `lib/@vibe/compiler/`; the annotation is only
an exact-path label, not closure authority. Categories separately expose
`codegen`, `checker_core_and_model`, `checker_artifact`, and
`checker_observation` source contribution, but none of those path-based groups
claims that an extracted checker engine already exists. `current_checker` has
an additional strict closure invariant: no module categorized as `codegen`
(including `codegen/` and `perceus/` sources) is allowed. The collector rejects
such a plan before building, and report validation rejects a contaminated
`current_checker` report. This invariant deliberately does not apply to the
`full_compiler` case, whose whole-compiler closure necessarily contains codegen.

Each build has its own temporary `VIBE_BUILD_CACHE_DIR` and disables the
persistent artifact cache. The supplied compiler is used for both plan and
builds. The caller is responsible for supplying a matching stage2; its path
and SHA-256 are recorded so a report is attributable. The three supported
roots are required to build, and repeated output must be byte-identical;
either failure aborts the collector rather than being relabeled unavailable.

## Metrics

For available core Wasm outputs, the report records raw/gzip-9/brotli-11
bytes, SHA-256, canonically sorted exact imports, per-build SHA-256 values, and
exact byte-for-byte repeated-artifact equality. Source closure digests and
equal repeated artifacts are deterministic evidence for a matching
compiler/source/compression implementation.

Build wall time, Node `WebAssembly.compile`, instantiation, and direct export
invocation are raw sample arrays and are environment-sensitive. The report
records Node/V8/OS/CPU metadata rather than presenting them as stable scores.
Instantiation and direct invocation run only when the core module has no
imports and its named entry is actually exported. The collector never invents
host imports, calls a component through `WebAssembly.Module`, or guesses a CLI
ABI. Unsupported timing paths carry a reason; unavailable is never encoded as
zero.
