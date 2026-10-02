# Module system Oracle

Status: the executable source of truth for ADR-0063 and ADR-0070. 2026-07-16
(current-model summary 2026-08-01, #1269).

vibe's package and module policy is defined by the Lean model in
`formal/VibeFormal/Module/`, and the compiler's loader refines its judgements
on the filesystem. It supersedes the incoming-only boundary and the recursive
discovery of the earlier ADR-0063 / ADR-0070.

<a id="現行モデル-canonical--ここが唯一の現行記述"></a>

## Current model

This section is canonical: the only description of the current rules, and the
source of truth for the **current** rules on package
boundaries, visibility, and pinning (#1269). Other documents (spec,
cheatsheet, tutorial, install) link here instead of explaining it themselves.
Where another description disagrees, this section and
`formal/VibeFormal/Module/` win.

**1. `index.vpkg` is the only boundary.** A source is owned by its nearest
ancestor `index.vpkg`; a nested `index.vpkg` starts another package.
`index.vibe` and the legacy `index.vibei` are **not** boundaries: they are
read for compatibility only, and a new package always has an `index.vpkg`.
More than one index spelling in a directory is a hard error.

**2. Visibility is per owner.** An ownerless source is a public compatibility
space that anyone may import. An owned implementation can be imported only
from the same owner; another owner sees only that package's `index.vpkg`
facade (in both directions, parent to child and child to parent, and an
ownerless importer cannot bypass it either).

**3. The implicit build roots are the direct children only.** Only the
ordinary `*.vibe` files in the same directory as `index.vpkg` are implicit
roots. Subdirectories are not scanned; a source there enters the graph through
a relative import / export edge from a direct root. `*_test.vibe` and
`*_bench.vibe` are left out of the ordinary build and the package hash and
cannot be import targets (when run explicitly they inherit the nearest owner's
private production modules and the `index.vpkg` shared imports). `_*.vibe` and
`*.draft.vibe` are left out of the automatic roots and hash, but an explicit
relative import from the same owner brings them into the graph and the hash
closure. A symlink may not be a module source, a contract, or an import
target.

**4. Contract and header.** `index.vpkg` is the public contract, written as
bodyless declarations, under a key=value header: `name` / `version` /
`description` / `deps` / `main` / `generated_hash` (ADR-0080).
`deps = { @scope/pkg : x.y.z }` is the one place a dependency's version is
declared; `import @scope/pkg { .. }` only resolves names and carries no
version. The old `version x.y.z` spelling (no `=`) is still accepted. A body
in `index.vpkg` is an error, and there is no `priv` modifier: what the
contract does not declare is private to the package.

**5. Pins and updates.** Two layers, for two purposes:

| task | command | recorded in |
|---|---|---|
| declared-dependency check | `vibe check --deps-missing <root>` | — (CI: compiler_gate 60) |
| package hash, computed and written back | `vibe hash --write <pkg_dir\|index.vpkg>` | `generated_hash` (idempotent) |
| add a dependency and pin it | `vibe add <source-spec>` | the root `index.vpkg`: a `deps` entry plus `require @scope/name x.y.z = #pkg:b3:<hex> from <source>@<commit>` (a legacy `#pkg:sha1:<hex>` still verifies); the package itself in `.vibe/store/` |
| complete an unpinned `require` | `vibe fmt` | the `require` line, from the copy in `.vibe/store/` when that copy's version satisfies the constraint. Offline: an unanswerable line is left as written, and the build then refuses it |
| restore the store from the pins | `vibe fetch` | `.vibe/store/` (the `$VIBE_HOME/cache/pkg/` cache first, else the pinned source; hash-verified either way) |
| publish a version | `vibe pkg publish <pkg_dir>` | the claimed bump must be exactly the one the contract diff requires (patch: contract unchanged; minor: additions only; major otherwise); `$VIBE_HOME/cache/` and the local transparency log (ADR-0065) |

`@scope/name` resolves in order: `.vibe/store/` (pin-verified) → the workspace
`lib/` → each `VIBE_LIB` root (`:`-separated; the compiler's own default is
`$VIBE_HOME/lib`, and an installed toolchain's launcher sets it to the
toolchain's own `lib/` followed by `$VIBE_HOME/lib`, so the active toolchain's
stdlib wins, #2677). The lib/VIBE_LIB steps are a dev-mode convenience; under
`VIBE_REQUIRE_PINS=1` an unpinned resolution is an error. A store import is
verified against the pins of the importer's owning `index.vpkg` (the nearest
enclosing one, so the root manifest covers the whole project) as well as the
importer's own head. This is the one dependency lane (#2676,
[install.md](../../user/getting-started/install.md#dependencies)); the earlier
vendoring lane (`vibe.deps` / `vibe.lock` / `deps/`) is gone, and so are
`index.lock` and `module Name { }` blocks (a parse error naming the edit,
#728).

## Rules

1. `index.vpkg` is the only boundary. A source is owned by its nearest
   ancestor `index.vpkg`; a nested `index.vpkg` starts another package.
2. An ownerless source is a public compatibility space and may be imported
   whether or not the importer has an owner. An owned implementation target
   must belong to the importer's owner. Across owners, only the other
   package's `index.vpkg` facade may be imported. The restriction applies in
   both directions, parent to child and child to parent, and an ownerless
   importer cannot bypass it to reach an owned implementation.
3. `index.vibe` and the legacy `index.vibei` are not boundaries. More than one
   index spelling in a directory is a hard error whichever one is the entry.
4. The implicit build roots are the ordinary `*.vibe` files in the same
   directory as `index.vpkg`. Subdirectories are not scanned; a source there
   enters the graph through a relative import / export edge from a direct
   root.
5. `*_test.vibe` / `*_bench.vibe` are left out of the ordinary build and the
   package hash and cannot be import targets. A companion run explicitly
   inherits the nearest owner's private production modules and the
   `index.vpkg` shared imports.
6. `_*.vibe` / `*.draft.vibe` are left out of the implicit roots and the
   automatic hash input. When a production module of the same owner imports
   one by a relative path, it enters both the graph and the content-addressed
   hash closure, and inherits the nearest owner's `index.vpkg` shared imports.
7. A module source, contract, or import target may not be a symlink.
8. **A contract's transparent types are ambient inside the package (#1840).**
   A struct / enum / type alias defined transparently in `index.vpkg` is
   written by the loader as a real, content-keyed source under
   `.vibe/build/vpkg_types/` (the **materialized types module**, ownerless);
   the facade re-exports it, and each sibling implementation imports it
   through the directory-shared import prefix. That is how a sibling resolves
   an enum constructor through the ordinary import machinery (there is always
   exactly one definition site; two definitions of a same-named enum would be
   two identities and trap at run time, #1879). In the model this is not a new
   rule but an application of rule 2's legal import of an ownerless source.
   `effect` / `effectset` / opaque declarations stay in the facade.

## Oracle and implementation

| observable rule | Lean Oracle | implementation refinement / regression guard |
|---|---|---|
| filename role | `Source.role` | `loader/header_cache.vibe::contract_sibling_impl_raws` |
| regular source, exclusive index | `Valid` | `ensure_regular_source_fs` / `validate_index_layout_fs` |
| boundary, nearest owner | `Boundary` / `Workspace.ownerOf` | `nearest_vpkg_path_fs` |
| direct implicit root | `IsImplicitBuildRoot` | `contract_sibling_impl_raws` |
| companion shared scope | `InheritsSharedImports` | `vpkg_directory_shared_import_prefix_fs` |
| owner / ownerless visibility | `AllowedImport` | `enforce_incoming_boundary_fs` |
| automatic / reachable hash input | `automaticallyIncludedInPackageHash` / `includedInPackageHash` | `collect_package_hash_source_closure_fs` |
| cache-independent observation | policy functions are pure | `module_policy_context_fingerprint_fs` |
| concrete witnesses | `Proofs/ModuleExamples.lean` | `tests/contract_vpkg_test.vibe`, `tests/contract_vpkg_shared_scope_test.vibe` |

`Fs::stat_token` returns the reserved value `-1` for a symlink, for bootstrap
compatibility, and `ensure_regular_source_fs` rejects it. A regular file's
token is a metadata hash as before; the JS and Rust runners implement the same
rule.

The persistent source cache folds into its context fingerprint, beyond the
external package resolution, each source's owner, the content of the owner's
contract, and the list of direct production roots. A cache hit made stale by
an index conflict, a nested boundary, a shared import or a changed direct root
is therefore discarded, and the same policy is re-evaluated as on a cold graph
walk.

## Hash closure

`package_hash` takes as input:

- `index.vpkg` itself;
- the direct production roots in the same directory;
- the same-owner sources reached from them through relative import / export.

An external package contributes not its source bytes but the require pin
recorded in `index.vpkg`. Test / bench companions are refused as edge targets,
so they never enter the closure. Changing a same-package source that affects
execution therefore changes the package hash.

## Epistemic status

`pkf run formal-check` proves the classification, owner, visibility and
hash-input judgements on a finite workspace model. The real filesystem's path
normalization, the parser, the cache, the hash bytes and the Wasm codegen are
not extracted from Lean; the corresponding refinements are pinned by
regression tests and the generation / fixpoint gate. Candidates for
strengthening it: a differential oracle that turns a fixture graph into Lean
input, and a model that proves the package-hash closure's graph reachability
by induction.
