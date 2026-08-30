# tree-sitter-vibe

[Tree-sitter](https://tree-sitter.github.io/) grammar for the [Vibe programming language](https://github.com/mizchi/vibe-lang).

This grammar is used by the Helix, Zed, and Neovim editor integrations.

## Features

- Full expression grammar with correct operator precedence
- Declarations: `let`, `enum`, `struct`, `trait`, `impl`, `type`, `module`
- Control flow: `if`/`else`, `match`, `while`, `for`/`in`, `loop`, `handle`/`throw`
- Functions with type parameters, effects, and labeled arguments
- Pattern matching: constructors, tuples, records, or-patterns, guards
- String interpolation (`\{expr}`)
- Import/export with specifier lists

## Build

Use the CLI pinned in `package.json`, not a globally installed one. `tree-sitter-cli`
0.24.x emits `LANGUAGE_VERSION 14` with a `.version` field, while everything
committed here is 15 with `.abi_version` — generating with the wrong version
produces a plausible-looking diff and no error, silently downgrading the ABI for
every consumer.

```bash
cd integrations/treesitter-vibe

pnpm install --ignore-scripts

pnpm exec tree-sitter generate          # regenerate src/ from grammar.js
pnpm exec tree-sitter test              # corpus suite (10 cases)
pnpm exec tree-sitter parse ../../examples/syntax.vibe
```

### The three artifacts move together

One `grammar.js` produces three committed artifacts, and they are only correct
as a set:

| artifact | consumer |
| :--- | :--- |
| `src/parser.c` | the corpus suite, Neovim, the Rust/Node bindings |
| `../../playground/public/tree-sitter-vibe.wasm` | the playground editor |
| `../zed-vibe/grammars/vibe.wasm` | the Zed extension |

They had always been regenerated in the same commit until #2403 added prefix
`~` in an environment with no emscripten, so only the C parser could be rebuilt.
The two wasm files went stale and `~x` stayed a syntax error in the playground
and in Zed while the corpus suite was green — nothing detected it, because the
pairing was a habit rather than a check. It is a check now:
`scripts/check_treesitter_artifacts.sh` (run in CI's `structural-lint` job)
compares all three against `generated.sha256` and fails when one moves alone.

Hashing alone would not be enough — `generated.sha256` is a file in the tree, so
regenerating `src/parser.c` and then restamping makes every hash agree while the
wasm is still stale. So `scripts/check_treesitter_wasm_corpus.sh` proves each
wasm by **parsing** `test/corpus/*.txt` with it, using the loader version
`playground/package.json` pins, and the stamper refuses to write unless that
passes. Behaviour is not rewritable: a wasm built before a grammar change parses
the new corpus case wrongly.

So after any `tree-sitter generate`, rebuild the wasm from the same `src/` and
restamp:

```bash
pnpm run build:wasm     # builds both wasm files and restamps generated.sha256
```

That needs `emcc` on `PATH` or a running docker daemon. If you cannot build it,
**do not restamp** — leave the gate red, which is the state it exists to make
visible.

The Zed extension additionally pins a commit SHA in
`integrations/zed-vibe/extension.toml`; Zed compiles the grammar itself from
that revision, so bump the `rev` after pushing a grammar change.

### Install tree-sitter CLI

Prefer `pnpm exec tree-sitter` inside this directory, which resolves the pinned
version. A globally installed CLI must match that pin:

```bash
cargo install tree-sitter-cli --version 0.25.10
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
