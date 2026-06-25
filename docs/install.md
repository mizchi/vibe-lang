# Installing vibe

vibe is distributed as a small **wasmtime runner** (`moonrun_wt`) plus a
**portable compiler wasm** (`vibe-cli.wasm`). At install time the compiler wasm
is AOT-compiled to a host-specific `vibe-cli.cwasm` so the compiler is not
re-JITed on every command. See `docs/release-roadmap.md` (テーマ1) for the
rationale behind this split.

## Quick install (from a checkout)

```bash
bash scripts/install.sh
```

This will:

1. build (or reuse) the `moonrun_wt` runner from `tools/moonrun_wasmtime`,
2. install the committed seed compiler as `vibe-cli.wasm`,
3. AOT-compile it to `vibe-cli.cwasm` for this machine,
4. install the `vibe` launcher and link it onto your `PATH`.

Then:

```bash
vibe version
echo 'export let main = () -> Int { 40 + 2 }' > hello.vibe
vibe run hello.vibe        # -> 42
```

### Install layout

```
$VIBE_HOME/                 (default: ~/.vibe)
├── bin/
│   ├── vibe                # launcher (subcommand dispatch + orchestration)
│   └── moonrun_wt          # wasmtime runner
└── lib/
    ├── vibe-cli.wasm       # portable compiler artifact
    └── vibe-cli.cwasm      # host-specific AOT build (rebuilt by `vibe self update`)
```

`~/.local/bin/vibe` is symlinked to `$VIBE_HOME/bin/vibe` (override the bin
directory with `--bin-dir` or `VIBE_BIN_DIR`; skip linking with `--no-link`).

## Installer options

```
bash scripts/install.sh [--prefix DIR]      # VIBE_HOME (default ~/.vibe)
                        [--bin-dir DIR]      # PATH link dir (default ~/.local/bin)
                        [--runner PATH]      # use a prebuilt moonrun_wt
                        [--cli-wasm PATH]    # use a specific compiler wasm
                        [--no-link]          # do not symlink onto PATH
```

To install a released compiler instead of the seed, pass the release artifact:

```bash
bash scripts/install.sh --cli-wasm vibe-selfhost-<tag>.wasm
```

## Commands

```
vibe run     <file.vibe> [entry]      compile (resolving imports) then run
vibe compile <file.vibe> -o <out>     compile to a .wasm
vibe build   <file.vibe> -o <out>     alias of compile
vibe check   <file.vibe> [entry]      parse + typecheck (no output kept)
vibe test    <file_test.vibe>...      compile + run test {} blocks
vibe version                          print toolchain versions
vibe self update --cli-wasm <path>    refresh compiler wasm + rebuild .cwasm
vibe help                             usage
```

The default entry function is `main`. Pass a different entry as the second
argument to `run`/`check`, or via `--entry` to `compile`/`build`.

## Updating the compiler independently of the runner

The runner and the compiler wasm version independently. To move the compiler
forward (e.g. to a newer selfhost build) without rebuilding the runner:

```bash
vibe self update --cli-wasm path/to/new/vibe-cli.wasm
```

This copies the new compiler wasm into place and rebuilds the host-specific
`vibe-cli.cwasm` against the installed runner.

## Notes

- A `vibe-cli.cwasm` is only valid for the exact `moonrun_wt`/wasmtime build
  that produced it. The launcher falls back to the portable `vibe-cli.wasm` if
  the `.cwasm` looks older than the runner, and `vibe self update` regenerates
  it. Do not copy a `.cwasm` between machines or toolchain versions.
- Set `VIBE_RUNNER_BACKTRACE=1` (or `RUST_BACKTRACE=1`) to see the full runner
  backtrace when diagnosing a runner-level failure; by default guest traps are
  reported as a single-line message.
