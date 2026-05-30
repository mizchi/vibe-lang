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

## Harness must bust the compile caches

`runtime_compile` has global `compile_module_cache` (path-keyed) and
`wasm_artifact_cache` (content-keyed). Compiling the *same* `"main"` source N
times hits them after the first pass, so most iterations skip
emit/optimize/most-of-compile and the samples describe the **cache-hit** path,
not a fresh compile (thanks to Codex review on #480 for catching this). The
harness therefore varies both the module path and the source content each
iteration (`m<i>` + a `// iter <i>` comment) so every compile is a cache miss
(~0.13ms/iter cached → ~7ms/iter fresh), and aborts on compile error instead of
swallowing it.

## Findings (fresh compile — cache-busted)

Top user functions by stack frequency (`addr2line`-symbolicated from folded
stacks; ~9.2k samples over 10.6s):

| function | ~% of stacks | what |
|---|---|---|
| `ripple Query.fetch/execute<TypeEnv>` + `VibeDb.types` | ~86% | **typecheck**, driven through the incremental-query framework |
| `parser/AstParser.parse_*` | ~58% | parsing the user module |
| `checker.type_expr_eff` | ~37% | expression typechecking |

A fresh compile is **dominated by typecheck (incl. ripple incremental-query
overhead) and parse** — both program-proportional, not fixed startup. The
bundle prelude processing (`walk_block_refs` etc.) that looked hot in the
*cache-hit* profile is a smaller, fixed component once caches are busted.

Memory management (`moonbit_incref/decref_inlined`, malloc/free) is still a
large self-time bucket (~25-30%), consistent with the AST/TypeEnv-heavy
allocation of typecheck + parse.

## Takeaway for #402

- The largest compile cost is **typecheck**, routed through `ripple Query`
  (incremental-query) machinery — the query/caching overhead and the
  `type_expr_eff` tree walk are the constant factors to attack next, and they
  scale with the program (not fixed startup).
- The bundle prelude partition is a smaller **fixed** cost; the companion
  branch removes it via a disk snapshot of the partition name-set (a focused
  win for fresh selfhost processes), but it is not the dominant compile lever
  that the cache-hit profile suggested.
