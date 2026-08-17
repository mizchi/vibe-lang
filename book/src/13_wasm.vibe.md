# 13 — Targeting wasm

The compiler is a wasm program that emits wasm. You do not opt into wasm
as a backend — it is the representation.

## Two codegen paths

- **linear memory** (default for `vibe test` / `vibe build --release`):
  tagged i64 values, a bump/RC heap, Perceus planning for ownership.
- **wasm-gc**: typed heap types, `mut` struct fields (ADR-0052). Set
  `VIBE_TEST_BACKEND=gc` to opt a test onto this path.

Not every program is valid on both. HOF / Iterator gaps still exist on
gc. Prefer linear unless you need a gc-only feature.

## Feature levels

Generated modules declare the wasm feature level they need
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md)).
Denied capabilities are folded out, so a program that never reaches
`Http` should not demand a networking-capable runtime.

## WIT

Types that can appear on a WIT boundary follow nominal rules (ADR-0089).
`@vibe/wit_runtime` provides the `Result` that maps to WIT
`result<T, E>` — that is the one blessed two-armed return type. Everywhere
else, write `T with Exception[E]`.

## What "selfhost" means

`bootstrap/seed/` is a pinned compiler wasm. `lib/@vibe/compiler/` is
source. `scripts/generations.sh` builds stage1 then stage2. A fixpoint
is stage2 compiling the compiler to the same bytes as stage3. You do
not need MoonBit, LLVM, or a native vibe compiler.
