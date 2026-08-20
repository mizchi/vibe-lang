# pkfire / pkspec

[`pkfire`](https://github.com/mizchi/pkfire) (typed task runner with
content-addressed caching) is the **canonical task runner** for vibe-lang —
it replaces the former `justfile`.

[`pkspec`](https://github.com/mizchi/pkspec) is no longer part of this repo.
`pkspec/VibeSpec.pkl` / `VibeTest.pkl` — a spec↔test coverage companion tool —
were removed first: they were never consumed by `pkf run test` / `test-local` /
any CI job beyond a standalone `pkspec check`/`coverage` step, and had sat
unused since they were added. `pkspec/Packages.pkl` (the package list that
generated one `test:<pkg>` task per package) went with those tasks in
#881/#987. That left `pkspec/` holding nothing but a `.gitignore` for schemas
nothing regenerates, so the directory was deleted. If a spec-coverage gate is
wanted again, re-run `pkspec init --dir pkspec` and re-author `VibeTest.pkl`
from scratch rather than resurrecting the old files.

The task definitions live in `Taskfile.pkl` (~100 tasks after the dead-task cleanup). Multi-line
shell that doesn't fit a single Pkl `cmd =` lives in `scripts/pkfire/*.sh`
and is invoked directly. CI runs every job through `pkf run …` with
`~/.cache/pkfire` persisted via `actions/cache` so unchanged subgraphs are
cache hits.

## Install

The repo's `nix develop` shell ships `pkgs.pkl`. The pkfire binary is not
in nixpkgs — install it via:

```bash
# Nix (uses the upstream flake)
nix run github:mizchi/pkfire -- list

# go install (needs the Pkl CLI on PATH for pkfire)
go install github.com/mizchi/pkfire/cmd/pkf@latest
```

CI uses the `mizchi/pkfire@v0.14.2` composite action via
`.github/actions/setup-vibe` (set `pkfire: 'true'` on the caller). Pass
`pkfire-cache: 'true'` to also hydrate `~/.cache/pkfire`.

## pkfire — `Taskfile.pkl`

`Taskfile.pkl` is the sole source of task definitions (the former `justfile`
was retired). Simple recipes are inlined via `cmd = …`; complex multi-line
shell lives in `scripts/pkfire/*.sh` (or other `scripts/*.sh`) and is invoked
directly.

Highlights (post-#594 selfhost-only):

| Task           | Behaviour                          | Notes                                |
|----------------|------------------------------------|--------------------------------------|
| `fmt`          | `true` (no-op placeholder)         | fmt 未移植 (#594)           |
| `test`         | `bash scripts/compiler_gate.sh`| operation gate — commit 前の主チェック |
| `test-local`   | affected tests via `flaker`        | fast inner loop                      |
| `run`          | `bash scripts/vibe_run.sh $@`      | `acceptsArgs` — pass via `--`        |
| `release-check`| `deps { compiler-gate }`           | sign-off: bundle/module-source sync + seed→stage1→stage2→stage3 fixpoint + compile/run validation |
| `info` / `check` / `test-update` | legacy `moon …`  | MoonBit host 依存で #594 以降は無効。検証は `test` / `release-check` / `vibe check` を使う |

Two helper factories keep the file readable:

- `scriptTask(name, "scripts/X.sh")` — wraps a single-shell-script recipe

Run from the repo root:

```bash
pkf list
pkf run test
pkf run run -- prog.vibex        # `run` is scripts/vibe_run.sh: one .vibex root
pkf graph --format tree
pkf run --explain-cache test
```

The cache lives in `~/.cache/pkfire` (global, per-user); `.pkfire/` in the
repo is git-ignored as a fallback.

### Why pkfire

- **Typed deps**: `deps { checkDocCommands }` is a Pkl value, not a string —
  a typo fails at evaluation time rather than at run time.
- **Content-addressed cache**: re-running a task after a no-op edit is a cache
  hit, keyed on the task's declared `inputs`. That makes the inputs
  load-bearing: a task whose inputs omit something it reads will replay a
  stale verdict, which is why `pkf run check-task-inputs` exists.
- **`pkf affected --since=origin/main`**: cheap PR-diff aware runs.

This section used to argue pkfire against `just`, and the one below described
one generated task per moon package under `src/` (`test:parser`,
`test:checker`, … 32 of them) wrapping `moon test -p`. `just`, `moon` and
`src/` were all retired with the MoonBit host (#594), and the per-package
`test:*` tasks went in the dead-task cleanup. Test selection is now
`pkf run test-affected`, which walks the compiler's own resolved import graph
(`vibe deps --direct`) and falls back to running everything whenever it cannot
decide — see the "Local Test Execution" section of
[AGENTS.md](../AGENTS.md).

## git hooks (`pkf hooks`)

`pkf hooks install` writes `.git/hooks/*` shims that delegate to
`pkf run <hook-name>` — pkfire binds a git hook to the task whose name
matches the hook (e.g. the `pre-commit` task).

This repo ships a **`pre-commit`** task that runs `scripts/precommit.sh`: the
review-derived structural lint gates (architecture-debt, review-regressions,
lock-check). The `moon fmt` staged-`.mbt` hook it used to run went with the
MoonBit host (#594); formatting is enforced instead by the required
`vibe-fmt-check` CI job. Hooks live under `.git/`
(not version-controlled), so each clone must opt in once:

```bash
pkf hooks install      # wire .git/hooks → pkf run
pkf hooks list         # show which hooks are installed / declared
pkf hooks uninstall    # remove the shims
```

## Status

`Taskfile.pkl` imports nothing from `pkspec` any more and the directory is
gone. The `.github/workflows/pkfire-pkspec.yml` workflow (name kept — it is a
required check) now only runs `pkf format --check` + `pkf lint` — both required
(no `continue-on-error`), sub-10s per PR.
