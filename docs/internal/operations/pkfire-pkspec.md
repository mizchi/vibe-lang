# pkfire

[`pkfire`](https://github.com/mizchi/pkfire) (`pkf`, a typed task runner with
content-addressed caching) is the task runner for vibe-lang. Task definitions
live in `Taskfile.pkl` and the modules it imports from `scripts/pkfire/`
(`common.pkl` for shared source lists and factories, `quality_tasks.pkl` for
the lint, check and KPI tasks). Multi-line shell that does not fit a single
Pkl `cmd =` lives in `scripts/` and is invoked directly. CI runs its jobs
through `pkf run …`.

`pkf list` prints the visible tasks with their descriptions; `pkf list --all`
adds the internal ones (such as `post-generation-gate`).

## Install

The version is pinned in **`.github/pkfire-version`**, the single source of the
pin; `scripts/check_pkfire_pin.sh` checks that every declaration in CI and the
SessionStart hook agrees with it.

```bash
# pkf + the Pkl CLI it needs, at the pinned versions, into
# ~/.local/share/vibe-pkfire/bin (override with PKFIRE_INSTALL_DIR)
bash scripts/install_pkfire_release.sh
export PATH="$HOME/.local/share/vibe-pkfire/bin:$PATH"
pkf version
```

The script downloads release binaries for Linux (x86_64, aarch64) and macOS
(arm64) and refuses to install if either binary does not report the pinned
version.

In CI, `.github/actions/setup-vibe` with `pkfire: 'true'` runs the same script
(with the binaries cached on the pin and the script's hash). Pass
`pkfire-cache: 'true'` to also restore the task cache, `~/.cache/pkfire-mbt`.
The SessionStart hook installs the pinned release into a dedicated nix profile.

## `Taskfile.pkl`

Simple recipes are inlined via `cmd = …`; a recipe that is one script uses the
`scriptTask(name, "scripts/X.sh")` factory. Tasks reference each other as Pkl
values (`deps { checkDocCommands }`), so a typo fails at evaluation time rather
than at run time.

Frequently used tasks:

| Task | Behaviour | Notes |
|---|---|---|
| `fmt` | `bash scripts/vibe_fmt_apply.sh` | formats `lib/**/*.vibe` and `lib/**/*.vpkg` in place; `check-vibe-fmt` is the read-only CI counterpart |
| `test` | `bash scripts/compiler_gate.sh` | operation gate — the main pre-commit check |
| `test-affected` | tests reachable from the change through the compiler's resolved import graph | falls back to the full set when it cannot decide (#988) |
| `test-local` | affected tests via `flaker` | selects by directory, so it misses importers elsewhere (AGENTS.md, "Local Test Execution") |
| `run` | `bash scripts/vibe_run.sh $@` | `acceptsArgs` — pass a `.vibex` root via `--` |
| `full-gate` | `generation-gate` → `post-generation-gate` | the complete selfhost sign-off ([operation-gate.md](operation-gate.md)) |
| `release-check` | `compiler-gate` plus the release checks | full sign-off before a release |

Run from the repo root:

```bash
pkf list
pkf run test
pkf run run -- prog.vibex          # `run` is scripts/vibe_run.sh: one .vibex root
pkf graph                          # the dependency tree
pkf run test --explain-cache       # why a task did or did not hit the cache
pkf affected Taskfile.pkl          # tasks whose declared inputs include a path
```

The cache lives in `~/.cache/pkfire-mbt` (per user); `.pkfire/` in the repo is
git-ignored as a fallback.

### The cache makes inputs load-bearing

Re-running a task after a no-op edit is a cache hit, keyed on the task's
declared `inputs`. A task whose inputs omit something it reads will therefore
replay a stale verdict. `pkf run check-task-inputs` checks that a task which
runs the compiler keys on the compiler, and AGENTS.md's "Which compiler
answered?" section covers the related rule that a gate asking the compiler a
question must be handed the generation it is about
(`deps { selfhostGeneration }`).

## git hooks (`pkf hooks`)

`pkf hooks install` writes `.git/hooks/*` shims that delegate to
`pkf run <hook-name>` — pkfire binds a git hook to the task whose name
matches the hook (e.g. the `pre-commit` task).

This repo ships a **`pre-commit`** task that runs `scripts/precommit.sh` against
a snapshot of the staged index: the review-derived lint
(`scripts/lint_review_regressions.sh`), the architecture-debt ratchet, the
guest-profile contract lint, and the doc path-citation check. Formatting is
enforced by the required `vibe-fmt-check` CI job instead. Hooks live under
`.git/` (not version-controlled), so each clone must opt in once:

```bash
pkf hooks install      # wire .git/hooks → pkf run
pkf hooks list         # show which hooks are installed / declared
pkf hooks uninstall    # remove the shims
```

## The `pkfire-pkspec.yml` workflow

The workflow keeps its file name because it is a required check; it validates
pkfire configuration only. It installs the pinned pkf, asserts `pkf version`
matches `.github/pkfire-version`, and runs `pkf format --check` over
`Taskfile.pkl` and the `scripts/pkfire/*.pkl` modules plus `pkf lint`. It runs
on changes to those files, in well under a minute.
