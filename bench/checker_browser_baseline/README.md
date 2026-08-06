# Checker browser baseline

This is an **opt-in observation baseline** for Issue #1440. It uses four fixed,
ownerless Vibe roots and deliberately has no local `index.vpkg`, package
extraction, public API, or checker ABI:

- `parser_only.vibe` lexes and parses a fixed small program.
- `current_checker.vibe` lexes, parses, and invokes the current checker.
- `checker_engine_only.vibe` exercises that parser + parent-checker engine
  boundary under a strict closure policy that excludes the optional artifacts
  child and backend/runtime ownership.
- `checker_engine_plus_artifacts.vibe` executes the existing checked effect-set
  observation -> artifact -> v1 encode pipeline through
  `@vibe/compiler/checker/artifacts`.

`current_checker` and `checker_engine_only` intentionally execute equivalent
current checker-engine workload today, so their generated Wasm may be identical.
`checker_engine_only` does not claim a separate engine API or a behavioral
implementation difference. Its independent value is the strict artifact-free
closure policy and its fixed root identity; the collector and serialized-report
validator require that declared root to occur exactly once in the attested
module plan.

The `full_compiler` case is rooted at the existing
`lib/@vibe/compiler/cli_adapter.vibe` / `cli_main` self-host compiler root. That
is the buildable whole-compiler root verified by the repository's self-build
flow. A root that merely imports `@vibe/compiler` is not used because it is not
buildable as a standalone baseline input.

## Run

Supply a stage2 compiler built from the source being measured:

```bash
node scripts/measure_checker_browser_baseline.mjs _build/gen/stage2.wasm
```

The default report is ignored at
`_build/checker_browser_baseline/report.json`. Use `--out`, `--samples N`
(`N >= 2`), or `--keep-work` when inspecting an isolated run.

## Report schema and authority

Schema version 2 has six fixed ordered cases:

1. available `parser_only`;
2. available `current_checker`;
3. available `checker_engine_only`;
4. available `checker_engine_plus_artifacts`;
5. available `full_compiler`;
6. explicitly unavailable `full_compiler_check` because no supported direct
   check invocation ABI exists.

Every available source closure comes only from a fresh
`VIBE_MODULE_PLAN=1` version-1 sidecar and its numbered ingested `.src`
companions. The collector does **not** derive a closure from import text or
`compiler_sources_manifest.tsv`. It records canonical plan order, declared
dependency occurrences (including duplicates), ingested source byte counts and
SHA-256 digests, path-derived categories, and a manifest annotation.
Compiler-relative manifest paths are resolved under `lib/@vibe/compiler/`; the
annotation is only an exact-path label, not closure authority.

The extracted child is classified before the broader checker path:

- `checker_artifacts_contract` for its exact `index.vpkg`;
- `checker_artifacts_artifact` for child `*_artifact.vibe` sources;
- `checker_artifacts_observation` for child `*_observation.vibe` sources;
- `checker_artifacts_support` for any remaining child source.

These categories report source ownership and do not infer per-symbol
reachability. Parent-checker artifact/observation names remain separate from
those child categories.

Case-specific closure policies are applied both to the live compiler sidecar
before a build and by the strict serialized-report parser. `current_checker`
remains codegen/perceus-free. `checker_engine_only` rejects every artifacts
child source and all compiler `codegen`, `perceus`, `runtime`, `cache`, and
`loader` sources. `checker_engine_plus_artifacts` rejects the same five backend
or host-facing ownership groups and requires exact plan evidence for the child
`index.vpkg` plus the invoked `checked_effect_set_observation.vibe` and
`checked_effect_set_artifact.vibe` sources. `full_compiler` intentionally does
not use those exclusions.

Each plan and build receives a fresh temporary `VIBE_BUILD_CACHE_DIR`, inherited
`VIBE_*` variables are removed, and the persistent artifact cache is disabled.
The supplied compiler is used for both planning and every build. The caller is
responsible for supplying a matching stage2; its path and SHA-256 are recorded.
All five supported roots must build, and repeated output must be byte-identical;
either failure aborts rather than being relabeled unavailable.

## Metrics

For available core Wasm outputs, the report records raw, gzip level 9, and
Brotli quality 11 bytes, SHA-256, canonically sorted exact imports, per-build
SHA-256 values, and exact `Buffer.equals` repeated-artifact evidence. Source
closure digests and equal repeated artifacts are deterministic evidence for a
matching compiler/source/compression implementation.

Build wall time, Node `WebAssembly.compile`, instantiation, and direct export
invocation are raw sample arrays and are environment-sensitive. The report
records Node/V8/OS/CPU metadata rather than presenting them as stable scores.
Instantiation and direct invocation run only when the core module has no imports
and its named entry is actually exported. The collector never invents host
imports, calls a component through `WebAssembly.Module`, or guesses a CLI ABI.
Unsupported timing paths carry a reason; unavailable is never encoded as zero.
