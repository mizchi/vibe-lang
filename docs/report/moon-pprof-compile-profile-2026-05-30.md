# moon-pprof CPU profile of `vibe compile` (#402)

2026-05-30. Function-level CPU profile of the compile hot path using
[`mizchi/moon-pprof`](https://github.com/mizchi/moon-pprof), to complement the
manual `--profile-callstack` stage breakdown and guide the next compile lever.

## Why a harness + samply (not `moon-pprof profile <wasm>`)

`moon-pprof profile <wasm>` runs a wasm under wasmtime + a guest profiler, but
its host only provides the minimal MoonBit imports (`spectest.print_char` +
WASI `fd_write`). The selfhost compile wasm (`vibe_compile_wasi.wasm`) needs
the custom `__moonbit_fs_unstable.*` host imports (to read source / write
output), which moon-pprof does not define:

```
moon-pprof: unknown import: `__moonbit_fs_unstable::begin_read_string_array` has not been defined
```

A no-fs harness wasm doesn't help either: the compile path transitively
references `@os_fs` (the #427/#476 disk caches), so the fs imports are linked
regardless of runtime flags.

**Workflow used instead** (native CPU profile → pprof):

```bash
# 1. native harness that compiles an embedded source in-memory in a loop
moon build --target native src/cmd/vibe_pprof_harness
# 2. record (needs perf_event_paranoid <= 1)
echo 1 > /proc/sys/kernel/perf_event_paranoid
samply record --save-only -o prof.json \
  _build/native/debug/build/cmd/vibe_pprof_harness/vibe_pprof_harness.exe
# 3. convert + summarize with moon-pprof
moon-pprof firefox2pprof prof.json prof.pb.gz
moon-pprof summary prof.pb.gz
moon-pprof pprof2folded prof.pb.gz folded.txt   # for stack-level analysis
```

`src/cmd/vibe_pprof_harness` embeds `bench/compiler_size/cases/base64.vibe` and
calls `@runtime_compile.compile_module_wasm_with_opt_level` on an in-memory
`VibeDb` (`db.set_source`) — no fs, no CLI args.

Note: samply `--save-only` leaves frame symbols in a `.syms.json` sidecar that
moon-pprof's `firefox2pprof` does not read, so `summary` shows raw addresses;
symbolicate the top addresses with `addr2line -f -e <binary> <addr>`.

## Findings

### Memory management dominates (~30%+ self time)

| function | self time |
|---|---|
| `moonbit_incref_inlined` | ~15% |
| `moonbit_decref_inlined` | ~8% |
| `_mi_page_malloc_zero` / `__libc_malloc` / `operator delete[]` | ~8% |

The compile path is **allocation-bound** — refcount churn + malloc/free are the
largest self-time buckets. Reducing per-compile allocation (re-building the
prelude/builtin stmt set every compile) is the highest-leverage win.

### Hot user functions on the call stacks

(by sample count; `addr2line`-symbolicated from the folded stacks)

- `parser/AstParser.parse_*` (parse_expr / or / and / pipe / unary) — heavy,
  but **over-represented by the harness** (it recompiles the *same* source N
  times and the db re-parses the user source each `VibeDb::new()`; real compiles
  parse each file once).
- **`core.walk_block_refs`** — the reference walk used by the bundle stage's
  prelude partition (dependency graph) and surgical prelude DCE. Confirms the
  bundle fixed cost found via `--profile-callstack` (`bundle/collect/prelude_add`
  + `bundle/collect/dce`).
- `VibeDb.imports` + `ripple Query.fetch/execute` (ImportSpec / HashedModule) —
  incremental-query overhead in import resolution.

## Takeaway for #402

Both the stage profile (`bundle` ~4×, dominated by re-processing the whole
prelude/builtin set) and this CPU profile (allocation-bound; `walk_block_refs`
hot) point to the same lever: **cache the bundled prelude/builtin stmt set**
(analogous to #427/#476) so each compile doesn't re-merge, re-walk, and
re-allocate the standard library. That cuts both the ref-walk time and the
allocation churn this profile attributes to memory management.
