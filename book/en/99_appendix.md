# Appendix — Where to look next

This book is the narrative. These are the other surfaces, in the
order they are usually useful.

## In this repository

- [docs/cheatsheet.md](../../docs/cheatsheet.md) — one-page language
  reference. If the book and the cheatsheet disagree, run a
  `.vibe.md` block and believe the compiler.
- [docs/install.md](../../docs/install.md) — installer, `VIBE_HOME`,
  the dispatcher.
- [docs/cli-commands.md](../../docs/cli-commands.md) — every `vibe`
  verb.
- [docs/editor-and-debugging.md](../../docs/editor-and-debugging.md) —
  LSP, DAP, `type-at` / `binding-at` / `symbols`.
- [docs/adding-modules.md](../../docs/adding-modules.md) — where a new
  package goes (`@vibe` vs `@vibex` vs a user scope).
- [docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md) —
  which wasm proposals generated modules may use.
- [docs/concurrency.md](../../docs/concurrency.md) — `Send`, regions,
  `TaskGroup`.
- [docs/adr.md](../../docs/adr.md) — the decisions this book cites
  by number.

## Commands the book assumes

```bash
vibe check file.vibe                 # empty = compiles
vibe test file_test.vibe
vibe run hello.vibex
bash scripts/vibe_md.sh check book/en/*.vibe.md
bash scripts/vibe_book.sh            # _build/book/index.html
pkf run book
pkf run vibe-md-tutorial
```

## Japanese translation

Every chapter of this book has a Japanese translation in
[book/ja/](../ja/). English is canonical.
`pkf run check-tutorial-translation-parity` checks that each pair still
runs the same programs.

## What this book is not

It is not the spec ([docs/spec/syntax.md](../../docs/spec/syntax.md)),
not the effect taxonomy, and not a replacement for reading the
compiler. It is the document you hand someone who has written Rust or
TypeScript and needs vibe's actual rules, with examples the compiler
is willing to run.
