# Resolved Array callees — 2026-10-02

Implementation and measurement record for the next slice of
[#3255](https://github.com/mizchi/vibe-lang/issues/3255), following the MutList
slice in [#3265](https://github.com/mizchi/vibe-lang/pull/3265).

## Scope and remaining boundaries

Three operations now carry resolved IDs: `Array::with_capacity` (13),
`Array::push` (14), and `Array::set` (15). The checker resolves the lexical
or module binding before selecting the operation's existing typing rule.
Capacity freshness, element unification, index receiver facts and rejection
diagnostics retain their existing behavior. Three checker spelling arms were
removed (41 → 38).

The shared registry supplies arity and runtime targets. Both backends consume
the resolution cell, including GC's native `array.set` shortcut. A resolved
builtin target bypasses a same-named program function or local value.
Synthesized mutation calls in exception, await, suspend, async boundary and
linear codegen lowering explicitly carry the builtin identity. The existing
first-class builtin wrappers already use the same factory.

Binary AST v3 and the 16-bit typed-lowering carrier accept the expanded
registry without changing their wire layout. The source fingerprint invalidates
older cached facts; unknown IDs remain rejected. See the
[binary ABI contract](../compiler/ast_binary_abi.md).

The shared emission helpers retain their import closure. Unchecked table-backed
Array calls retain the generic function-table path. Source spelling remains at
source resolution and explicit builtin factories; the remaining 38 checker
arms, definition/local/constructor identities, effect/ownership/allocation/
capture consumers and rename guards remain work for #3255.

## Baseline and regression coverage

Baseline: `ac2fdce395fec2d172c97948a03e53a52d47683f` (merged #3265).
Baseline stage2 SHA-256:
`023f92375b11c5e3b7ac0c4411718607ed203bb8238c88f8057ae7000d753ad3`.
Fresh candidate stage2 and stage3 match:
`2bc190fb7602ee92b9d9b9912f3ff31a7f61b55e5e60548b2156f1a0927d8891`.

Before migration, the direct, imported/re-exported, first-class and native GC
array fixtures passed on main. The new identity test failed with operation
`0` where `13` was expected. The migrated tests cover:

- lexical shadowing and stale identity replacement;
- explicit compiler builtin references under a shadow;
- capacity, value and index rejection diagnostics;
- binary transport and typed-carrier restoration/rebasing above ID 12;
- imports/re-exports, private same-named functions and first-class values;
- index-write sugar under a program `Array::set`;
- receiver/index/value evaluation once, in that order (`123`), with
  noncommutative results (`29 - 16 = 13`);
- heap element replacement and GC native-array alias identity.

Both runtime fixtures also run in the existing RC-shadow/GC compiler gate.

## Compiler and source footprint

| Measure | Main | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Compiler Wasm | 3,907,185 B | 3,907,620 B | +435 B (+0.011%) |
| Maintained compiler/CLI source files | 561 | 561 | 0 |
| Maintained source bytes | 12,414,076 | 12,415,652 | +1,576 B |
| Maintained source lines | 316,329 | 316,346 | +17 |
| Largest maintained source | 2,952 lines | 2,952 lines | 0 |

The source census covers maintained `.vibe`/`.vpkg` files under compiler and
CLI, excluding tests, benches and generated bundles/module source/fingerprint.
The largest file remains `entry/compiler/file_compile/file_compile.vibe`,
under the 3,000-line limit.

## Allocation protocol and results

Each compiler compiled its own frozen source tree. The main snapshot came from
the baseline commit; the candidate snapshot came from the final formatted
sources. Their generated codegen fingerprints are `208dadd5c52681ec` and
`2e5d5fb0a4b1ca58`. Both tree and compiler paths have equal lengths.

The existing `scripts/selfhost_build_metrics.mjs` collector ran four interleaved
rounds in AB/BA/AB/BA order. Each sample used a fresh process, an empty cold
cache, then the same cache for warm; body and checked-module caches were off.
Builds and tests did not run concurrently. The collector's protocol hash is
`9b582d510ad85ad9926c5e84621433708f332d34b94b29932715375c92cac6a9`.
Node was 24.7.0 on Linux x64.

| Compiler-closure allocation volume | Main | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Whole, cold | 1,025,308,508 B | 1,032,843,896 B | +0.735% |
| Whole, warm | 623,266,620 B | 630,842,216 B | +1.215% |
| Production split, cold | 1,338,677,436 B | 1,346,351,464 B | +0.573% |
| Production split, warm | 936,635,500 B | 944,349,760 B | +0.824% |

Every allocation reading repeated exactly in all four samples. Production
split count stays 314 on both trees. Cold/warm and repeated output Wasm hashes
match within each configuration. These are bump allocation volumes, not live
heap or RSS. The small increase is reported explicitly; this refactor claims
no memory reduction or compile-time speedup.

Median whole cold/warm wall times were 5,845/4,412 ms on main and
5,986/4,496 ms on candidate; split cold/warm were 6,654/5,093 and
6,693/5,061 ms. These bounded wall readings are advisory on a shared machine; no speedup is
claimed.

Raw samples, compiler/probe hashes and source census hashes:
[resolved-array-callees-2026-10-02.json](../../../bench/perf/analysis/resolved-array-callees-2026-10-02.json).
The JSON uses the existing collector schema for each configuration. To repeat,
build the baseline and candidate in equal-length frozen trees, then alternate
`collect({root, compiler, rounds: 1})` four times per tree.

The live-checkout selfcompile KPI reads 1,031,028,144 B, below the unchanged
1,125,830,736 B ceiling (+10% over the committed baseline). All five output
size-ratchet samples pass the existing +2% limit.

## Watchdog self-test timing

The release gate exposed an existing timing weakness in
`scripts/run_bounded_test.sh`: wall-clock backsteps can hide the grandchild
failure that its deliberate child-only watchdog mutation must report.
The self-test now measures elapsed time with Node's monotonic clock.
A forced backwards realtime clock proves the old timer control misses that
defect while the monotonic probe catches it. The real helper also passes under
the simulated backstep. The GNU timeout wrapper also used realtime to distinguish KILL escalation
from a command that dies of SIGKILL before the bound. A second full release
run exposed that backsteps can return 137 for an actual timeout. That
classification now uses a monotonic clock: a shell builtin read of Linux
uptime, or Node on other hosts. When neither clock exists, the existing
marker watchdog enforces the bound. A forced backstep reproduces the old
137 result, while the real wrapper keeps 124 and preserves early SIGKILL.
The marker watchdog implementation is unchanged. The Node clock path and
clock-unavailable fallback also have explicit controls. These host script
changes do not alter the measured compiler artifacts.

The full active unit corpus passed: 1,558/1,558 files.

The formatter closure self-test also completed a real rebuild inside one
`stat` second. Its missing-dependency probe now pins the old artifact inode
with a hard link and checks atomic publication, rather than requiring a
strictly larger whole-second mtime. The dependency manifest still must be
recaptured without the missing row. The standalone formatter probe passes.

The final release run also logged `-2s rc=0` for two unrelated gate
companions, confirming an actual realtime backstep on this WSL host.

## Final sign-off

- Full active unit corpus: 1,558/1,558 files passed.
- `pkf run release-check -j 1`: all 118 tasks passed (112 ran, 6 cached).
- Compiler stage2/stage3 fixpoint matches the measured candidate hash.
- Staged AST pre-commit checks passed with the fresh candidate CLI.
- Doctest: 70 passed, 0 failed, 78 recorded skips; tutorial parity: 20 chapters.
- Existing live-heap ceiling and all five output-size ratchets passed.
