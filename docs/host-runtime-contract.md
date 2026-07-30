# ADR-0086: Compiler host runtime contract (#1143)

Status: accepted

Date: 2026-07-28

Related: ADR-0010(WASM Component Model / WIT 統合 — 本 ADR が定める host
import 契約はこの WIT 化方針の compiler-host 版)、ADR-0079(wasm proposal
依存を compiler-host / codegen-target の2水準に分離 — `runtime/vibewt` を
実験的機能に依存してよい実行基盤として扱う既存の前例)、ADR-0050(wasmtime
AOT は selfhost bench の host-side accelerator であり、canonical selfhost
artifact は WASI wasm standalone として実行可能であり続けるべき、という
「Wasmtime を必須にしない」という本 ADR と同じ動機の既存決定)、ADR-0056(
`runtime/vibewt` / cwasm cache を execution substrate として canonical
artifact と切り分ける cutover ADR)、ADR-0084(capability/algebraic effect
の分類と `.vibex` entry row の許可規則 — resource kind retrofit 後の
builtin effect の WIT 生成は同 ADR の射程、本 ADR は compiler 自身の
host boundary という別の対象を扱う姉妹 ADR)、
[docs/effect-wit-mapping.md](effect-wit-mapping.md)
(`vibe compile --wit` によるユーザープログラム側の effect-surface WIT 化 —
本 ADR が扱う compiler 自身の host boundary とは対象が異なる姉妹機構)

> **Status (2026-07-28):** three passes, two rounds of Codex review. Round 1
> documented the contract (over-broadly). Round 2 audited every op for real
> `cli_main` reachability and narrowed it, but got two details wrong. Round 3
> (Codex review again) fixed those: dropped `Fs::remove` (its only call site
> is an orphaned entry point, not reachable from `cli_main`) and corrected a
> false claim about which ops `runtime/vibewt` does/doesn't implement. No
> pass changed any runner implementation. `docs/wit/vibe-compiler-host.wit`
> is the reference world.

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

**Round 3 correction (Codex review, PR #1180):** round 2's audit checked
for *any* real call site but didn't check whether the *file containing*
that call site is itself reachable from `cli_main`'s import graph — missing
that `Fs::remove`'s only call site is under `entry/cli_cache/`, an
alternate entry point `cli_adapter.vibe` never imports and nothing else in
the compiler calls into. Dropped. Round 2 also mischaracterized which of
the ten removed ops are actually missing from `runtime/vibewt` — corrected
below. The final six ops, verified reachable from `cli_main`'s own import
graph (`cli_adapter.vibe` directly imports the `runtime` and `loader`
packages):

| op | found in |
|---|---|
| `read-file`, `write-file`, `write-bytes` | `cli_adapter.vibe` directly (its primary output path — compiled artifacts, funcmap, wit, component, normalize/doc-at/binding-at/symbols/diagnostics text — is `write_bytes`, never `write_file`) |
| `exists` | `runtime/typecheck_fs.vibe`, `cache/persistent_cache.vibe` (under the imported `runtime` package) |
| `stat-token` | `loader/loader.vibe`, `core/module_graph_path.vibe` (under the imported `loader` package) |
| `readdir` | `loader/loader.vibe`, `loader/header_cache.vibe` (same package) |

The other eleven round-1 ops — `read-bytes`, `is-dir`, `is-file`, `remove`,
`mkdir`, `mkdir-p`, `chdir`, `getcwd`, `copy`, `append`, `rename` — either
have zero real call sites anywhere in the compiler's own source, or (in
`remove`'s case) a real call site that isn't reachable from `cli_main`.
They're recognized builtin names (the checker accepts them when a *user*
program calls them via `import Fs`/`lib/@vibe/fs`), but `cli_main` never
invokes any of them itself. `env`/`stdin`/`stdout` were untouched by any
round (already tag-consistent with their builtin-table signatures,
`lookup_io_a`/`lookup_io_b` in `checker/builtins_system.vibe`).

Types follow `wit_type_text`'s existing mapping (`Int` → `s64`, `Bool` →
`bool`, `String` → `string`, `Bytes` → `list<u8>`, `Unit` → omitted return
type). Parameters are positional (`arg0`, `arg1`, ...) — vibe effect
operation declarations don't carry parameter names, the same reason
`wit_gen.vibe`'s own output uses `arg0`/`arg1`.

**Round 1's open question, resolved by round 2, corrected by round 3:**
round 2 claimed `runtime/vibewt/src/main.rs`'s `register_vibe_imports` has
no registrations at all for the ten then-removed ops. Wrong — Codex caught
that vibewt actually registers three of them (`fs_is_dir`, `fs_is_file`,
`fs_read_bytes`, confirmed at lines ~1791-1835), it just doesn't register
the other seven (`fs_mkdir`/`fs_mkdir_p`/`fs_chdir`/`fs_getcwd`/`fs_copy`/
`fs_append`/`fs_rename`). Whichever runner implements how many of them is
moot for this contract either way: `cli_main` reaches none of the eleven
excluded ops, so neither vibewt's partial coverage nor the Node runner's
full coverage of them matters — that surface serves *user-program*
`lib/@vibe/fs` usage (via the general-purpose `--wit` path), not something
`cli_main` itself needs.

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
contract's six `fs` ops (`read-file`/`write-file`/`write-bytes`/`exists`/
`stat-token`/`readdir`), `env`/`stdin`/`stdout` in full, plus `Process`/`sh`
and a debugger-only surface `cli_main` doesn't use. It also happens to
implement all eleven of the excluded-from-this-contract-but-still-a-real-builtin
ops (`is_dir`/`is_file`/`read_bytes`/`mkdir`/`mkdir_p`/`chdir`/`getcwd`/
`copy`/`append`/`rename`/`remove`) — full parity with
`scripts/wasm_vibe_host_runner.js`'s Node `vibeModule` on the `Fs` surface
as of #1220 (originally `remove`/`is_dir`/`is_file` from #901, `read_bytes`
from #632, and `rename`/`mkdir`/`mkdir_p`/`chdir`/`getcwd`/`copy`/`append`
from #1220 — the last seven had been recognized builtins with real call
sites, e.g. `lib/@vibex/shell/commands.vibe`, `coverage_local_merge.vibe`'s
atomic-write pattern, but crashed any program calling them under the real
`vibe run` with an unknown-import trap until #1220 ported them). The Node
runner still has an entire `http_*`/`json_*` surface neither this contract
nor `vibewt` has — that extra surface belongs to library effects
(`lib/@vibe/http`) used by **compiled user programs**, generated
per-program by the existing `--wit` path — not by this fixed compiler-host
contract. `cli_main` itself never reaches any of it, regardless of which
runner happens to implement how much of it. This was exactly the kind of
informal drift #1143 was raised to prevent; the round 2/3 reachability
audit above resolves what `cli_main` itself needs, and #1220 independently
closed the remaining `fs` gap for programs that reach beyond `cli_main`
(i.e. every other compiled `.vibex`/`.vibe` program a user runs through the
same production runner).

## Non-goals of this pass

- No runner was changed to conform to or validate against this `.wit` file.
- No third (non-Wasmtime) runtime implementation was written or attempted.
- Whether/how to keep this file mechanically in sync with the two runners
  going forward (a differential check, a generator, ...) is unscoped follow-up.
