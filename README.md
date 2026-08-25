# vibe

vibe is a small, effect-typed language with a **selfhost-only** compiler: the
parser, type checker, and WASM codegen are all written in vibe itself
(`lib/@vibe/compiler/`, `lib/@vibe/cli/`) and built from a pinned,
sha256-verified seed via a wasm runner — no MoonBit toolchain is required to build or run it (the
original MoonBit host was retired in #594).

## Install

vibe ships as a small wasmtime runner (`viberun`) plus a portable compiler
wasm; the installer AOT-compiles the compiler for your machine at install time.
Building the runner from source needs `git`, `bash`, and `cargo`; pass
`--runner PATH` to use a prebuilt one instead. See
[docs/install.md](docs/install.md) for the full prerequisite list.

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
. "$HOME/.vibe/env"   # or restart the shell — ~/.vibe/bin is the PATH entry
vibe version
echo 'fn main with Console { println("42") }' > hello.vibex
vibe run hello.vibex        # -> 42
```

See [docs/install.md](docs/install.md) for the install layout, options, and how
to update the compiler independently of the runner.

## Sample code

```vibe
// Effect-typed error handling: failure travels in the effect row, not in the
// return type, so the success value flows straight through to the caller.
fn safe_div(a: Int, b: Int) -> Int with Exception[String] {
  match b {
    0 => throw("division by zero"),
    _ => a / b
  }
}

// Structs and module-local helpers
struct Point { x: Int; y: Int } derive(Eq, Show)

fn Point::manhattan(p: Point) -> Int {
  p.x + p.y
}

fn main with Console {
  // `handle` is where the row is discharged — no per-call unwrapping.
  let result = handle {
    safe_div(10, 2) + Point::manhattan(Point::{ x: 3, y: 4 })
  } with Exception[String] {
    Throw(msg) => {
      println("failed: \{msg}")
      0 - 1
    }
  }
  println("\{result}")
}
```

New to the language? Start with **[The Vibe Book](book/README.md)**
(`book/en/`) — a rust-book-shaped tour. Every chapter is a `*.vibe.md`
executable doc (#1142): code blocks are compiled and run, and the printed
output is embedded right in the markdown. `bash scripts/vibe_book.sh`
renders `_build/book/index.html`. The old `docs/tutorial/` path redirects
there.

## Design policy

Three commitments drive every design decision. When two goals conflict, the
tiebreak order is: never be silently wrong > honest representation > surface
convenience. (Agent-facing version with concrete precedents: `AGENTS.md`.)

**1. A modern, statically-typed functional language where side effects are
explicit.** Syntax and discipline in the lineage of Rust / MoonBit / Koka /
Verse: effects live in row types (`with Exception + Fs`), not in return-type
wrappers. Types and diagnostics are tuned for the LLM evaluation loop — the
worst failure class is *silently wrong* (it outranks "crashes" in triage),
diagnostics must lead with an actionable edit rather than internal pass names,
one concept gets exactly one spelling, and every code block in the docs is
compile-checked against the current compiler. The one-spelling rule is being
applied as decided-but-landing work: `==` becomes structural in every context
(ADR-0097, #1526 — today bare `Array`/`Bytes` `==` is still reference
equality), iteration converges on two layers — eager `Array::*` and pull
`AsyncIter` (ADR-0099, #1559) — and `Exception` is the canonical spelling with
`Error` deprecated at the 1.0 freeze (ADR-0085, #1564).

**2. Self-hosted on wasm, using wasm's newest capabilities.** The compiler is
written in vibe and built from a committed seed — no other toolchain. Internal
representations stay friction-free with wasm and WIT rather than hiding them:
values are tagged i64, `String` is officially a byte string indexed by byte
offset (ADR-0098 — what the memory actually holds), and what may cross a WIT
boundary is decided by nominal rules (ADR-0089). Continuations are designed
against wasm-gc (typed reference lanes, ADR-0095), stack switching (stackful
lift + `waitable-set` today, JSPI as an alternate backend), and threads —
concurrency is **shared-nothing** for now (`TaskGroup` + `Send`/region
checks), with the representation chosen so real threads can land later.

**3. Explicit control of permissions and effects, for the vibe-coding era.**
Deno-style permissions meet a Koka-style effect system: capabilities travel in
the effect row, call sites stay plain function calls, and authority is fixed
at the earliest possible phase (build → apply → instantiate; immutable while
running — ADR-0075/0084/0088). Incremental build serves notebook-style
iteration (the `vibe check` lane reuses typing by default). Capabilities
resolved at build time drive progressive code generation for the target wasm
runtime: `--allow-*` flags const-fold and dead-code-eliminate ungranted
capabilities, and emitted binaries declare which wasm feature level they need.

## Features

- Type inference with row-polymorphic effects (`with Async`, `with Exception`)
- Pattern matching and destructuring, including struct/record forms
- Module system with import/export, `.vpkg` package contracts
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
registry) and pinned by content hash. Package boundaries, visibility, and
pinning are specified in
[docs/module-system-oracle.md](docs/module-system-oracle.md); installing and
vendoring are covered in [docs/install.md](docs/install.md).

## Docs

Start here:
- [docs/cheatsheet.md](docs/cheatsheet.md) — language cheatsheet, covers all
  implemented syntax/features
- [The Vibe Book](book/README.md) — rust-book-shaped tour (`book/en/*.vibe.md`)
- [docs/vibe.md](docs/vibe.md) — language specification (normative for
  implemented behavior)

Reference index:
- [docs/cli-commands.md](docs/cli-commands.md) — full `vibe` CLI command reference
- [docs/module-system-oracle.md](docs/module-system-oracle.md) — package boundaries, visibility, pinning (canonical)
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

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
See [LICENSE](LICENSE).
