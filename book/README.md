# The Vibe Programming Language

A book-shaped tour of vibe, in the spirit of *The Rust Programming Language*.
Every runnable example is a `` ```vibe run `` block in a `.vibe.md` file and
is checked by `scripts/vibe_md.sh`. The HTML site is built by
`lib/@vibex/book`, a small static site generator with a rust-book-like
sidebar. Fences tagged `vibe`, `vibe run`, or `.vibe`, and standalone
`.vibe` chapters listed in `SUMMARY.md`, are highlighted by a small
scanner (keywords from the lexer, PascalCase types, numbers, `@pkg`
paths, `#directives`). No external highlighter crate.

```bash
# prove the examples
bash scripts/vibe_md.sh check book/en/*.vibe.md
pkf run vibe-md-tutorial

# render _build/book/index.html
bash scripts/vibe_book.sh
pkf run book
```

Open `_build/book/index.html` in a browser. On `main`,
`.github/workflows/book-pages.yml` rebuilds this tree and deploys it to
GitHub Pages (`https://mizchi.github.io/vibe-lang/`). The repo Pages
source is already **GitHub Actions**. This replaces the old playground
artifact at that URL; the playground still lives in `playground/`
(`pkf run playground-dev`).

## Layout

| Path | Role |
| --- | --- |
| `book/SUMMARY.md` | chapter list (mdbook-style links) |
| `book/en/` | English chapters (canonical) |
| `book/ja/` | Japanese translations of the original tour |
| `lib/@vibex/book/` | HTML renderer + SUMMARY parser |
| `scripts/vibe_book.sh` | compile and run the generator |

The former `docs/tutorial/` chapters live here now. `docs/tutorial/README.md`
is a pointer.

## Chapter map

See [SUMMARY.md](SUMMARY.md). The parts follow *The Rust Programming
Language*: a short getting-started plus a small program, then concepts,
mutation (the ownership analog), data, packages, collections, effects,
generics, concurrency, and tooling.

Start at [Installation and Hello, vibe](en/01_getting_started.vibe.md)
or jump to [A small program](en/19_a_small_program.vibe.md).
