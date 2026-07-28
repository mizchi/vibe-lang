# Compiler host runtime contract (#1143)

> **Status (2026-07-28):** first pass. Documents what exists today; does not
> change any runner implementation. `docs/wit/vibe-compiler-host.wit` is the
> reference world.

## Why this exists

The compiler's own host boundary — what a wasm runner must provide for
`cli_main` to work at all — was previously only implicit in two concrete
runner implementations: `runtime/vibewt` (Rust/Wasmtime) and
`scripts/wasm_vibe_host_runner.js` (Node, also Wasmtime-backed). Nothing
described the contract itself, independent of either implementation. This is
distinct from `vibe compile --wit` (`docs/effect-wit-mapping.md`), which
renders a **compiled program's own** effect surface as WIT — that generator
explicitly leaves host-capability effects (`Fs`, `Env`, `Stdin`, `Stdout`,
...) as a `// host capability effect '...' (provided by the vibe runtime; no
WIT mapping yet)` comment rather than a real import. This doc (and its
companion `.wit` file) is a hand-authored answer to that gap, scoped to the
compiler's own entry point rather than arbitrary user programs.

## The contract

`export fn cli_main() -> Int with { Error, Fs, Env, Stdin, Stdout }`
(`lib/@vibe/compiler/cli_adapter.vibe`) is the row that matters. `Error`
never crosses the host boundary (vibe-internal control flow — an escaping
throw is a component trap, not a host capability), matching the rule
`wit_gen.vibe` already applies to user programs. The other four map to
`docs/wit/vibe-compiler-host.wit`'s four `import` interfaces, with
signatures taken verbatim from where the guest side declares them:

| interface | op | guest declaration |
|---|---|---|
| `fs` | `read-file`/`write-file`/`exists`/`mkdir` | `effect Fs { ... }`, `lib/@vibe/fs/fs_effect.vibe` |
| `env` | `get`/`args-get`/`args-len` | `lookup_io_b`, `lib/@vibe/compiler/checker/builtins_system.vibe` |
| `stdin` | `read-char`/`read-stream` | `lookup_io_a`, same file |
| `stdout` | `write-char`/`write-stream` | `lookup_io_b`, same file |

Types follow `wit_type_text`'s existing mapping (`Int` → `s64`, `Bool` →
`bool`, `String` → `string`, `Unit` → omitted return type). Parameters are
positional (`arg0`, `arg1`, ...) — vibe effect operation declarations don't
carry parameter names, the same reason `wit_gen.vibe`'s own output uses
`arg0`/`arg1`.

## What's NOT part of this contract

Preopen-dir sandboxing, store/linker setup, fuel/memory limits, and other
per-runner configuration (`runtime/vibewt/src/main.rs`'s `linker.instantiate`
call sites) are how a given runtime chooses to implement these imports, not
part of what the imports are. A conformant third runner is free to sandbox
differently as long as it exposes the same four interfaces.

## The #906 worker-transport adapter modes need nothing new

`VIBE_MODULE_JOB_DIR`, `VIBE_LIST_DEPS`, `VIBE_PUBLISH_ENV_CACHE`
(`cli_adapter.vibe`, added for the `--jobs N` parallel frontend work,
`docs/compiler-parallelism.md`) are plain `Env::get(...) == "1"`-gated
branches that only ever call `fs.read-file`/`fs.write-file` — treating
`input_path`/`output_path` as a directory rather than a single file in
job-dir/env-cache mode. No new host imports; same four interfaces, different
env var and path-shape convention.

## A drift this pass already found

The two existing runners do **not** implement the same surface today.
`runtime/vibewt`'s `register_vibe_imports` implements exactly the contract
above (plus `Process`/`sh` and a debugger-only surface `cli_main` doesn't
use). `scripts/wasm_vibe_host_runner.js`'s Node `vibeModule` implements a
strict superset: `fs_getcwd`/`fs_chdir`/`fs_mkdir_p`/`fs_rename`/`fs_copy`/
`fs_append`/streaming-write ops, plus an entire `http_*`/`json_*` surface —
**none of which `runtime/vibewt` implements at all**. `cli_main` itself
never calls any of this; it belongs to library effects (`lib/@vibe/http`,
extended `lib/@vibe/fs` ops) used by **compiled user programs**, generated
per-program by the existing `--wit` path, not by this fixed compiler-host
contract. Recorded here as evidence for exactly the kind of informal
drift #1143 was raised to prevent, not as something this pass fixes.

## Non-goals of this pass

- No runner was changed to conform to or validate against this `.wit` file.
- No third (non-Wasmtime) runtime implementation was written or attempted.
- The Node/vibewt surface mismatch above is recorded, not resolved.
- Whether/how to keep this file mechanically in sync with the two runners
  going forward (a differential check, a generator, ...) is unscoped follow-up.
