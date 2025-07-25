# Vibe Language - Technology Stack

## Architecture

### System Architecture
- **Language Core**: AST definitions, type system, parser, and language primitives
- **Compiler Pipeline**: Type checking, effect inference, semantic analysis, and code generation
- **Runtime System**: Interpreter, effect runtime, and memory management
- **Codebase Manager**: Content-addressed storage with incremental compilation
- **Developer Tools**: Shell/REPL, CLI, LSP server, MCP server, and test runner

### Compilation Pipeline
1. **Parsing**: Experimental GLL parser with unified grammar
2. **Semantic Analysis**: Scope resolution, effect permissions, special form validation
3. **Type Checking**: Hindley-Milner inference with let-polymorphism
4. **Effect Inference**: Track and infer computational effects
5. **Code Generation**: WebAssembly component output

## Backend Technology

### Language Implementation
- **Language**: Rust (100% of codebase)
- **Parser Framework**: Custom GLL (Generalized LL) parser implementation
- **Type System**: Hindley-Milner with extensions for effects and records
- **Memory Management**: Perceus reference counting for efficient GC

### Core Dependencies
- **salsa**: Incremental computation framework for fast recompilation
- **wasmtime**: WebAssembly runtime for executing compiled code
- **wit-bindgen**: WebAssembly Interface Types for component model
- **cranelift**: Code generation backend for WebAssembly

### Storage & Persistence
- **rusqlite**: SQLite database for content-addressed code storage
- **blake3**: Fast cryptographic hashing for content addressing
- **bincode**: Efficient binary serialization

## Development Environment

### Prerequisites
- **Rust**: 1.70+ (with cargo)
- **Git**: Version control
- **SQLite**: Embedded database (via rusqlite)

### Build Tools
- **cargo**: Rust package manager and build tool
- **cargo-component**: WebAssembly component tooling
- **clippy**: Rust linter for code quality
- **rustfmt**: Code formatter

## Common Commands

### Development
```bash
# Build all crates
cargo build --all

# Build release version
cargo build --release

# Run tests
cargo test --all

# Run specific crate tests
cargo test -p vibe-language
cargo test -p vibe-compiler

# Code quality
cargo clippy --all -- -D warnings
cargo fmt --all
```

### Using Vibe Shell (vsh)
```bash
# Start interactive shell
cargo run -p vibe-cli --bin vibe

# Run a program
cargo run -p vibe-cli --bin vibe -- run <file.vibe>

# Type check
cargo run -p vibe-cli --bin vibe -- check <file.vibe>

# Run benchmarks
cargo run -p vibe-cli --bin vibe -- bench
```

### Testing
```bash
# Run Vibe language tests
cargo run -p vibe-cli --bin vibe -- test

# Run integration tests
cargo test --all --test '*'

# Run with debug output
RUST_LOG=debug cargo test
```

## Environment Variables

### Development
- `RUST_LOG`: Control logging level (error/warn/info/debug/trace)
- `RUST_BACKTRACE`: Enable backtrace on panic (1/full)
- `VIBE_DB_PATH`: Override default codebase database location

### Runtime
- `VIBE_CACHE_DIR`: Directory for cached compilation artifacts
- `VIBE_STDLIB_PATH`: Override standard library location

## Port Configuration

### Development Services
- **LSP Server**: Communicates via stdio (no port)
- **MCP Server**: Communicates via stdio (no port)
- **REPL**: Interactive terminal (no port)

### Future Services
- **Debug Server**: 9229 (planned)
- **Web Playground**: 8080 (planned)

## Testing Infrastructure

### Test Frameworks
- **Rust native tests**: Unit and integration tests
- **Vibe test runner**: In-source test execution for .vibe files
- **Snapshot testing**: Golden file testing for parser/compiler output

### Continuous Integration
- **GitHub Actions**: Automated testing on push
- **Test coverage**: 70%+ target coverage
- **Benchmark tracking**: Performance regression detection

## Development Workflow

1. **Write code** in appropriate crate
2. **Run tests** with `cargo test`
3. **Check types** with `cargo check`
4. **Lint code** with `cargo clippy`
5. **Format code** with `cargo fmt`
6. **Test Vibe code** with `vibe test`
7. **Benchmark** critical paths