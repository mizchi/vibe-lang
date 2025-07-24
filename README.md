# Vibe Language

Vibe Language is a purely functional programming language designed for AI-assisted vibe coding - a development style focused on experimentation and trial-and-error. It features complete type inference, content-addressed code storage, and an extensible effect system.

## Key Features

- **Pure Functional**: No side effects, referential transparency
- **Complete Type Inference**: Hindley-Milner type system with let-polymorphism
- **Content-Addressed**: Unison-style hash-based code storage
- **Effect System**: Track and control side effects with extensible effects
- **Auto-Currying**: Automatic partial application support
- **Pattern Matching**: Exhaustive pattern matching on lists and ADTs
- **WebAssembly Target**: Compile to WebAssembly components

## Quick Start

```bash
# Build
cargo build --release

# Start Vibe Shell (REPL)
cargo run -p vsh

# Run a program
cargo run -p vsh -- run examples/hello.vibe

# Type check
cargo run -p vsh -- check examples/fibonacci.vibe

# Run tests
cargo run -p vsh -- test
```

## Basic Syntax

```haskell
-- Variables and functions
let x = 42
let add x y = x + y
let inc = add 1  -- Partial application

-- Recursive functions
rec factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

-- Pattern matching
match list {
  [] -> 0
  x :: xs -> 1 + length xs
}

-- Let-in expressions
let x = 10 in
let y = 20 in
  x + y

-- Pipeline operator
[1, 2, 3]
  |> map (fn x -> x * 2)
  |> filter (fn x -> x > 2)
  |> sum

-- Effects (basic implementation)
let greet name = perform IO.print ("Hello, " ++ name)
```

## Project Structure

- `vibe-core/` - Core language definitions (AST, types, parser)
- `vibe-compiler/` - Type checker, effect inference, WebAssembly codegen
- `vibe-runtime/` - Interpreter and runtime system
- `vibe-workspace/` - Content-addressed storage and namespace management
- `vsh/` - Vibe Shell (REPL, CLI, LSP, MCP, test runner)

## Standard Library

- `core.vibe` - Basic functions and types
- `list.vibe` - List operations
- `math.vibe` - Mathematical functions
- `string.vibe` - String manipulation

## Development

```bash
# Run all tests
cargo test --all

# Check code style
cargo clippy --all

# Format code
cargo fmt --all

# Run benchmarks
cargo bench
```

## License

MIT License