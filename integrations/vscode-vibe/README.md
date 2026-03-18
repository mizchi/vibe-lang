# vscode-vibe

VSCode extension for the [Vibe programming language](https://github.com/mizchi/vibe-lang).

## Features

- Syntax highlighting for `.vibe` files (TextMate grammar)
- Bracket matching and auto-closing
- Comment toggling (`//`)
- String interpolation highlighting (`\(expr)`)

## Install

### From VSIX (recommended)

```bash
cd integrations/vscode-vibe
npx @vscode/vsce package
code --install-extension vscode-vibe-0.1.0.vsix
```

### From source directory

```bash
cd integrations/vscode-vibe
pnpm install --ignore-scripts
npx @vscode/vsce package
code --install-extension vscode-vibe-0.1.0.vsix
```

## Uninstall

```bash
code --uninstall-extension mizchi.vscode-vibe
```

## Structure

```
vscode-vibe/
├── package.json                 # Extension manifest
├── language-configuration.json  # Brackets, comments, indentation
└── syntaxes/
    └── vibe.tmLanguage.json     # TextMate grammar
```
