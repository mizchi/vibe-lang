# Compiler invocation configuration (#1953)

The migration starts with one independently measurable lane: target `#cfg`
flags in the flat-source RC compiler. This is a first slice, not completion
of #1953 or a claim that the compiler as a whole is reentrant.

## Boundary and authority

`@vibe/compiler/config` defines the compiler-private algebraic effect
`Config::CfgFlags() -> String`. It provides only the target program's flags.
It cannot authorize generated source, unstable imports, file access, or trace
output. Operations for other configuration families must preserve that
separation rather than returning one unrestricted settings object.

The positional CLI captures `VIBE_CFG` as an immutable string. Both the ordinary
and compile-only lane tables pass that snapshot to the small RC boundary,
`compile_source_wasi_only_rc_with_cfg`, which handles `Config` around
`compile_source_wasi_only_rc_configured`. The selected compiler reads the effect
once, trims the CSV as before, and
passes the resulting flags explicitly to `parse_program_located_with_cfg`.
That parser never reads or updates the ambient flag cells. Its directive scan
copies the supplied flags before adding file-local `#cfg_enable` directives.

The CLI still appends flag directives to the source, preserving the existing
source and byte-offset protocol. Generated-source trust remains a separate,
explicit Bool input. Existing programmatic compile entries retain their
ambient behavior during migration; callers choosing the configured entry
must discharge its `Config` row themselves. A missing handler is not silently
replaced by process state or an empty default.

No push/pop stack, restoration setter, or temporary global override implements
the configured lane. Nested handlers select their own value, and unwinding an
inner handler leaves the enclosing value available.

## Remaining inventory

| Configuration | Current owner / boundary | Remaining migration |
| --- | --- | --- |
| Target `VIBE_CFG` | `parser/parser.vibe`: `cfg_ambient_flags`, `cfg_ambient_flags_csv_cell`; `compiler/config/config.vibe`: `configure_compiler_cfg_flags` | FS/import, tooling, legacy compile APIs, and worker entry points still use these compatibility cells. |
| Persistent-cache flag namespace | `compiler/cache/persistent_cache.vibe`: `persistent_cache_cfg_flags_cell` | Replace the setter with the same invocation's flag value; bind every parse memo and persistent namespace to that value together. The configured flat RC lane has no persistent artifact/parse cache. |
| In-process parse/header memo identity | `compiler/loader/header_cache.vibe`, `loader_contract_source_fs.vibe`: `cfg_ambient_flags_csv()` | Carry the scoped value with the parse request and its memo identity; changing only the parser would permit a cross-configuration cache hit. |
| Unstable-package authority | `compiler/cli_adapter_cli_main_with_lanes.vibe`, `cli/dispatch.vibe`: `VIBE_UNSTABLE`; runtime diagnostics already receive explicit `allow_unstable` | Snapshot at each invocation boundary and grant only the import-checking lane access. Do not fold this into build-time compiler feature flags. |
| Generated-source authority | positional CLI's `VIBE_INTERNAL_TRUSTED_SOURCE`; source compilers receive `trusted_generated` | Preserve the out-of-band authorization; source bytes must never enable the bypass. It is not granted by the flag-only `Config` effect. |
| Checked Exception-row mode | `checker/effects/checker_effects_dh_call_to_binding.vibe`: `error_row_mode_cell`, CLI `VIBE_CHECK_ERROR_ROW` | Migrate the checker/effect-pass policy together after the target flags. This remains shared configuration, unlike checked type facts belonging to a compilation. |
| Checked-module cache mode | `runtime/checked_module_cache/cache.vibe`: `checked_cache_mode`, CLI `VIBE_CHECKED_MODULE_CACHE` | Separate immutable policy from mutable cache contents/reset and transport it through the cache lane. |
| Typing reuse policy | `runtime/typecheck_fs_*`, adapter `set_experimental_typing_dependency_env_reuse_enabled` | Preserve the check-only/compile distinction and cache validation; do not treat mutable memo contents as configuration. |

Compiler lane specialization is #2497. Telemetry, trace sinks and their
enable cells remain #2498; a `Log` effect is deliberately not introduced.
Mutable checking observations, type environments, caches, and code-generation
scratch state are not configuration snapshots. Removing those globals is
separate work and still matters before arbitrary concurrent compiler calls.

## Evidence required per slice

`lib/@vibe/compiler/tests/invocation_config_test.vibe` checks nested values,
exception unwinding, actual RC compiles with a poisoned ambient flag set, and
byte-identical outer output before and after both successful and failed inner
compiles. Another case pauses an outer compiler at its flag request, runs
successful and failing inner compiles inside that handler, then resumes the
outer compiler and compares its output. A mutation replacing the configured parser selection with the
ambient selection must fail the poison test. Differential CLI output, the
stage2/stage3 fixpoint, allocation/wall measurements and the normal
`pkf run release-check` remain required before committing a migration slice.

Next, move the FS parser and cache identity as one lane, then migrate the
authority reads and remaining checker policies. Only after every supported
entry and artifact uses scoped configuration can #1953 close.
