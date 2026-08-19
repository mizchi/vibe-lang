# vibe 0.1.0 release notes

> **Status: in preparation.** The tag has not been cut; `vibe version` reports
> `0.1.0-dev` until it is. The version ladder is ADR-0109 — 0.1.0 is the first
> release usable by anyone but the author, and everything before it was 0.0.x
> development.

The previous and only published release is `v0.0.1` (2026-04-14). Between it and
0.1.0 the language was rewritten in itself, so these notes describe a different
compiler rather than a list of fixes. The work once prepared under the name
"0.3.0 GA" is part of this release; the record of that intermediate state is
[archive/release-notes-0.3.0.md](archive/release-notes-0.3.0.md).

## The headline: vibe compiles itself

`v0.0.1` was compiled by a MoonBit host implementation. That host is gone
(#594). The compiler is now written in vibe, lives in `lib/@vibe/compiler/` and
`lib/@vibe/cli/`, and is built from a committed seed plus its own source with no
MoonBit toolchain involved. Building it requires only the Rust/node wasm runner.

The practical consequence for a user is that the language and its compiler are
now the same artifact: a diagnostic you find is a diagnostic in code you can
read, and every feature below is one the compiler itself depends on.

## Language

- **Effects are rows, not return-value wrappers.** Functions are pure by
  default and declare what they do with `with E`. `throw` / `handle ... with
  Exception` / the `?` operator, user-defined algebraic effects
  (`effect` / `perform` / `resume`), and effect polymorphism `with e` are all
  part of the frozen surface (ADR-0016, ADR-0050).
- **Capabilities are carried by the row, and authorized once.** A call site
  stays a plain function call; authority is settled at build → apply →
  instantiate and is then invariant for the run (ADR-0075/0084/0088). The
  two-clause form `with {A} allows {C}`, the optional grade `?`, and the
  `Attempt[T, E]` that `perform?` returns landed over the #1961 series — they
  are on the unstable surface and can still change.
- **`Result` was removed** (#1324). Errors are the `Exception` effect;
  `Error` is deprecated for the 1.0 freeze in favour of `Exception`
  (ADR-0085).
- **`String` is a byte string** with byte-offset indexing (ADR-0098), which is
  what the memory actually holds. Source positions follow: every position the
  CLI reports or accepts is a byte position (ADR-0108,
  [source-range-contract.md](source-range-contract.md)), with the LSP boundary
  the single documented exception.
- **`Int` arithmetic wraps identically on every backend** — 63-bit two's
  complement, literals up to 2^62-1 (#1877). Each backend previously wrapped at
  its own 62/63/64-bit boundary and silently disagreed, which is the worst
  failure shape this project recognizes.
- **`fn main { ... }`** is the entry point, top-level is declarations only, and
  a typo'd entry name is a compile error rather than a silently empty module
  (ADR-0069 Phase 1).
- Syntax was narrowed where two spellings meant one thing: string interpolation
  is `\{expr}`, type-declaration bodies separate with `;`, top-level named
  functions are `fn` (ADR-0064), and struct literals are `Type::{ ... }`.
- Other additions: generic struct type parameters, trait bounds in package
  contracts, `derive(Eq)`, conditional impls, `is` expressions, `loop` /
  `break(v)` / `continue(...)`, and inline wasm
  (`fn f(a: Int) -> Int = wasm "(...)"`, linear backend, ADR-0072).

## Packages and distribution

- **`index.vpkg` is the package contract and the public API boundary**
  (ADR-0070). Importing a file inside a package boundary is a compile error, and
  the legacy `index.vibei` is gone.
- `vibe new` / `add` / `fetch --frozen` / `verify` / `pkg publish|install|yank`,
  with content-hash locking (`index.lock`) and semver constraint resolution.
  The registry slice is file-based with an RFC6962-shaped transparency log.
- 26 `@vibe/*` packages and 18 `@vibex/*` packages ship with the toolchain.
- `install/install.sh` is the curl entry point and is smoke-tested on multiple
  operating systems by the `cli-install` workflow.

## Tooling

The CLI is designed to be read by an LLM as much as by a person: one finding per
line, fixed field order, **empty output means clean**, and messages that name
the edit that fixes them rather than an internal pass name.

- `vibe check [--single-file] [--json]` — the single verb for "does this
  compile" (#1567). It resolves imports from the filesystem, so it answers on
  its own.
- `vibe symbols` / `type-at` / `binding-at` / `doc-at` — the same semantic
  analysis an editor gets over LSP, available from the shell.
- `vibe deps [--direct]` — the resolved import closure, taken from the loader
  itself, so it cannot drift from what a build compiles.
- `vibe grep --pattern ... [--where ...]` — AST pattern search that does not
  stop at syntax: filters are written against the checker's answers (inferred
  type, effect row, resolved name, ill-typedness).
- `vibe escapes`, `vibe allocs`, `vibe rc-classify`, `vibe rc-plan` — what the
  compiler decided about boxing, allocation, and reference counting.
- `vibe lsp` — diagnostics, hover, document symbols, go-to-def, references,
  rename, completion, signature help.
- `vibe fmt` — a CST-token formatter over `.vibe` and `.vpkg`, enforced in CI.
- `vibe shell` — a compiled REPL (declarations accumulate and recompile; there
  is no interpreter), plus `vibe test`, `vibe bench`, `vibe serve`,
  `vibe normalize`, `vibe context-pack`.

## Backends and runtime

- The **linear-memory backend is the stable surface**. The wasm-gc backend is
  opt-in (`VIBE_BACKEND=gc`) and experimental: it compiles one file at a time,
  so using an imported name fails — with a diagnostic that says so and points at
  the linear backend (#1976). Remaining builtin-level differences each have a
  row in `scripts/builtin_parity_classification.tsv`, enforced at the gate.
- Generated wasm declares the feature level it requires
  ([wasm/feature-levels.md](wasm/feature-levels.md)); `--allow-*` const-folds and
  DCEs away the code for capabilities that were not granted.
- Async, structured concurrency, and the WASI 0.3 component surface work — the
  async serve lane streams a request body to its handler (#1540) — but remain on
  the **unstable** surface (ADR-0012/0068).
- Region-based allocation and Perceus reuse (ADR-0090, #1770) cut allocation in
  the compiler's own hot paths; `#zero_alloc` summaries are checked across
  imports.

## Documentation

- **The Vibe Book** (`book/src/`) has 20 doctest-checked chapters, and every ` ```vibe run `
  block in it is compiled and executed by doctest, with its output checked
  against the recorded ` ```output `. A chapter cannot go stale silently.
- [docs/cheatsheet.md](cheatsheet.md) is the language reference and is
  doctest-checked the same way.
- [spec/stable-surface.md](spec/stable-surface.md) states what 0.1.0 promises
  SemVer stability for, and `pkf run check-freeze-surface` derives the symbol
  list from that document and probes each name against the compiler — a name it
  promises cannot quietly stop existing.

## Known gaps

- **The Japanese book covers chapters 1–7 of 20.** English is canonical
  (`book/src/`); `book/ja/` is a translation, and the pair is checked for
  identical program output by `pkf run check-tutorial-translation-parity`.
  Chapters 8–19 have no translation yet.
- **`bench` blocks do not run on the wasm-gc lane** (#1701).
- `vibe symbols` does not return doc comments; hover and `vibe doc-at` do.
- `vibe check --json` exists only under `--single-file` — the import-resolving
  lane throws diagnostics as strings and has no range to report (#1567).
- Everything in §6 of [spec/stable-surface.md](spec/stable-surface.md) is
  outside the SemVer promise, most notably async/structured concurrency and the
  capability authorization surface.

## Release checklist (owner)

- [ ] `0.1.0` tag
- [ ] `VIBE_VERSION` bumped from `0.1.0-dev` to `0.1.0`
      (`scripts/build_release_assets.sh` fails the build if it does not match
      the tag)
- [ ] `pkf run release-check` green on the tagged commit
