# selfhost `type` stage: typed-env snapshot (#476)

2026-05-30. Removing the prelude **typecheck** floor that #427 left after it
eliminated the parse cost. Tracking: #476, rolls up into #402.

## TL;DR

- #427 cached the *parsed AST*; the residual `type`-stage floor was the
  *typecheck* of the prelude (`ensure_prelude_functions`, ~3.5ms host /
  ~25-29ms selfhost-moonrun).
- This serializes the **typechecked env** to disk and deserializes it on a
  fresh process, skipping the prelude parse *and* typecheck entirely.
- Result (cold = real typecheck, warm = snapshot):
  - host compile-lite `type` stage **13.7ms → 3.4ms (−75%)**
  - selfhost wasm (moonrun): `type/prelude_functions` (~54-61ms cold) **fully
    skipped** on warm; prelude parse + typecheck frames disappear.
- cold vs warm compiler output **bit-identical** on 5 cases; full test suites
  green.

## Design

The hot path (`get_prelude_only_env_for_module` → `ensure_prelude_seed`, used
by `db.types` / compile / check) builds a **prelude seed** env once per
process and clones it per module. The cost is `ensure_prelude_functions`
typechecking the prelude source. (The `type_check` path additionally builds a
**builtins seed** via `ensure_builtin_modules`.)

We snapshot the *definitional* state of these seed envs — exactly the maps
`clone_for_module` propagates: bindings (`name → TypeScheme`), enum/struct/
alias defs, the ctor index, effect defs, the trait graph + impls, fn API
versions, and purity flags (including the `__prelude_loaded` /
`__builtins_loaded` sentinels). Per-instance state — the session typevar
counter, unification subs, all caches, profiling counters, `addr_types`,
`inferred_effects` — is excluded; deserialize rebuilds into a fresh session.

### Components

- `src/core/bin_codec.mbt` — a small public facade (`TypeBinWriter` /
  `TypeBinReader`) over the private AST-serializer primitives, so the checker
  reuses the exact `@core.Type` encoding instead of duplicating it.
- `src/checker/typeenv_snapshot.mbt` — `serialize_builtins_env` /
  `deserialize_builtins_env` + the disk plumbing (reuses the #427
  `ast_disk_cache` dir / enable flag).
- Integration: `ensure_prelude_seed` (prelude snapshot) and
  `get_cached_prelude_env_for_module_with_session` (builtins snapshot) try a
  snapshot before typechecking; a miss persists one.

### Correctness

- **Typevar-id safety.** `instantiate_scheme` always remaps a scheme's stored
  typevar ids to fresh vars before use, so baked ids are self-contained
  placeholders. As defence in depth, deserialize also advances the session
  typevar counter past every baked id, replicating the non-snapshot path's
  counter so freshly allocated user vars can never collide.
- **Best-effort + fallback.** Any disabled cache / miss / fs error / version
  skew / corrupt blob falls back to typechecking. The magic + version +
  length-prefixed layout makes a torn write fail to deserialize (→ fallback),
  never decode into a wrong env; the filename is the source content hash so
  distinct sources can't collide.
- **Versioned key.** The cache filename folds `content_hash(source)` +
  `AST_BINARY_VERSION` (wire format) + `AST_CACHE_PARSER_VERSION` (parser
  output) + `TYPEENV_SNAPSHOT_VERSION` (checker semantics / encoding). Bump
  `TYPEENV_SNAPSHOT_VERSION` on any checker change that alters the typed env
  for unchanged source.

## Measurements

### host (compile-lite base64, native debug, cold→warm)

| frame | cold | warm |
|---|---|---|
| type (stage total)     | 13,695 | 3,427 (**−75%**) |
| type/prelude_functions | 9,598  | — (skipped) |
| type/prelude_typecheck | 2,841  | — |
| type/prelude_parse     | 6,749  | — |

### check path (db.types base64), cold→warm

`type/prelude_functions` 2,745 → — ; `type/prelude_typecheck` 2,737 → —.
`checker/type_check_with_env` (user module) unchanged.

### selfhost wasm (`vibe_check_wasi.wasm` under moonrun), cold→warm

moonrun is the v8 interpreter (~5× slower than the wasmtime-aot KPI runtime);
the delta is what validates the lever on the real selfhost path.

| frame | cold (≈µs) | warm |
|---|---|---|
| type/prelude_functions | 53,000–61,000 | — (skipped) |
| type/prelude_typecheck | 25,000–29,000 | — |
| type/prelude_parse     | 27,000–32,000 | — |

The `prelude-env.<hash>.v1-p1-e1.venv` snapshot is created and reused by the
selfhost wasm, confirming the lever end-to-end under the selfhost runtime.

## Validation

- cold (real typecheck) vs warm (snapshot) `compile-lite --wasm` output
  **bit-identical** on basics / base64 / effects / module_export /
  module_import.
- Round-trip unit test: every propagated map matches a fresh-session
  reconstruction; load sentinels present; byte-stable re-serialize.
- Tests: core 89/89, checker 172/172, loader 52/52, runtime_compile 241/241,
  parser 90/90.

## Status vs #402 cutover

With #427 (parse) + #476 (typecheck), the prelude `type`-stage startup is
eliminated on warm processes. Combined with the wasmtime-AOT runtime (Phase 2,
already default), this is the Phase-1 lever set for the 1.33× gate; remaining
`type`-stage cost is the user module's own `type_check_with_env`, which scales
with the program rather than being fixed startup.
