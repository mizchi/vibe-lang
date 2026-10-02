# Build cache layering & GC policy

This note covers the **incremental build cache** the compiler writes
under `.vibe/build/cache/vibe_*` at the project root
([install.md](../../user/getting-started/install.md#project-layout), #2675), how its fingerprints relate to the ADR-0004
content-address *identity* layer, and how to reclaim disk (#631, #633).

## Two distinct hash layers

vibe uses content hashing for two unrelated purposes. They are intentionally
**separate** and must not be conflated:

| Layer | Purpose | Hash | Where |
|-------|---------|------|-------|
| **Identity** (ADR-0004 / ADR-0093) | Content-addressed modules — `HashRef` (runtime), `VersionRef`, `SymbolRef` (user-facing). Published package and contract identities are algorithm-tagged: `pkg:b3:` / `ct:b3:` on every new write. | **BLAKE3-256** (`lib/@vibe/blake3`). SHA-1 (`pkg:sha1:` / `ct:sha1:`, `lib/@vibe/core/sha1.vibe`) survives only as a reader that verifies historical pins. | identity / distributed refs |
| **Build cache** | A fast key for "have I already compiled exactly this input with exactly this compiler?" Only ever compared for equality within one project's `.vibe/build/cache`; a miss just recompiles. | **`compact_string_fingerprint`** (`lib/@vibe/cache/cache.vibe`) — a non-cryptographic double-polynomial rolling hash `"len:h1:h2"` (h1/h2 31-bit, distinct large primes → ~62 effective bits). | `lib/@vibe/compiler/cache/persistent_cache.vibe` |

**Why two hashes, not one.** The build cache is a pure performance optimization
on the local `.vibe/build/cache` tree: a forged collision can at worst return a stale
artifact for *your own* next build, never corrupt a published identity. A
non-cryptographic rolling hash is therefore the right tradeoff — cheap to
compute over large merged sources, and collisions (simultaneous match of `len`,
`h1`, and `h2`) are vanishingly unlikely for real inputs. The identity layer is
where cryptographic strength matters, and it uses BLAKE3. Build-cache keys are
not routed through BLAKE3: the speed of the rolling hash is the point, and the
identity layer already owns the cryptographic guarantee.

## Cache key: content + version (#630)

The build-cache key is `persistent_cache_version_tag() | <content fingerprint>`,
where the version tag is:

```
v23 | cg-<codegen_fingerprint()> [cfg=<flags>]
```

- `v23` — a manual knob, bumped when the on-disk format or the meaning of a
  stored entry changes (a new envelope, a new TypeEnv transport version) so
  that every older entry cold-misses. The comment above
  `persistent_cache_version_tag` in `persistent_cache.vibe` records why each
  value was bumped.
- `cg-<…>` — a build-time hash of every compiler source file
  (`compiler_sources_manifest.tsv`), generated with the bundles
  (`cache/codegen_fingerprint.vibe`). Any change to emitted wasm / runtime ABI
  changes the compiler source, hence this segment, hence the key — so a codegen
  change automatically invalidates stale artifacts with no manual bump (#630).
- `cfg=<flags>` — present only when `VIBE_CFG` is set: the active `#cfg` flag
  set, in the caller's spelling. A module parsed under one flag set keeps
  different statements than under another, so each flag set is its own cache
  universe; a build with no flags keeps the tag it always had (#2513).

## GC policy (#631)

Cache entries are **content-addressed and append-only**: a store overwrites only
the exact same key, and a source/codegen change produces a *new* key, leaving the
prior file as an orphan. Nothing deletes orphans in place, so `.vibe/build/cache/vibe_*`
grows monotonically over a long editing session.

This is deliberate — automatic mid-build GC would need a per-build reachable-set
mark-sweep and risks evicting entries a concurrent build still wants. Instead,
reclaiming is an **explicit, first-class command**:

```bash
vibe clean                       # a project: remove .vibe/build entirely
pkf run cache-clean              # this repository: delete every persistent-cache entry
bash scripts/cache_clean.sh -n   # dry-run: report what would be reclaimed
```

`scripts/cache_clean.sh` removes only the persistent-cache files
(`.vibe/build/cache/vibe_*`, plus any `_build/vibe_*` rows left by compilers
from before #2675); generation builds, fixtures, the vpkg type stubs and
everything else are untouched. A full rebuild simply repopulates the cache.
Because the key already version-tags on every codegen change, a clean is never
*required* for correctness — only to reclaim disk.

For the compiler cache and the launcher's artifacts this repository is a
project like any other: they live under `.vibe/build/` here too, so there is
one rule, and the repository root has no `index.vpkg` (a root package would
make every loose source its member under ADR-0070, and the gates already run
from the root), so the current directory is the root. `_build/` stays for the
repository's own tooling — selfhost generations, bench and coverage output,
gate scratch, CI shard artifacts — which is repository infrastructure rather
than product behavior (#2001).

## Experimental ingestion fingerprint stamp (#1379)

`VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP=1` enables a narrow, metadata-only
optimization at the compiler's `fingerprint_file_fs` helper. On a fresh process
memo miss, it may reuse a compact build fingerprint only when the current
`Fs::stat_token(path)` **text** exactly equals the stamped token. The v1 payload
contains only that token and `len:h1:h2`; it never stores raw source, a
transformed facade, or a source prefix. The key is compiler-version and
resolution-seed scoped, length-delimits the logical path, uses a dedicated
namespace, and honors `VIBE_BUILD_CACHE_DIR` rebasing.

This is an explicitly opt-in performance hint, not a source cache and not a
semantic identity change. Stat tokens are a trusted-stat limitation: an
out-of-band modification that preserves a runner's token can reuse a stale
fingerprint. In particular, direct loader/source reconstruction reads still
occur and are authoritative; a stamp does **not** mean all host source reads
disappear. Missing, malformed, truncated, wrong-version, token-mismatched, or
torn stamps fail closed to the usual disk read and hash. Official Rust and Node
runners implement the `Fs::write_file` publication atomically; the language Fs
contract does not universally promise this, so non-official runner corruption is
also treated only as a miss.

For check-only measurement, request the separate compiler-owned sidecar with
both `VIBE_INGESTION_TELEMETRY_OUT` and a non-empty control-free
`VIBE_INGESTION_TELEMETRY_NONCE`. It reports `String::length` **string units**
at this helper (`source_read_string_units`, `hash_input_string_units`, and stamp
text units), not raw bytes. Runner `host_fs_scope` remains a separate aggregate
raw-byte boundary observation. The sidecar is rejected outside
`VIBE_CHECK_ONLY=1`, stale requested output is removed before CLI early returns,
and publication after a successful check is required before the final `ok`.

## Concurrent publication

Append-only keys avoid invalidation races but do not by themselves make a write
atomic. Artifact entries are published in one host call, `Fs::write_bytes`
(`store_artifact_envelope_at` in `lib/@vibe/cache/cache.vibe`), and both
official hosts make that call atomic: `scripts/wasm_vibe_host_runner.js`
(`atomicWriteFileSync`) and `runtime/viberun` (`vibe_atomic_write`) write a
pid+nonce-unique temporary file in the destination directory and rename it over
the target. A concurrent reader therefore sees the old complete file, the new
complete file, or a miss; concurrent writers of one key last-write-win as
complete files. Each artifact is also wrapped in a length-validated envelope
(`VART1` + payload length, #1326), so a torn read that some other runner could
still produce decodes as a miss rather than as truncated bytes.

The guest itself does no temporary-file dance: an earlier guest-level
tmp+rename was the only shared mutable temporary in the picture, and two guest
writers of one key could rename each other's temporary away (#2402 review).
A per-key single-flight table could avoid duplicate work but is not required
for correctness. Automatic mid-build GC remains out of scope because it has
the stronger cross-build reachability problem described above.

## CI caches

`.github/workflows/ci.yml` persists these caches across runs via
`actions/cache`:

| Cache | Path | Key | Why it's safe |
|-------|------|-----|---------------|
| Seed artifact | `bootstrap/seed/compiler.wasm` | `seed-artifact-` + hash of `bootstrap/seed.json` | pinned release asset; the manifest hash IS its identity, and `scripts/ensure_seed.sh` re-verifies the sha256 after restore |
| Generated compiler files | the five generated files under `lib/@vibe/compiler/` plus `.generated.stamp` / `.generated.inputs` | `gen-v1-` + `bash scripts/ensure_generated.sh --print-fingerprint` | the fingerprint covers every input of the generation ([bootstrap.md](bootstrap.md#generated-compiler-files)) |
| Shard stage2 | `_build/_ci_shard_gen/` | `stage2-v2-` + the same generated-files fingerprint + hash of `scripts/generations.sh` and `scripts/wasm_vibe_host_*.js` | the stage2 build is a deterministic function of exactly those inputs. The `compiler-build` job builds it once per run from the generated flat module source and uploads it; the shard jobs download that artifact instead of building their own |
| Persistent compile cache | `.vibe/build/cache/vibe_selfhost_*` and the unit runner's `_build/vibe_unit_out_cache` | `vibecache-v2-` + hash of `cache/codegen_fingerprint.vibe` + shard + run id (restored by prefix) | every cache row already folds the codegen fingerprint into its own key (see above), so rows from another compiler version are ignored on lookup — restoring can never serve a stale artifact |

The unit-test battery itself is split across parallel matrix jobs with
`VIBE_UNIT_TEST_SHARD=i/N`; the partition is weight-balanced from
`scripts/unit_test_weights.tsv` (regeneration procedure in that file's
header). Isolated per-test cache roots (`VIBE_BUILD_CACHE_DIR`) let the
cache-inspecting tests run inside the parallel fan-out instead of a
sequential tail — except the few tests that assert on the default root's own
semantics, which stay sequential (see `strict_cache_tail` in
`scripts/unit_test_runner.sh`). [ci-speed.md](ci-speed.md) has the cost model.
