# Batched source embedding in compiler generation

A local `generations.sh build` observation took 329.951s. Its existing trace
attributed approximately 59s to the two adapter-bundle passes and the compiler
sources bundle. Each pass started Python separately for every source file.
These observations select the target; the optimization comparison uses the
controlled experiment below.

The generator now sends ordered binding/path/file triples over NUL-delimited
stdin and starts one Python interpreter per pass. The helper retains the
existing source filtering, contract declarations and string escaping. It
streams one source function at a time. The seed validation compile remains.
The helper is included in the generated-artifact freshness fingerprint.

The measurement alternates AB/BA for three pairs, using separate project
snapshots with equal-length paths. Each starts without its merge-flatten
compiler, then repeats with that tool available. Both receive identical
initial generated library products. Persistent guest artifact caching is
disabled. Every invocation runs the full generator and its seed validation;
all five regenerated products must agree byte-for-byte across all lanes.

Whole-generator durations use Python `time.monotonic`. Existing trace spans
use system wall time; one backward span is retained in raw evidence and
excluded from phase attribution. No percentage comes from those wall spans.

## Results

| Full generator, merge tool state | Before | After | Change |
| --- | ---: | ---: | ---: |
| Cold merge tool | 200.905s | 144.347s | -28.2% |
| Warm merge tool | 134.379s | 79.080s | -41.2% |

Each cell is the median of three independent samples. Every invocation passes
the seed validation compile. All five products agree in all twelve runs and
also match the initial source-checked products. The emitted adapter module
source remains the exact 11,028,387-byte input used by the current stage2
compiler (SHA-256 `46a20ed75f40768d224f1cafe529deb592bd529feb70ae9a0e7528f0c9bb7268`).

This removes process setup in source preparation. It changes neither the
compiler algorithm nor the generated Vibe program. The percentages describe
the full bundle generator, including mandatory seed validation and, on the
cold lane, rebuilding the merge tool. They are not percentages for the whole
release check, or for compiler guest allocation. Generation and compile-only
artifact builds both consume this generator.

## Regression checks

Nine tests cover raw and filtered source text, Unicode, quotes, backslashes,
CRLF, empty sources, final-newline preservation, ordering, multiline imports,
contract declarations, NUL-delimited paths, malformed/missing inputs, and a
producer edit making an otherwise current generated-artifact stamp stale.
The tests fail when contract declarations are stripped or when the helper is
removed from the freshness fingerprint. The task is required by release-check
and CI runs the tests before preparing the compiler products.

The raw sample report retains producer identities, seed identity, artifact
hashes, every output and trace, mutation receipts and the reproduction script.

Full `pkf run release-check --timing` passed before and after integrating main:
119 tasks (106 ran, 13 cached), then 120 tasks (56 ran, 64 cached). The first
run executed the compiler gate and its fresh seed-to-stage3 fixpoint. The
integrated run reused that verdict, built a fresh seed-to-stage2 compiler,
and was followed by a separate fresh stage2-to-stage3 compile. Both stages
are byte-identical to the original compiler (SHA-256
`6be3a8b0c2a2fb7a85849e017c83290c3ae9402a59122c44e177d728e2f86e89`).
All five final generated products still match the measured products.
The release timings have different cache states and are validation receipts,
not an A/B performance comparison.

AST-required staged-snapshot pre-commit passed with the integrated tree's
explicit stage2 compiler.
