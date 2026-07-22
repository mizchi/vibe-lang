# mini-vcs — gleam

**Toolchain not available in this sandbox** (`gleam` not on `PATH`,
2026-07-22). almide's own upstream comparison includes Gleam as a "modern
peer" (`docs/pl-survey-2026-07.md`), so this language is kept in the
`langs/` set for completeness, but a round including it must run
somewhere with the Gleam toolchain installed and report results back into
`results/` manually — `run_lang_bench.sh` (if/when written) should skip
it automatically when `command -v gleam` fails rather than hard-erroring.

Once available: `gleam build`, then wrap the produced Erlang/JS target
similarly to the `typescript/README.md` `node` invocation, or use
`gleam run` directly if it accepts forwarded argv+cwd correctly for the
acceptance scenario.
