# clients/wasm

`clients/wasm/vibe.wasm` is a distributable build of the selfhost compiler for
the `wasm-gc` release target. It exports `vibe_check` and friends, and
`clients/js/` binds to it.

## Rebuilding

**Nothing in this repository rebuilds it.** The artifact is committed, last
produced under the MoonBit host (#900) by a task that went with that host in
#594; there is no `wasm-gc` release build of the compiler in the tree today to
replace it. Until one exists, treat the committed binary as the artifact — do
not expect a command to regenerate it.

This README previously showed `pkf run build-wasm-vibe`, which names no task.

The artifact is **stale**: it rejects `fn` declarations (`expected expr, got
`fn``) while still typechecking `let`, so it predates the current syntax.
`clients/js/` defaults to it anyway, because its previous default
(`_build/wasm-gc/release/build/lib/lib.wasm`, a MoonBit-host output) has had
no producer since #594 and made `createVibeService()` throw unconditionally.

## Smoke test with wasmtime

The committed artifact does still run:

```bash
bash scripts/test_wasm_vibe_wasmtime.sh
```

which is:

```bash
wasmtime run -W gc=y -W function-references=y --invoke vibe_check clients/wasm/vibe.wasm 1024 0 4096 4096
```
