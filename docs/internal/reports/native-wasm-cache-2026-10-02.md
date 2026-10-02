# Native runner code cache: validation latency

The previous compiler optimization spent 52m57s in `release-check`. Its
separate unit-test compile batch took 620.05s for 1,560 files. These are
historical, single-run workflow observations, not paired performance results.
They motivate measuring validation work in addition to compiler guest work.

The native runner prepared the same stage2 Wasm from scratch for each fresh
process. A lightweight real grep command took approximately 462ms with the
portable Wasm and 7.6ms with an image produced by that same runner's existing
`--precompile` command. Both returned the same file listing. Preparing the
image once cost 441ms. This identified repeated native compilation as a
removable cost without changing the compiler guest.

## Change

Enable Wasmtime 47.0.2's built-in compiled-code cache on the shared engine
configuration. Wasmtime keys code by input bytes and compilation settings,
including compiler identity. A fresh Store, guest state and host bindings
are created on every invocation. This also covers the component and daemon
engines derived from that configuration. Existing `.cwasm` loading stays on
its existing path; this change adds no custom deserialization.

`VIBE_NATIVE_CACHE=0` disables the cache. `VIBE_NATIVE_CACHE_DIR` selects an
isolated root; relative roots resolve against the process working directory.
Its `viberun-native` child is the directory Wasmtime owns, so cleanup cannot
remove neighboring caller files. Otherwise Wasmtime's default cache directory and cleanup settings
apply. Unavailable cache storage falls back to normal compilation. Corrupt
entries are rebuilt by Wasmtime. This is independent of the compiler's
`VIBE_BUILD_CACHE_DIR` and persisted source/module products.

## Measurement protocol

The fixed compiler is the stage2 from PR #3268, SHA-256
`6be3a8b0c2a2fb7a85849e017c83290c3ae9402a59122c44e177d728e2f86e89`.
Both configurations use exactly the same native runner executable. Lane `a`
disables its native cache; lane `b` enables it. The machine is idle, with no
builds or test suites running alongside measurements. Four pairs alternate
AB/BA. Reported medians are the upper middle element, matching the compiler
measurement collector.

The startup input is `fixtures/array_test.vibe`, selected by this command:

```sh
viberun stage2.wasm grep --pattern 'Array::push($(a:exp), $(b:exp))' \
  --list-files fixtures/array_test.vibe
```

Each lane starts with an empty, equal-length native cache path and then runs
the same command a second time in that directory. All outputs agree.

The application-scale probe is the unmodified
`scripts/check_grep_driver_parity.sh`, with `GREP_PARITY_STAGE2` pointing to
the same compiler. Every whole gate starts with an empty native cache, so
its first compilation and cache publication are included. The gate creates
isolated guest caches itself, exercises both drivers, checks plain/JSON and
chunk boundaries, and tests memory-budget handoff and advertised flags.
Each invocation must pass every property.

Final paired samples, executable identities and receipts are recorded in
`bench/perf/analysis/native-wasm-cache-2026-10-02.json`.

## Results

| Probe | Cache disabled | Cache enabled | Change |
| --- | ---: | ---: | ---: |
| Fresh native cache, first startup | 459.0ms | 516.9ms | +12.6% (+57.9ms) |
| Same native cache, second startup | 476.2ms | 29.8ms | -93.7% |
| Whole grep driver-parity gate, fresh native cache | 39.671s | 30.297s | -23.6% |

The enabled gate includes its first cache publication. Every property passed
in all eight paired gate runs. The startup's initial cost pays back on the
second invocation of that Wasm.

A separate native compile of the same `fixtures/array_test.vibe` with isolated
cold/warm guest caches produced byte-identical 8,750-byte Wasm in every lane
(SHA-256 `ca1db6f8e8532541f33369a4935fd15f3857d441f37519fee01fcba326046196`).
Fuel, allocated bytes, heap frontier and committed memory match between
native-cache enabled and disabled at each guest cache temperature. Fuel
instrumentation remains enabled and gets its own compiled-code cache entry.

## Scope of the result

This changes native preparation time, not the compiler's algorithm or guest
allocation volume. It does not claim a percentage improvement to the full
52m57s release-check, the Node compile daemon, or peak-live compiler memory.
The cold startup includes cache publication and can be slower than disabling
the cache; repeated processes using the same Wasm amortize that cost.

## Regression validation

Seven Rust unit tests prove reuse across engines with fresh guest state,
changed bytes at the same path, fuel configuration separation and continued
metering, unavailable/disabled storage, corrupt entry recovery, and concurrent
writers and isolation from neighboring files. Three subprocess tests prove the actual runner entrypoint populates
the cache, still executes a changed trapping module, recovers corrupt code,
handles disabled/unavailable storage, and confines cleanup to its namespace. The entrypoint test fails against
the pre-change runner because that runner creates no native cache.

`cargo test --manifest-path runtime/viberun/Cargo.toml` passes all 37 unit
tests and all three integration tests. The regression task runs the same std-only
integration source against the existing release runner, using `rustc --test`.
This avoids relinking the runner because restored Cargo source mtimes changed.
It is required by `release-check` and runs in the CI job that already prepares
the native runner.

`pkf run release-check --timing` passes: 119 tasks, 54 run and 65 cached.
PKF reports 20m34s; the external process timer records 1,358.365s. The cached
compiler-gate log is replayed, so it is not credited as a new gate run. A
fresh seed → stage1 → stage2 generation was built, and its stage2 matches
the fixed compiler used by the measurements. A fresh forward stage3 compiled
from that stage2 with the generation defaults is byte-identical to stage2;
the complete seed → stage1 → stage2 → stage3 chain is recorded in the raw report.

The timing table identifies remaining work in this checkout:

| Executed task | PKF task time |
| --- | ---: |
| `generation` | 4m45s |
| `check-compile-only-lanes` | 2m50s |
| `test-check-grep-driver-parity` | 2m16s |
| `test-check-grep-memory-budget` | 1m59s |

These are one-run workflow observations, not new optimization percentages.
The full timing table is retained in the raw report. The prior 52m57s run
had 104 executed and 14 cached tasks; comparing those totals would mix
validation cache conditions.
