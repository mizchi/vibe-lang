# Recursive compiler cache encoding (2026-10-01)

Issue: [#3258](https://github.com/mizchi/vibe-lang/issues/3258).
Base: `09c4f2eb0` (the merged source split, #3254).

## Implementation and byte contract

The environment encoder owns one sequence of String pieces. For each nested
length-delimited type, type expression, or definition, it reserves a prefix
slot, emits the children once, and fills the slot with the measured byte
length. Nested prefixes count toward their parent's length. The final join
copies the payload once. Prefix Strings and piece-array capacity are included
in every allocation measurement; this is a segmented writer, not a claim of
constant space. Its pieces live for one encoding call.

The same writer emits every Type, TypeExpr, TypeDef, TypeEnv, generic bound,
trait method, and binding-origin variant. EnvCached still rebuilds its index
from the authoritative chain, once, and emits its canonical order. Its type
rows no longer need a temporary plain-Type array.

The lowering encoder appends directly to the caller's pieces. It feeds the
body digest incrementally with the exact row bytes, including the newline
between body rows. It retains the existing two moduli, seeds, and absolute
byte position in the second hash. Header and count lines remain outside the
digest. There is no joined digest-input String, second body array, separate
equality-row String, or intermediate lowering payload in a combined record.
The decoder retains its independent compact_string_fingerprint calculation.

Wire versions are unchanged: v9 worker/dependency transport, v10 combined disk
records, and the lowering section's v8 count/digest/end-marker envelope.
Missing lowering remains distinct from a checked empty table. No metadata is
dropped; the default compile still leaves experimental TDRE9 off.

## Evidence

Canonical literals captured from the base compiler before editing the encoder
pin every recursive variant, provenance kind, generic/trait field, and a stale
accelerator. Another literal pins complete v8 bytes and its digest. Empty,
offset-only, equality-only, and multibyte digest inputs are cross-checked with
the independent decoder. Existing deletion, mutation, truncation, duplicate,
foreign-version, and missing-versus-empty refusals remain covered.

Allocation assertions failed on the base implementation and pass after the
change. These numbers use the bump lane on both sides; an RC heap high-water
is not a measure of cumulative allocation because freed blocks may be reused.

| Probe | Output bytes | Base allocation | Candidate allocation |
| --- | ---: | ---: | ---: |
| 24 nested signatures with a 4 KiB name | 4,827 | 674,964 | 14,452 |
| 512 offsets and 512 equality rows | 155,140 | 948,344 | 228,960 |

## Controlled compiler workload

Command: `node scripts/compare_compiler_memory.mjs BASE CANDIDATE OUT 3 closure`.
The input is codegen_lexer_test.vibe in one fixed candidate source tree.
Compiler paths have equal length; each cold sample starts with an isolated
empty cache, and its warm sample reuses only that cache. Order alternates AB/BA.
The compiler binaries use bump allocation; the generated target is linear RC.
All twelve outputs are byte-identical, SHA-256
`13f9eb8a1f99817d95471e2d2ba1225fe876e41f0cbc7ff841527fb2579d23b1`.

An A/A control with the same candidate in both equal-length artifact slots
agrees exactly for cold and warm allocation. The control was collected after
the paired comparison, before regression jobs; it is not a timing baseline.

| Temperature | Base heap_ptr | Candidate heap_ptr | Difference | Median wall |
| --- | ---: | ---: | ---: | --- |
| Cold | 1,108,536,888 | 1,093,713,496 | -14,823,392 (-1.34%) | 3.465 → 3.464 s |
| Warm | 652,304,088 | 652,312,920 | +8,832 (+0.0014%) | 2.517 → 2.498 s |

The cold allocation win is 14.14 MiB. Warm does not rewrite the same cache
payloads and is nearly unchanged. The wall differences are small; no speedup
is claimed. These samples ran without concurrent compiler builds or suites.
Raw samples, selectors, source identity, artifact hashes, and A/A results are
in [the measurement artifact](../../../bench/perf/analysis/cache-streaming-2026-10-01.json).

Stage2 size is 3,874,793 bytes (base: 3,875,476, -683 bytes). Stage2 and stage3
are byte-identical:
`3ab79d52ca1f8918eef18063743fd83c3f6229d904a8de5e30e683b08837a88d`.

The ordinary default-target KPI gives 1,092,576,408 bytes in three cold runs.
The allocation ratchet moves down from 1,107,397,680 to that value, keeping
the existing 10% tolerance. Those KPI runs overlapped regression work, so their
wall times are not performance evidence. Explicit VIBE_RC=0 changes the target
and gives 975,440,056 bytes; that number is not the default KPI baseline.

## Validation

- Fresh stage2: 41 codec tests pass on RC; allocation probes also pass on bump.
- Compiler gates: early, mid, and late pass, including cache-state output parity.
- Full unit corpus: 1,547/1,547 active unit-test files pass with the fresh stage2.
- All maintained source files remain within 3,000 lines.

The remaining interface and rendering costs belong to #3256 and #3257. Callee
identity is tracked separately in #3255.
