# selfhost cutover KPI — re-measure after #427 + #476 (2026-05-30)

Refreshes the stale (2026-05-17, moonrun) numbers in #402 after the
wasmtime-AOT runtime became the default and #427 (AST parse cache) + #476
(typed-env snapshot) removed the prelude `type`-stage startup.

- Driver: `VIBE_SELFHOST_PERF_RUNS=5 bash scripts/bench_selfhost_perf.sh`
- Runtime: **wasmtime-aot** (`tools/moonrun_wasmtime`, `.cwasm` precompiled)
- Caches **active**: `.vibe/ast/prelude-env.*.venv` (#476) + `*.vast` (#427)
  written + reused by the selfhost wasm during the run (median-of-5 reflects
  warm runs).
- 5 KPI cases (basics, base64, effects, module_export, module_import).

## Totals (selfhost ÷ host wallclock, gate ≤ 1.33×)

| phase | per-case ratios | **median** | vs #402 (2026-05-17, moonrun) |
|---|---|---|---|
| **check**   | 0.43 / 0.71 / 0.74 / 0.77 / 1.25 | **0.77×** ✅ | 2.23× |
| **compile** | 3.29 / 3.34 / 3.37 / 3.47 / 3.55 | **3.37×** ❌ | 3.97× |

**check now passes the 1.33× gate** (median 0.77×); **compile is ~3.4×**, still
the focus.

## Stage breakdown (ratio ranges across cases)

### compile (~3.37× total)

| stage | ratio | note |
|---|---|---|
| bundle | **3.7–4.1×** | worst stage — lowering / linking |
| load   | 3.3–3.7×    | apply_lock + parse |
| compile (module) | 3.4–3.7× | |
| type   | 3.0–3.2×    | prelude parse/typecheck removed by #427/#476; residual is user-module typecheck + wasmtime constant overhead |
| emit   | 2.0–3.1×    | codegen |
| write  | 1.6–9.8×    | moonrun/wasi fs shim, algorithmically fixed (tiny absolute) |

### check (~0.77× total)

| stage | ratio | note |
|---|---|---|
| load   | **0.02–0.06×** | selfhost far faster — host pays per-invocation session-http / db setup the selfhost check skips; dominant reason check total < 1× |
| type   | 1.9–3.9×    | snapshot active; residual is user-module typecheck + deserialize + constant overhead |

## Interpretation

- The headline check win is two-fold: (1) #427/#476 keep `check.type` bounded
  (no prelude parse/typecheck per process), and (2) the host check pays a
  session-http/db setup cost per invocation that the selfhost path doesn't —
  so `check.load` is ~20–50× cheaper on selfhost, pulling the total under 1×.
  The apples-to-apples `check.type` stage is still ~2–4× selfhost-slower; the
  total passing the gate is partly a load-stage asymmetry, not pure
  type-stage parity.
- **compile is the remaining gate blocker (~3.4×)**, dominated by **bundle
  (~4×)** and the `compile`/`load` stages. Type stage is no longer the
  ceiling there either.

## Next levers (compile)

1. **bundle stage (~4×)** — biggest single compile ratio; profile
   lowering/linking hot functions (`compile/bundle` callstack).
2. **emit / codegen** — `codegen/compile_functions` was 33% of compile in the
   old profile; re-profile under the current build.
3. **load** — apply_lock + parse; #427 AST cache helps parse, apply_lock
   fast-path (#401) helps lock.

Per #402's strategic note, wasmtime-AOT (now default) was the big multiplier;
with check under gate, the focused work is compile-stage constant-factor
(bundle/emit) reduction.

## compile bundle/emit profiling (host, native debug, warm)

Added finer `--profile-callstack` instrumentation to the bundle path
(`compile/bundle/{collect,dce,cache_key}` and, inside the collector,
`bundle/collect/{deps,prelude_add,dce}`) — the bundle stage was previously a
single opaque self-time leaf.

`compile/bundle` totals (µs), basics / base64:

| sub-stage | basics | base64 | nature |
|---|---|---|---|
| bundle/collect/**prelude_add** | ~1300–1600 | ~1300–1600 | **fixed** — merges every prelude+builtin value def into each bundle |
| bundle/collect/dce | ~450 | ~490 | fixed — surgical prelude DCE reachability walk (`dce_module_with_entry_names`) |
| bundle/cache_key | ~7 | ~680 | program-proportional — content hash of bundled module |
| bundle/collect/deps | ~1 | ~1 | negligible for these cases |

`compile/emit` = `codegen/compile_functions` + `codegen/build_module`, both
program-proportional (tiny for small programs); not a fixed floor.

**Finding:** like the prelude parse (#427) and typecheck (#476) floors, the
bundle stage carries a **~1.3–1.6ms fixed cost from re-processing the entire
prelude/builtin value set on every compile** (`prelude_add` merge loop +
surgical prelude DCE). This dominates the worst compile stage.

Landed here: memoized `prelude_partition_value_stmts` (the dependency-graph +
fixpoint partition was recomputed twice per compile; now once per process).
Modest on single-file compile (~300µs) but removes a full recompute per module
on multi-module / warm-process compiles.

**Follow-up (next lever):** cache the *bundled* prelude/builtin stmt set (or
disk-snapshot it, analogous to #476) so each compile doesn't re-merge +
re-DCE the full standard library. Estimated ~1.7ms off the compile `type`/
`bundle` fixed cost — the largest remaining compile-stage constant factor.
