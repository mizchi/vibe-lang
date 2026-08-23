# Experimental Wasmtime guest-profiler integration

Core-module guest profiling is available for ordinary runs and per-block
benchmarks. Component profiling and continuation-visibility probes are not yet
implemented. Tracking issue: <https://github.com/mizchi/vibe-lang/issues/2207>.

## Why revisit this

Vibe currently exposes several measurements, but none of the live paths provides
a Wasm guest CPU call tree from `viberun`:

- `vibe bench` reports per-block latency statistics and bump-heap bytes/op.
- `--profile-tsv` and `--profile-callstack` describe compiler-defined phases.
- `scripts/profile_compile.sh` uses V8's CPU profiler through the Node host.
- `VIBE_MEM_SAMPLE_MS` samples `__heap_ptr` in `viberun` through Wasmtime epoch
  interruption.

These answer different questions from Wasmtime's `GuestProfiler`: which Vibe
guest functions occupy the sampled Wasm stack, and which guest-to-host calls
divide those samples.

This is a restoration as much as a new feature. The archived May 2026 report
records a working `vibe profile ... --out ... --interval-us ...` workflow using
`GuestProfiler`, but that command is no longer present in the current launcher.
See `docs/archive/report/profile-wasm-gc-vs-linear-2026-05-26.md`.

## Wasmtime contract

Wasmtime 47.0.2, which `runtime/viberun/Cargo.toml` currently selects, exposes
the required API:

- `GuestProfiler::new` for a core `Module`, and `new_component` for a
  `Component`;
- `sample` to capture the currently active allowed guest frames;
- `call_hook` to mark guest-to-host intervals;
- `finish` to write Firefox processed-profile JSON.

The intended sampler is not an unrelated thread calling `sample`. The guest
must be on the same stack and thread as `sample`, so a timer thread increments
the engine epoch and `Store::epoch_deadline_callback` performs the capture on
the executing guest thread. Epoch checks occur at function entries and loop
headers, which biases samples toward those safepoints, and host-call time does
not receive guest samples. `Store::call_hook` supplies host-call interval
markers but not host native frames.

This is distinct from `Config::profiler(ProfilingStrategy::...)`, which
registers JIT code with native platform profilers. `GuestProfiler` is the
portable, per-guest facility and is therefore the appropriate default for macOS
Arm64 as well as Linux x64.

Primary references:

- <https://docs.wasmtime.dev/api/wasmtime/struct.GuestProfiler.html>
- <https://docs.wasmtime.dev/examples-profiling-guest.html>
- <https://github.com/bytecodealliance/wasmtime/blob/main/src/commands/run.rs>

## What the current runner already has

The core-module `run` path in `runtime/viberun/src/main.rs` already contains
most of the scheduling mechanism for heap sampling:

1. enable `Config::epoch_interruption(true)` only for a sampled run;
2. set a store deadline and install `epoch_deadline_callback`;
3. increment the engine epoch from a timer thread;
4. stop and join that thread after guest execution, including a trapped run.

The profiler should share one epoch scheduler with heap sampling rather than
install a second callback: a Store has one deadline callback, so the callback
must dispatch all enabled sampling consumers. The profiler itself can live in
`HostState`; its callback must temporarily take it out of the state before
passing the Store context to `sample`, following Wasmtime CLI's borrow-safe
pattern. The same pattern applies to `Store::call_hook`.

Current precompiled `.cwasm` files are produced with the ordinary engine
configuration and contain no epoch checks. As with heap sampling, a guest
profile must initially require fresh `.wasm`. A later AOT profile mode may
create a separately keyed `.cwasm` with epoch interruption enabled; silently
reusing the normal AOT cache would be incorrect.

## Proposed user surface

Keep CPU profiling orthogonal to the compiler-phase profiler:

```text
vibe profile input.vibe --out profile.json --interval-us 1000
vibe bench input.vibe --guest-profile profiles/ --interval-us 1000
```

The first form profiles one normal execution. It should compile a fresh named
Wasm module, run it through `viberun`, finish the JSON on success or trap, and
print the `profiler.firefox.com` viewing hint.

For `vibe bench`, produce one file per `__bench_<name>` block. Create and arm
the profiler only after that block's warmup, stop sampling before calculating
or printing statistics, and include only measurement iterations. A combined
profile would mix unrelated blocks and make the fresh-Store isolation in
`bench()` ineffective. Suggested filenames are derived from a sanitized bench
label plus a collision-resistant short hash.

`--interval-us` needs a conservative default such as 1000 microseconds. A
100-microsecond interval is useful for short investigations but can distort a
microbenchmark. Bench profiling is diagnostic and must not be used as the
latency-regression measurement from the same invocation; the normal unprofiled
bench remains the KPI source.

## Symbol quality

`GuestProfiler` builds its symbol table from Wasmtime's compiled function
names. It does not consume Vibe's `vibe.linemap` or `.funcmap` sidecar, and the
current API emits function-level frames rather than Vibe source lines.

Therefore the first integration gate is preservation of the Wasm name section
on every profiled backend. A useful profile should reject or prominently warn
when most frames resolve as `wasm-function[N]`. Source-level attribution is a
separate follow-up: either post-process the Firefox profile with Vibe metadata,
or upstream/extend an explicit symbol mapping. Do not enable Wasmtime guest
debugging as a shortcut: `GuestProfiler::new` rejects `debug_guest`, because
that instrumentation clones code per instantiation and invalidates profiler
address assumptions.

## Components, effects, and stack switching

The component path should use `GuestProfiler::new_component`, but it cannot be
treated as a mechanical extension of the synchronous core path. It already
uses async/concurrent Wasmtime APIs, and its epoch handling may also be needed
for yielding or cancellation. Profiling must compose with that policy through
one callback rather than overwrite it.

An active stack-switching continuation should be visible when its guest frames
are the currently executing Wasm stack. A suspended continuation is not on that
stack and should not be expected in a sample. Multiple workers executing on
different stores or host threads require one profiler/thread stream per
executing store; a single core-run profiler must not claim whole-runtime worker
coverage.

Before using profiles to assess the experimental effect backend, add probes
for:

- a sample inside the initial guest stack;
- a sample after suspend/resume on a continuation stack;
- cancellation while another worker remains active;
- failure propagation across workers;
- host-call markers around an effect operation;
- Linux x64 and macOS Arm64 output with equivalent named guest frames.

These probes should first establish what Wasmtime's backtrace considers active
across stack switching. Any missing suspended-worker view is a semantic limit
of sampling, not evidence that the worker did no work.

## TDD implementation sequence

1. **Exploration**: restore the archived workflow against Wasmtime 47 in a
   standalone runner test and inspect the JSON schema and names.
2. **Red**: add CLI tests for a normal profile, trapped-run flush, host-call
   markers, missing name warning, and rejection of ordinary `.cwasm`.
3. **Green**: introduce a runner-owned sampling coordinator shared by heap and
   guest CPU profiling, then wire the normal core-module path.
4. **Refactor**: factor profile lifecycle and filename handling away from
   `run`, without changing the unprofiled engine configuration.
5. **Red/Green**: add per-block bench profiles with warmup exclusion and prove
   that unprofiled benchmark output and timings use the old path.
6. **Red/Green**: add component and stack-switching probes only after the core
   contract is stable.

## Acceptance criteria

- No profiler or epoch overhead when profiling is disabled.
- A profile is flushed after success and after a guest trap.
- Firefox Profiler opens the output and shows Vibe function names.
- Host-call intervals are marked through `call_hook`.
- Heap and CPU sampling can be enabled together through one epoch callback.
- Every bench block gets an isolated post-warmup profile.
- Ordinary `.cwasm` input fails with an actionable message; a future
  profile-instrumented AOT artifact has a distinct cache/config identity.
- Tests document active versus suspended continuation visibility on Linux x64
  and macOS Arm64.

## Remaining non-actions in this branch stage

- Do not claim suspended continuations or other worker threads are sampled
  until the probes above demonstrate it.
- Do not use profiled benchmark timings as regression KPIs.
