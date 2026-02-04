# xsh

xsh language prototype and runtime (MoonBit).

## Docs

- `docs/xsh.md` - Language/spec notes

## Development

```bash
moon check
moon test
```

## CLI

```bash
moon run --target native src/xsh_cli -- run fixtures/hello.xsh
moon run --target native src/xsh_cli -- test fixtures/hello.xsh
moon run --target native src/xsh_cli -- compile fixtures/hello.xsh
moon run --target native src/xsh_cli -- repl  # TUI repl (completion + layout)
printf 'add(1,2)\nsub(5,3)\n' | moon run --target native src/xsh_cli -- repl-stdin --no-prompt
just install  # install native binary to ~/.local/bin/xsh (override with XSH_PREFIX)
moon run --target native src/xsh_cli -- bench --n 20000 --warmup 1000 --expr "add(1,2)"
```

## Fixtures

Fixtures live in `fixtures/*.xsh` and include a `__DATA__` JSON section.
`moon test` runs them via `src/xsh/fixture_test.mbt`.

WASM fixtures live in `fixtures/wasm/*.xsh` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.xsh` and check for `struct.new/get/set`.

## Bench

```bash
just bench-wasmtime
just bench-compare
just bench-cmd-latency
```
