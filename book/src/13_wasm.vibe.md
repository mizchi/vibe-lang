# 13 — Targeting wasm

日本語版: [13_wasm.vibe.md](../ja/13_wasm.vibe.md)

The compiler is a wasm program that emits wasm. You do not opt into wasm
as a backend — it is the representation. Internal values are tagged i64.
Strings are byte strings. Types that can appear on a WIT boundary follow
nominal rules so the boundary does not have to invent a mapping.

## Two codegen paths

- **linear memory** (default for `vibe test` / `vibe build --release`):
  tagged i64 values, a bump/RC heap, Perceus planning for ownership.
- **wasm-gc**: typed heap types, `mut` struct fields (ADR-0052). Set
  `VIBE_TEST_BACKEND=gc` to opt a test onto this path.

```bash
vibe test foo_test.vibe                       # linear
VIBE_TEST_BACKEND=gc vibe test foo_test.vibe  # wasm-gc
vibe build --release app.vibe                 # standalone .wasm
```

Not every program is valid on both. HOF / Iterator gaps still exist on
gc. Prefer linear unless you need a gc-only feature. Bench caches key
on the backend, so switching linear → gc recompiles.

## Feature levels

Generated modules declare the wasm feature level they need
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md)).
Denied capabilities are folded out, so a program that never reaches
`Http` should not demand a networking-capable runtime.

Two levels are tracked: `v8` (Chrome / Node / Deno) and `web-baseline`
(those plus Firefox and Safari). A proposal is safe for a level only
when every engine in the set supports it **without a flag**. The
compiler host (`viberun`) is allowed to enable experimental proposals;
generated user code is not.

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

Next: [Pitfalls](14_pitfalls.vibe.md).
