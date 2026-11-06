# Compiler invocation configuration (#1953)

Target `#cfg` flags have scoped entries for the flat-source RC compiler,
shared FS parsing, source collection and filesystem typechecking. These are migration slices,
not completion of #1953 or a claim that the compiler as a whole is reentrant.

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

## FS parsing and AST identity

`parse_program_located_shared_fs_configured` reads `Config::CfgFlags` once,
trims the CSV with the same decoder as the RC entry, and joins it into one
canonical snapshot. That string selects the in-process memo version, supplies
the parser's explicit flags on a miss, and selects the persistent AST namespace
for both loading and publishing. Recording a parse receives the captured
string; it never rereads ambient flags after a nested invocation.

The compatibility `parse_program_located_shared_fs` copies the parser's exact
ambient flags with `cfg_ambient_flags_snapshot` and derives their exact identity at its
boundary. It does not reinterpret the compatibility setter's array as CSV.
If a compatibility array element contains a literal comma, its CSV would
alias several directive flags; shared parsing preserves that exact array
without memoizing or persisting it, and prefetch declines that identity.
AST prefetch captures the ambient identity too; both use the same explicit
AST-cache functions. This also keeps parsing and cache identity paired if a
legacy caller updates only the parser's flags. The pure shared parse uses the
same explicit parser and memo implementation. Existing shallow-copy and
bounded-memo behavior, parse diagnostics, AST-cache policy and fail-open
decoding are preserved. With matching settings, cache paths (including the
empty-flag path) remain compatible.

The cache adapter's `*_with_cfg` functions take explicit namespace data;
they acquire no `Config` authority and never consult the legacy cfg cell.
The other identity dimensions and filesystem/environment authority remain
unchanged. These functions do not make the mutable ASTs or cache state safe
for arbitrary concurrent mutation.

## Filesystem source collection

`collect_source_groups_fs_configured` and `collect_all_sources_fs_configured`
capture `Config` once through `target_cfg_capture`. The opaque `TargetCfg`
value retains the exact flags, parser identity and compiler/flag cache namespace.
Its constructor is hidden by the package contract; the array accessor returns
a copy. It carries target flags only, with no host or generated-source authority.

The collection, manifest, header and contract helpers receive that value as
an explicit parameter. Their signatures retain the existing `Source`,
`ModuleParse`, `ContractIngest`, `Env` and `Fs` authority boundaries. Legacy
entries capture the compatibility flags at their outer boundary and delegate
to the same implementations. The cache namespace is derived from those flags,
so changing only the old persistent-cache cell cannot select another parse's
header or source group.

Source-list, source-group, manifest-header, module-header, contract-facade and
vpkg-prefix paths use `*_in_namespace` adapters. The legacy adapters delegate
to the same key recipes. A cold path and every warm/fallback path retain the
same snapshot. Import-name and re-export type-parameter memos carry its identity,
and generated-type registry entries are filtered by it. The contract provider's
re-export visiting stack belongs to that walk rather than to the process.

`cfg_flags_identity` preserves ordinary CSV identities, including `""` for no
flags. A compatibility array containing an empty element or literal comma uses
a comma-prefixed sequence of length-delimited elements. No ordinary array can
produce that prefix. This distinguishes `["a,b"]`, `["a", "b"]` and
`["", "3:a", "b"]` without reinterpreting the setter's exact values. Legacy
semantic-use observations read the same identity as their parse memo.

Unlocated and located-preserving parser variants accept explicit flags too;
their lowering, diagnostics and `None` binder-authority paths are preserved.
The structural binder-context gate pins both the compatibility delegations
and the explicit variants.

## Filesystem typechecking

`check_file_fs_configured` captures `Config` once and carries the same `TargetCfg`
through source collection, import planning and the module checking walk. It owns
the DB and returns `Unit`. `module_plan_manifest_fs_configured` supplies the same
boundary for a separately requested dependency plan. The reusable DB entry,
`db_typecheck_fs_with_config`, accepts immutable data directly.

A caller retaining a DB handles the flag read before passing a snapshot to that
data entry. The closure-escape checker conservatively treats an opaque result
as potentially holding a function; putting an effectful opaque-DB return inside
a handler does not prove it handler-independent. The configured file check
keeps that result internal. No exception to the escape rule is introduced.

`TypeDb` records the exact target-flag identity of its derived results. A change
forgets resident fingerprints, dependency edges, environments and downstream
merge/artifact products, while preserving source inputs, source-set revision and
cumulative work counters. An unchanged identity retains warm reuse. Non-empty
flag identities also enter conservative module fingerprints, so shared memos
keyed by those fingerprints cannot conflate two configurations. The empty-flag
fingerprint retains its previous representation. Compatibility fingerprint
helpers keep their original input-only recipe, independently of ambient flags.
The legacy in-memory coordinator uses the checker's flag-aware fingerprint
for its warm lookup too; configuration switches still discard its derived results.
Its parsing and other policy reads remain a separate migration slice.

Storage helpers take only an explicit namespace, not a parser configuration.
`*_in_namespace` adapters share the legacy storage recipes; compatibility cache
APIs capture `persistent_cache_namespace_current`, preserving the old cache
setter's behavior independently of parser flags. Scoped callers pass
`target_cfg_namespace` instead. This covers dependency lists, leaf fingerprints,
module environments, TDRE aliases/witnesses and checked-module products. The
scoped alias input key binds non-empty flags too; its direct and segmented encoders
agree, and empty flags retain the previous bytes. Compatibility alias-key
functions retain their original declared inputs and framing, without acquiring
a new dependency on the ambient flag cells. A checked-module product
binds its namespace inside its exact input context, so moving a payload into
another flag set's valid outer storage envelope still forces a fresh check.

The checker parse, first-semantic-use observation and optional interface
observations use the same snapshot as planning. Legacy semantic-use observations
keep their constant-time ambient identity getter. Cache mode and checked-row
policy are separate remaining configuration; mutable contents still need
ownership or synchronization before arbitrary concurrent compiler calls.

Merge/codegen, final-artifact orchestration, worker/tooling boundaries and CLI
integration remain later slices. Existing CLI entries retain compatibility
behavior rather than granting the whole compiler reentrancy.

## Remaining inventory

| Configuration | Current owner / boundary | Remaining migration |
| --- | --- | --- |
| Target `VIBE_CFG` | `parser/parser.vibe`: `cfg_ambient_flags`, `cfg_ambient_flags_csv_cell`; `compiler/config/config.vibe`: `configure_compiler_cfg_flags` | Collection and FS checking use explicit `TargetCfg`; memory-only checking, merge/codegen, CLI orchestration, tooling and workers still need that snapshot passed through. Legacy parser entries retain compatibility reads. |
| Persistent-cache flag namespace | `compiler/cache/persistent_cache.vibe`: `persistent_cache_cfg_flags_cell` | Collection, AST, typing and checked-module storage use captured identities in the scoped lane. Final-artifact and content-only fingerprint/stamp adapters remain; the latter values are independent of target flags. Cache-only compatibility APIs retain the legacy cell. |
| In-process parse/header memo identity | `compiler/loader/header_cache.vibe`, `loader_contract_source_fs.vibe` | Collection and checking use scoped identities for parse, semantic use, import-name, re-export and generated-type reuse. Other merge/tooling entries retain compatibility APIs. |
| Unstable-package authority | `compiler/cli_adapter_cli_main_with_lanes.vibe`, `cli/dispatch.vibe`: `VIBE_UNSTABLE`; runtime diagnostics already receive explicit `allow_unstable` | Snapshot at each invocation boundary and grant only the import-checking lane access. Do not fold this into build-time compiler feature flags. |
| Generated-source authority | positional CLI's `VIBE_INTERNAL_TRUSTED_SOURCE`; source compilers receive `trusted_generated` | Preserve the out-of-band authorization; source bytes must never enable the bypass. It is not granted by the flag-only `Config` effect. |
| Checked Exception-row mode | `checker/effects/checker_effects_dh_call_to_binding.vibe`: `error_row_mode_cell`, CLI `VIBE_CHECK_ERROR_ROW` | Migrate the checker/effect-pass policy together after the target flags. This remains shared configuration, unlike checked type facts belonging to a compilation. |
| Checked-module cache mode | `runtime/checked_module_cache/cache.vibe`: `checked_cache_mode`, CLI `VIBE_CHECKED_MODULE_CACHE` | Separate immutable policy from mutable cache contents/reset and transport it through the cache lane. |
| Typing reuse policy | `runtime/typecheck_fs_*`, adapter `set_experimental_typing_dependency_env_reuse_enabled` | Preserve the check-only/compile distinction and cache validation; do not treat mutable memo contents as configuration. |
| AST and ingestion-stamp cache policy | `compiler/cache/cache_underlying.vibe`: `ast_cache_enabled_cell`, `ingestion_stamp_enabled_cell` | These environment-derived enable settings remain process-wide policy. Scoped target flags do not change their ownership; separate their immutable policy from cached contents in a later slice. |

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

`invocation_config_fs_test.vibe` poisons both compatibility cells, checks
flag-specific memo answers, runs successful and failing inner parses from an
outer parse's handler, and verifies independent on-disk AST namespaces. Run
it with the default cache policy and with `VIBE_EXPERIMENTAL_AST_CACHE=1`.
The latter also evicts through the real memo bound before checking disk-warm
answers, so an in-memory hit cannot impersonate persistent-cache reuse.
The bootstrap gate runs that enabled-policy case with its own freshly built
stage2; the ordinary unit shard also exercises the default policy.

`target_cfg_test.vibe` checks normalization, exact identities, copied array
access, independent namespaces and nested captures. `invocation_config_loader_test.vibe`
poisons both old cells, exercises recursive and manifest collection, forces
the source-list fallback, and checks warm flag switches, nested successful and
failed calls, re-export memo separation and generated-type registry filtering.
Mutations selecting ambient flags, a global source-list namespace, another
configuration's registry rows or another configuration's type-parameter memo
must fail at runtime. The bootstrap gate also runs these with AST caching on.

`invocation_config_typecheck_test.vibe` checks resident flag switches, unchanged
warm reuse, scoped plans and dependency-list storage, checked-module disk hits,
first semantic use, successful/failing nested calls, flag-bound fingerprints and
alias keys, and refusal/repair of a product copied across namespaces. The
bootstrap gate runs it against its own fresh stage2 with AST caching on. Negative
controls must fail at runtime when parsing reads ambient flags, resident results
survive a flag change, dependency-list storage selects the global namespace,
fingerprints or alias keys omit flags, checked-module input context reads the legacy namespace, or a compatibility
logical key acquires an ambient flag dependency. `incremental_test.vibe` pins preserved inputs/revision/counters
when derived results are forgotten.

Next, carry the snapshot into CLI orchestration, merge/codegen and final
artifacts, then migrate remaining authority reads and checker policies. Only
after every supported entry and artifact uses scoped configuration can #1953 close.
