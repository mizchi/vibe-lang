# WasmFX effect probe

This probe pins the representation boundary between Vibe's algebraic effects
and the stack-switching implementation in `mizchi/wasmtime-threads`.

It is deliberately separate from the production compiler. Its first job is to
prove which source-level restrictions are implementation artifacts of the
current suspend-CPS lowering rather than requirements of Vibe's effect model.

Run with:

```sh
cargo +1.97.1 test --manifest-path tools/wasmfx_effect_probe/Cargo.toml
```

The Wasmtime revision is pinned so the probe remains reproducible.

Measured 2026-09-20: all three cases pass on **Linux x64** as well as Apple
Silicon macOS -- the pinned revision builds and stack-switches on both. This
line used to read "Run on Apple Silicon macOS", which a reader takes as a
platform requirement; #2221's acceptance gate asks for the same matrix on both,
and nobody had run the probe on the second one.

The toolchain floor is real and is above several distributions' default: the
manifest says `rust-version = "1.96"` and this was measured on 1.97.1. A 1.94
toolchain is refused by cargo before any code is compiled.
