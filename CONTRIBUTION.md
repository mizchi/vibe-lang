# Contributing to vibe

This document covers the internal development workflow: building the
selfhost compiler, running the verification gates, the task-runner command
reference, and the project layout. For the language itself, start with
[README.md](README.md) and [docs/cheatsheet.md](docs/cheatsheet.md).

vibe is **selfhost-only**: the compiler, type checker, and codegen are all
written in vibe itself (`lib/@vibe/compiler/`, `lib/@vibe/cli/`) and built
from a committed seed (`bootstrap/seed/`) via a Rust/node wasm runner — no
MoonBit toolchain is required (the original MoonBit host was retired in #594;
see [docs/archive/moonbit-retirement.md](docs/archive/moonbit-retirement.md)).

The task runner is [pkfire](https://github.com/mizchi/pkfire) (`pkf`), defined
in `Taskfile.pkl`. If you're working with an AI coding agent on
this repo, see [CLAUDE.md](CLAUDE.md) for the full agent-facing workflow and
gotchas — this document is the human-readable overview of the same territory.

## Development

```bash
pkf run                # default: release-check (full sign-off)
pkf run test           # operation gate — the main pre-commit check
pkf run test-affected  # only the tests the change can reach (fast inner loop)
pkf run test-unit      # selfhost unit tests (allowlist-gated)
pkf run full-gate      # full selfhost operation gate
pkf run fmt            # format lib/**/*.vibe and lib/**/*.vpkg
pkf run coverage       # selfhost suite coverage aggregation
pkf run release-check  # fmt + check + test + gates, before release
```

Type checking is a CLI verb rather than a task: `vibe check <file.vibe>`
(empty output = clean, diagnostics one per line + exit 1).

The playground is an ordinary vite app with no pkf task — `cd playground &&
pnpm install && pnpm dev` (or `pnpm build`).

Coverage は selfhost テストスイート基準で測る:
- 集計: `pkf run coverage`
- branch coverage gate: `pkf run coverage-suite-branch-gate`
- next-branch 提案: `pkf run coverage-suite-next-branches`
- 詳細: [docs/coverage.md](docs/coverage.md)

## Before committing a compiler change

Any change touching `lib/@vibe/compiler/` (or the parser/ast/core contract
packages it depends on) must go through the full selfhost verification cycle
before you commit:

```bash
pkf run release-check  # fmt + info + check + test + vibe-normalize + bundle-size + selfhost gates
```

See [CLAUDE.md](CLAUDE.md) ("Tooling" / "Local Test Execution" sections) for
the exact regen → gate → full-unit-allowlist sequence, cache-corruption
recovery steps, and the manifest transitive-import rules — that level of
detail is kept in CLAUDE.md since it's primarily useful for scripted/agent
workflows, but it applies equally to manual development.

## Distribution artifacts

`clients/js/` には配布用 wasm (`clients/wasm/vibe.wasm`) を呼ぶ JS バインディングを置く:
- `clients/js/index.js` / `clients/js/index.d.ts` (`createVibeService`, `init`, `check`, `format`, `checkProject`, `ideOutline`, `idePeekDef`, `ideSearch`)
  - `createVibeService({ bootstrap: { prelude, kv } })` または `service.init({ prelude, kv })` で初期状態を注入可能
  - `checkProject({ entry, files })` と IDE request (`{ entry, path, files, ... }`) は import 解決対応（init で注入した `kv` も解決対象）
- `clients/js/cli.js` shell から使う JS CLI (`vibe ide` 相当)
- `clients/js/lsp.js` / `clients/js/lsp.d.ts` (stdio/ws 非依存の transport 抽象)

`clients/wasm/` には配布用 wasm を置く:
- `clients/wasm/vibe.wasm` — selfhost compiler をビルドした成果物。
  **これを再生成する仕組みはリポジトリに無い** (最後の生成は MoonBit host 時代
  の #900、当時のタスクは #594 で host ごと撤去された)。コミット済みバイナリ
  そのものが成果物。
- `bash scripts/test_wasm_vibe_wasmtime.sh` で `wasmtime --invoke vibe_check`
  疎通確認 (コミット済み成果物に対しては現在も通る)
- `pkf run build-release-assets v0.0.1` で GitHub Release 添付用の versioned asset を `dist/release/v0.0.1/` に生成
- `v*` tag push で `.github/workflows/release.yml` が `vibe-v*.wasm` と checksum を GitHub Release に公開

## CLI (development reference)

`pkf run run` is **not** a CLI multiplexer. It is `scripts/vibe_run.sh`, which
takes one `.vibex` executable root with entry `main` (ADR-0075) — so the
`pkf run run -- compile ...` / `-- test ...` / `-- ide ...` forms this section
used to show could never work, and neither could their targets: there is no
`.vibex` under `examples/`, and `ide`, `index`, `lsif` and `shell-stdin` are
answered `unknown command` by the CLI.

Install the CLI to exercise it:

```bash
VIBE_HOME=~/.vibe VIBE_BIN_DIR=~/.local/bin bash install/install.sh
```

```bash
# Type-check + diagnose. Empty output = clean; diagnostics one per line, exit 1.
vibe check examples/basics.vibe
vibe check --single-file examples/basics.vibe   # buffer scope, no import resolution

# Compile to wasm (the file needs an exported `main`)
vibe compile examples/perform_handle.vibe -o /tmp/out.wasm
vibe compile --component script.vibe -o out.component.wasm
vibe compile --wit script.vibe                  # the WIT world for its effect surface

# Tests and benches
vibe test lib/@vibe/builtin/bool_test.vibe
vibe test lib/@vibe/builtin                     # a directory expands to *_test.vibe
vibe bench lib/@vibe/builtin/iterator_bench.vibe

# Compiled REPL
vibe shell

# Editor queries — the same analysis the LSP serves, from the shell
vibe symbols  examples/basics.vibe
vibe type-at  examples/basics.vibe 3 7
vibe deps     examples/basics.vibe
vibe grep --pattern 'Iterator::map($(a:args))' lib
```

Without installing, the two wrappers the gates themselves use:

```bash
bash scripts/vibe_test.sh lib/@vibe/builtin/bool_test.vibe   # compile + run test blocks
bash scripts/vibe_run.sh  scripts/review_lint.vibex          # run a .vibex root
```

`scripts/vibe_test.sh` compiles with the **committed seed** unless you pass
`VIBE_TEST_CLI_WASM=<stage2.wasm>` — when the change under test is in the
compiler, an unset value answers for a compiler that does not contain it.

For the user-facing command reference see
[docs/cli-commands.md](docs/cli-commands.md).

## WASM Execution

### With async host runtime (supports sleep)

```bash
# Build Rust host runtime
pkf run build-async-host

# Compile, then run the wasm on the async host
vibe compile your_script.vibe -o /tmp/out.wasm
pkf run run-wasm-async -- /tmp/out.wasm
```

(There is no `pkf run sleep-demo`; `examples/wasm/sleep_demo.vibe` is compiled
and run with the two commands above.)

### With wasmtime (basic)

```bash
vibe compile script.vibe -o /tmp/out.wasm
wasmtime /tmp/out.wasm
```

### With `deps/wasmtime` submodule (experimental flags)

```bash
# one-time init + build
pkf run wasmtime-submodule-init
pkf run build-wasmtime-submodule

# run wasmtime from submodule directly
pkf run wasmtime-submodule -- run -W gc --invoke _start /tmp/out.wasm

# or switch existing vibe scripts/tasks to submodule wasmtime
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run component-run -- script.vibe

# inject extra wasmtime runtime flags into vibe scripts/*
# (space-separated list; each token is passed as -W / -S)
VIBE_WASMTIME_WASM_FLAGS='component-model-async=y concurrency-support=y' \
VIBE_WASMTIME_WASI_FLAGS='p3=y' \
VIBE_USE_WASMTIME_SUBMODULE=1 \
pkf run component-run -- script.vibe

# inspect current flag env values used by scripts/wasmtime_run.sh
pkf run show-wasmtime-flags

```

### With wasmtime stack-switching (x86_64 Linux only)

```bash
# Via container (for stack-switching support)
pkf run experimental_wasmtime_stack_switching -- /tmp/out.wasm
```

## Project Structure

Everything is now vibe source (`.vibe`); the retired MoonBit host tree (`src/`,
`moon.mod`, `*.mbt`) is gone (#594).

```
lib/                      # All vibe source: stdlib + compiler + experimental
├── @vibe/                # official packages
│   ├── compiler/         #   selfhost compiler
│   │   ├── syntax/       #     lexer + parser
│   │   ├── checker/      #     type checker with effects
│   │   ├── codegen/      #     WASM code generation (linear + gc lanes)
│   │   ├── core/         #     AST types and serialization
│   │   ├── loader/       #     source/lock resolution + module loading
│   │   ├── contract/     #     .vibei contract grammar + conformance engine
│   │   ├── perceus/ ripple/ #  ownership / reference-counting passes
│   │   ├── normalize/ fmt/  #  normalization + formatter
│   │   ├── cache/ runtime/  #  caches, compiler hooks, shell support
│   │   ├── builtins/     #     builtin signature SSoT (declarations.vibe)
│   │   └── entry/        #     compiler entrypoints
│   ├── cli/              #   selfhost CLI command surface + entrypoints
│   ├── wasi/              #   WASI p2/p3 runtime adapters
│   └── …                 #   stdlib: prelude, io, path, fs, http, json, socket,
│                         #   time, process, shell, random, collection, module,
│                         #   core, ast, parser
└── @vibex/               #   experimental: math, regexp, url, uuid, toml, diff,
                          #   fmt, color, template, semver, quickcheck, base64, …

runtime/                  # Host runtime: wasmtime runner (viberun),
│                         #   daemon client (viberun_client), `vibe` launcher
clients/                  # Embeddings + distribution artifacts
├── js/                   #   JS bindings (LSP / IDE / DAP / graph-query)
└── wasm/                 #   distributed compiler wasm (vibe.wasm)
bootstrap/                # Committed seed compiler (seed/ + seed.json)
tools/                    # Dev tooling: wasmtime_bench (raw-wasmtime microbench,
                          #   standalone Rust crate, not wired into pkf/CI)
tools/async_host/         # Rust/wasmtime host runtime for async (sleep)
integrations/             # Editor plugins (treesitter / vscode / zed)
examples/                 # Example scripts (examples/wasm/ needs a host)
fixtures/                 # Test fixtures (compiler regression corpus)
scripts/ pkspec/          # Build/test scripts + pkfire/pkspec definitions
```

See also [docs/adding-modules.md](docs/adding-modules.md) for the module
placement conventions, and CLAUDE.md's "MoonBit host vs selfhost" section for
where new compiler work should land.

## Fixtures

Fixtures live in `fixtures/*.vibe` and include a `__DATA__` JSON section; they are
exercised through the selfhost gate (`pkf run full-gate`) and `pkf run
test-fixtures`. Runtime-style fixtures (effect, HTTP, struct) live in
`fixtures/runtime/`.

WASM fixtures live in `fixtures/wasm/*.vibe` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.vibe` and check for `struct.new/get/set`.

## Bench

`vibe bench` は `bench {}` ブロックを言語機能として実行する:

```bash
vibe bench examples/simple_bench.vibe
```

`<file|dir...>` 指定時の canonical backend は `--backend compiled` で、`--backend wasm` は互換 alias として受け付ける。
legacy の式ベンチ (`--expr/--case/--cases`) は廃止。`bench {}` を含む `.vibe` file を渡す。
compiled bench path ではサイズ優先で `--no-dce -Oz` 相当のコンパイルを使い、各ケースに `wasm_bytes=<size>` を出力する。

コンパイラ内部のマイクロベンチは pkf タスクではなく `bench {}` ブロックを
持つファイルで、`vibe bench` に直接渡す:

```bash
vibe bench lib/@vibe/compiler/checker_bench.vibe   # 型検査
vibe bench lib/@vibe/compiler/codegen_bench.vibe   # codegen
vibe bench lib/@vibe/compiler/fmt_bench.vibe       # formatter
vibe bench bench/bench_string.vibe                 # stdlib 側は bench/ 以下
```

タスクとして残っているのは以下の3つ:

```bash
pkf run bench-compile-hotspots -- <stage2.wasm>  # 実コンパイルの self-time 表
pkf run bench-http
pkf run bench-module-job-pool
```

(`bench-typechecker` / `bench-symbol-index` / `bench-advanced-graph` /
`bench-array-build` / `bench-char-conversion` / `bench-jsonschema` /
`bench-bundle-size-monitor-strict` はいずれも存在しないタスクだった。)

## Task management

タスクは GitHub Issues (`gh issue`) で管理する。ロードマップは
[docs/release-roadmap.md](docs/release-roadmap.md) 参照 (`TODO.md` は
`docs/archive/TODO.md` へ移動済み、historical のみ)。設計判断は
[docs/adr.md](docs/adr.md) に記録する。
