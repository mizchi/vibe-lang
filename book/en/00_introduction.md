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
bash scripts/vibe_md.sh check book/en/*.vibe.md
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

Two kinds of chapters, as in *The Rust Programming Language*: concept
chapters, and a small project chapter.

**Getting Started** installs the toolchain, writes hello, then builds a
small program (the guessing-game slot). You can stop after that and still
have written vibe.

**Common Programming Concepts** is values, functions, control flow, and
the actual contracts of `Int` / `String`.

**Mutation and Regions** is vibe's ownership analog: `let mut` is local,
escape is capture, regions tag scratch buffers.

**Structuring Data** is structs, enums, `match`, `Option`, and the railway.

**Growing Projects** is modules, `.vpkg` contracts, and `test` / `inspect`.

**Common Collections** is `Array` / builders / `MutMap`, then iteration.

**Effects and Authority** is the heart of the language: algebraic `handle`,
then `allows` vs `with` for host capabilities.

**Generic Programming** is traits, `derive`, and `==`.

**Concurrent Programs** and **Tooling and Targets** are TaskGroup / Send
and the CLI-as-IDE / wasm representation.

Japanese translations of the original tour live in `book/ja/`. The English
files are canonical; a pair must run the same programs (same `` ```output ``
blocks). Later chapters are English-only for now.

When an example is deliberately not runnable — rejected syntax, a checker
feature that codegen does not implement yet — it is marked
`` ```vibe skip `` with a reason. Never use `skip` to hide a broken
example.

The [cheatsheet](../../docs/cheatsheet.md) is the one-page reference this
book expands. If a sentence here and a sentence there disagree, a measured
`.vibe.md` block wins — then we fix the book.
