# Wasmtime guest CPU profiling

Status: implemented for core modules (#2207): `vibe profile` for an ordinary
run and `vibe bench --guest-profile` per benchmark block. Component inputs,
continuation visibility and source-line attribution are not implemented, and
no open issue owns them (see *Not implemented*). The user-facing description
is the "Wasmtime guest CPU profiles" section of [profiling.md](profiling.md);
this document is the runner contract behind it.

## What it measures

Wasmtime's `GuestProfiler` samples the Wasm stack of the running guest: which
vibe functions occupy it, and which guest-to-host calls divide the samples. It
answers a different question from the other measurements:

- `vibe bench` reports per-block latency and bump-heap bytes per operation;
- `--profile-tsv` / `--profile-callstack` describe compiler-defined phases;
- `scripts/profile_compile.sh` uses V8's CPU profiler through the Node host;
- `vibe run --mem-sample` samples `__heap_ptr` through epoch interruption.

`GuestProfiler` is distinct from `Config::profiler(ProfilingStrategy::...)`,
which registers JIT code with native platform profilers. It is portable and
per-guest, so it works the same on macOS Arm64 and Linux x64.

## The surface

```text
vibe profile <file.vibex> [--out FILE] [--interval-us N] [-- args...]
vibe bench <file.vibe> --guest-profile DIR [--interval-us N]
```

- **`vibe profile`** profiles one ordinary run. `--out` defaults to
  `profile.json` and `--interval-us` to 1000. The CLI
  (`selfhost_cli_profile_plan_args`, `lib/@vibe/cli/dispatch.vibe`) writes a
  `run-guest-profile` host action, and the launcher (`runtime/vibe`) executes
  it as a `vibe run` with the profile requested, refusing an `--out` that
  resolves to the source file. `viberun` profiles when `VIBE_GUEST_PROFILE`
  names an output path, at `VIBE_GUEST_PROFILE_INTERVAL_US` (default 1000 µs;
  zero or a non-integer is an error), and prints `vibe::guest-profile
  path=<path>` when the file is written.
- **`vibe bench --guest-profile DIR`** writes one profile per
  `__bench_<name>` block. Each block's profiler is armed after its warmup and
  stopped before its statistics are computed, so only measured iterations are
  sampled. The file name is the sanitized block label (at most 200
  characters) plus a stable 64-bit hash of the label, so two labels that
  sanitize alike do not overwrite each other. An empty `--guest-profile` is
  refused, and a profiled bench asks the compiler to keep Wasm function names.

The output is Firefox processed-profile JSON, readable at
<https://profiler.firefox.com/>. A profile is written after a successful run
and after a guest trap. Latencies from a profiled invocation are diagnostic
only: the profiler changes execution cost, so a KPI or regression comparison
uses an unprofiled run.

## How the runner samples

- **On the guest's own thread.** `sample` must run on the stack that executes
  the guest, so a timer thread increments the engine epoch and
  `Store::epoch_deadline_callback` takes the sample. Epoch checks sit at
  function entries and loop headers, which biases samples toward those
  safepoints, and time spent in a host call receives no guest samples.
- **One deadline callback.** A Store has one, so heap sampling and guest
  profiling share it, and the callback dispatches to whichever is enabled. The
  profiler lives in `HostState` and is taken out of the state while it samples
  or handles a call hook (the Wasmtime CLI's borrow-safe pattern).
- **Guest time, not wall time.** `Store::call_hook` marks host-call intervals
  in the profile and drives `GuestCpuClock`, which accumulates guest time
  across host calls, so a short guest burst between two host calls is not lost
  to a wall-clock reset. The heap sampler keeps its own absolute deadline.
- **Fresh `.wasm` only.** An ordinary `.cwasm` was compiled without epoch
  checkpoints, so profiling one is refused by name rather than producing an
  empty profile.
- **Unprofiled runs pay nothing.** Epoch interruption is enabled only for a
  sampled run.

`scripts/lint_guest_profile_contract.sh` (run by `scripts/precommit.sh`) pins
these invariants in the sources: the shared `GuestCpuClock`, all four
`CallHook` transitions, no reintroduced wall-clock sampling state, the
filename bound, a profile writer whose flush errors surface, and the CLI's
distinction between an omitted and an empty `--guest-profile`.
`scripts/test_vibe_bench.sh` runs both commands end to end: one JSON per bench
block, preserved function names, colliding labels, a trap after warmup that
still flushes, and a named `vibe profile` run.

## Symbols

`GuestProfiler` names frames from Wasmtime's compiled function names, that is,
from the Wasm name section. It does not read vibe's `vibe.linemap` or
`.funcmap`, so frames are functions, not source lines. Wasmtime guest
debugging is no shortcut: `GuestProfiler::new` rejects `debug_guest`, whose
instrumentation clones code per instantiation.

## Not implemented

None of these has an open issue.

- **Component Model inputs.** `viberun` refuses them ("guest profiling for
  Component Model inputs is not implemented yet"). The component path would
  use `GuestProfiler::new_component`, and its async / concurrent driver may
  need the epoch for yielding or cancellation, so profiling has to share that
  callback rather than replace it.
- **Continuation and worker visibility.** A continuation that is executing
  should appear in a sample; a suspended one is not on the stack and will not.
  Workers on different stores or threads need one profiler stream each. Before
  profiles are used to judge an effect backend, probes should establish what
  Wasmtime reports for: a sample in the initial guest stack; a sample after
  suspend / resume on a continuation stack; cancellation while another worker
  runs; failure propagation across workers; host-call markers around an effect
  operation; and equivalent named frames on Linux x64 and macOS Arm64. A
  missing suspended-worker view is a limit of sampling, not evidence that the
  worker did no work.
- **A profile-instrumented AOT artifact**, which would need a `.cwasm` keyed
  separately from the ordinary AOT cache.
- **Source-line attribution**, by post-processing the profile with vibe's
  metadata or by an explicit symbol mapping.
- **A warning when most frames resolve as `wasm-function[N]`**, i.e. when the
  name section is missing.
