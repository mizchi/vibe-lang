# selfhost `type` stage: AOT-parse disk cache (#427)

2026-05-30. Reducing the fixed startup cost of the selfhost compiler's
`type` stage. Tracking: #427, rolls up into #402.

## TL;DR

- Re-decomposed the current-main `type` stage. **It is no longer dominated
  by `type/builtin_modules`** (the 179ms / 65% bottleneck profiled in #400).
  Since #400 landed session-level caching + `skip_fn_body_check`, the
  `db.types` / `compile-lite` hot paths go through `type_check_with_env`,
  which loads only the **prelude** (`ensure_prelude_functions`), not the full
  builtin module set. `type/builtin/*` frames no longer appear in the profile
  for the 5 KPI cases.
- The new ceiling is **prelude parse + prelude typecheck**:
  - compile path `type/prelude_functions` ≈ 10.5ms = parse **6.9ms (66%)** +
    typecheck 3.5ms (33%).
  - check path ≈ 3.5ms, dominated by typecheck (parse is amortized to a
    different frame).
- Landed the **AOT-parse lever** (Option C from #400): a best-effort on-disk
  cache of the pre-parsed binary AST. Deserializing is ~10x faster than
  re-parsing. Validated on host and on the real selfhost wasm; output is
  bit-identical.
- Remaining blocker for the `≤3ms` acceptance target: **prelude typecheck**
  (~3.5ms wasmtime-aot) is untouched by parse-caching and needs typed-env
  serialization (Option A/B). Documented below.

## Decomposition (host, native debug, `--profile-callstack`, 5 KPI cases)

`type/prelude_functions` total, split into parse vs typecheck (µs):

| case | compile parse | compile TC | check TC |
|---|---|---|---|
| basics         | 7004 | 3551 | 4517 |
| base64         | 6757 | 3476 | 3536 |
| effects        | 6927 | 3501 | 3395 |
| module_export  | 6973 | 3401 | 3478 |
| module_import  | 6950 | 4259 | 3406 |

Parse is ~66% of the compile-path type-stage fixed cost; on the check path
the prelude parse is amortized elsewhere and typecheck dominates.

## Lever comparison (microbench, native debug, parse vs deserialize)

| source | parse µs | deserialize µs | speedup | binary bytes |
|---|---|---|---|---|
| prelude (9.8KB)        | 14,567 | 1,451 | **10.0×** | 15.4KB |
| builtins (12 mods, 40.5KB) | 52,786 | 5,703 | **9.3×** | 62.2KB |

- **AOT parse (Option C, landed)** — skip parse via cached binary AST. ~10x on
  the parse portion. Serializer already existed
  (`@core.serialize_module_binary` / `deserialize_module_binary`).
- **typed-env snapshot (Option A/B, deferred)** — skip parse *and* typecheck
  by serializing the typed builtins env. Bigger win (removes the ~3.5ms
  typecheck floor) but needs new `TypeEnv` serialization infra.
- **prelude env reuse** — already done within a process via the #400 session
  cache; does not help a fresh selfhost invocation.

## Implementation

`src/checker/ast_disk_cache.mbt` — `parse_ast_cached(source)` mirrors
`@parser.parse_ast` but:

1. key = `content_address_hash(source)` + `AST_BINARY_VERSION` (serializer wire
   format) + `AST_CACHE_PARSER_VERSION` (parser/desugar semantics, bumped when
   the AST produced for unchanged source changes);
2. read `.vibe/ast/<key>.vast`, `deserialize_module_binary` on hit;
3. on miss/error/version-skew: parse, then best-effort
   `serialize_module_binary` + write.

Wired into the two parse sites: `prelude_ast()` (`src/checker/prelude.mbt`)
and the builtin loop in `ensure_builtin_modules`
(`src/checker/typecheck_prelude.mbt`).

Design notes:
- **Correctness-safe:** every step falls back to parsing on any failure, so
  compiler output is unaffected. The 4-byte `vAST` magic + version guard +
  length-prefixed encoding make a torn/partial write fail to deserialize
  (→ fallback), never decode into a wrong-but-valid AST. The filename is the
  source's SHA1, so distinct sources cannot collide.
- **Portable:** cache dir is cwd-relative (`.vibe/ast`, gitignored) so it
  resolves under the wasmtime/moonrun preopens that host the selfhost wasm
  (which see cwd, not an absolute `~/.cache`). `@os_fs` is already imported by
  the checker and links on `--target wasm` (`__moonbit_fs_unstable.*` imports
  present in `vibe_check_wasi.wasm`).
- **Toggle:** `set_ast_disk_cache_enabled(Bool)` / `set_ast_disk_cache_dir`
  for tests/benches. Default on.

## Validation

- Cold vs warm `compile-lite --wasm` output **bit-identical** on basics /
  base64 / effects / module_import.
- `moon test -p mizchi/vibe/checker` 171/171, `-p mizchi/vibe/core` 88/88.

### Host (compile-lite, base64, native debug), cold→warm

| frame | cold | warm | Δ |
|---|---|---|---|
| type/prelude_parse     | 12,706 | 2,003 | **−84%** |
| type/prelude_functions | 17,777 | 7,080 | **−60%** |
| type (stage total)     | 22,219 | 12,064 | **−46%** |
| type/prelude_typecheck | 5,059 | 5,064 | ~0 (expected) |

### Selfhost wasm (`vibe_check_wasi.wasm` under moonrun), cold→warm

moonrun is the v8 interpreter (~5× slower than the wasmtime-aot KPI runtime);
the cold→warm **delta** is what validates the cache on the real selfhost path.

| frame | cold (≈µs) | warm (≈µs) | Δ |
|---|---|---|---|
| prelude_parse         | ~36,000 | ~15,000 | **~−60%** |
| prelude_functions     | ~72,000 | ~46,000 | **~−37%** |
| prelude_typecheck     | ~35,000 | ~30,000 | ~−13% (variance) |

The `.vibe/ast/<hash>.v1.vast` blob is created and reused by the wasm,
confirming the disk cache works end-to-end under the selfhost runtime.

## Status vs #427 acceptance criteria

- [x] `type` stage re-decomposed into builtin / prelude / user typecheck with
      `--profile-callstack`; finding that builtin_modules is no longer the
      ceiling recorded.
- [x] remaining fixed cost after `ensure_builtin_modules` identified =
      prelude **parse** (cached now) + prelude **typecheck** (the floor).
- [x] AOT-parse / typed-env-snapshot / prelude-reuse compared; AOT-parse
      landed, typed-env-snapshot scoped as the next lever.
- [~] `check.type` median to ≤3ms: parse eliminated, but the **typecheck
      floor (~3.5ms wasmtime-aot) remains** → needs typed-env serialization.
      Documented here per the "blocker documented with profile" criterion.

## Next lever (deferred): typed-env snapshot (Option A/B)

To reach the ≤3ms `check.type` target, serialize the typed builtins env
(`cached_builtins_env`) so a fresh process deserializes a ready `TypeEnv`
instead of re-running `ensure_prelude_functions` typecheck. Needs new
`TypeEnv` serialization (the `store.mbt` types). Same disk-cache plumbing as
here can host it. Estimated removal: the remaining ~3.5ms typecheck floor.
