# ADR-0086: Compiler host runtime contract (#1143)

Status: accepted

Date: 2026-07-28

Related: ADR-0010 (WASM Component Model / WIT integration; this is its
compiler-host instance), ADR-0079 (wasm proposals split into compiler-host and
codegen-target levels; `runtime/viberun` may depend on experimental features),
ADR-0103 (Wasmtime AOT is a host-side accelerator, and the canonical selfhost
artifact stays runnable as standalone WASI wasm — the same "do not require
Wasmtime" motive), ADR-0056 (`runtime/viberun` and the `.cwasm` cache are an
execution substrate, separate from the canonical artifact), ADR-0084 (effect
classes and the entry row; generating WIT for builtin effects in user programs
is its subject, not this one's), [effect-wit-mapping.md](effect-wit-mapping.md)
(`vibe compile --wit`, the WIT of a *compiled program's* effect surface — a
sibling mechanism for a different subject).

## Why this exists

A wasm runner has to provide some set of host functions for the compiler's own
entry point, `cli_main`, to run at all. That set was implicit in two runner
implementations — `runtime/viberun` (Rust / Wasmtime) and
`scripts/wasm_vibe_host_runner.js` (Node) — and described nowhere on its own.
This is not what `vibe compile --wit` answers: that renders a compiled
program's own effect surface and leaves host capabilities as a comment.

## The contract

**The row.** The compiler adapter's entry is

```text
export fn cli_main() -> Int with Exception + Fs + Env + Stdin + Console + Stderr + Process + Profiler
```

in `lib/@vibe/compiler/cli_adapter_cli_main_with_lanes.vibe`. Its host boundary
is what that row admits, lowered to raw `vibe.*` core imports:

- `Exception` never crosses the boundary. It is vibe-internal control flow; an
  escaping throw is a trap, not a host capability — the rule `wit_gen.vibe`
  applies to user programs too.
- `Console` is the label `print` carries and lowers onto the `stdout` imports;
  there is no `console` import.
- `Process` reaches the host as `process_exit` (`vibe_process_exit_raw`), and
  `Stderr` as `stderr_write_stream`.
- The boundary is the functions `cli_main` actually reaches, not every builtin
  tagged with a label on its row: a row admits all `Fs` builtins, and late DCE
  keeps an import only when a reachable call survives (imports are
  demand-gated on the used builtin names).

**The inventory is the import section of the built compiler.** Every name in it
is a `portableCore` field of `docs/generated/host-runtime-contract.json`, and
`scripts/check_host_runtime_contract.py` checks fail-closed that the emitter
and both runners agree on that band, so a conformant runner is one that
implements the band. Measured on the committed seed
(`seed/array-capacity-2026-09-20`, `bootstrap/seed/compiler.wasm`), with
`node scripts/host_capability_probe.mjs <compiler.wasm>`:

| interface | imports |
|---|---|
| `fs` | `fs_read_file`, `fs_read_bytes`, `fs_write_file`, `fs_write_bytes`, `fs_exists`, `fs_is_dir`, `fs_is_file`, `fs_stat_token`, `fs_read_dir`, `fs_mkdir_p`, `fs_remove`, `fs_remove_file`, `fs_getcwd` |
| `env` | `env-get`, `args-len`, `args-get` |
| `stdin` | `stdin_read_char`, `stdin_read_stream` |
| `stdout` | `stdout_write_char`, `stdout_write_stream` |
| `stderr` | `stderr_write_stream` |
| `process` | `process_exit` |
| `profiler` | `profile-now-us` |

plus `wasi_snapshot_preview1.fd_write`, which is not part of `vibe.*`. The
names come from the codegen of the compiler that compiled it, so a compiler
built by a stage2 from this checkout imports `fs_read_dir_nul` instead of the
seed's `fs_read_dir` (#2957, a NUL-joined result); both runners still provide
`fs_read_dir` for modules built before that change.

**Values** follow the raw core ABI of
[../../user/reference/host-runtime-contract.md](../../user/reference/host-runtime-contract.md):
packed `(ptr << 32) | byte_len` strings, the `Bytes` header struct, untagged
`i64` results (`vibe.abi: host_import_abi=raw`).

**Not part of the contract**: preopen-directory sandboxing, store and linker
setup, fuel and memory limits, and other per-runner configuration
(`runtime/viberun`'s `register_vibe_imports` in `src/host_imports.rs`, the
node runner's `vibe` import object). They are how a runner implements the
imports, not what the imports are, and a third runner may sandbox differently.

**The worker-transport modes need nothing new.** `VIBE_MODULE_JOB_DIR`,
`VIBE_LIST_DEPS` and `VIBE_PUBLISH_ENV_CACHE` (the `--jobs N` parallel frontend,
[compiler-parallelism.md](compiler-parallelism.md)) are `Env::get`-gated
branches in the same adapter that read and write files through the same `fs`
imports, treating the input / output path as a directory.

## The hand-written WIT world

`docs/internal/compiler/wit/vibe-compiler-host.wit` renders this boundary as a
WIT world (`fs`, `env`, `stdin`, `stdout`; export `cli-main`). It is
hand-written and nothing checks it against the import section, and it has
fallen behind it: its `fs` interface has six functions (`read-file`,
`write-file`, `write-bytes`, `exists`, `stat-token`, `readdir`), it has no
`stderr`, `process` or `profiler` interface, and its `readdir` returns
`list<string>` where the raw import returns one joined string. Generating it
from the same table the emitter uses is ADR-0112's design
([host-contract-artifact-lazy-cli.md](host-contract-artifact-lazy-cli.md)
§1.4), which is unimplemented and has no open owner. Until then the manifest
and the built compiler's import section, not the `.wit`, are the contract.
