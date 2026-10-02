# Effect callable-body index — 2026-10-02

## Problem and measured scope

After indexing large checker environments, a named-artifact profile of the
current full flat compiler input spends 2.932 seconds (9.65% of sampled self
time) in `afe_lookup_callable_body`. Every request scans all collected callable
rows, even after finding a match, because multiple definitions of one name must
remain ambiguous. Most of this work comes from handler-payload inference.

The baseline is `ce9d911ec818eb148d321c7e4132e8ce19d00293` (PR #3273). Its
compiler and generated input were frozen before changing the implementation.
The controlled comparison compiles that same frozen input with both artifacts;
it does not compare different compiler programs or warmed default caches.

## Change and semantics

Keep the ordered body table and index its names during collection. A one-based
row ID identifies a unique body; zero records ambiguity. A second definition
sets zero even when both bodies are identical. Recursive module collection and
both statement forms feed the same registration helper.

The index lives in a module-level mutable cell and is replaced by the existing
entry-memo reset. All three checker entries reset it before collecting their
own bodies. Lookup reads the indexed row from the authoritative body table and
returns `None` for an absent or ambiguous name. Additional collection updates
the index immediately, including names previously queried as absent.

This preserves the existing conservative name-based body resolution. The
optimization does not grant a body to an ambiguous name or change payload,
reachability, recursion, or lexical-scope rules.

## Controlled comparison

Three alternating AB/BA pairs for each configuration, on an idle WSL machine
with Node 24.7.0. Compiler, cache, and output paths have equal length across
lanes. The flat artifact cache is disabled; each FS pair uses a fresh cache for
its cold invocation and the same cache in a fresh process for its warm repeat.
All six flat outputs and all twelve FS outputs are byte-identical within their
respective corpora. Elapsed time is measured with `time.monotonic`.

| Corpus / cache | Before median | After median | Time delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| Full flat compiler / uncached | 30.180 s | 27.094 s | −10.2% | +0.0961% |
| Codegen lexer test / FS cold | 4.681 s | 4.700 s | +0.42% | +0.1166% |
| Codegen lexer test / FS warm | 3.029 s | 3.027 s | −0.08% | +0.000294% |

FS time deltas are below the noise floor. Full-flat allocation high water is
2,072,352,028 → 2,074,343,644 bytes, about 1.99 MB more. Reserved linear memory
is unchanged in all three configurations. RSS medians are +0.29% flat,
+0.77% FS cold, and +0.22% FS warm; RSS is not a deterministic allocation
metric. This is a CPU improvement with a small allocation cost.

The diagnostic profile reduces the lookup's sampled self time from 2.932
seconds to 9.565 milliseconds. The whole-time claim uses the controlled
interleaved samples, not the single diagnostic profiles.

## Validation

Six new tests exercise real handler-payload inference through existing public
checker APIs: unique/missing names, duplicate names in both orders and identical
duplicates, nested modules and function declarations, additional collection,
sequential programs, and expression/statement entry resets. They pass on the
baseline and candidate. All 55 existing async-effect tests and six entry-memo
tests pass on the candidate, including transitive and recursive payload paths.

A fresh fixed-seed → stage1 → stage2 → stage3 build converges. Stage2 equals
stage3 with names enabled. The measured release artifact removes only the name
section and retains `vibe.abi`; its SHA-256 is
`8b0c12c875c4f492761e1106e9eede77da77d1ef11a1784c8fc9e7c5e239b077`.
That generation skipped run-validation; the targeted tests above are separate.
Full release-check passes: 121 tasks, 107 run and 14 cached, in 45m33s.
Its fresh compiler passes the compiler gate and is byte-identical to the
measured release artifact. AST-required staged pre-commit also passes with the candidate compiler.

## Reproduce

Build a baseline stage2 and generated flat source at commit
`ce9d911ec818eb148d321c7e4132e8ce19d00293`, and build candidate stage2 from the
same pinned seed. Place the baseline compiler, generated flat source and
candidate compiler at `_build/afe-callable-index/baseline.wasm`,
`_build/afe-callable-index/baseline-flat.vibe`, and
`_build/afe-callable-index/candidate.wasm`. Use release artifacts with names
stripped. Keep other compiler jobs idle.

With Python and Node 24.7.0 available, replay the recorded harness:

```bash
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("bench/perf/analysis/effect-callable-body-index-2026-10-02.json").read_text())
exec(compile(report["reproduction_python"], "effect-callable-body-reproduction", "exec"))
PY
```

The replay creates a fresh output directory. The raw report records each
invocation, environment, sample, producer/artifact identity, profile summary,
validation receipt and the runnable harness.
