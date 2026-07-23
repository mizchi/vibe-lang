# mini-vcs — cross-language benchmark spec

Language-agnostic spec for a toy version-control CLI, modeled on almide's
"minigit" benchmark (`docs/BENCHMARKS.md` upstream, 233 LOC winning
implementation — see `docs/pl-survey-2026-07.md`). The **same prompt below**
is given to the same model in each target language; implementations are
compared on pass rate, LOC, and (where applicable) binary size / build
time — see `README.md`.

Deliberately small and hash-free (no content-addressed storage, no
checkout/branch/diff) so it is implementable in roughly 150–300 LOC in any
of the target languages and testable with exact string comparison, no
language-specific hashing behavior to reconcile.

## Prompt (give verbatim to the model, plus "implement this in \<language\>")

> Implement a command-line tool `minivcs` with five subcommands: `init`,
> `add <file>`, `commit -m <message>`, `log`, and `status`. Behavior:
>
> - `minivcs init`: create a `.mvcs/` directory to hold repository state.
>   Print `Initialized empty repository` and exit 0. If `.mvcs/` already
>   exists, print `Already initialized` to stderr and exit 1.
> - `minivcs add <file>`: stage the given file (by name) for the next
>   commit. Print `Added <file>` and exit 0. If the file does not exist in
>   the working directory, print `No such file: <file>` to stderr and
>   exit 1.
> - `minivcs commit -m <message>`: create a commit from the currently
>   staged files. Commits are numbered sequentially starting at 1 (first
>   commit ever made in this repo is commit 1, regardless of how many
>   files it stages). Print `Committed <id>: <message>` and exit 0, then
>   clear the stage. If nothing is staged, print `Nothing to commit` to
>   stderr and exit 1.
> - `minivcs log`: print one line per commit, **newest first**, each line
>   exactly `<id> <message>`. If there are no commits, print nothing
>   (exit 0).
> - `minivcs status`: print exactly two lines:
>   `staged: <comma-separated file names, alphabetically sorted, no
>   spaces after commas>` (or `staged: (none)` if nothing is staged), then
>   `untracked: <comma-separated file names in the working directory
>   (excluding `.mvcs`) that have NEVER been staged or committed,
>   alphabetically sorted>` (or `untracked: (none)`). A file becomes
>   "tracked" (and so drops out of `untracked` for good) the first time it
>   is `add`ed, whether or not it has since been committed — so a file
>   that was added and committed, then not re-added, is neither `staged`
>   nor `untracked` (this tool does not need a third "clean" state in the
>   output; it is simply absent from both lines).
>
> All repository state lives under `.mvcs/` in the current working
> directory; the tool does not need to search parent directories for it.
> Use whatever internal storage format you like under `.mvcs/` — only the
> stdout/stderr/exit-code behavior above is checked.

## Acceptance

`acceptance_test.sh` drives a compiled/built binary through a fixed
command sequence in a fresh temp directory and diffs stdout/exit codes
against the expected transcript below. See that script's header for the
exact invocation contract (`$1` = command to run the tool, e.g. a path to
a binary or `node dist/minivcs.js`).

Fixed scenario (also encoded in `acceptance_test.sh`):

1. `status` before init → **must fail** in some form (either subcommand
   errors because `.mvcs/` is missing, or treat as `untracked: (none)` if
   no files exist yet — implementations MAY choose either as long as they
   do not crash; `acceptance_test.sh` only asserts non-crash here, not a
   specific transcript line, since the prompt does not pin this case).
2. `init` → `Initialized empty repository`, exit 0.
3. `init` again → `Already initialized` (stderr), exit 1.
4. write `a.txt` (`hello`), `b.txt` (`world`) in the cwd.
5. `status` → `staged: (none)` / `untracked: a.txt,b.txt`.
6. `add a.txt` → `Added a.txt`, exit 0.
7. `status` → `staged: a.txt` / `untracked: b.txt`.
8. `commit -m "first"` → `Committed 1: first`, exit 0.
9. `status` → `staged: (none)` / `untracked: b.txt`.
10. `add b.txt` → `Added b.txt`.
11. `commit -m "second"` → `Committed 2: second`.
12. `log` → two lines, newest first: `2 second` then `1 first`.
13. `commit -m "empty"` (nothing staged) → `Nothing to commit` (stderr), exit 1.
