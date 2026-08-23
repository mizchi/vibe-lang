# WasmFX effect probe

This probe pins the representation boundary between Vibe's algebraic effects
and the stack-switching implementation in `mizchi/wasmtime-threads`.

It is deliberately separate from the production compiler. Its first job is to
prove which source-level restrictions are implementation artifacts of the
current suspend-CPS lowering rather than requirements of Vibe's effect model.

Run on Apple Silicon macOS with:

```sh
cargo +1.97.1 test --manifest-path tools/wasmfx_effect_probe/Cargo.toml
```

The Wasmtime revision is pinned so the probe remains reproducible.
