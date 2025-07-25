# Vibe Language - Project Structure

## Root Directory Organization

```
vibe-lang/
├── vibe-language/      # Core language definitions and parser
├── vibe-compiler/      # Type checker and code generation
├── vibe-runtime/       # Interpreter and runtime system
├── vibe-codebase/      # Content-addressed storage and namespace management
├── vibe-cli/           # CLI tools, shell, LSP, and MCP servers
├── vibe/              # Vibe standard library and examples
├── docs/              # Technical documentation and proposals
├── examples/          # Example Vibe programs
├── tests/            # Integration tests
├── target/           # Build artifacts (git-ignored)
└── .kiro/            # Kiro spec-driven development files
```

## Subdirectory Structures

### vibe-language/ - Language Core
```
src/
├── lib.rs               # Public API exports
├── ast.rs              # AST definitions (currently in types.rs)
├── types.rs            # Type system definitions and AST
├── effects.rs          # Effect type definitions
├── parser/             # Parser implementations
│   ├── mod.rs         # Parser module organization
│   ├── lexer.rs       # Tokenization
│   ├── parser_impl.rs # Main parser logic
│   ├── ast_bridge.rs  # AST construction from parse tree
│   └── experimental/  # New GLL parser development
│       ├── gll/      # GLL parser framework
│       └── unified_vibe_parser.rs # Unified grammar implementation
├── pretty_print.rs     # AST pretty printing
├── builtin_modules.rs  # Standard library modules
└── metadata.rs         # AST metadata management
```

### vibe-compiler/ - Compilation Pipeline
```
src/
├── lib.rs              # Compiler API
├── type_checker.rs     # Hindley-Milner type inference (in lib.rs)
├── effect_inference.rs # Effect system inference
├── semantic_analysis.rs # Semantic validation phase
├── perceus.rs          # Reference counting optimization
├── improved_errors.rs  # Enhanced error messages
├── module_env.rs       # Module environment management
└── wasm/              # WebAssembly backend
    ├── codegen.rs     # Code generation
    ├── emit.rs        # WASM emission
    └── component.rs   # Component model support
```

### vibe-runtime/ - Runtime System
```
src/
├── lib.rs              # Runtime API
├── interpreter.rs      # Expression evaluation (in lib.rs)
├── effect_runtime.rs   # Effect handler runtime
└── backend.rs          # Runtime backend abstraction
```

### vibe-codebase/ - Storage and Management
```
src/
├── lib.rs              # Codebase API
├── codebase.rs         # Core codebase functionality
├── hash.rs             # Content hashing utilities
├── namespace.rs        # Hierarchical namespace management
├── incremental.rs      # Incremental compilation support
├── database.rs         # SQLite storage backend
├── query_engine.rs     # Code search and queries
├── ast_command.rs      # Structural code transformations
├── dependency_extractor.rs # Dependency analysis
└── package/            # Package management
    ├── manifest.rs     # Package.vibe parsing
    ├── registry.rs     # Package registry interface
    └── resolver.rs     # Dependency resolution
```

### vibe-cli/ - Developer Tools
```
src/
├── bin/
│   ├── vibe.rs        # Main CLI entry point
│   └── vibe-api.rs    # API server (future)
├── cli.rs             # CLI command handling
├── shell.rs           # Interactive REPL
├── commands.rs        # CLI command implementations
├── lsp/               # Language Server Protocol
│   ├── mod.rs        # LSP server setup
│   ├── handlers/     # LSP request handlers
│   └── capabilities.rs # Server capabilities
├── mcp/               # Model Context Protocol
│   ├── server.rs     # MCP server implementation
│   └── tools.rs      # MCP tool definitions
└── test_runner/       # Test execution framework
```

## Code Organization Patterns

### Module Structure
- Each crate has a clear, focused responsibility
- Public APIs are exported through `lib.rs`
- Internal modules use `mod.rs` for organization
- Tests are co-located with implementation files

### Separation of Concerns
- **Parser**: Only handles syntax → AST conversion
- **Type Checker**: Pure type inference, no side effects
- **Effect System**: Separate inference from type checking
- **Runtime**: Isolated from compilation pipeline
- **Storage**: Abstract interface for persistence

### Dependency Flow
```
vibe-cli
    ↓
vibe-codebase ← vibe-runtime
    ↓              ↓
vibe-compiler ←────┘
    ↓
vibe-language
```

## File Naming Conventions

### Rust Source Files
- **Module files**: `snake_case.rs` (e.g., `type_checker.rs`)
- **Test files**: `<module>_test.rs` or `tests/` directory
- **Binary targets**: `kebab-case.rs` in `src/bin/`

### Vibe Source Files
- **Source files**: `lowercase.vibe` (e.g., `core.vibe`)
- **Test files**: `*_test.vibe` or inline `test` blocks
- **Examples**: Descriptive names in `examples/`

### Documentation
- **Markdown files**: `kebab-case.md` for multi-word names
- **Proposals**: `docs/proposals/<feature-name>.md`
- **Guides**: `docs/<topic>-guide.md`

## Import Organization

### Rust Imports
```rust
// External crates first
use salsa::Database;
use wasmtime::Engine;

// Standard library
use std::collections::HashMap;
use std::path::PathBuf;

// Internal crates
use vibe_language::{Expr, Type};
use vibe_compiler::TypeChecker;

// Current crate modules
use crate::error::CompilerError;
use crate::utils::format_type;
```

### Vibe Imports
```haskell
# Standard library
import List
import Math

# Aliased imports
import String as Str

# Versioned imports
import Json@abc123

# Local modules
import MyModule
```

## Key Architectural Principles

### Content Addressing
- Every expression has a unique hash
- Code is stored by content, not by name
- Names are just aliases to hashes
- Enables perfect incremental compilation

### Effect Tracking
- Effects are part of the type system
- Pure functions have no effects
- Effects must be explicitly handled
- Enables safe, controlled side effects

### Incremental Everything
- Type checking is incremental (Salsa)
- Compilation is incremental
- Tests run incrementally
- Even the REPL maintains incremental state

### Parser Evolution
- Moving from hand-written parser to GLL
- Unified grammar for consistency
- Experimental development in parallel
- Backwards compatibility maintained

### Tool Integration
- LSP for editor support
- MCP for AI model integration  
- Shell for interactive development
- All tools share the same codebase backend