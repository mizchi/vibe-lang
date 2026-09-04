# Build cache layering & GC policy

This note covers the **incremental build cache** the compiler writes
under `_build/vibe_*`, how its fingerprints relate to the ADR-0004
content-address *identity* layer, and how to reclaim disk. It is the resolution
record for #631 (cache GC) and #633 (hash-layer clarification).

## Two distinct hash layers

vibe uses content hashing for two unrelated purposes. They are intentionally
**separate** and must not be conflated:

| Layer | Purpose | Hash | Where |
|-------|---------|------|-------|
| **Identity** (ADR-0004) | Content-addressed modules — `HashRef` (runtime), `VersionRef`, `SymbolRef` (user-facing). A stable, collision-resistant name for a definition's content. | **SHA1** (cryptographic). `lib/@vibe/core/sha1.vibe` (@vibe/core package) implements it with known-answer vectors. | identity / distributed refs |
| **Build cache** | A fast key for "have I already compiled exactly this input with exactly this compiler?" Only ever compared for equality within one machine's `_build`; a miss just recompiles. | **`compact_string_fingerprint`** — a non-cryptographic double-polynomial rolling hash `"len:h1:h2"` (h1/h2 31-bit, distinct large primes → ~62 effective bits). | `lib/@vibe/compiler/cache/persistent_cache.vibe` |

**Why two hashes, not one.** The build cache is a pure performance optimization
on the local `_build` tree: a forged collision can at worst return a stale
artifact for *your own* next build, never corrupt a published identity. A
non-cryptographic rolling hash is therefore the right tradeoff — cheap to
compute over large merged sources, and collisions (simultaneous match of `len`,
`h1`, and `h2`) are vanishingly unlikely for real inputs. The ADR-0004 identity
layer is where cryptographic strength matters, and that uses SHA1. There is no
plan to route build-cache keys through SHA1; the speed of the rolling hash is a
feature, and the identity layer already owns the cryptographic guarantee.

## Cache key: content + version (#630)

The build-cache key is `persistent_cache_version_tag() | <content fingerprint>`,
where the version tag is:

```
v10 | cg-<codegen_fingerprint()>
```

- `v10` — a manual knob bumped only on a cache **format** change (how `.hex` /
  `.tsv` entries are serialized).
- `cg-<…>` — a build-time hash of every compiler source file
  (`compiler_sources_manifest.tsv`), regenerated with the bundle. Any change to
  emitted wasm / runtime ABI changes the compiler source, hence this segment,
  hence the key — so a codegen change automatically invalidates stale artifacts
  with no manual bump (#630).

## GC policy (#631)

Cache entries are **content-addressed and append-only**: a store overwrites only
the exact same key, and a source/codegen change produces a *new* key, leaving the
prior file as an orphan. Nothing deletes orphans in place, so `_build/vibe_*`
grows monotonically over a long editing session.

This is deliberate — automatic mid-build GC would need a per-build reachable-set
mark-sweep and risks evicting entries a concurrent build still wants. Instead,
reclaiming is an **explicit, first-class command**:

```bash
pkf run cache-clean              # delete every _build/vibe_* cache entry
bash scripts/cache_clean.sh -n   # dry-run: report what would be reclaimed
```

`scripts/cache_clean.sh` removes only `_build/vibe_*` files (the persistent cache);
generation builds, fixtures, and everything else under `_build` are untouched. A
full rebuild simply repopulates the cache. Because the key already version-tags
on every codegen change, a clean is never *required* for correctness — only to
reclaim disk.

## Ingestion fingerprint telemetry

For check-only measurement, request the separate compiler-owned sidecar with
both `VIBE_INGESTION_TELEMETRY_OUT` and a non-empty control-free
`VIBE_INGESTION_TELEMETRY_NONCE`. It reports `String::length` **string units**
at this helper (`source_read_string_units`, `hash_input_string_units`), not raw
bytes. Runner `host_fs_scope` remains a separate aggregate
raw-byte boundary observation. The sidecar is rejected outside
`VIBE_CHECK_ONLY=1`, stale requested output is removed before CLI early returns,
and publication after a successful check is required before the final `ok`.

## Concurrent publication requirement

Append-only keys avoid invalidation races but do not by themselves make a
write atomic. The current implementation writes artifact bytes directly to the
final cache path. Before ADR-0068 compiler workers or concurrent compiler
processes may publish the same key, publication must move to a unique temporary
file in the destination directory followed by atomic rename.

Workers may compute an artifact, but the compiler coordinator owns publication.
If two publishers race on the same content-derived key, either may win only
after a complete write; the loser removes its temporary file. Readers must see
the old complete value, the new complete value, or a miss, never partial bytes.
A per-key single-flight table may avoid duplicate work but is not required for
correctness. Automatic mid-build GC remains out of scope because it has the
stronger cross-build reachability problem described above.

## CI caches (2026-07 wall-time rework)

`.github/workflows/ci.yml` persists three caches across runs via
`actions/cache`:

| Cache | Path | Key | Why it's safe |
|-------|------|-----|---------------|
| Seed artifact | `bootstrap/seed/compiler.wasm` | hash of `bootstrap/seed.json` | pinned release asset; the manifest hash IS its identity |
| Shard stage2 | `_build/_ci_shard_gen/` | hash of seed manifest + committed flat module source + generations/runner scripts | the stage2 build is a deterministic function of exactly those inputs; on any compiler change the flat source changes and the key misses |
| Persistent compile cache | `_build/vibe_selfhost_*` | hash of `cache/codegen_fingerprint.vibe` (per shard) | every cache row already folds the codegen fingerprint into its own key (see above), so rows from another compiler version are ignored on lookup — restoring can never serve a stale artifact |

The unit-test battery itself is split across parallel matrix jobs with
`VIBE_UNIT_TEST_SHARD=i/N`; the partition is weight-balanced from
`scripts/unit_test_weights.tsv` (regeneration procedure in that file's
header). Isolated per-test cache roots (`VIBE_BUILD_CACHE_DIR`) let the
cache-inspecting tests run inside the parallel fan-out instead of a
sequential tail — except the few tests that assert on the default root's own
semantics, which stay sequential (see `strict_cache_tail` in
`scripts/unit_test_runner.sh`).
