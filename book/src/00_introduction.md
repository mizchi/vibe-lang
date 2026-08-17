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

Chapters 1–8 are the language tour that used to live in `docs/tutorial/`.
They are still the fastest path from zero to "I can write a package."
Chapters 9–14 go into mutation, capabilities, concurrency, the CLI, and
wasm — the parts that make vibe's design different from a typical
functional scripting language.

Japanese translations of the tour chapters live in `book/ja/`. The English
files are canonical; a pair must run the same programs (same `` ```output ``
blocks).

When an example is deliberately not runnable — rejected syntax, a not-yet
implemented form — it is marked `` ```vibe skip `` with a reason. Never use
`skip` to hide a broken example.
