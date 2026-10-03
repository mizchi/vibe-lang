# Monotonic selfcompile KPI timing — 2026-10-03

Realtime clock adjustments can make selfcompile_kpi.sh report a negative
wall_ms and let an over-budget compile pass its optional wall-time gate.
Two monotonic observations now measure elapsed milliseconds. Linux reads
/proc/uptime with shell builtins; the portable fallback uses the repository's
Node process.hrtime.bigint(). The existing run_bounded helper uses the same
clock choices for seconds.

Linux uptime has centisecond resolution, so expressing it in milliseconds
does not provide one-millisecond precision. Node fallback process startup
contributes to the measured interval. Wall values remain advisory and depend
on the host and load; heap gating keeps its existing deterministic meaning.
Failure to obtain a clock terminates the KPI rather than publishing a value.

## Reproduction and contracts

A mock runner performs 30 ms of real work and reports heap_ptr=12345/pages=2.
A PATH-local date fixture supplies 10 s followed by 9 s. The original script
reports wall_ms=-1000 and exits 0 with a 1 ms budget. Both revised backends
report positive intervals and reject that budget. The actual production
script owns clock selection; only ignored fixture copies force the fallback.

Eight permanent regression tests cover both backends, the backwards-clock
gate, positive metrics, heap gating, runner exit status, missing output/stats
and work-dir cleanup. Against the original script four fail and four pass;
the revised script passes all eight. Eighteen earlier private observations
also pin the full runner arguments, cold cache and cleanup. Existing
fixed-workdir rejection tests pass unchanged.

## Actual compilation parity

The compiler is the validated PR #3294 release artifact:
c0a33f3d5d2650e8545a6f76dfaedad1c08fd942957b6306785fea4f720780d0.
Source base is 9f893dc8d0efc667ebc38adc6c2a800ddb10b9a2.
The ordinary default codegen_lexer_test.vibe workload uses isolated cold
caches and its existing allocator/entry/runtime defaults. A delegating runner
copies user Wasm before normal work-dir cleanup; it preserves compile flags.
Three alternating original/Linux pairs plus two private forced Node-fallback
observations produce eight actual compiles.

Every observation agrees exactly:

| Measure | Original | Linux monotonic | Node fallback |
| --- | ---: | ---: | ---: |
| heap_ptr_bytes | 1,019,551,480 | 1,019,551,480 | 1,019,551,480 |
| reserved Wasm pages | 18,663 | 18,663 | 18,663 |
| emitted user Wasm | identical | identical | identical |

Emitted user Wasm SHA:
8e1bd76763eaf5c86ae44ab7cf51cbaae96c6079a7f61b5371e6f4bed9a1bd6f.
Compiler, input, tracked guest sources, runtime and HEAD guards pass.
The raw record retains signed advisory wall values and command/hash receipts.
This is a measurement-correctness change; compiler throughput is not measured
as a benefit. The heap baseline, tolerance and allocator policy stay as before.

## Validation

The 52-test heap-policy task passes, including the eight new clock tests,
and the existing fixed-workdir suite passes.
Full release-check passes: 122 tasks (13 cached, 109 run) in 44m18s. Source/runtime/staged guards agree, and the gated compiler hash matches the real-KPI compiler. AST-required staged pre-commit passes and is repeated against the final staged validation-status updates.

Local replay preparation lives under _build/monotonic-kpi-fix and
_build/monotonic-kpi-preparation. The published raw record preserves the
clock fault, contract observations, real compilation and source identities.
