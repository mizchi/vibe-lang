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
in `Taskfile.pkl` (238 tasks). If you're working with an AI coding agent on
this repo, see [CLAUDE.md](CLAUDE.md) for the full agent-facing workflow and
gotchas — this document is the human-readable overview of the same territory.

## Development

```bash
pkf run            # check + test (release-check)
pkf run fmt        # format code
pkf run check      # type check
pkf run test       # run tests
pkf run test-local # affected local tests via flaker (fast inner loop)
pkf run test-unit           # selfhost unit tests (allowlist-gated)
pkf run full-gate           # full selfhost operation gate
pkf run test-integration-deno  # deno integration tests (artifact-only wasm-gc)
pkf run coverage            # selfhost suite coverage aggregation
pkf run release-check       # full check before release (fmt + info + check + test + gates)
pkf run playground-dev      # current wasm build で playground を起動
pkf run playground-build    # GitHub Pages 向け playground を build
```

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
- `clients/wasm/vibe.wasm` — selfhost compiler をビルドした成果物
- `pkf run build-wasm-vibe` で更新
- `pkf run test-wasm-vibe-wasmtime` で `wasmtime --invoke vibe_check` 疎通確認
- `pkf run build-release-assets v0.0.1` で GitHub Release 添付用の versioned asset を `dist/release/v0.0.1/` に生成
- `v*` tag push で `.github/workflows/release.yml` が `vibe-v*.wasm` と checksum を GitHub Release に公開

## CLI (development reference)

These examples run scripts through the task runner (`pkf run run -- ...`),
which is how you'd exercise the CLI while developing the compiler itself. For
the user-facing `vibe <command>` reference, see
[docs/cli-commands.md](docs/cli-commands.md).

```bash
# Run vibe script
pkf run run -- examples/basics.vibe
# (comprehensive syntax tour)
pkf run run -- examples/syntax.vibe

# Run unstable async examples (required for await/sleep/yield runtime execution)
pkf run run -- --unstable-async examples/async.vibe
# flags can also be placed before command
pkf run run -- --unstable-async run examples/async.vibe

# Run tests in script
pkf run run -- test examples/*.vibe
# For async tests
pkf run run -- test --unstable-async examples/async.vibe

# Compile to WASM
pkf run run -- compile --wasm examples/wasm/sleep_demo.vibe -o /tmp/out.wasm
# Compile + optimize with wite (-Oz default)
pkf run run -- compile --wasm --wite examples/wasm/sleep_demo.vibe -o /tmp/out.opt.wasm
# Compile + optimize with explicit level
pkf run run -- compile --component -O3 script.vibe -o out.component.opt.wasm

# Compile to Component Model WASM
pkf run run -- compile --component script.vibe -o out.component.wasm

# Generate component embedding WIT for wasm-tools/wkg pipeline
pkf run run -- compile --wit-component script.vibe -o out.component.wit

# (stdio builtins are wired through wasi:cli/stdin|stdout + wasi:io/streams)

# Interactive shell
pkf run run -- shell

# Line shell for stdio/pipeline environments
pkf run run -- shell-stdin --no-prompt
# Enable unstable async in line shell
pkf run run -- shell-stdin --unstable-async

# IDE-like symbol queries
pkf run run -- ide outline examples/syntax.vibe
pkf run run -- ide peek-def some_fn examples/syntax.vibe
pkf run run -- ide search Option examples/syntax.vibe
# JS-backed ide command
pkf run ide-js -- outline examples/syntax.vibe
pkf run ide-js -- peek-def some_fn examples/syntax.vibe
pkf run ide-js -- search Option examples/syntax.vibe
# `ide-js` は entry から相対 import を再帰収集して project request を生成する

# Advanced graph index PoC (build/query/verify)
pkf run run -- index build examples/syntax.vibe -o /tmp/advanced-graph-index.json
pkf run run -- index query symbol add /tmp/advanced-graph-index.json
pkf run run -- index verify /tmp/advanced-graph-index.json

# Emit LSIF from the same symbol index backend
pkf run run -- lsif -o /tmp/vibe.lsif examples/syntax.vibe

# Build component + run with wasmtime (explicit invoke for non-command component)
pkf run component-run -- lib/@vibe/builtin/test_import_test.vibe
# stdin 経由の実行も可能:
printf 'A' | pkf run component-run -- your_stdio_script.vibe
# stream TUI デモ:
printf 'hello\nworld\n' | pkf run component-run -- examples/wasm/tui_stream_demo.vibe
# 簡易デモ実行タスク:
pkf run demo-tui-stream

# moonix で実行（moonix の CLI 差分はランチャで吸収）
pkf run component-run-moonix -- lib/@vibe/builtin/test_import_test.vibe

# Install CLI to ~/.local/bin/vibe
pkf run install
```

Notes:
- Script-level stdio execution goes through `pkf run component-run -- <file.vibe>`
  (moonix 実行は `pkf run component-run-moonix -- <file.vibe>`, 必要なら
  `MOONIX_BIN=/path/to/moonix`; `component-run-moonix` は `moonix` 未導入時に
  `scripts/bootstrap_moonix_bin.sh` を自動試行する)。
- Components import `wasi:cli/stdin|stdout@0.2.0` and `wasi:io/streams@0.2.0`
  directly, so they run on a component / p3-compatible host.
- Backend 契約: selfhost CLI では `--wasm` = linear (production default)、
  `--wasm-gc` は未配線 (throw)。詳細は
  [docs/spec/memory-contract.md](docs/spec/memory-contract.md)。
- The old MoonBit-host wasi CLIs (`vibe_wasi` / `vibe_compile_wasi` under
  `src/cmd/`) were retired with the MoonBit host in #594; the distributed
  compiler wasm is now built from selfhost source (`pkf run build-wasm-vibe`,
  or the installer's seed → stage1 → stage2 build).

## WASM Execution

### With async host runtime (supports sleep)

```bash
# Build Rust host runtime
pkf run build-async-host

# Run sleep demo
pkf run sleep-demo

# Run any WASM with sleep support
pkf run run -- compile --wasm your_script.vibe -o /tmp/out.wasm
pkf run run-wasm-async -- /tmp/out.wasm
```

### With wasmtime (basic)

```bash
pkf run run -- compile --wasm script.vibe -o /tmp/out.wasm
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
pkf run run -- bench examples/simple_bench.vibe
```

`<file|dir...>` 指定時の canonical backend は `--backend compiled` で、`--backend wasm` は互換 alias として受け付ける。
legacy の式ベンチ (`--expr/--case/--cases`) は廃止。`bench {}` を含む `.vibe` file を渡す。
compiled bench path ではサイズ優先で `--no-dce -Oz` 相当のコンパイルを使い、各ケースに `wasm_bytes=<size>` を出力する。

コンパイラ内部のマイクロベンチ (pkf tasks):

```bash
pkf run bench-typechecker      # 型検査スループット
pkf run bench-symbol-index     # シンボルインデックス構築
pkf run bench-advanced-graph   # graph index build/query
pkf run bench-array-build      # 配列構築
pkf run bench-char-conversion  # 文字コード変換
pkf run bench-jsonschema       # jsonschema 検証
pkf run bench-bundle-size-monitor-strict  # bundle-size budget チェック
```

## Task management

タスクは GitHub Issues (`gh issue`) で管理する。ロードマップは
[docs/release-roadmap.md](docs/release-roadmap.md) 参照 (`TODO.md` は
`docs/archive/TODO.md` へ移動済み、historical のみ)。設計判断は
[docs/adr.md](docs/adr.md) に記録する。
