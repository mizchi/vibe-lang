# Selfhost performance benchmarks

Macro and micro benches for the self-hosted vibe compiler / checker. Pair
with `bench/selfhost_check_parity` and `bench/selfhost_cutover` to keep
host vs selfhost output equivalent.

## Macro: stage-level wallclock

Driver: `scripts/bench_selfhost_perf.sh` → `just bench-selfhost-perf`.

Compares host CLI vs selfhost wasm (under `moonrun`) on the cases listed in
`cases.txt`. Median of N runs (default 3) per phase per stage; emits ratio
gates that `just test-selfhost-perf-gate` enforces.

Output: `_build/bench/selfhost_perf/{summary,stage_summary}.{e2e,in-memory}.tsv`.

## Memory: peak RSS + wallclock

Driver: `scripts/bench_selfhost_memory.sh` → `just bench-selfhost-memory`.

Combines `hyperfine` (stable wallclock, std-dev, JSON export) with
`/usr/bin/time -v` (peak resident-set size in KB) and reports the
selfhost/host ratio per phase per case. Optional gates:
`VIBE_SELFHOST_MEMORY_MAX_RSS_RATIO` / `VIBE_SELFHOST_MEMORY_MAX_RSS_KB`.

Linux only — relies on GNU `/usr/bin/time -v`'s `Maximum resident set size`
field. macOS users need `gnu-time` (`brew install gnu-time`) and to point
`/usr/bin/time` at it via PATH.

Output: `_build/bench/selfhost_memory/rss_summary.tsv` and
`_build/bench/selfhost_memory/hyperfine/<case>.<phase>.json`.

A first-pass measurement on `examples/basics.vibe` (debug selfhost wasm)
showed selfhost compile is ~6x slower / ~6x larger RSS than host, and
selfhost check is ~2.6x slower / ~3x larger — consistent with the
"selfhost perf gap" item tracked in `TODO.md`.

## Micro: vibe bench probes (currently blocked)

Files:
- `vibe/compiler/lexer_hotspot_probe.vibe` + `selfhost_lexer_bench.vibe`
- `vibe/compiler/parser_hotspot_probe.vibe` + `selfhost_parser_bench.vibe`
- `vibe/compiler/checker_hotspot_probe.vibe` + `selfhost_checker_bench.vibe`

Driver (host CLI compiled backend):
`scripts/bench_selfhost_compile_hotspots.sh` → `just bench-selfhost-compile-hotspots`.

These bench files type-check clean (`vibe check ...` passes) and define
per-case probes that exercise the selfhost lexer / parser / checker against
real selfhost sources and synthetic shapes (deep binop chains, wide match,
chained let / ESeq sequences).

**Currently blocked**: `vibe bench`'s `compile-lite` calibration step pulls
in the imported selfhost compiler modules and either errors with
"unsupported: closure-capture / unknown name" or hangs in calibration —
same gap as `selfhost_hotspots_bench.vibe` (see `cases.txt` header
comment). Until compile-lite supports the closure / capture paths these
probes need, run only the macro and memory benches above.

When that gap closes (TODO #295: "selfhost perf gap cutover 水準まで"),
these micro-benches will surface per-phase hotspots — lexer keyword_lookup
cost, parser infix-chain dispatch, env_lookup walk depth — without I/O or
wasm-runtime overhead.
