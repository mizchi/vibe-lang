# Shared dependency-interface views (2026-10-01)

Issue: [#3256](https://github.com/mizchi/vibe-lang/issues/3256).
Base: `9cd0af9c7`, the dependency-update correctness fix in
[PR #3262](https://github.com/mizchi/vibe-lang/pull/3262), on the merged
source split (#3254).

## Ownership and authority

Each filesystem or in-memory TypeDb walk owns a DependencyInterfaceSet.
Publication retains the actual successfully accepted environment. Its first
importer derives immutable flat bindings, definitions, selectable names,
trait names, uppercase binding slots, declared names and reference markers.
Later importers share those arrays. An ordinary warm walk that reuses the
checked products retains only the small product entries and derives no views.

The set is opaque at the package contract. Its arrays and memoized products
are private. Re-publication at the same path replaces the product and clears
all derived facts. The set lives for one check, with no global path memo;
standalone workers construct their own set. The resolver retains the exact
ordered dependency environments supplied to the job. Compatibility entries
construct views only for referenced dependencies.

Aliases, selected roots, declaration closure, collision state and diagnostics
remain importer-owned. The shared view does not memoize a selected projection
or identity closure. Accelerator arrays are not declaration authority: facts
come from the underlying chain, and provenance lookup also skips EnvCached's
index rows. Valid cached and uncached products have the same answers.

## Regression evidence

The new API fails to compile before implementation. The allocation regression
also fails when each lookup reconstructs the dependency view. Seven tests pin
independent aliases, replacement publications, independent selected type
names, authoritative types despite a stale index, foreign same-name collision
diagnostics, included construction cost, and provenance despite a stale index.
The provenance regression failed before the authoritative lookup change.

The dependency-update tests from PR #3262 check two importers, aliased
re-exports, hidden type closure, trait bounds and local shadowing on cold,
warm and edited graphs. They also reject an unchanged Int return after its
import becomes String, including a retry after a rejected check. This
correctness fix is part of both compilers in the comparison below.

The bump probe constructs the shared product and projects eight importers
from 1,024 existing dependency bindings. It allocates 46,288 bytes in total;
rebuilding on each lookup exceeds its 131,072-byte budget. RC also passes,
but its reused blocks make heap high-water unsuitable for allocation volume.

## Controlled workload

Command: `node scripts/compare_compiler_memory.mjs BASE CANDIDATE OUT 3 closure`.
Both compilers compile codegen_lexer_test.vibe from the same fixed candidate
source tree. Artifact slots have equal path lengths. Each cold sample starts
with an isolated empty cache; only its corresponding warm sample reuses it.
Order alternates AB/BA, with fresh processes. The compiler binaries use bump
allocation and the emitted target is linear RC. Publication and view
construction costs are included. No build or suite overlapped these samples.

| Temperature | Base heap_ptr | Candidate heap_ptr | Difference | Median wall |
| --- | ---: | ---: | ---: | --- |
| Cold | 1,108,502,096 | 1,093,538,256 | -14,963,840 (-1.35%) | 3.431 → 3.435 s |
| Warm | 652,293,904 | 652,337,512 | +43,608 (+0.0067%) | 2.491 → 2.475 s |

The cold saving is 14.27 MiB. Warm adds 42.6 KiB of bounded product ownership;
it does not construct projection arrays when no importer needs them. No
speedup is claimed. An A/A control collected before the regression jobs
agrees exactly in both temperatures; its directory path differs from the
paired run, so its absolute byte counts are not the paired baseline.

All twelve generated Wasm outputs are byte-identical across compilers,
rounds and temperatures: SHA-256
`13f9eb8a1f99817d95471e2d2ba1225fe876e41f0cbc7ff841527fb2579d23b1`.
A separate pair of cold compiles also produces 352 byte-identical combined
v10 records per lane, totaling 3,613,548 bytes. The comparison uses the entire
raw record-byte multiset; compiler namespace filenames are not compared.

The [raw artifact](../../../bench/perf/analysis/dependency-interface-views-2026-10-01.json)
retains selectors, source identity, artifact hashes, every sample, control
results and every cache record hash. This measurement isolates #3256 from
#3258; their savings must not be added without a combined measurement.

## Validation

Stage2 and stage3 are byte-identical:
`0cb783c63d23d8ca2fa4afee25bcb92ea9bbe6e199ac83b2be01ef3e2bf6a779`.
Fresh stage2 passes all ten targeted view and dependency-update tests on RC;
the seven view tests also pass on bump.

- Full unit corpus: 1,547 / 1,547 active files passed with the fresh stage2.
- Compiler gates: early, mid and late passed, including cache-state parity,
  rendering, nominal authority and imported trait checks.
- Formatter, strict AST review lint, architecture lint, documentation
  classification and path citations passed.
- All maintained source files remain within 3,000 lines.
