# Negated cfg declarations: #2498 prerequisite

`#cfg(not(flag))` selects a fallback using the same active flag set as
`#cfg(flag)`. This lets a feature's real implementation and its fallback
share an API without a second, independently configurable flag. All five
parser directive consumers use the same polarity-aware membership check.
The recovery parser also reports directive and inactive-body syntax errors
instead of silently discarding them.

This is a prerequisite for #2498, not completion of telemetry separation.
The measurements used `seed/process-exit-op-2026-11-05`, and the compiler
declarations in that experiment kept the new syntax inside test source
strings. The current `seed/cfg-negation-2026-11-09` also resolves negated guards
during bootstrap, enabling the subsequent compiler-source migration.
No new effect, ambient configuration cell, or runtime sink policy is added.

## Artifact and behavior checks

Base: `0d71f8814720cec2a58cb15cb24acac78ac59e50`. Both artifacts were built
with `VIBE_WASM_NAMES=1`, using `ensure_generated.sh` followed by
`generations.sh build --stage3` with the freshly generated module source.
Both named stage2/stage3 pairs match byte for byte. Hashes, function counts,
source hashes, and all timing samples are in [results.json](results.json).

A real compiler invocation rejected the new syntax before the change.
Afterward, flat and imported-module probes were compiled with flags off,
on, then off again, sharing each probe's persistent cache. Each produced
and executed a named Wasm: the disabled artifact returned `7` and had no
`telemetry_encoder` function; the enabled artifact returned `101` and kept
its five-byte function body. Repeated disabled outputs were byte-identical.
This proves selection on the probe artifacts, not absence of telemetry from
the full compiler.

The added parser tests fail on two verified source mutations: ignoring the
negation and removing the recovery diagnostic write. Both mutations were
restored, and the restored test passed. Unit tests cover explicit and ambient
flags, trailing file-local enables, all parser entry points, source spans,
whole impl blocks, malformed conditions, the positive flag named `not`,
module-source emission, and formatter retention/fixpoint.

## Controlled walltime and allocation comparison

N=3 per compiler, corpus, and cache temperature; 24 fresh Node processes.
Each cold run used a fresh private cache and its warm run reused only that
cache. The order was AB / BA / AB. Compiler, cache, and output paths were
literally identical across variants. No other build or test ran during the
measurement. Both compilers compiled the same post-change source tree.

| corpus | cache | baseline wall | candidate wall | heap-pointer delta |
| --- | --- | ---: | ---: | ---: |
| compiler | cold | 9.111 s | 9.102 s | -5,760 B |
| compiler | warm | 4.795 s | 4.796 s | -1,864 B |
| CLI | cold | 19.119 s | 19.143 s | -11,728 B |
| CLI | warm | 10.495 s | 10.575 s | -5,032 B |

Wall changes are below 0.8%; no speedup is claimed. `heap_ptr` is the bump
high-water pointer, including static data, not live memory or RSS. These
small differences are effectively neutral. All 24 generated Wasm outputs
match within their corpus. The named compiler grows by 801 file bytes and
601 code-section payload bytes (599 function-body bytes, one function).

Reproduce with explicit named full compilers, on an idle machine:

```sh
python3 bench/perf/experiments/cfg-negation-2498/measure.py \
  /absolute/baseline/stage2.wasm /absolute/candidate/stage2.wasm \
  _build/cfg-negation-new-measurement
```

## Regression validation

The rebuilt candidate passes 315 targeted tests (six files, 105 tests on
each of bump, RC, and RC-shadow) and all 2,043 active unit-test files with
the normal allocator setting, four workers, and the compiled-output cache
disabled. The ordinary `pkf run release-check -j 1` passed: 112 tasks, 105
executed, seven cached, 60m12s, including the release fixpoint and whole-compiler
RC bootstrap. The PR records the actual repository commit-hook result.

The freshly rebuilt named compile-only compiler also compiled and executed
the imported-module probe on bump and RC, with the flag off and on. All four
runs select the expected implementation and keep the encoder only when enabled.
Its artifact hash and per-case results are recorded in results.json.

An initial whole-corpus attempt forced bump mode and was stopped after four
inline-Wasm ABI fixtures failed. These assume the tagged calling convention:
the baseline and candidate both fail them in bump mode and produce
byte-identical Wasm for each. The normal full corpus was rerun successfully;
these controls and the unchanged outputs are included in results.json.
