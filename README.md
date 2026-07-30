# vibe

vibe is a small, effect-typed language with a **selfhost-only** compiler: the
parser, type checker, and WASM codegen are all written in vibe itself
(`lib/@vibe/compiler/`, `lib/@vibe/cli/`) and built from a committed seed via
a wasm runner — no MoonBit toolchain is required to build or run it (the
original MoonBit host was retired in #594).

## Install

vibe ships as a small wasmtime runner (`viberun`) plus a portable compiler
wasm; the installer AOT-compiles the compiler for your machine at install time.
Building the runner from source needs `git`, `bash`, and `cargo`; pass
`--runner PATH` to use a prebuilt one instead. See
[docs/install.md](docs/install.md) for the full prerequisite list.

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/scripts/installer.sh | bash
. "$HOME/.vibe/env"   # or restart the shell — ~/.vibe/bin is the PATH entry
vibe version
echo 'fn main with { Stdout } { Stdout::write_stream("42\\n") }' > hello.vibex
vibe run hello.vibex        # -> 42
```

See [docs/install.md](docs/install.md) for the install layout, options, and how
to update the compiler independently of the runner.

## Sample code

```vibe
// Pattern matching + effect-typed error handling
fn safe_div(a: Int, b: Int) -> Result[Int, String] {
  match b {
    0 => Err("division by zero"),
    _ => Ok(a / b)
  }
}

// Structs and module-local helpers
struct Point { x: Int; y: Int } derive(Eq, Show)

fn Point::manhattan(p: Point) -> Int {
  p.x + p.y
}

fn main with { Stdout } {
  let result = match safe_div(10, 2) {
    Ok(v) => v + Point::manhattan(Point::{ x: 3, y: 4 }),
    Err(_) => -1
  }
  Stdout::write_stream("\{result}\n")
}
```

New to the language? Start with the runnable tour:
[docs/tutorial/](docs/tutorial/README.md) — every chapter is a `*.vibe.md`
executable doc (#1142): code blocks are compiled and run, and the printed
output is embedded right in the markdown, so the examples and their results
cannot drift apart.

## Features

- Type inference with row-polymorphic effects (`with {Async}`, `with {Error}`)
- Pattern matching and destructuring, including struct/record forms
- Module system with import/export, `.vibei` package contracts
- Async/await syntax (runtime gate: `--unstable-async`)
- Lambda expressions with placeholder shorthand (`_+1`)

### Runtime targets

| Target | Description |
|--------|-------------|
| Native CLI | Compiled execution via the host runtime (`run` / `test` / `shell`) |
| WASM (linear) | **Production default**: `compile --wasm`, `build --release`, `test`, `bench` (tagged-i64, bump allocator) |
| WASM + js-string | WASM with JS string builtins for embedding |
| WASM GC | Long-term primary target; backend exists (`lib/@vibe/compiler/codegen/gc/`) but is not yet wired into the CLI compile path — see [docs/spec/memory-contract.md](docs/spec/memory-contract.md) |
| Component Model | WASI/component packaging for composition |

### Editor & debugging

`vibe lsp` is a stdio Language Server (diagnostics, typed hover, symbols,
go-to-definition, scope-accurate references/rename, completion, signature
help), plus a function-granularity interactive debugger
(`vibe run --break <fn>` / `--trace`) and a VS Code DAP adapter. See
[docs/editor-and-debugging.md](docs/editor-and-debugging.md).

### Packages & dependencies

Dependencies are distributed over git/URLs (Deno/Go style — no central
registry) and pinned by content hash. See
[docs/module-system.md](docs/module-system.md#配布とパッケージ管理-giturl-分散)
for the full `vibe.deps` / `vibe add` / `vibe fetch` workflow.

## Docs

Start here:
- [docs/cheatsheet.md](docs/cheatsheet.md) — language cheatsheet, covers all
  implemented syntax/features
- [docs/tutorial/](docs/tutorial/README.md) — runnable, CI-checked tour
- [docs/vibe.md](docs/vibe.md) — language specification (normative for
  implemented behavior)

Reference index:
- [docs/cli-commands.md](docs/cli-commands.md) — full `vibe` CLI command reference
- [docs/module-system.md](docs/module-system.md) — module system + package distribution
- [docs/adding-modules.md](docs/adding-modules.md) — how to add/repair a `lib/@vibe/*` module
- [docs/editor-and-debugging.md](docs/editor-and-debugging.md) — LSP, debugger, DAP
- [docs/builtin_contract_table.generated.md](docs/builtin_contract_table.generated.md) — builtin function contracts
- [docs/effect-wit-mapping.md](docs/effect-wit-mapping.md) — effect system ↔ WASI WIT mapping
- [docs/registry-design.md](docs/registry-design.md) — package registry design
- [docs/release-roadmap.md](docs/release-roadmap.md) — roadmap and release themes
- [docs/adr.md](docs/adr.md) — architecture decision records
- [docs/known-issues.md](docs/known-issues.md) — known issues and workarounds

## Contributing

Building the compiler itself, running the selfhost gates, project layout, and
the full CLI/task-runner reference for development live in
[CONTRIBUTION.md](CONTRIBUTION.md).

## License

MIT
