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
(an ordinary vite app: `cd playground && pnpm install && pnpm dev`).

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

## What the check does and does not prove

`bash scripts/vibe_md.sh check` compiles and runs each `` ```vibe run `` block
and compares it against the `` ```output `` block that follows. That proves the
code and the recorded output are true of the current compiler. It proves
nothing about the prose, the choice of API, or the order the chapters teach in
— those are review's job.

The whole book is checked by the required `compiler-gate` CI job, which passes
`VIBE_MD_STAGE2` explicitly from the stage2 built in the same checkout;
`pkf run release-check` depends on `vibe-md-tutorial-gated`, which carries the
same guarantee. Neither allows a silent fallback to the committed seed, so a
chapter cannot go green by accident on an older compiler.

## When to use ` ```vibe skip `

Only for examples that are **deliberately** not runnable: syntax that is
rejected on purpose, target syntax that is not implemented yet, illustrative
paths that do not exist. Put the reason in a comment on the block's first line,
and attach a tracking issue for anything unimplemented. When it becomes
runnable, turn it into `vibe run` with a real `output` block.

Never move code to `skip` because its test broke.

## Chapter map

See [SUMMARY.md](SUMMARY.md). The shape follows *The Rust Programming
Language* — a short getting-started plus a small program, then the
concepts — but the spine turns on effects: getting-started, concepts,
mutation, data, then **effects and capabilities** at 8 and 9, then the
railway, packages and tests, collections, generics, concurrency and
tooling. Chapters 3 to 7 are exactly what a handler needs (functions,
control flow, types, enums and `match`) and no more, and everything from
10 on is written on top of the row rather than around it.

Start at [Installation and Hello, vibe](en/01_getting_started.vibe.md)
or jump to [A small program](en/02_a_small_program.vibe.md).
