# Introduction

This book is a tour of **vibe**: a modern, statically typed functional language
where side effects are explicit, the compiler is self-hosted on wasm, and
every example you see is supposed to be true.

It is modeled on *The Rust Programming Language* — read a section, run the
code, keep going — but the source of each chapter is a `.vibe.md`. A
`` ```vibe run `` fence is compiled and executed by `scripts/vibe_md.sh`,
and the following `` ```output `` fence is that run's stdout. If the compiler
changes, the book fails CI instead of quietly rotting.

```bash
bash scripts/vibe_md.sh check book/src/*.vibe.md
bash scripts/vibe_book.sh          # render _build/book/index.html
```

## What vibe is

Three commitments, in this order when they collide:

1. **Never be silently wrong.** Types and diagnostics exist for an evaluation
   loop — human or LLM. A crash is better than a wrong answer. Diagnostics
   lead with the edit that fixes the program, not a pass name.
2. **Honest representation.** Values are tagged i64. Strings are byte strings.
   Effects are a row on the function (`with Exception + Fs`), not a wrapper
   return type. If wasm cannot express it cleanly, the language should not
   pretend it can.
3. **Surface convenience last.** One concept, one spelling.

The lineage is Rust / MoonBit / Koka / Verse. The compiler is written in
vibe and built from a committed seed. You do not need a second language
toolchain to work on vibe.

## How to read this book

**Getting started** is the language tour that used to live in `docs/tutorial/`.
It is still the fastest path from zero to "I can write a package."

**Language** goes into the parts the tour only pointed at: byte strings,
collections, mutation and escape, generics, iteration, and `==`.

**Systems** is why vibe is not "another functional scripting language":
capabilities, structured concurrency, the CLI as an editor query surface,
and wasm as the representation rather than a backend you opt into.

Japanese translations of the original tour live in `book/ja/`. The English
files are canonical; a pair must run the same programs (same `` ```output ``
blocks). Later chapters are English-only for now.

When an example is deliberately not runnable — rejected syntax, a not-yet
implemented form — it is marked `` ```vibe skip `` with a reason. Never use
`skip` to hide a broken example.

The [cheatsheet](../../docs/cheatsheet.md) is the one-page reference this
book expands. If a sentence here and a sentence there disagree, the
cheatsheet plus a failing `.vibe.md` block win — then we fix the book.
