# Precise imported Show-wrapper metadata — 2026-10-03

Issue [#3257](https://github.com/mizchi/vibe-lang/issues/3257) removes inert
render rows introduced by the split compiler's wider import surface. On one
immutable post-#3254 compiler input, three alternating A/B pairs reduce bump
heap high-water by 4.21% cold and 4.47% warm. With complete checked-module
reuse enabled, the reductions are 3.40% and 2.86%. Every emitted user Wasm is
byte-identical. Reserved linear-memory pages are unchanged.

Raw samples, selectors, compiler/source hashes, telemetry and cache-carrier
counts are in
[`bench/perf/analysis/imported-show-wrapper-metadata-2026-10-03.json`](../../../bench/perf/analysis/imported-show-wrapper-metadata-2026-10-03.json).
The baseline and candidate are rebuilt on main
`f5391add9ee36afe0ab6ee62ef70aabfd1b717aa`, including #3296. AST-required
review lint passes against the complete main-to-candidate diff. The complete
`pkf run release-check` passes on this rebased tree (122 tasks, including the
compiler gate, every required companion self-test, documentation and
distribution checks).

## Measured cost

The old collector treats every imported/re-exported spelling as a possible
direct `__to_string(param)` wrapper. Most compiler imports are ordinary calls.
Their argument rows are valid type observations, but the renderer never reads
them. The fixed input persists 8,679 such render rows, with 693,324 bytes of
serialized keys. All lowering rows together occupy 1,067,356 bytes of text.

A private diagnostic compiler measures 22,870,612 inclusive allocated bytes
inside 628 cold render-collector calls. Lowering-memo publication itself uses
51,568 bytes; combined environment/lowering text encoding uses approximately
25.56 MB. The encoder figure includes the entire environment and all lowering
rows. Inclusive counter totals are not additive and do not predict the saving.
These attribution counters use the pre-rebase baseline. Eight counter/control
cold/warm observations preserve user Wasm; enabling the
counters changes whole-compile heap high-water by at most 24 bytes.

The optimization is measured with an ordinary compiler, including fact
classification, publication, serialization, loading and import projection.
No diagnostic counters, effect-check overrides or runner changes are present
in the measured candidate.

## Authority and transport

`EnvShowWrappers` belongs to the canonical module environment. It contains
precise wrapper names and separately records imported names whose metadata is
unavailable. An absent node keeps conservative collection; a present empty
set means that the published value surface has no wrappers. Cached lookup
rows supply no classification authority.

The same module publication factory derives local facts from the existing
direct-wrapper shape classifier and imported facts from the exact dependency
product. Local declarations override imported spellings. Facts are restricted
to the public value surface. Selected imports and re-exports project aliases
from that dependency's view, including surface-only aliases and qualified
names. Unknown facts remain unknown across further re-exports. The serialized
builtin-iterator boundary also retains unknown candidates.

The render collector combines local wrappers with selected known/unknown
dependency candidates. Ordinary imported calls no longer materialize render
rows. Actual wrappers retain their scalar/composite agreement checks.

Worker/dependency TypeEnv advances to v10, combined environment/lowering
records to v11, and `vCHK`/`vMOD` to v2. Text facts have a checksum over both
name lists. Binary payload checksums cover the new node. Old versions and
damaged metadata miss rather than becoming trusted empty facts. The global
cache namespace advances to v24; dependency transport aliases/witnesses use
TDRE10. The module-input field layout remains v1, with the new canonical
dependency environment bytes included in its identity.

TypeEnv scans that observe only typing treat the node transparently; transforms
and lossless transports preserve it. A wrapper-body edit can keep the exact
same function type while changing the environment transport and dependent
reuse keys. Complete artifact restoration republishes facts from its checked
program and current selected dependencies through the same factory.

## Fixed-input allocation comparison

The input is the tracked tree at `94da0d000e2e5c6c461bd6ee55cf3aa8c6041977`,
plus its five generated compiler files: 5,427 hashed files, verified unchanged.
The entry is `lib/@vibe/compiler/tests/codegen_lexer_test.vibe`. Each sample
uses a fresh Node host-runner process, a bump compiler, a linear-RC target,
and disabled AST/body caches. Both compiler artifacts use current main as
their source base; the immutable workload remains the earlier post-#3254 tree.
Each round/mode/compiler has a separate empty
cold cache; its warm sample consumes that populated cache. A/B order alternates.

| Checked-module cache | Temperature | Baseline bytes | Candidate bytes | Delta |
|---|---|---:|---:|---:|
| Off | Cold | 1,021,928,056 | 978,926,488 | -43,001,568 (-4.21%) |
| Off | Warm | 619,043,368 | 591,348,376 | -27,694,992 (-4.47%) |
| On | Cold | 1,321,257,760 | 1,276,288,432 | -44,969,328 (-3.40%) |
| On | Warm | 1,467,490,832 | 1,425,449,576 | -42,041,256 (-2.86%) |

Each value repeats exactly in all three trials. Compiler telemetry confirms
zero cold reuse, 314/314 warm reuse with the cache off, and 311/314 checked
artifact reuse with it on. The three remaining modules are rechecked.
All 24 user outputs have SHA-256
`8e1bd76763eaf5c86ae44ab7cf51cbaae96c6079a7f61b5371e6f4bed9a1bd6f`.

The 314 combined carriers now contain 28 non-render typed rows instead of
8,707 total rows: 8,679 render rows disappear on this compiler workload.
Typed-key bytes fall from 694,669 to 1,345, and lowering row text from
1,067,356 to 2,541 bytes. Every carrier's lowering counts and digest validate.
Total cache bytes fall from 4,129,831 to 2,938,804 off, and from 69,136,454 to
67,164,537 on; the latter retains 317 complete module artifacts.

This is allocation volume/high-water, not live RAM. Reserved pages remain
18,663 cold and 12,442 warm off, and 27,994 in both temperatures on. Wall
observations are retained as advisory data; no CPU/wall improvement is claimed.

## Validation and baseline

Four red tests on the original compiler catch ordinary imports, ordinary
aliases/re-exports and a same-typed wrapper-body edit. Three controls already
pass. The final import suite adds qualified names and unknown re-export facts;
all nine pass. Additional non-simple concrete renderers (a local alias, an
extra statement and a second parameter) preserve Double/Bool/Char rendering
and byte-identical Wasm. Unsupported erased-generic bodies are refused with
the same diagnostics by both compilers. Seven transport tests exercise cached canonical facts, text and
binary round-trips, unavailable versus empty facts, same-length corruption,
old versions and dependency-key freshness.

The real FS oracle asserts Bool, Double, Char, Unit, arrays, options and tuples
through generic imported wrappers, a qualified-name alias and two re-export
hops, and the real builtin `to_string` for Bool and Char. Cold/warm output
agrees with enabled checked-module reuse; warm restores 22 artifacts
(24 after the dependency-body edit). Changing only the dependency wrapper body from `__to_string`
to a constant retains its signature and leaves the consumer source untouched.
The rendered result changes correctly, then agrees warm. A verify-mode run
checks the cold/warm artifact result. The existing module-job oracle passes
real worker publication/import plus diagnostic and malformed-job controls.

Fresh final stage2 equals stage3, SHA-256
`87df48a987017f4e09edb5cb172f2e00a3db5bb6b4ae640545d7df869d5a3087`.
The default production KPI uses the current input tree, separately from the
fixed-tree A/B experiment. Three ordinary cold invocations agree on
977,343,584 bytes and 18,663 pages. The committed baseline ratchets down from
1,019,539,416 to 977,343,584 with its +10% tolerance intact; the historical
baseline difference is not attributed wholesale to this patch.

The full AST-required main-to-candidate review lint passes. The final release
record updates only documentation and benchmark evidence; compiler source
digests and the just-built fixpoint remain unchanged. Historical pre-rebase
A/B summaries are retained separately in the raw record.
