# zed-vibe

[Zed](https://zed.dev/) extension for the [Vibe programming language](https://github.com/mizchi/vibe-lang).

## Features

- Syntax highlighting for `.vibe` files
- Bracket matching
- Auto-indentation
- Code outline (functions, types, tests in symbol navigator)

## Install (Dev Extension)

1. Open Zed
2. Open the command palette (`Cmd+Shift+P`)
3. Run **zed: install dev extension**
4. Select the `integrations/zed-vibe` directory

The grammar is fetched from the `integrations/treesitter-vibe` directory in this repository via the commit SHA in `extension.toml`.

## Update grammar

After updating `treesitter-vibe`, update the `rev` in `extension.toml`:

```bash
# Push changes first
git push origin main

# Update rev to the latest commit
git rev-parse HEAD
# Edit extension.toml [grammars.vibe] rev = "<new-sha>"
```

Then reinstall the dev extension in Zed.

## Structure

```
zed-vibe/
├── extension.toml              # Extension manifest + grammar source
└── languages/vibe/
    ├── config.toml             # Language config (.vibe, //, tab_size=2)
    ├── highlights.scm          # Syntax highlighting
    ├── brackets.scm            # Bracket pairs
    ├── indents.scm             # Auto-indentation rules
    └── outline.scm             # Code outline (symbol navigator)
```
