# lib/@vibe/compiler

The vibe compiler, written in vibe. Since #594 this is the **only**
implementation: the MoonBit host (`src/`, `moon.mod`) was retired, and the
compiler is built from the committed seed (`bootstrap/seed/`) plus this package
and `lib/@vibe/cli/`. Parser, checker, codegen, CLI commands, adapters, the
bundle and the component entry all live here — see the "where changes go"
section of [AGENTS.md](../../../AGENTS.md).

This file used to open by calling the package "experimental" and listing
"Known Gaps Before Full Self-Hosting". Self-hosting landed; one of those gaps
(`return` "is not supported (parser rejects it)") was measurably untrue — it
compiles and runs.

## Structure

- **Frontend** — lexer (source → tokens), parser (tokens → AST for
  expr/stmt/type/pattern), printer (AST → normalized source).
  `|>` is desugared in the parser (`x |> f(a, b)` → `f(x, a, b)`); mixing it
  with other infix operators at top-level parse scope is rejected. `import` is
  the only module syntax — `use` was removed.
- **Type checking** — expression + statement checker on an HM-like inference
  baseline, trait/type-def environment plumbing, and import-surface checks in
  the statement pass (a name a dependency does not export is reported at check
  time, #1521/#1533).
- **Module loading** — multi-file resolution with import cycle detection, and
  the fixture parse / roundtrip / typecheck helpers the suites use.
- **`type_db` + `ripple`** — the incremental-typecheck substrate
  (`type_db.vibe`, tests in `tests/type_db_*`): fingerprint caching and
  import-dependency-based invalidation. Still a substrate rather than a
  default path through the main checker pipeline.

## Known limitations

- `raise` is rejected: `'raise' is deprecated, use 'throw(expr)' instead`.
- Deep recursion in the checker can reach the host stack limit. The runner now
  derives `--stack-size` from `ulimit -s` instead of a fixed value, and
  `scripts/check_declaration_scale.sh` (`pkf run check-declaration-scale`)
  pins the scale that used to fall over (#2134).

Current gates and remaining work: GitHub Issues and
[docs/release-roadmap.md](../../../docs/release-roadmap.md).

## Verification

```bash
pkf run release-check     # full sign-off
pkf run test              # the operation gate — the main pre-commit check
pkf run test-affected     # only the tests the change can reach
pkf run test-cli-core     # the CLI suite
```
