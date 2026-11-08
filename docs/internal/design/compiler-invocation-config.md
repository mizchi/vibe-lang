# Compiler invocation configuration (#1953)

Target `#cfg` flags have scoped entries for the flat-source RC compiler,
shared FS parsing, source collection, filesystem and in-memory typechecking, source merging, owned typed-lowering inputs, and checked source-group codegen. These are migration slices,
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
The in-memory coordinator uses the same flag-aware fingerprint for its warm lookup.

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

Full compile and final-artifact orchestration, worker/tooling boundaries and CLI
integration remain later slices. Existing CLI entries retain compatibility
behavior rather than granting the whole compiler reentrancy.

## In-memory typechecking

`check_sources_memory_configured` captures `Config` once, owns a DB populated
from the supplied virtual files, and returns `Unit`. Like the configured FS
check, it keeps opaque DB values inside the operation instead of returning
them through an effect handler. A caller retaining its DB passes a captured
`TargetCfg` to `db_typecheck_with_config` directly.
A missing entry is refused before the walk; supplied empty text remains valid.

The dependency planner, `MemorySources` header provider, shared parse memo,
module checker and fingerprint lookup all receive that same snapshot.
`memory_module_header_with_config` uses both the configured loader policy and
the configured `ModuleParse` answer. The checker uses
`CheckJob::check_with_raw_diagnostics_with_config`: parse errors keep their
existing path handling, while type diagnostics retain the raw spans and markers
that the source API's final renderer owns. First-semantic-use observations use
the check's identity too.

These APIs require `Env` and `Exception`, with `Config` added only at the
capturing boundary. They acquire no `Fs` authority. Virtual directory/package
resolution, source-revision validation, dependency publication, collected-error
policy and shipped owned-head provenance keep their existing providers and
authority boundaries. A flag change uses the shared `TypeDb` invalidation;
unchanged flags retain resident dependency/environment reuse. Warm checks are
tested with parse counters as well as fingerprint counters: recording the same
fingerprint twice does not increment the latter and cannot prove reuse.

Compatibility entries capture the exact legacy flags once at their boundary
and delegate to the same data implementations. They do not write the flag cells
or temporarily replace another invocation's configuration. Other policies and
mutable cache contents remain separate work; this does not make the complete
compiler safe for arbitrary concurrent calls.

## Source merging

`build_grouped_merged_source_configured` captures `Config` once and returns the
linked source text. Its statement-data counterpart,
`build_grouped_merged_stmts_with_config`, receives the snapshot directly. The
shared merger parses every source with the configured engine parser; the same
selected statements drive the whole-program export plan, import aliases and
collision fallback. Legacy merge variants capture flags once before calling
that shared kernel, preserving their location/provenance/count observations.

`db_merged_source_with_config` and `db_grouped_merged_source_with_config` pass
one snapshot through all parses, including collision-provider reparses. They
validate the DB's configuration before looking up resident products. The whole-program merge
fingerprints bind the exact non-empty flag identity, including empty grouped
inputs, so a downstream caller cannot mistake identical source bytes under
different target flags for the same product. Empty flags retain the legacy
fingerprint bytes. Group products retain their input-only recipe inside the
configuration-validated DB, avoiding a repeated flag hash for every group. Warm group hits still replay rename metadata and retain the
whole-program overlap check and staged group reuse.

The plain shared merge needs only `Exception`; its capturing boundary adds
`Config`. DB merges retain `Env` and `Exception`, without `Fs`. Neither boundary temporarily
replaces the compatibility cells. Opaque DBs stay on the data side; the effect
boundary returns text.

### Owned checked-lowering inputs

`db_checked_lowering_inputs(db, cfg)` captures only accepted per-module rows
whose path, exact source, checked fingerprint and target identity agree with
the DB. Configured checks and validated cache providers publish that identity;
unbound compatibility rows cannot authorize a capture. Capture must happen
before another check overwrites a requested memo row. A stale or absent row
asks for a recheck instead of becoming an empty complete channel.

`CheckedLoweringInputs` hides its constructor and copies the offset and equality
arrays. Immutable source/fingerprint strings are shared. Resetting the memo,
checking another target or mutating a caller's arrays cannot change a retained
snapshot; its alias-clone query also returns a copy. Empty complete channels and
declined placement markers retain their distinct representations.

`merged_stmts_and_offsets_with_config` validates the snapshot's target and every
merged source before changing rename or location state. Parsing clears shared call cells and restores callee identities and argument
placements exclusively from the owned rows. Both the ordinary
union and alias-collision provider lookup use owned rows, with the same
callee/placement rebase and equality-name rewrite as compatibility merging.
The data entry needs only `Exception`; it acquires neither `Env` nor `Fs`.
Legacy wrappers retain their current memo-based behavior.

Namespace and location metadata remain owned by the serial merge phase. This
transport does not make codegen, module/final-artifact orchestration, CLI or
workers reentrant.

### Checked source-group codegen

`compile_checked_source_groups_wasi_with_config` accepts the caller's checked
source groups, `TargetCfg` and retained `CheckedLoweringInputs`, and returns
Wasm bytes. Its row is only `Exception`: it neither discovers files nor reads
ambient flags, rechecks sources, or loads/stores final artifacts. The caller
owns the checked closure; source and target witnesses are validated before
merge metadata changes. All lowering channels reach the ordinary codegen
entry, including call identities/placements, String operators, numeric/render
offsets and structural equality keys.

`compile_checked_source_groups_wasi_configured` adds only `Config`, captures
it once, and delegates to that data entry. It grants no unstable import,
generated-source or launcher authority. A mismatched target requires a recheck.
`mvp`, `no-dce`, `rc` and `rc-shadow` share a decoded mode and emission kernel
with the existing checked closure-source driver. RC modes use the existing
heap-parameter elaboration and retain every typed offset channel; `rc-shadow`
also enables ownership instrumentation. The cached compatibility driver uses
distinct typed artifact kinds for all four modes. These entries carry no
launcher grants. Unsupported modes are refused with the allowed
choices before merging. Namespace/location state and codegen scratch remain
serial phase-owned. CLI/full filesystem orchestration, body caches, workers
and final-artifact configuration remain later slices; this is not general compiler reentrancy.

## Persistent-cache policy boundaries

`@vibe/compiler/cache/policy` owns immutable, opaque `AstCachePolicy` and
`IngestionStampPolicy` values. Separate `AstCacheConfig::Active` and
`IngestionStampConfig::Enabled` effects capture one decision each. They grant
no target-flag, checked-artifact, generated-source, tracing or filesystem
authority. Cache contents, counters, memo eviction and reset are independent.

The AST value is the **effective persistent-AST decision**, after the caller
accounts for other reuse lanes. Compatibility parsing and prefetch retain the
existing predicate: the experimental AST flag must be enabled and checked
module mode must not be `on`. The new explicit policy entries use the supplied
value, even when a legacy mode disagrees. Shared in-process parse memos remain
available with persistent caching disabled; policy does not change semantic
cache identity.

`parse_program_located_shared_fs_with_cache_policy` and
`ast_cache_prefetch_fs_with_cache_policy` receive both `TargetCfg` and that
policy. Parse, prefetch, persistent load and publication share the selected
decision. Their `*_cache_configured` boundaries capture flags and policy once
before I/O. Scoped requests do not consult the legacy enable/mode cells.
Compatibility entries keep their lazy process-setting reads and delegate to
the same implementation. AST decoding, malformed-entry fallback, memo bounds
and target namespaces are unchanged.

`fingerprint_file_fs_with_policy` receives stamp policy and a captured cache
namespace. `fingerprint_file_fs_configured` captures only stamp policy; the
caller still supplies the namespace. The compatibility entry captures its
existing environment-derived decision and namespace. The key recipe, stat-token
validation, strict metadata-only codec and process-memo priority are unchanged.
Disabled policy never probes or publishes a stamp. A warm process memo may
answer before the enabled stamp lane, as before. Source text is always read
from its ordinary source provider and is never replayed from a stamp.

Full collection/typecheck/CLI orchestration still needs these policies passed
through. Checked-module cache mode, typing reuse, cache roots and mutable cache
ownership remain separate migrations; this slice does not make compiler walks
concurrent.

## Remaining inventory

| Configuration | Current owner / boundary | Remaining migration |
| --- | --- | --- |
| Target `VIBE_CFG` | `parser/parser.vibe`: `cfg_ambient_flags`, `cfg_ambient_flags_csv_cell`; `compiler/config/config.vibe`: `configure_compiler_cfg_flags` | Collection, FS and in-memory checking use explicit `TargetCfg`; source merge entries accept it; typed merge and checked source-group codegen accept owned lowering inputs on bump, RC and RC-shadow; CLI orchestration, final artifacts, tooling and workers still need that snapshot passed through. Legacy parser entries retain compatibility reads. |
| Persistent-cache flag namespace | `compiler/cache/persistent_cache.vibe`: `persistent_cache_cfg_flags_cell` | Collection, AST, typing and checked-module storage use captured identities in the scoped lane. Final-artifact and content-only fingerprint/stamp adapters remain; the latter values are independent of target flags. Cache-only compatibility APIs retain the legacy cell. |
| In-process parse/header memo identity | `compiler/loader/header_cache.vibe`, `loader_contract_source_fs.vibe` | Collection and checking use scoped identities for parse, semantic use, import-name, re-export and generated-type reuse. Other merge/tooling entries retain compatibility APIs. |
| Unstable-package authority | `compiler/cli_adapter_cli_main_with_lanes.vibe`, `cli/dispatch.vibe`: `VIBE_UNSTABLE`; runtime diagnostics already receive explicit `allow_unstable` | Snapshot at each invocation boundary and grant only the import-checking lane access. Do not fold this into build-time compiler feature flags. |
| Generated-source authority | positional CLI's `VIBE_INTERNAL_TRUSTED_SOURCE`; source compilers receive `trusted_generated` | Preserve the out-of-band authorization; source bytes must never enable the bypass. It is not granted by the flag-only `Config` effect. |
| Checked Exception-row mode | `checker/effects/checker_effects_dh_call_to_binding.vibe`: `error_row_mode_cell`, CLI `VIBE_CHECK_ERROR_ROW` | Migrate the checker/effect-pass policy together after the target flags. This remains shared configuration, unlike checked type facts belonging to a compilation. |
| Checked-module cache mode | `runtime/checked_module_cache/cache.vibe`: `checked_cache_mode`, CLI `VIBE_CHECKED_MODULE_CACHE` | Separate immutable policy from mutable cache contents/reset and transport it through the cache lane. |
| Typing reuse policy | `runtime/typecheck_fs_*`, adapter `set_experimental_typing_dependency_env_reuse_enabled` | Preserve the check-only/compile distinction and cache validation; do not treat mutable memo contents as configuration. |
| AST and ingestion-stamp cache policy | `compiler/cache/cache_underlying.vibe`: `ast_cache_enabled_cell`, `ingestion_stamp_enabled_cell` | Explicit AST parse/prefetch and ingestion fingerprint entries accept immutable policies; separate effects capture them once. Compatibility entries retain process memos. Collection/typecheck/CLI orchestration and mutable cache contents remain to migrate. |

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

`invocation_config_merge_test.vibe` checks the plain shared merger and the
ordinary/grouped DB mergers under poisoned ambient flags, one Config read with
successful/failing inner merges, Alpha→Beta→Alpha resident reuse, discarded
checker/artifact products, collision-provider reparsing and failure recovery.
Flag identities differ even for identical selected text or empty groups; empty
flags retain the legacy fingerprint representation. Compatibility entries also
observe flag changes before consulting their resident caches.

`invocation_config_lowering_test.vibe` checks copied channels, callee and
placement rebasing, reset isolation, empty versus missing rows, source and
fingerprint witnesses, target mismatches, Alpha→Beta typed String/equality
merges, configured builtin shadows, labeled parameter reordering, shared call-cell reset, refusal before location-state changes, and resident/disk-warm FS
publication. The bootstrap gate runs it with AST caching enabled.

`invocation_config_codegen_test.vibe` compares all four supported modes with the
compatibility typed driver, executes the generated Wasm, and checks retained
products after another target check and memo reset. An independent RC/RC-shadow kernel comparison also pins backend selection and
escaping owned captures, including repeated cached-mode calls. Runtime answers cover
String/equality and numeric/render channels, including a same-source Float64/Int
record-field switch, argument placements and builtin identity; nested successful and refused emits run inside an outer flag request.
Wrong source/target products and unsupported modes leave merge metadata intact.
The bootstrap gate runs it on its fresh stage2 with AST caching enabled.

`cache/policy/policy_test.vibe` pins independent capture, retained decisions and
nested exception unwinding without Env. `invocation_cache_policy_test.vibe`
exercises persistent AST cold/off/disk-warm/malformed/prefetch paths after real
memo eviction, nested flag/policy captures with a changed legacy mode, and
stamp publication, disabled policy, source edits and namespace retention. Run
with both experimental environment flags off and on; the bootstrap gate also
runs these suites on its fresh stage2.
