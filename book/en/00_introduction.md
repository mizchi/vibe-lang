# Introduction

**vibe** is a statically typed functional language that compiles to
WebAssembly, in which a function's signature tells you what it can do —
not just what it takes and returns.

That is the whole idea, and it looks like this:

- `fn parse(s: String) -> Int` cannot fail, cannot print, cannot touch
  the disk. If it could, the signature would say so.
- `fn parse(s: String) -> Int with Exception` can fail. Callers either
  handle it or declare it too, and the compiler decides which.
- `fn main with Console` may write to the terminal. It may not read a
  file, because it never asked to.

Most languages leave these facts in the body, where you find them by
reading carefully or by being surprised in production. Here they are in
the type, they are checked, and they compose.

## Why you might want this

**You can tell what a function does without reading it.** The row is
part of the signature, so "does this write to disk" is answered by the
declaration rather than by an audit of everything it calls.

**Permissions are decided when you build, not hoped for at runtime.** A
program that never asked for the network cannot reach it, and the
generated wasm module does not carry the code for capabilities you
denied.

**The compiler prefers to stop rather than to guess.** When a diagnostic
and a silent wrong answer are both possible, vibe takes the diagnostic,
and the message leads with the edit that fixes your program.

**It is small enough to hold in your head.** One concept, one spelling.
The [cheatsheet](../../docs/cheatsheet.md) is a single page, and this
book is that page with the reasoning filled in.

vibe compiles to wasm and is written in itself — the compiler is a vibe
program built from a committed seed, so working on vibe needs no second
toolchain. Its lineage is Rust, MoonBit, Koka and Verse.

## How to read this book

Start at the beginning and keep going; each chapter assumes the ones
before it.

[Installation and Hello, vibe](01_getting_started.vibe.md) gets the
toolchain working. [A small program](02_a_small_program.vibe.md) is a
forty-line calculator that uses features you have not been taught yet —
it is there so you can decide early whether this language is for you.
Everything after that is the tour: values and control flow, then
mutation, data, modules and tests, collections, and then the two
chapters the language exists for — [Effects](13_effects.vibe.md) and
[Capabilities](14_capabilities.vibe.md). Generics, concurrency and the
wasm-facing tooling close it out.

If you already program in a typed functional language, chapters 3 to 12
will feel familiar and you can skim to Effects.

## About the examples

Every ` ```vibe run ` block in this book is compiled and executed by the
current compiler, and the ` ```output ` block beneath it is that run's
real output. When the language changes, the book fails its build rather
than quietly going stale. An example that is deliberately not runnable
is marked ` ```vibe skip ` with the reason in the block.

If a sentence in this book and the compiler disagree, the compiler is
right and the sentence is a bug — please report it.

Japanese translations live in [book/ja/](../ja/). They run the same
programs, so a code block is identical in both and only the prose is
translated.

*Building and rendering the book is described in
[book/README.md](../README.md).*
