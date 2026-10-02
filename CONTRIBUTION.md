# Contributing to vibe

This document covers the internal development workflow: building the
selfhost compiler, running the verification gates, the task-runner command
reference, and the project layout. For the language itself, start with
[README.md](README.md) and [docs/user/reference/cheatsheet.md](docs/user/reference/cheatsheet.md).

vibe is **selfhost-only**: the compiler, type checker, and codegen are all
written in vibe itself (`lib/@vibe/compiler/`, `lib/@vibe/cli/`) and built
from a committed seed (`bootstrap/seed/`) via a Rust/node wasm runner — no
MoonBit toolchain is required (the original MoonBit host was retired in #594;
its last state is tag `moonbit-host-final-2026-06-23`).

The task runner is [pkfire](https://github.com/mizchi/pkfire) (`pkf`), defined
in `Taskfile.pkl`. If you're working with an AI coding agent on
this repo, see [CLAUDE.md](CLAUDE.md) for the full agent-facing workflow and
gotchas — this document is the human-readable overview of the same territory.

## Development

With rustup, this checkout selects the stable Rust release and Wasm targets
in `rust-toolchain.toml` automatically. The Nix development shell uses the
same file. Run `rustup toolchain install` to install the selected toolchain
and `rustup show` to inspect it.

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

### jev-lint on Vibe sources

With a sibling `mizchi/jev-lint` checkout (Node 24+ and its dependencies
installed), run `pkf run jev-parser` to build the native tree-sitter parser
at `.jev-lint/parsers/vibe.dylib`, then `pkf run jev-plan` to inspect the
no-API scan of `lib/`. `.jev-lint.yaml` enables two warning-level Vibe rules
with fully qualified names. To request verdicts for selected files, run
`node --experimental-strip-types ../jev-lint/src/cli.ts check --config
.jev-lint.yaml lib/@vibe/builtin/array_test.vibe`; this requires the
`TYPESAFE_API_KEY` or `TYPESAFEAI_API_KEY` environment variable. Set
`JEV_LINT_CLI` when the sibling checkout is elsewhere.

The grammar in `integrations/treesitter-vibe/` also builds the playground and
Zed WASM parsers. After changing it, regenerate the C parser and both WASM
files, then run `bash scripts/stamp_treesitter_artifacts.sh`. The stamper
checks the corpus against both WASM copies before updating its hash manifest.

Coverage は selfhost テストスイート基準で測る:
- 集計: `pkf run coverage`
- branch coverage gate: `pkf run coverage-suite-branch-gate`
- next-branch 提案: `pkf run coverage-suite-next-branches`
- 詳細: [docs/internal/operations/coverage.md](docs/internal/operations/coverage.md)

## Before committing a compiler change

Any change touching `lib/@vibe/compiler/` (or the parser/ast/core contract
packages it depends on) must go through the full selfhost verification cycle
before you commit:

```bash
pkf run release-check  # seed->stage3 fixpoint + bundle sync + compile/run validation
```

See [CLAUDE.md](CLAUDE.md) ("Tooling" / "Local Test Execution" sections) for
which compiler a test runs on, how affected tests are selected, and the rules
for a performance measurement — that level of detail is kept in CLAUDE.md
since it's primarily useful for scripted/agent workflows, but it applies
equally to manual development.

## Distribution artifacts

`clients/js/` holds the JS bindings that call the distributed wasm
(`clients/wasm/vibe.wasm`):
- `clients/js/index.js` / `clients/js/index.d.ts` (`createVibeService`, `init`, `check`, `format`, `checkProject`, `ideOutline`, `idePeekDef`, `ideSearch`)
  - The initial state can be injected with `createVibeService({ bootstrap: { prelude, kv } })` or `service.init({ prelude, kv })`.
  - `checkProject({ entry, files })` and the IDE requests (`{ entry, path, files, ... }`) resolve imports, including the `kv` injected by `init`.
- `clients/js/cli.js` — a JS CLI for the shell (the equivalent of `vibe ide`)
- `clients/js/lsp.js` / `clients/js/lsp.d.ts` — a transport abstraction independent of stdio/ws

`clients/wasm/` holds the distributed wasm:
- `clients/wasm/vibe.wasm` — a build of the selfhost compiler. **Nothing in the
  repository regenerates it**: it was last produced in the MoonBit-host era
  (#900), and the task that built it was removed with the host in #594. The
  committed binary is the artifact.
- `bash scripts/test_wasm_vibe_wasmtime.sh` checks that `wasmtime --invoke
  vibe_check` works against it (it still passes on the committed artifact).

Release assets:
- `pkf run build-release-assets v0.0.1` writes the versioned assets for a
  GitHub Release to `dist/release/v0.0.1/`.
- Pushing a `v*` tag runs `.github/workflows/release.yml`, which publishes
  everything `scripts/build_release_assets.sh` writes to
  `dist/release/<tag>/`: `vibe-cli-<tag>.wasm` (the compiler installs run),
  `vibe-toolchain-<tag>.tar.gz`, one `viberun-<tag>-<target>.tar.gz` per
  target, the seed trio `vibe-compiler-<tag>.wasm` /
  `vibe-compiler-module-source-<tag>.vibe` / `vibe-compiler-seed-<tag>.json`
  (what `scripts/fetch_compiler.sh` uses for a reproducible bootstrap),
  `release-manifest.json` and `SHA256SUMS.txt`. What each asset contains is
  in [install.md](docs/user/getting-started/install.md#updating).

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
[docs/user/reference/cli-commands.md](docs/user/reference/cli-commands.md).

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

# or use the submodule binary through the shared runner
VIBE_USE_WASMTIME_SUBMODULE=1 bash scripts/wasmtime_run.sh --invoke _start /tmp/out.wasm

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
│   │   ├── syntax/       #     lexer + parser entry points
│   │   ├── checker/      #     type checker with effects
│   │   ├── lowering/ normalize/ #  desugaring + lowering passes
│   │   ├── codegen/      #     WASM code generation (linear + gc lanes)
│   │   ├── perceus/      #     ownership / reference-counting plan
│   │   ├── core/         #     AST types and serialization
│   │   ├── loader/ module_graph/ contract/ # module resolution + index.vpkg contracts
│   │   ├── cache/ incremental/ #  persistent caches + incremental reuse
│   │   ├── runtime/ entry/  #  compiler drivers + entrypoints
│   │   ├── fmt/ refactor/   #  formatter + checked refactorings
│   │   ├── builtins/     #     reference list of builtin signatures (documentation only)
│   │   └── tests/        #     compiler unit tests
│   ├── cli/              #   selfhost CLI command surface + entrypoints
│   ├── wasi/             #   WASI p2/p3 runtime adapters
│   └── …                 #   ast, parser, builtin, core, console, fs, path, http,
│                         #   json, socket, time, process, random, scan, semver,
│                         #   concurrent, module, symbol, blake3, lsp, optimizer, …
└── @vibex/               #   experimental: argparse, book, color, fmt, immut,
                          #   jsonschema, quickcheck, regexp, shell, tasks, toml,
                          #   url, zlib, wasm_* parsers/encoders

runtime/                  # Host runtime: wasmtime runner (viberun),
│                         #   daemon client (viberun_client), `vibe` launcher
clients/                  # Embeddings + distribution artifacts
├── js/                   #   JS bindings (LSP / IDE / DAP / graph-query)
└── wasm/                 #   distributed compiler wasm (vibe.wasm)
bootstrap/                # Pinned seed (seed.json; the wasm is fetched and sha256-verified)
tools/                    # Dev tooling: wasmtime_bench (raw-wasmtime microbench,
                          #   standalone Rust crate, not wired into pkf/CI)
tools/async_host/         # Rust/wasmtime host runtime for async (sleep)
integrations/             # Editor plugins (treesitter / vscode / zed)
examples/                 # Example scripts (examples/wasm/ needs a host)
fixtures/                 # Test fixtures (compiler regression corpus)
scripts/                  # Build/test scripts + pkfire task modules (scripts/pkfire/)
```

See also [docs/internal/project/adding-modules.md](docs/internal/project/adding-modules.md) for the module
placement conventions, and CLAUDE.md's "変更の入れ先" section for where new
compiler work should land.

## Fixtures

Runtime fixtures are ordinary `*_test.vibe` files with `inspect` expectations.
The unit runner discovers them directly under `fixtures/`, including
`fixtures/runtime/`. Run one with `vibe test <file>` and update its snapshots
with `vibe test --update <file>`. `pkf run full-gate` checks execution coverage
and rejects legacy expectation tails and `.diag` expectation files.

Compile-rejection fixtures use `fixtures/typecheck/expected.tsv`. Compiler
warning snapshots live in `lib/@vibe/compiler/tests/warning_snapshots/`.
`lib/@vibe/compiler/tests/gc_struct_opcode_snapshot_test.vibe` checks decoded
`struct.new/get/set` instructions in the tested GC function's body.

## Bench

`vibe bench` runs `bench {}` blocks as a language feature:

```bash
vibe bench examples/simple_bench.vibe
```

The form is `vibe bench <file.vibe> [--iters N] [--warmup N] [--guest-profile DIR]`,
given a `.vibe` file that contains `bench {}` blocks. Set
`VIBE_BENCH_BACKEND=gc` to measure on the wasm-gc lane.

The compiler's internal microbenchmarks are files with `bench {}` blocks, not
pkf tasks. Pass them to `vibe bench` directly:

```bash
vibe bench lib/@vibe/compiler/checker_bench.vibe   # type checking
vibe bench lib/@vibe/compiler/codegen_bench.vibe   # codegen
vibe bench lib/@vibe/compiler/fmt_bench.vibe       # formatter
vibe bench bench/bench_string.vibe                 # stdlib benches live under bench/
```

Three bench tasks remain:

```bash
pkf run bench-compile-hotspots -- <stage2.wasm>  # self-time table of a real compile
pkf run bench-http
pkf run bench-module-job-pool
```

## Task management

タスクは GitHub Issues (`gh issue`) で管理する。ロードマップは
[docs/internal/project/release-roadmap.md](docs/internal/project/release-roadmap.md) 参照。設計判断は
[docs/internal/design/adr.md](docs/internal/design/adr.md) に記録する。
