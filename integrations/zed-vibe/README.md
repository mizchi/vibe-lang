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

Zed builds the grammar itself from the revision named here, so `grammars/vibe.wasm`
in this directory is a build artifact Zed never reads — **the `rev` is what Zed
users actually get.** After a grammar change reaches `main`, point it at a commit
that contains that change:

```bash
git fetch origin main
git rev-parse origin/main
# Edit extension.toml [grammars.vibe] rev = "<that sha>"
```

Then reinstall the dev extension in Zed.

This bump can only happen **after** the grammar change is merged, since the SHA
does not exist before then — which is why it is a separate follow-up and why no
CI gate enforces it. A gate would have to fail on every PR that touches the
grammar, for a condition that PR cannot satisfy, and a gate nobody can satisfy is
a gate that gets disabled. #2409 is the record of what that costs: `~` parsed in
the corpus suite and stayed a syntax error in Zed, and nothing noticed.

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
