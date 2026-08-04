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

CI uses the `mizchi/pkfire@v0.10.0` composite action via
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
| `info` / `check` / `test-update` | legacy `moon …`  | MoonBit host 依存で #594 以降は無効。検証は `test` / `release-check` / `vibe diagnostics` を使う |

Two helper factories keep the file readable:

- `justTask(name)` — wraps a recipe whose body stays in the justfile
- `scriptTask(name, "scripts/X.sh")` — wraps a single-shell-script recipe

Run from the repo root:

```bash
pkf list
pkf run check
pkf run test
pkf run run -- examples/hello.vibe
pkf graph --format tree
pkf run --explain-cache check
```

The cache lives in `~/.cache/pkfire` (global, per-user); `.pkfire/` in the
repo is git-ignored as a fallback.

### Why bother when `just` works?

- **Typed deps**: `deps { check }` is a Pkl value, not a string — typos fail
  at evaluation time.
- **Content-addressed cache**: re-running `pkf run check` after a no-op edit
  is a cache hit; `just check` always re-invokes `moon`.
- **`pkf affected --since=origin/main`**: cheap PR-diff aware runs.

For one-off shell tasks, `just <recipe>` is still the right choice — the
pkfire Taskfile only mirrors the common entry points.

### Differential test execution

`Taskfile.pkl` generates one task per moon package under `src/`
(`test:parser`, `test:checker`, `test:cmd-vibe`, …) whose `inputs` are
scoped to that package's directory. Combine with pkfire's `affected` query
and a `test:*` glob target to run only the packages whose files changed:

```bash
# vs a git ref (e.g. PR base)
pkf affected --since=origin/main 'test:*'

# explicit file list (CI helpers, scripts, hooks)
pkf affected --files="$(git diff --name-only origin/main | paste -sd,)" 'test:*'

# preview only — no commands run
pkf affected --since=origin/main --dry-run --explain 'test:*'

# full sweep, cache reuse for unchanged packages
pkf run 'test:*'
```

The `'test:*'` glob is important: without it, `pkf affected` also pulls in
wide-scope tasks (`check`, `test`, `release-check`, …) whose inputs cover
all of `src/`. Names flatten `/` to `-` (e.g. `test:cmd-vibe` for
`mizchi/vibe/cmd/vibe`) so a single glob covers all 32 packages.

`pkf` treats each `moon test -p` as a black box; cross-package dep
tracking (parser change → checker tests need rerun) is handled inside
moon, not by pkfire. For the final pre-commit sweep, fall back to
`just test` or `pkf run test`.

## git hooks (`pkf hooks`)

`pkf hooks install` writes `.git/hooks/*` shims that delegate to
`pkf run <hook-name>` — pkfire binds a git hook to the task whose name
matches the hook (e.g. the `pre-commit` task).

This repo ships a **`pre-commit`** task that runs
`scripts/pkfire/precommit_fmt.sh`: it `moon fmt`s the staged `.mbt` files and
re-stages them, so every commit lands formatted. Hooks live under `.git/`
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
