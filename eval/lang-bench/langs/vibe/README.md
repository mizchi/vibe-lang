# mini-vcs — vibe

## Relevant API surface

- argv: `Env::args_len` / `Env::args_get` (`with Env::Read` or the
  narrower `Env::args_len`/`Env::args_get` effectset — see
  `docs/effectset.md`).
- file I/O: `lib/@vibe/fs` (`Fs::exists`, `Fs::read_file`,
  `Fs::write_file`, `Fs::stat_token`). Directory listing: check
  `vibe symbols lib/@vibe/fs/index.vibe` (or the sibling `index.vibei`
  contract) for the current readdir-shaped export — API discovery
  convention per the repo's own `CLAUDE.md`.
- stdout/stderr: `lib/@vibe/builtin`'s `stdout_write` (see
  `eval/lang-review/golden/*.vibe` for usage); check the same package for
  a stderr equivalent, or use the exit-code channel plus stdout if none
  exists yet (note this as a friction point in `findings/` if so).

## Build

```bash
S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
[ -f "$S2" ] || S2=bootstrap/seed/compiler.wasm
VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$S2" eval/lang-bench/attempts/<round>/vibe/minivcs.vibe \
  eval/lang-bench/attempts/<round>/vibe/minivcs.wasm main
```

## Run (for `acceptance_test.sh`)

The compiled tool is a wasm module, not a native executable, so
`acceptance_test.sh`'s `<run-command>` must be a wrapper script that
forwards argv into the host runner and preserves the *current working
directory* the acceptance test set up (each subcommand — `init`/`add`/
`commit`/`log`/`status` — needs to see the temp dir's `.mvcs/`, `a.txt`,
etc.). Write a small wrapper, e.g.:

```bash
#!/usr/bin/env bash
# eval/lang-bench/attempts/<round>/vibe/run.sh
exec bash "<repo-root>/scripts/run_wasm_vibe_host_runner.sh" --invoke _start \
  VIBE_PREOPEN_DIR="$PWD" \
  "<repo-root>/eval/lang-bench/attempts/<round>/vibe/minivcs.wasm" -- "$@"
```

Then: `bash eval/lang-bench/acceptance_test.sh "bash .../run.sh"`. Confirm
the exact `run_wasm_vibe_host_runner.sh` argv-forwarding flag (`--` vs a
dedicated flag) against `bash scripts/run_wasm_vibe_host_runner.sh --help`
before relying on this — not verified against a real implementation in
this harness-only pass.

## LOC / size

`wc -l minivcs.vibe` for LOC; `wc -c minivcs.wasm` for binary size
(comparable to the `rc_off` column methodology in
`bench/binary_size/README.md`, though this is a much larger program than
that suite's 5 micro-benchmarks).
