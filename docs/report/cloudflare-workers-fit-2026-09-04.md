# Cloudflare Workers fit assessment (2026-09-04)

Question: can the vibe compiler, as it stands after the #2386 slices, run as a
Cloudflare Worker? Three targets were set for the assessment:

1. compiler wasm at or under 1.0 MB after `wasm-opt` and minify (800 KB with
   headroom);
2. a small program compiles inside a 128 MB isolate;
3. a warm-cache incremental self-build fits in 128 MB.

Everything below was measured on this checkout (`0305c29`, main) unless the row
says "seed" (`bootstrap/seed/compiler.wasm`, seed `applied-trait-impl-2026-08-28`).
Every compile ran through `scripts/wasm_vibe_host_runner.js` with
`VIBE_WASM_MEMORY_STATS=1` and a fresh `VIBE_BUILD_CACHE_DIR` per run, so cold
means cold. `heap_ptr` is the bump-allocator high-water; `pages` is the linear
memory actually reserved, which is what the isolate limit counts.

## The platform limits being measured against

From the Workers limits page (read 2026-09-04): Worker size **3 MB compressed on
the free plan, 10 MB paid**; **128 MB per isolate including JavaScript heap and
WebAssembly allocations**; global scope must finish inside 1 second; CPU time
10 ms per request free, 30 s default (up to 5 min) paid. The compressed budget
is therefore not the constraint. The two constraints that bite are the 128 MB
isolate and, for the free plan, CPU time. The 1.0 MB uncompressed target is a
self-imposed one (startup and cold-instantiation cost); it is evaluated as
stated.

The compiler wasm uses these features: exception handling (`try_table`,
exnref), bulk memory, multivalue, tail calls, reference types, sign extension,
non-trapping float-to-int, SIMD. Node 22 still needs
`--experimental-wasm-exnref`; current V8 in Workers ships exnref by default,
but this was not exercised on the platform itself. It imports 20 host
functions, all in the `vibe.*` namespace (fs, env, args, stdin/stdout, exit)
plus `wasi_snapshot_preview1.fd_write`. A Workers host shim is one JS object
with those 21 entries; the existing runner is not needed.

## 1. Size

### Measured

| artifact | bytes | gzip -9 | brotli 11 |
|---|---:|---:|---:|
| seed, as shipped (stripped, no name section) | 2,737,946 | 739,644 | 463,558 |
| seed after `wasm-opt -Oz` (explicit feature flags) | 2,141,130 | 514,200 | 371,767 |
| seed after `wasm-opt -Oz --converge` | 2,139,107 | 511,178 | 369,142 |
| stage2 from this checkout, stripped code section only | 2,718,569 | | |
| vibec compile-only core (`compile_cli_request` face), `wasm-opt -Oz` | 3,083,290 | 554,403 | 391,033 |

Section breakdown of the seed: code 95.1 % (2,602,905 B, 5,680 functions),
data 4.6 % (126 KB, 4,062 segments), everything else under 0.3 %. There is no
name section and no producers section to strip; the whole artifact is
instruction bytes.

Three facts about the tooling, learned while measuring:

- `wasm-opt -Oz` with `--all-features` produces a module V8 refuses to
  instantiate (`unknown import kind 0x7e`). Passing the feature flags
  explicitly (exception-handling, bulk-memory, multivalue, tail-call,
  reference-types, sign-ext, nontrapping-float-to-int, mutable-globals, simd,
  threads) produces a valid module that compiles `json_test.vibe` to the same
  bytes as the unoptimized seed, in the same wall time. `-O4` crashes binaryen
  132 (`Flatten.cpp:231 UNREACHABLE`). `-O3` gives 2,185,140 B. So the
  achievable binaryen floor today is about 2.14 MB, a 22 % reduction, and
  binaryen removes about 2,500 of the 5,680 functions by inlining.
- The in-house optimizer (`lib/@vibe/optimizer`, `scripts/minify_wasm.sh`) was
  not run over the compiler in this session. `docs/wasm-opt-dogfood.md` records
  it at or below `wasm-opt -Oz` on small programs and behind on large ones, and
  `docs/vibec-component.md` records 4.9 MB to 3.85 MB on the library build.
  It is not the lever that closes the gap either.
- The compile-only vibec face (3.08 MB after `-Oz`) is larger than the whole
  CLI. That is not because compile needs more code: the library build keeps
  every function reachable from the funcref table, so binaryen cannot remove
  them, while the CLI build is pruned by the compiler's own DCE. A Workers
  artifact must be built as an executable-shaped module with the compiler's
  DCE, not as the `__no_entry__` library, or it starts 1 MB behind.

### Where the bytes are

Attribution uses a stage2 built with `VIBE_WASM_NAMES=1` (function names
carry their source file). Code section 2,718,569 B, 6,131 functions.

| group | bytes | share |
|---|---:|---:|
| codegen linear + common (excluding the effect-lowering file) | 487,560 | 17.9 % |
| checker | 412,191 | 15.2 % |
| normalize (`desugar_trait_dict.vibe` alone: 326,106) | 385,681 | 14.2 % |
| effect lowering (`inline_direct_perform.vibe`) | 279,752 | 10.3 % |
| parser + lexer + printer + ast | 231,890 | 8.5 % |
| core (types, builtin registry, alias rewrite) | 206,254 | 7.6 % |
| gc backend | 139,813 | 5.1 % |
| loader + contract + manifest | 91,057 | 3.3 % |
| component / serve / wit | 87,803 | 3.2 % |
| typecheck_fs + module_source | 76,936 | 2.8 % |
| persistent caches, codecs, telemetry, incremental, checker artifacts | 67,715 | 2.5 % |
| perceus / RC lane | 50,758 | 1.9 % |
| fmt | 34,392 | 1.3 % |
| grep | 31,944 | 1.2 % |
| editor queries (type-at, binding-at, symbols, doc-at, escapes, allocs, rc-*) | 31,329 | 1.2 % |
| lambdas (unnamed) | 32,234 | 1.2 % |
| lsp + json | 7,671 | 0.3 % |
| inspect update, debug break/trace | 9,040 | 0.3 % |
| CLI adapter + dispatch | 6,869 | 0.3 % |

Two files are 22 % of the compiler:

- `lib/@vibe/compiler/normalize/desugar_trait_dict.vibe` (20,482 lines, 719
  functions, 326 KB) is not one pass. By function prefix: `gen_` 28 KB,
  `dlh_` (local lambda hoisting) 26 KB, `infer_` (a second, syntactic type
  inference used by the desugars) 24 KB, `eq_` (structural equality shapes)
  23 KB, `rewrite_` 21 KB, `collect_` 16 KB, `dinsp_` (inspect) 12 KB,
  `interp_` (string interpolation shapes) 11 KB, `dtpw_`, `relabel_` (labeled
  arguments), `railway_`, `erase_`, `das_` (array spread), `constructor_`, and
  the exception-kind cell. Its 29 exports are 12 independent passes.
- `lib/@vibe/compiler/codegen/common_base/inline_direct_perform.vibe` (15,398
  lines, 480 functions, 280 KB) is four effect-lowering strategies: `scps_`
  (suspend CPS pass) 122 KB, `edp_` (evidence dictionaries) 114 KB, `idp_`
  (direct perform inlining) 11 KB, `awp_` (await poll) 13 KB. A fifth, the
  replay loop, still lives in `lib/@vibe/compiler/codegen/expr/compile_expr_tail6.vibe`.

Largest single functions: `compile_wasi_module_linked_impl_with_typed_offsets`
66.6 KB, `check_expr_capture_impl` 66.5 KB, `compile_call_core` 63.5 KB,
`registry_typed_rows` 52 KB, `compile_call_gc` 44 KB, `compile_wasi_module_gc_impl`
26 KB, `lc_inject_async_sleep_boundary` 22 KB. `registry_typed_rows`
(`lib/@vibe/compiler/core/builtin_registry.vibe`), the two `iw_*_table`
functions in `lib/@vibe/compiler/codegen/common_base/inline_wat.vibe` (50 KB
together), `lc_inject_stdin_surface_wrappers` (10 KB), and
`double_parse_expr` / `double_to_string_expr` (19 KB, float algorithms built
as AST) are tables encoded as instruction sequences. They belong in the data
section, or as pre-assembled wasm bodies, where they compress to a fraction.

### Verdict on target 1

Compressed: met with a wide margin (372 KB brotli against a 3 MB limit).
Uncompressed 1.0 MB: **not met, and not reachable by tooling.** The arithmetic:

| step | bytes |
|---|---:|
| stage2 today | 2.72 MB |
| drop everything a compile-only Worker does not run (gc backend, component/serve, fmt, grep, editor queries, lsp, perceus/RC, caches/telemetry, debug) | −0.46 MB (17 %) → 2.26 MB |
| `wasm-opt -Oz` (measured ×0.78) | → 1.76 MB |
| move the data-as-code tables to data | about −0.10 MB → 1.66 MB |

That is still 1.7× the target. The remaining 1.66 MB is the language itself:
checker, the desugar collection, five effect lowerings, linear codegen. The
target is reached only by halving that core, which is a specification and
design decision (section 5), not an optimizer setting. Note also that the
feature-drop row assumes the dropped features are not reachable from the
compile path; today `VIBE_BACKEND`, `VIBE_RC`, `VIBE_DEBUG` and friends are
read at run time (section 4), so the compiler's own DCE cannot remove them.
The row is what becomes possible once they are build-time `#cfg` flags.

## 2. Memory

### Measured, stage1 built from this checkout (bump allocator, cold cache)

| input | closure | wall | heap_ptr | linear memory |
|---|---|---:|---:|---:|
| `bench/binary_size/hello_world.vibe` | 1 file | 0.28 s | 1.95 MB | 4 MB (64 pages, the minimum) |
| `lib/@vibe/json/json_test.vibe` | 8 files, 1.2 k lines | 0.65 s | 18.0 MB | 21 MB |
| `lib/@vibe/optimizer/wasm_opt_test.vibe` | 2 files, 9.6 k lines | 1.07 s | 54.9 MB | 72 MB |
| `lib/@vibe/parser/parser_smoke_test.vibe` | 17 files, 13.7 k lines | 2.18 s | 127 MB | 161 MB |
| `lib/@vibe/compiler/tests/codegen_lexer_test.vibe` | full compiler closure | 8.70 s | 1,354 MB | 1,835 MB |
| `lib/@vibe/lsp/lsp_diagnostics_test.vibe` (seed) | lsp + compiler | 24.4 s | 2,774 MB | 2,802 MB |

Warm (persistent cache populated, same input, seed compiler): full closure
5.6 s, heap_ptr 978 MB, 1,460 MB of pages. The issue's own HEAD numbers are
652 MB warm / 1,353 MB cold, consistent with the 1,354 MB cold measured here.

### Verdict on target 2

**Met for the measured closures up to 9.6 k lines; not met at 13.7 k.** The
closure column is the loader's own import closure (`vibe deps`), so the rows
are comparable: hello world through the 9.6 k-line optimizer closure reserve
at most 72 MB of linear memory and leave room for the JavaScript heap; the
13.7 k-line parser closure reserves 161 MB and does not fit. The boundary
between those two is unmeasured, and line count is only a proxy: the json
closure costs about 17 KB of pages per line and the optimizer about 7.5 KB,
because imported interfaces and source structure decide the allocation, not
length. So the honest statement is "closures the size of the optimizer fit,
closures the size of the parser do not", with one vibe package, not one
application, as the unit that fits. Wall time is
inside the paid CPU budget for every row and outside the free 10 ms one for
every row, hello world included: its 0.28 s is the wall time of a node process
that also starts the runtime and instantiates a 2.7 MB module, and no CPU-time
measurement was taken, so nothing here shows any compile fitting the free
budget.

### The shipped allocator is not the lever

The compiler self-build is pinned to the bump allocator (`VIBE_RC=0` in
`scripts/generations.sh`), which never frees. The obvious hypothesis is that
most of the 1.35 GB is garbage a freeing allocator would reclaim. It was tested:
a stage1 was built with `VIBE_RC=1` from the same flat source (4.76 MB with
names, against 3.36 MB for the bump build) and run on the same inputs.

| input | bump heap_ptr | RC heap_ptr | bump wall | RC wall |
|---|---:|---:|---:|---:|
| json_test | 18.0 MB | 21.4 MB | 0.65 s | 1.09 s |
| wasm_opt_test | 54.9 MB | 65.5 MB | 1.07 s | 1.87 s |
| parser_smoke_test | 127 MB | 153 MB | 2.18 s | 4.26 s |
| full closure | 1,354 MB | 1,526 MB | 8.7 s | 22.2 s |

The RC compiler uses **more** memory and 2 to 2.5× the wall time on every
input. What this does and does not show needs care. It shows that the RC lane
as shipped does not reduce the compiler's memory: RC adds headers and dup/drop
traffic, and the frontier did not come down. It does **not** prove that the
1.35 GB is all live. `heap_ptr` is the arena frontier under both lanes, and
the RC allocator's free-list walk is bounded to the first 16 nodes, bumping
on a deeper miss (`gen_rc_alloc_body` in
`lib/@vibe/compiler/codegen/builtin_bodies/bodies_core_a1a2.vibe`; the bound
was added because the unbounded walk cost 44 % of a self-compile), so on a
mixed-size workload a rising frontier can be bounded-search fragmentation as
much as reachability. Settling that needs a peak-live-bytes instrument (bytes
in reachable RC blocks at each phase boundary) or an allocator that reliably
reuses freed blocks; neither exists yet, and #2494 carries the measurement.
The structural facts still hold either way: the merged AST, the type
environments and the per-pass rewritten trees are all reachable until codegen
ends, so a freeing allocator cannot return them before then. The consequence
for the 128 MB question: **bounding the live set per unit of work is the lever
that works regardless of how that measurement comes out**, which means
processing one module at a time with the rest of the program present only as
interfaces, and the live-bytes number decides how much an allocator can add on
top.

### Verdict on target 3

**Not met, and no cache setting reaches it.** The warm lane still lexes and
parses every file of the merged program (0.6 s), runs every prelude pass over
the whole program (`effect_lowering_prelude` 1.3 to 1.5 s) and holds the whole
merged AST; the per-function body cache (#2388 step 3, opt-in) removes
`compile_expr` time but not the whole-program state, which is why warm heap is
still 650 to 980 MB. A 128 MB warm self-build needs the pipeline #2388's last
comment already describes (persisted parse per file, prelude analyses keyed per
function, desugars scoped to changed modules), plus one more constraint that
follows from the RC measurement: **the unit of work must run in an instance
whose memory is discarded afterwards.** `scripts/minify_wasm.sh` already uses
that shape (one pass per process because the optimizer never frees). A Worker
does **not** give it for free: the platform reuses an isolate and its global
scope across requests, so a compiler instance kept in module scope carries its
bump heap and `__heap_ptr` into the next compile. Dropping the JavaScript
reference is not a release either: `WebAssembly.Instance` and
`WebAssembly.Memory` have no disposal operation, so the pages stay live until
V8 collects them, on its schedule, and a request boundary inside a reused
isolate does not force that collection either. The only reclamation the
deployment can count on is therefore inside **one** linear memory that every
phase shares: the compiler exports an arena reset (the bump allocator makes
this cheap: `__heap_ptr` back to the static-data end plus re-initialization of
the module-level cells), and the same instance runs the next unit in the same
pages. Linear memory never shrinks, so the isolate then holds the maximum
arena high-water over the phases, not their sum, which is the bound the
per-module argument needs. Concurrent units count against the same 128 MB.
Without a shared memory and a reset, the per-module estimate does not bound
the isolate at all.

Budget check for that design, as an order of magnitude only: 1,354 MB over
about 260 k closure lines is about 5.2 KB of heap per source line on average,
so a unit of work the size of `desugar_trait_dict.vibe` (20 k lines) lands
near 100 MB on its own before its dependencies' interfaces, within a factor
of the whole budget. The average is not a threshold: the closures measured
above range from 7.5 to 17 KB of pages per line depending on structure and
imports, and splitting a file adds interface overhead of its own. So the
largest files are a memory concern for the per-module design, and the actual
cutoff (which module sizes fit a 128 MB shared-memory unit) is a measurement
to take on that unit once it exists (#2509), not a number to extrapolate.
Until then the file-split work (#1849) is motivated by this estimate and its
target size is set by the measurement, not by this paragraph.

## 3. Build units and dynamic linking

The compiler is 314 non-test files, 232 k lines (`lib/@vibe/compiler` and
`lib/@vibe/cli`), compiled as one closure; a generation build (seed to stage2
with validation) took 373 s here, one full compile 8.7 s. Comments are 17 % of
lines. Test files are another 79 k lines; the generated bundles 12 k.

Seams that already exist and could carry a split:

- `.vpkg` bodyless contracts are a stable module interface (ADR-0070).
- `lib/@vibe/compiler/ast_binary.vibe` is a versioned binary AST encoding
  designed for crossing a process boundary (`docs/ast_binary_abi.md`).
- The checked-body transport and `checker/artifacts` (#1958) are a typed-IR
  artifact format, shadow-only today.
- `CodegenBodyCache` persistence (#2388 step 3) is a per-function body store
  with the index spaces already made edit-stable (#2394, #2400).
- `vibec` (`docs/vibec-component.md`, `scripts/build_vibec.sh`) is a
  component with a `compile(source, request)` world and a `vibec-hosted` world
  whose imports are `read-file` / `exists` / `read-dir` / `stat-token`. That
  hosted world is the shape a Worker needs, with one caveat: its imports are
  synchronous WIT functions, and KV / R2 reads are promises that a synchronous
  wasm import cannot await. The host therefore prefetches the module's source
  closure into an in-memory VFS before entering the wasm (or the boundary
  becomes asynchronous through JSPI), and the callbacks answer from memory.

A split along these seams gives four build units plus tooling:

1. **frontend**: lexer, parser, loader, contract; emits binary AST + module
   headers per file;
2. **checker**: consumes headers + AST, emits checked module artifacts;
3. **lowering + codegen (linear)**: consumes checked artifacts for one module
   plus dependency interfaces, emits relocatable bodies;
4. **link**: monoify instantiation set, comparators, capability const-fold +
   DCE, index assignment, assembly (the whole-program steps #2388 lists);
5. tooling units that a Worker never loads: fmt, grep, editor queries, lsp,
   gc backend, component/serve codegen.

What component-model dynamic linking buys and costs here. Each unit is its own
component with its own linear memory, so every boundary is a serialization:
AST binary is already 5 to 10× smaller than JSON and single-pass to decode,
and the per-module design has to persist exactly these artifacts anyway, so the
serialization is paid once, not twice. The wins are the ones the question is
after: a change to the checker rebuilds one unit (a fraction of 8.7 s), each
unit's live memory is bounded by one module, and unit-level test suites stop
recompiling the whole compiler closure per test file (the largest CI cost,
per #2388). The cost is that the flat self-build lane (one merged source,
`selfbuild_compile_stage2`) and the stage2 == stage3 fixpoint check have to be
restated per unit, and the seed becomes several artifacts. That is a bootstrap
procedure change (`docs/bootstrap.md`), not a language change.

What a Workers deployment would actually look like, given the above: one
Worker holding the frontend, checker, codegen and link units (target: the
1.7 MB figure from section 1, or lower after section 5). A request names one
module; the host fetches that module's source closure and its dependencies'
interfaces from KV / R2 into an in-memory VFS first, then instantiates one
phase at a time, feeds it through the synchronous `vibec-hosted` callbacks,
serializes the phase's artifact, and reclaims the phase's memory before the
next phase starts; the link step is a separate request. "Reclaims" has to be
deterministic, and that rules out two tempting shapes. Dropping an instance
reference leaves its linear memory to V8's garbage collector, and a request
boundary in a reused isolate does not force collection, so with one component
per phase, each holding its own `WebAssembly.Memory`, the previous phase's
pages can still be resident while the next phase grows: resetting an arena
pointer inside a finished component shrinks nothing and hands nothing to the
next one. The deployed artifact is therefore a **single core module with one
linear memory** that all phases share, and the arena reset between phases
happens in that memory; the per-phase components of section 3 are the build
and test shape, and the Worker artifact is their single-memory link. Linear
memory never shrinks, so the isolate holds the maximum arena high-water over
the phases plus the serialization buffers in flight, not the sum of the
phases. That bound is measured as an aggregate on the shared-memory build,
never inferred from the per-phase numbers, and it is the same bound the
per-module design needs on every host.

The link unit is the exception to "one module at a time", and the per-module
argument does not bound it. Monoify instantiation, comparator emission,
capability DCE, index assignment and assembly are whole-program by definition
(`docs/incremental-build.md` keeps them as barriers), so running link as its
own request resets the earlier phases' memory but leaves the linker's own
working set at program size. Today that working set is the merged AST (the
1.35 GB figure); nothing here measures what it becomes once link consumes
pre-encoded bodies and interface summaries instead of trees. The design target
is a linker whose live set is output-sized (the compiler's own output is 4 MB
of bodies plus index tables) and whose whole-program decisions read summaries,
not bodies; whether that fits 128 MB for the compiler itself is an open
measurement, listed on #2507, and until it exists the 128 MB claim covers the
per-module phases only.

## 4. Environment flags

The compiler sources read **101 distinct `VIBE_*` variables**; 99 of the
`Env::get` sites are in `lib/@vibe/compiler/cli_adapter.vibe`. The host
runner and launcher read another 129 that never reach the wasm. They fall into
five classes, and only two of them are flags in the usual sense.

**(a) Command selectors, about 45.** The launcher talks to `cli_main` through
the environment (env-mode adapter), so every subcommand is a variable:
`VIBE_FMT`, `VIBE_GREP` and its five modifiers, `VIBE_LSP`, `VIBE_SYMBOLS`,
`VIBE_TYPE_AT` / `VIBE_TYPE_LINE` / `VIBE_TYPE_COL`, `VIBE_DOC_AT`,
`VIBE_BINDING_AT`, `VIBE_ESCAPES` / `VIBE_ESCAPES_STRICT`, `VIBE_ALLOCS`,
`VIBE_DEPS` / `VIBE_DEPS_DIRECT` / `VIBE_LIST_DEPS`, `VIBE_NORMALIZE`,
`VIBE_DIAGNOSTICS` and two modifiers, `VIBE_RC_PLAN` / `VIBE_RC_PLAN_FN` /
`VIBE_RC_CLASSIFY`, `VIBE_CHECK_ONLY`, `VIBE_INPUT` / `VIBE_OUTPUT` /
`VIBE_ENTRY`, `VIBE_COVERAGE` and the driver-source emitters, the six
`VIBE_PUBLISH_*`, `VIBE_HASH` / `VIBE_HASH_WRITE`, `VIBE_EMIT_WIT`,
`VIBE_SERVE_COMPONENT` / `VIBE_SERVE_WIT_OUT`, `VIBE_INSPECT_UPDATE` and its
stdout variant, `VIBE_TESTMETA_OUT` / `VIBE_ENTRY_TESTMETA_OUT`,
`VIBE_HOST_ACTION_OUT`, `VIBE_CHECK_ERROR_ROW`, `VIBE_MISSING_VPKG_SCAN` /
`VIBE_DEPS_MISSING_SCAN`, `VIBE_FILL_PINS` / `VIBE_REPIN` / `VIBE_REQUIRE_PINS`,
`VIBE_MODULE_PLAN` / `VIBE_MODULE_JOB_DIR`, `VIBE_PUBLISH_ENV_CACHE`,
`VIBE_EMIT_MERGED_SOURCE` / `VIBE_EMIT_MODULE_SOURCE`, `VIBE_BATCH_TSV`. None
of these hurts optimization (each is one compare in `cli_main`, 11 KB total),
but the protocol forces every tool into one binary. Changing the protocol to
argv does not by itself remove any of it: a run-time branch in `cli_main`
keeps every handler reachable, and exporting every handler makes each export a
DCE root. What lets the tooling units of section 3 exist is a build-time
boundary: separate executable-shaped artifacts, `#cfg` selection of the
handlers, or a build that exports exactly one entry.

**(b) Run-time lane switches, 9.** These are the ones that block DCE, because
the branch they guard is decided after the wasm is built: `VIBE_RC` (`0` / `1`
/ `shadow`), `VIBE_BACKEND` (`gc`), `VIBE_DEBUG`, `VIBE_DEBUG_BREAK`,
`VIBE_CODEGEN_BODY_CACHE`, `VIBE_FS_COMPILE`, `VIBE_WASM_NAMES`,
`VIBE_WASM_KEEP_EXPORTS`, `VIBE_DEP_ORDER_SEED`. Most of
them choose the shape of the *output* (which allocator lane, which backend,
instrumented or not, stripped or not), so they are per-deployment choices, not
per-request ones: a compile service that offers only "linear, RC off,
stripped" builds an artifact with exactly those lanes, and one that offers
more ships more than one artifact. Three reads that look similar are
deliberately **not** on this list, because they are per-compilation inputs
or authority that arrive with the request and cannot be fixed for a whole
deployment: `VIBE_CFG`, the `#cfg` set of the program being compiled
(`docs/cheatsheet.md` documents callers choosing it); `VIBE_UNSTABLE`, the
ADR-0068 authorization that lets one compilation import `@vibe/concurrent`
while the next one is refused (`cli_adapter.vibe` reads it per compilation;
fixing it at build time would either refuse every caller or grant every
caller); and `VIBE_INTERNAL_TRUSTED_SOURCE`, which lets the generated
flattened self-build sources bypass the user-source validation
(`validate_user_source_stmts`). Fixing that one to true would let any request
claim trusted provenance for the reserved Iterator boundary, and fixing it to
false would reject the self-build input, so it stays behind an authenticated
per-compilation boundary, or the self-build gets its own internal-only
artifact. What moves to build time is the compiler's own feature set, never
its users' program inputs or anyone's authority. The gc backend (140 KB), component/serve codegen
(88 KB), the RC shadow lane, the debug-break and trace codegen (9 KB) and the
body cache all stay in every artifact because of them. The mechanism to fix
this already exists: `apply_cfg_env` turns `VIBE_CFG=a,b` into `#cfg_enable`
directives and `#cfg(flag)` statements are dropped at parse time, zero bytes
in the output. Moving class (b) from `Env::get` to `#cfg` is the change that
makes the 17 % drop in section 1 real, and it is the compiler applying pillar 3
(capabilities fixed at build time drive DCE) to itself.

**(c) Experiment toggles, 4, of which one is over.**
`VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE` (the code calls it `legacy`;
typing reuse is on by default) kept both arms of a decided question compiled
and tested; it is deleted in #2496, and `VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE=1`
stays as the emergency opt-out the on/off oracle depends on.
`VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP` (a metadata-only fingerprint
hint, `docs/build-cache.md`) is **kept for now**, by decision: it belongs to
the incremental-build line, which is to be completed rather than trimmed, and
whether the trusted-stat shortcut has a place in that line is that line's
call; the record is on #2496. `VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE` was
misread as an experiment in the first draft of this report: `scripts/generations.sh`
defaults it to `1` for bootstrap builds and `lib/@vibe/cli/dispatch.vibe` uses
it to force the uncached path around the unstable-opt-in cache hole, so it is
an operational safety control and stays until the cache identity carries the
unstable verdict. `VIBE_MODULE_PLAN` / `VIBE_MODULE_JOB_DIR` (the `--jobs`
pre-warm, "dev checkout only" per the launcher) become deletable once #2388's
per-module scoping supersedes them.

**(d) Telemetry and trace sinks, 16.** `VIBE_INCREMENTAL_TELEMETRY_OUT`,
`VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT` / `_NONCE`,
`VIBE_ARTIFACT_INPUT_TRACE_OUT` / `_NONCE`, `VIBE_INGESTION_TELEMETRY_OUT` /
`_NONCE`, `VIBE_INGESTION_PIPELINE_TELEMETRY_OUT` / `_NONCE`,
`VIBE_SCHEDULER_TRACE`, `VIBE_PROFILE_MEMORY_MARK` / `_MARKS`,
`VIBE_PROFILE_TSV`, `VIBE_PROFILE_CALLSTACK`, the six `VIBE_SUITE_*`. Each
one threads an `Option[String]` sink through the pipeline and keeps a JSON
encoder linked. One `#cfg(telemetry)` gate for all of them removes the code
from release artifacts and the parameters from the hot signatures.

**(e) Paths, 3.** `VIBE_HOME`, `VIBE_LIB`, `VIBE_BUILD_CACHE_DIR`. Legitimate
run-time configuration.

## 5. What to delete or decide at the specification level

Ordered by bytes recovered per decision, with the line counts that go with them.

1. **One effect lowering, not five** (280 KB + the replay loop; ADR-0076).
   Direct-perform inlining, evidence dictionaries, the suspend CPS pass, the
   await poll pass and the replay loop each implement `handle` / `perform`
   for a different shape of program. The design policy says one concept, one
   spelling; today the spelling is one but the lowering has five bodies, and a
   program's shape decides which it gets. Deciding that evidence passing (with
   CPS for `Suspend`) is the lowering, and deleting direct inlining and replay
   as optimizations to be re-derived later, removes about 120 KB and 6 k lines
   and, more importantly, one whole class of "which lowering did this take"
   bugs (#1095, #1347, the M2 replay corruption).
2. **Retire the syntactic type inference inside normalize** (`infer_` 24 KB,
   plus the `eq_` / `interp_` / `dtd_` shape-recording machinery, together
   about 60 KB). #2386 item 5 already plans to delete the shape recording once
   the typed lane is affordable; `infer_arg_type_name` and its neighbours are
   the same duplication one level up (a second inference over syntax because
   the checker's answer was not available where the desugar runs). The
   per-module pipeline of section 3 makes the checker's answer available by
   construction, so this deletion falls out of that work.
3. **Split `desugar_trait_dict.vibe` into its 12 passes and decide each.**
   Labeled and optional arguments (`relabel_`, `optional_`), railway binds,
   array spread, `inspect`, string interpolation and derives are each a
   surface feature that costs a rewrite pass. This document does not argue
   for removing any of them; it argues that each should be a file whose size
   is visible, so the question "is this feature worth 26 KB of compiler" can
   be asked per feature. `dlh_` (lambda hoisting) is an optimization, not a
   desugar, and belongs with the optimizer.
4. **The gc backend becomes a `#cfg` build unit** (140 KB, 13 k lines in
   `codegen/gc`). The wasm-gc lane stays: it is pillar 2's reference lane and
   the owner's decision is to keep it. What changes is that today it is
   compiled into every artifact and selected by an env var at run time; as a
   `#cfg(gc)` unit it stays in the CLI build and is absent from the
   compile-only artifact, at no cost to the lane itself.
5. **Tables as data**: `registry_typed_rows`, the inline-wat tables, the
   stdin surface wrappers, the async sleep boundary, and the float algorithms
   (about 150 KB as instructions). Emitting them as data segments or
   pre-assembled bodies is mechanical and cuts both size and the compile time
   of the compiler itself (`registry_typed_rows` is one 52 KB function body).
6. **Component / serve codegen** (88 KB in stage2, 185 KB in the library
   build; `entry/source_compile/wasi_only/component_codegen.vibe` is 9.5 k
   lines). Same treatment as the gc backend: a `#cfg` unit.
7. **`checker/artifacts`** (9.6 k lines, shadow-only per #1958). The DCE
   already drops most of it (7 KB survives), so it is a line-count and
   comprehension cost rather than a byte cost. The incremental-build line is
   to be completed, so this lane is promoted rather than deleted: it becomes
   the checked-module artifact of section 3, which makes it production code
   with the coverage and validation obligations that come with that.

## 6. Suggested gates

- A compiler-size KPI in the same shape as `scripts/bench_binary_size.sh`:
  bytes of the stripped stage2 code section, and after `wasm-opt -Oz` with the
  explicit feature list, ratcheted like `bench/perf/size_baseline.txt`.
- A memory KPI for a mid-size closure. The full-closure KPI cannot see the
  128 MB question; the parser closure is the right probe for "does one package
  compile in an isolate". The gated number is the reserved linear memory
  (`memory.buffer.byteLength`, 161 MB today for that closure), not `heap_ptr`
  (127 MB): the isolate limit counts pages, a `heap_ptr` gate would read as
  within budget while the memory is already 33 MB over it, and the JavaScript
  heap still has to fit beside it.
- The generation build should produce the named stage2 as a by-product when
  asked (`VIBE_WASM_NAMES=1 bash scripts/generations.sh build --out-dir <dir>`
  works today but takes six minutes), so attribution tables like the ones above
  are cheap to regenerate.
