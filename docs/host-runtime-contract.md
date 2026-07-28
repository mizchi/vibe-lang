# Compiler host runtime contract (#1143)

> **Status (2026-07-28):** two passes. Round 1 documented the contract
> (over-broadly, per Codex review). Round 2 audited every op for real
> `cli_main` reachability and narrowed it to what's actually called,
> resolving round 1's open question about `runtime/vibewt`'s missing
> registrations along the way. Neither pass changed any runner
> implementation. `docs/wit/vibe-compiler-host.wit` is the reference world.

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

**Round 1 correction (Codex review, PR #1178):** the first version of this
doc derived the `fs` interface from `effect Fs { ReadFile, WriteFile,
Exists, Mkdir }` (`lib/@vibe/fs/fs_effect.vibe`) — that's wrong. That block
is only a 4-op convenience subset for user-program `import Fs` usage. The
actual boundary the checker enforces is a per-builtin string tag
(`Some("Fs")` on each entry in
`lib/@vibe/compiler/codegen/common_base/builtin_registry.vibe`, plus
`Fs::readdir` in `checker/builtins_fs.vibe`), and `cli_main`'s `with {
Fs }` row admits any builtin carrying that tag. Round 1 added all 17
tagged ops on that basis.

**Round 2 correction (self-review, following up on round 1's own open
question):** admitting an op via the row tag and `cli_main` actually
*calling* it are different things — round 1 conflated them. Audited every
`Fs::<op>(` call site across `lib/@vibe/compiler`, excluding tests, the
checker/codegen registration tables themselves, and the auto-generated
`*_bundle.vibe` flatten artifacts (which just duplicate other files' text).
Seven ops have real, non-test call sites in load-bearing compiler files:

| op | found in |
|---|---|
| `read-file`, `write-file`, `write-bytes` | `cli_adapter.vibe` directly (its primary output path — compiled artifacts, funcmap, wit, component, normalize/doc-at/binding-at/symbols/diagnostics text — is `write_bytes`, never `write_file`) |
| `exists` | `runtime/typecheck_fs.vibe`, `cache/persistent_cache.vibe` |
| `stat-token` | `loader/loader.vibe`, `core/module_graph_path.vibe` |
| `remove` | `entry/cli_cache/cli_cache.vibe` |
| `readdir` | `loader/loader.vibe`, `loader/header_cache.vibe` |

The other ten round-1 ops — `read-bytes`, `is-dir`, `is-file`, `mkdir`,
`mkdir-p`, `chdir`, `getcwd`, `copy`, `append`, `rename` — have **zero**
real call sites anywhere in the compiler's own source. They're recognized
builtin names (the checker accepts them when a *user* program calls them
via `import Fs`/`lib/@vibe/fs`), but `cli_main` never invokes them itself.
Removed from the `.wit` file; `env`/`stdin`/`stdout` were untouched by
either round (already tag-consistent with their builtin-table signatures,
`lookup_io_a`/`lookup_io_b` in `checker/builtins_system.vibe`).

Types follow `wit_type_text`'s existing mapping (`Int` → `s64`, `Bool` →
`bool`, `String` → `string`, `Bytes` → `list<u8>`, `Unit` → omitted return
type). Parameters are positional (`arg0`, `arg1`, ...) — vibe effect
operation declarations don't carry parameter names, the same reason
`wit_gen.vibe`'s own output uses `arg0`/`arg1`.

**Round 1's open question, resolved by round 2:** `runtime/vibewt/src/main.rs`'s
`register_vibe_imports` has no `fs_mkdir`/`fs_mkdir_p`/`fs_chdir`/
`fs_getcwd`/`fs_copy`/`fs_append`/`fs_rename` registrations at all
(confirmed by direct grep), while `scripts/wasm_vibe_host_runner.js`'s Node
runner implements all of them. The round-2 reachability audit confirms
this is **not** a live gap: `cli_main` never reaches any of those seven
ops, so `vibewt` correctly omits them — the Node runner's superset there is
serving *user-program* `lib/@vibe/fs` usage (via the general-purpose `--wit`
path), not something `cli_main` itself needs.

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

## A drift found, and resolved as benign

`runtime/vibewt`'s `register_vibe_imports` implements exactly this
contract's seven `fs` ops, plus `env`/`stdin`/`stdout` in full, plus
`Process`/`sh` and a debugger-only surface `cli_main` doesn't use.
`scripts/wasm_vibe_host_runner.js`'s Node `vibeModule` implements a
superset: this contract's seven ops, PLUS the ten round-1-then-removed
ops (`read-bytes`/`is-dir`/`is-file`/`mkdir`/`mkdir-p`/`chdir`/`getcwd`/
`copy`/`append`/`rename`), PLUS an entire `http_*`/`json_*` surface. Both
extra pieces of the Node superset belong to library effects
(`lib/@vibe/fs`'s full surface, `lib/@vibe/http`) used by **compiled user
programs**, generated per-program by the existing `--wit` path — not by
this fixed compiler-host contract. `cli_main` itself never reaches any of
it. This was exactly the kind of informal drift #1143 was raised to
prevent, and the round-2 reachability audit above resolves it: not a live
bug, just two runners that happen to serve different total surfaces
(compiler-only vs. compiler-plus-every-user-library-effect) while agreeing
completely on what `cli_main` itself needs.

## Non-goals of this pass

- No runner was changed to conform to or validate against this `.wit` file.
- No third (non-Wasmtime) runtime implementation was written or attempted.
- Whether/how to keep this file mechanically in sync with the two runners
  going forward (a differential check, a generator, ...) is unscoped follow-up.
