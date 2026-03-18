# vscode-vibe

VSCode extension for the [Vibe programming language](https://github.com/mizchi/vibe-lang).

## Features

- Syntax highlighting for `.vibe` files
- Bracket matching and auto-closing
- Comment toggling (`//`)
- String interpolation highlighting (`\(expr)` and `\{expr}`)

## Install (development)

```bash
# From the extension directory
cd integrations/vscode-vibe
code --install-extension .
```

Or use "Extensions: Install from VSIX" in VSCode after packaging:

```bash
npx @vscode/vsce package
code --install-extension vscode-vibe-0.1.0.vsix
```

## Roadmap

- [ ] LSP integration (diagnostics, completion, go-to-definition)
- [ ] Snippet support
- [ ] Formatter integration
