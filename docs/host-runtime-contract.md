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
`docs/wit/vibe-compiler-host.wit`'s four `import` interfaces.

**Correction (Codex review, PR #1178 round 1):** the first version of this
doc derived the `fs` interface from `effect Fs { ReadFile, WriteFile,
Exists, Mkdir }` (`lib/@vibe/fs/fs_effect.vibe`) — that's wrong. That block
is only a 4-op convenience subset for user-program `import Fs` usage. The
actual boundary the checker enforces is a per-builtin string tag
(`Some("Fs")` on each entry in
`lib/@vibe/compiler/codegen/common_base/builtin_registry.vibe`, plus
`Fs::readdir` in `checker/builtins_fs.vibe`), and `cli_main`'s `with {
Fs }` row admits any builtin carrying that tag — 17 of them, not 4.
`cli_adapter.vibe` itself directly calls `Fs::write_bytes` (14x),
`Fs::write_file` (14x), and `Fs::read_file` (12x) — `write_bytes` is how it
writes essentially all CLI output (compiled artifacts, funcmap, wit,
component, normalize/doc-at/binding-at/symbols/diagnostics text), not
`write_file`. The other 14 ops (`exists`, `stat-token`, `is-dir`,
`is-file`, `remove`, `mkdir`, `mkdir-p`, `chdir`, `getcwd`, `copy`,
`append`, `rename`, `read-bytes`, `readdir`) come from files `cli_main`
transitively calls into (cache/persistent_cache.vibe, loader.vibe,
coverage_suite_lib.vibe, ...) rather than `cli_adapter.vibe` itself —
included in the `.wit` file since they carry the same "Fs" row tag and are
used pervasively across `lib/@vibe/compiler` (1500+ combined call sites),
but per-op reachability from `cli_main`'s specific dynamic call graph
(vs. just being present somewhere in the compiler's source tree) was not
individually traced for each of the 14. `env`/`stdin`/`stdout` were already
tag-consistent with their builtin-table signatures (`lookup_io_a`/
`lookup_io_b`, `checker/builtins_system.vibe`) and needed no correction.

Types follow `wit_type_text`'s existing mapping (`Int` → `s64`, `Bool` →
`bool`, `String` → `string`, `Bytes` → `list<u8>`, `Unit` → omitted return
type). Parameters are positional (`arg0`, `arg1`, ...) — vibe effect
operation declarations don't carry parameter names, the same reason
`wit_gen.vibe`'s own output uses `arg0`/`arg1`.

**Open question this correction surfaced, not resolved here:**
`runtime/vibewt/src/main.rs`'s `register_vibe_imports` has no
`fs_mkdir`/`fs_mkdir_p`/`fs_chdir`/`fs_getcwd`/`fs_copy`/`fs_append`/
`fs_rename` registrations at all (confirmed by direct grep), while
`scripts/wasm_vibe_host_runner.js`'s Node runner implements all of them.
Whether this means `vibe` built through `vibewt` would fail to instantiate
or trap if a code path using one of these ops is actually reached (vs.
those calls being confined to source that's part of the compiler's tree but
not reachable from `cli_main`'s own compiled binary) was not determined in
this pass — worth a dedicated follow-up rather than asserted as a live bug
here.

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
`runtime/vibewt`'s `register_vibe_imports` implements `read-file`/
`write-file`/`write-bytes`/`read-bytes`/`exists`/`stat-token`/`is-dir`/
`is-file`/`remove`/`readdir`, `env`/`stdin`/`stdout` in full, plus
`Process`/`sh` and a debugger-only surface `cli_main` doesn't use — but
**not** `mkdir`/`mkdir-p`/`chdir`/`getcwd`/`copy`/`append`/`rename` (see
the open question above — these may or may not be reachable from
`cli_main`'s own compiled binary). `scripts/wasm_vibe_host_runner.js`'s
Node `vibeModule` implements the full `fs` interface above INCLUDING those
seven, plus an entire `http_*`/`json_*` surface that belongs to library
effects (`lib/@vibe/http`) used by **compiled user programs**, generated
per-program by the existing `--wit` path, not by this fixed compiler-host
contract — that part of the Node superset is confirmed out of scope here.
The `mkdir`/`chdir`/`getcwd`/`copy`/`append`/`rename` gap is recorded as
exactly the kind of informal drift #1143 was raised to prevent; whether
it's a live bug or genuinely dead code from `cli_main`'s perspective is the
open question above, not resolved in this pass.

## Non-goals of this pass

- No runner was changed to conform to or validate against this `.wit` file.
- No third (non-Wasmtime) runtime implementation was written or attempted.
- The Node/vibewt surface mismatch above is recorded, not resolved.
- Whether/how to keep this file mechanically in sync with the two runners
  going forward (a differential check, a generator, ...) is unscoped follow-up.
