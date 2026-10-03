# Precise imported Show-wrapper metadata — 2026-10-03

Issue [#3257](https://github.com/mizchi/vibe-lang/issues/3257) removes inert
render rows introduced by the split compiler's wider import surface. On one
immutable post-#3254 compiler input, three alternating A/B pairs reduce bump
heap high-water by 4.21% cold and 4.47% warm. With complete checked-module
reuse enabled, the reductions are 3.40% and 2.87%. Every emitted user Wasm is
byte-identical. Reserved linear-memory pages are unchanged.

Raw samples, selectors, compiler/source hashes, telemetry and cache-carrier
counts are in
[`bench/perf/analysis/imported-show-wrapper-metadata-2026-10-03.json`](../../../bench/perf/analysis/imported-show-wrapper-metadata-2026-10-03.json).
Full `pkf run release-check` passes, including the compiler gate and every
required companion self-test. AST-required staged pre-commit passes. These
measurements and validation use the pre-rebase base below; fresh validation
and A/B measurement will accompany publication against current main.

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
Eight counter/control cold/warm observations preserve user Wasm; enabling the
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
and disabled AST/body caches. Each round/mode/compiler has a separate empty
cold cache; its warm sample consumes that populated cache. A/B order alternates.

| Checked-module cache | Temperature | Baseline bytes | Candidate bytes | Delta |
|---|---|---:|---:|---:|
| Off | Cold | 1,021,933,464 | 978,925,096 | -43,008,368 (-4.21%) |
| Off | Warm | 619,047,136 | 591,347,880 | -27,699,256 (-4.47%) |
| On | Cold | 1,321,263,592 | 1,276,286,088 | -44,977,504 (-3.40%) |
| On | Warm | 1,467,494,832 | 1,425,448,816 | -42,046,016 (-2.87%) |

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
all nine pass. Seven transport tests exercise cached canonical facts, text and
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
`fb4ac8e9e11c7bca7f24010d9a644a7c4d58c3716d4221ecd67e020b6d1336f6`.
The default production KPI uses the current input tree, separately from the
fixed-tree A/B experiment. Three ordinary cold invocations agree on
977,159,096 bytes and 18,663 pages. The committed baseline ratchets down from
1,019,539,416 to 977,159,096 with its +10% tolerance intact; the historical
baseline difference is not attributed wholesale to this patch.
