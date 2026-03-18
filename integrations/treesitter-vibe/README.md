# tree-sitter-vibe

[Tree-sitter](https://tree-sitter.github.io/) grammar for the [Vibe programming language](https://github.com/mizchi/vibe-lang).

This grammar is used by the Helix, Zed, and Neovim editor integrations.

## Features

- Full expression grammar with correct operator precedence
- Declarations: `let`, `enum`, `struct`, `trait`, `impl`, `type`, `module`
- Control flow: `if`/`else`, `match`, `while`, `for`/`in`, `loop`, `handle`/`throw`
- Functions with type parameters, effects, and labeled arguments
- Pattern matching: constructors, tuples, records, or-patterns, guards
- String interpolation (`\(expr)`)
- Import/export with specifier lists

## Build

```bash
cd integrations/treesitter-vibe

# Install dependencies
pnpm install --ignore-scripts

# Generate parser from grammar.js
tree-sitter generate

# Run tests (9 corpus tests)
tree-sitter test

# Parse a file
tree-sitter parse ../../examples/syntax.vibe
```

### Install tree-sitter CLI

```bash
cargo install tree-sitter-cli
# or
brew install tree-sitter  # library only, CLI needs cargo
```

## Use with Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "vibe"
scope = "source.vibe"
injection-regex = "vibe"
file-types = ["vibe"]
comment-token = "//"
indent = { tab-width = 2, unit = "  " }

[[grammar]]
name = "vibe"
source = { path = "/path/to/vibe-lang/integrations/treesitter-vibe" }
```

Then build the grammar and copy queries:

```bash
hx --grammar build

# Copy query files
mkdir -p ~/.config/helix/runtime/queries/vibe
cp queries/highlights.scm ~/.config/helix/runtime/queries/vibe/

# Or use the Helix-optimized queries from the repo setup
```

Verify with `hx --health vibe`.

## Use with Neovim

```lua
-- In your Neovim config (e.g. init.lua)
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.vibe = {
  install_info = {
    url = "/path/to/vibe-lang/integrations/treesitter-vibe",
    files = { "src/parser.c" },
  },
  filetype = "vibe",
}

vim.filetype.add({
  extension = { vibe = "vibe" },
})
```

Then run `:TSInstall vibe` and copy `queries/` to your Neovim runtime.

## Structure

```
treesitter-vibe/
├── grammar.js              # Grammar definition
├── tree-sitter.json        # Tree-sitter config
├── package.json            # npm package
├── queries/
│   ├── highlights.scm      # Syntax highlighting captures
│   └── tags.scm            # Symbol tags (functions, types)
├── test/corpus/            # Test cases
├── src/                    # Generated C parser
└── bindings/
    ├── node/               # Node.js binding
    └── rust/               # Rust binding
```
