# Compiler unit boundaries: what crossing each one costs today — 2026-11-09

Part of #2507. The first bounded step that #2507 names is to choose one real
boundary and measure its current encode/decode/live-set cost before extracting
any unit. Two of its four proposed boundaries already have a production
transport behind a flag. This report measures both on the same compiler, under
one protocol.

| boundary (#2507) | transport that exists today | selector |
|---|---|---|
| 1. frontend: source → binary AST | per-file AST cache, `selfhost_ast_v1` ([format](../compiler/ast_binary_abi.md)) | `VIBE_EXPERIMENTAL_AST_CACHE=1` |
| 2./3. checker → lowering/codegen | checked-module artifact ([design](../compiler/checked-body-transport.md)) | `VIBE_CHECKED_MODULE_CACHE=on` |

Neither boundary is a separate build unit yet. Each is a persistent artifact
that one process writes on a cold build and reads on a warm one, so the encode
side and the decode side are both visible.

**Result.** The frontend transport is affordable. It is the only one of the two
that is.

- **Frontend (boundary 1)** adds 12.4 MiB of artifacts to the compiler's own
  cache.
  - Writing them costs +3.9 % wall and +2.3 % heap on a cold build.
  - A warm build that reads them is wall-neutral (+0.6 %) and slightly smaller
    (−2.6 % heap).
- **Checker (boundary 2/3)** is a large loss in both directions: +54.7 % wall
  and +130.5 % heap on the warm build that should benefit.

## Protocol and provenance

- **Source:** main `c000874cc643b54e414a0e6f6d233c628ee6ad92`.
- **Stage2:** built from that commit by `scripts/generations.sh build`,
  sha256 `849db722a05885c47775ee9384f1060879d2357a29a9e248433b29d011c9e58b`.
- **Tool:** `scripts/checked_module_cache_cost.mjs`. #2507 adds `--cache ast`,
  which runs the same protocol over the per-file AST cache.
- **Raw record:** every sample is in
  [compiler-unit-boundaries-2026-11-09.json](../../../bench/perf/analysis/compiler-unit-boundaries-2026-11-09.json).

Protocol (the tool's own rules, enforced per sample):

- One isolated `VIBE_BUILD_CACHE_DIR` per (round, corpus, lane). Each cold build
  starts empty, and its warm build reuses only what that cold build wrote.
- Telemetry must show each sample is what it is called:
  - a cold build reuses 0 modules;
  - a warm `off` build reuses through today's conservative lane;
  - the warm `on` build reuses through the measured cache. For the AST lane this
    is `ast_cache_prefetches`; for the checked-module lane it is
    `modules_reused_checked_module_artifact`.
  - Every warm build reused **every** planned module: 722/722 on `cli`,
    380/380 on `closure`.
  - The `on` lane's cold build must also publish its artifacts. It published
    one per module.
- Both lanes must emit byte-identical wasm. They did, for every sample.
- Rounds and lane order: 3 rounds, lane order alternated per round. Tables give
  medians; the raw record keeps every sample.
- The cache that is not being measured is held off. Its two AST caches are not
  meant to run together.
- Body cache: off.
- `heap_ptr`: the compiler-owned bump frontier, the number the memory KPI is
  stated in.
- Peak RSS: not measured, because this host has no `time(1)`. The raw record
  says so.
- Host: Intel Xeon @ 2.10 GHz, Node v22.23.4. Wall times are single-host and
  advisory.

Corpora:

- `cli` is the compiler's own CLI closure, `lib/@vibe/cli/entry.vibe`
  (722 modules).
- `closure` is `lib/@vibe/compiler/tests/codegen_lexer_test.vibe`
  (380 modules).

## Frontend boundary: per-file binary AST

| corpus | build | wall off → on | heap off → on | cache dir off → on |
|---|---|---:|---:|---:|
| cli | cold | 27.25 s → 28.32 s (+3.9 %) | 2518 → 2575 MiB (+2.3 %) | 167.1 → 179.5 MiB |
| cli | warm | 16.70 s → 16.79 s (+0.6 %) | 1518 → 1479 MiB (−2.6 %) | 167.1 → 179.5 MiB |
| closure | cold | 13.90 s → 14.08 s (+1.3 %) | 1255 → 1285 MiB (+2.4 %) | 72.6 → 79.1 MiB |
| closure | warm | 8.04 s → 8.09 s (+0.7 %) | 746 → 718 MiB (−3.7 %) | 72.6 → 79.1 MiB |

**Encode side** (cold, which reads nothing back):
- It writes 12.4 MiB for the 722-module CLI closure, about 17.6 KiB per module.
- It costs 57 MiB of heap and about 1 s of wall.

**Decode side** (warm):
- It replaces every merge-lane parse with a load.
- The wall difference (+0.6 %, +0.7 %) is inside the round-to-round spread of
  the `off` lane itself. For example, the warm `off` CLI samples range from
  16.6 s to 17.1 s.
- The 39 MiB / 28 MiB heap reduction is real: the frontier is deterministic.

So what crosses this boundary is small, and decoding it is cheaper in memory
than re-parsing. But it buys almost no time.
[checked-body-transport.md](../compiler/checked-body-transport.md) profiled the
merge-lane parses it removes at about 133 ms of self time on the compiler's own
closure.

## Checker boundary: checked-module artifact

| corpus | build | wall off → on | heap off → on | cache dir off → on |
|---|---|---:|---:|---:|
| cli | cold | 26.88 s → 31.44 s (+17.0 %) | 2518 → 3440 MiB (+36.6 %) | 167.1 → 208.3 MiB |
| cli | warm | 16.28 s → 25.19 s (+54.7 %) | 1518 → 3498 MiB (+130.5 %) | 167.1 → 208.3 MiB |
| closure | cold | 13.56 s → 15.27 s (+12.6 %) | 1255 → 1656 MiB (+31.9 %) | 72.6 → 95.0 MiB |
| closure | warm | 7.73 s → 11.92 s (+54.2 %) | 746 → 1670 MiB (+123.9 %) | 72.6 → 95.0 MiB |

**Encode side** (cold): it writes 41.2 MiB for the CLI closure, about
58 KiB per module, 3.3× the AST lane's, and costs +922 MiB of heap.

**Decode side** (warm): it costs +1980 MiB of heap.

The warm `on` build's heap (3498 MiB) is **larger than a cold build without the
cache** (2518 MiB). So this transport is more expensive to read than doing the
checking it replaces.

[checked-body-transport.md](../compiler/checked-body-transport.md) recorded
+87 % wall / +61 % heap warm for this lane on an earlier compiler. The heap
ratio is now worse, while the reuse evidence is the same: every module was
served from an artifact. The causes it attributes still apply:
- the per-byte checksum;
- an input identity that copies every direct dependency's TypeEnv text;
- fields the reuse path never reads.

## What this decides for #2507

1. **The first unit to validate is the frontend**, if any unit is extracted. Its
   transport format already exists, has a decoder that fails closed (a torn or
   trailing-byte entry is a miss), round-trip and parse-equivalence tests
   (`ast_binary_*_test.vibe`), and a prefetch oracle that proves the warm lane
   reads it (`scripts/ast_cache_prefetch_oracle.mjs`). Crossing it costs
   +2.3 % heap and +3.9 % wall to encode, and is cheaper than parsing to decode.
2. **The checker → codegen boundary must not be the first one**, through today's
   checked-module artifact. Its decode side alone exceeds the cold build's whole
   heap. A checker unit needs a different interface first: one that carries
   only what the next consumer reads, without the dependency-text identity copy.
   It is not a matter of tuning this codec.
3. **Neither measurement proves a deployment property.** Both lanes run inside
   one process, and the artifacts round-trip through the persistent cache. The
   one-linked-module, phase-reset deployment #2507 proposes, its stale-state
   oracle, and the per-unit fixpoints (#2508) are still unbuilt. The heap
   numbers are a single bump frontier, not the simultaneous live set of
   separate Stores. Peak RSS was not measured here.

## Reproduce

```sh
bash scripts/generations.sh build --out-dir <dir>
node scripts/checked_module_cache_cost.mjs <dir>/stage2.wasm --rounds 3 --cache ast
node scripts/checked_module_cache_cost.mjs <dir>/stage2.wasm --rounds 3 --cache checked-module
```

`scripts/checked_module_cache_cost_test.sh` makes each acceptance rule fail
once, including the new one: an AST lane whose cache is not actually on is
refused for publishing no AST artifact. It then runs one green control per
cache.
