# The Vibe Programming Language

A book-shaped tour of vibe, in the spirit of *The Rust Programming Language*.
Every runnable example is a `` ```vibe run `` block in a `.vibe.md` file and
is checked by `scripts/vibe_md.sh`. The HTML site is built by
`lib/@vibex/book`, a small static site generator with a rust-book-like
sidebar and a tiny keyword highlighter (no external highlighter crate).

```bash
# prove the examples
bash scripts/vibe_md.sh check book/src/*.vibe.md
pkf run vibe-md-tutorial

# render _build/book/index.html
bash scripts/vibe_book.sh
pkf run book
```

Open `_build/book/index.html` in a browser.

## Layout

| Path | Role |
| --- | --- |
| `book/SUMMARY.md` | chapter list (mdbook-style links) |
| `book/src/` | English chapters (canonical) |
| `book/ja/` | Japanese translations of the original tour |
| `lib/@vibex/book/` | HTML renderer + SUMMARY parser |
| `scripts/vibe_book.sh` | compile and run the generator |

The former `docs/tutorial/` chapters live here now. `docs/tutorial/README.md`
is a pointer.

## Chapter map

See [SUMMARY.md](SUMMARY.md). Start at
[Getting started](src/01_getting_started.vibe.md) or jump to
[Values and functions](src/01_values_functions.vibe.md).
