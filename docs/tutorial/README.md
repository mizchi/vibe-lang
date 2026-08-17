# The vibe tutorial — a language tour you run

Every chapter is a `*.vibe.md`: the markdown itself is an executable document
(#1142). The ` ```vibe run ` blocks really are compiled and run, and the
` ```output ` block right after each one holds that run's output verbatim. Read
a paragraph, see the result — that is the style of this tutorial.

日本語版: [README-ja.md](README-ja.md)

```bash
# install (details: docs/install.md)
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
. "$HOME/.vibe/env"

# clone the repository to verify or regenerate
git clone https://github.com/mizchi/vibe-lang && cd vibe-lang
bash scripts/vibe_md.sh check docs/tutorial/01_values_functions.vibe.md
bash scripts/vibe_md.sh check docs/tutorial/*.vibe.md   # verify every chapter at once
bash scripts/vibe_md.sh write docs/tutorial/*.vibe.md   # run, and rewrite the ```output blocks
pkf run vibe-md-tutorial                                # the same check as a task
```

## First program (installed toolchain)

The copy/paste program that works with **only the installed toolchain** —
no repository `lib/` — is the host-builtin hello from
[docs/install.md](../install.md):

```bash
echo 'fn main with Stdout { Stdout::write_stream("42\\n") }' > hello.vibex
vibe run hello.vibex        # -> 42
```

`import @vibe/prelude` in the chapters below resolves from an installed
toolchain (`~/.vibe/lib`) as well as from the repository `lib/`.

| Chapter | Topic |
| --- | --- |
| [01 Values and functions](01_values_functions.vibe.md) | let / mut / primitive types / interpolation / fn / lambdas |
| [02 Control flow](02_control_flow.vibe.md) | if / while / loop / for-in / return / pipe |
| [03 Data](03_data.vibe.md) | tuple / array / record / struct / enum / pattern matching |
| [04 Option](04_option.vibe.md) | Option / `let*` / `?` |
| [05 Effects](05_effects.vibe.md) | `with ...` / Exception / handle / perform / resume |
| [06 Tests](06_tests.vibe.md) | test blocks / assert / CLI tooling |
| [07 Modules and packages](07_modules_packages.vibe.md) | import / export / @scope packages / contracts / pins |

What `bash scripts/vibe_md.sh check` (`pkf run vibe-md-tutorial`) verifies in
each `*.vibe.md` is only that the **current** source compiles, runs, and matches
the recorded output. It says nothing about whether the prose, the API choices,
or the teaching order are right.

## When a chapter breaks

A runnable block that stops working under the current compiler means a user
cannot run the canonical language tour, so it is **P1 (can't write it / it
crashes)**, filed as a GitHub issue with the `tutorial-breakage` label to keep
it findable. A block that type-checks and then returns a wrong value is **P0
(silent-wrong)**, as usual. The label does not override priority: the order of
work follows mechanically from P0 / P1 and `blocker` in
[issue triage](../issue-triage.md). Whether the fix belongs in the compiler or
in the spec follows that same triage and the repository's "when the grammar
blocks you" policy — an implementation constraint must not become something the
tutorial asks the reader to memorize.

Every chapter currently runs in the required `compiler-gate` CI job, which
points `VIBE_MD_STAGE2` at a stage2 built from the same checkout and runs
`scripts/vibe_md.sh check` over all of them. `pkf run release-check` depends on
`vibe-md-tutorial-gated`, which carries the same guarantee. Neither allows a
silent fallback to the committed seed, so a chapter cannot go green by accident
on an older compiler.

Use ` ```vibe skip ` **only for examples that are deliberately not runnable**:
rejected legacy syntax, target syntax that is not implemented yet, illustrative
paths that do not exist. Put the reason for the skip in a comment at the top of
the block, and attach a tracking issue for anything unimplemented. When it
becomes runnable, convert it to `vibe run` with the expected `output`. Never
move merely-broken code into a skip block. The skip blocks that show intended
language shapes are tracked by
[#1280 reserved fn](https://github.com/mizchi/vibe-lang/issues/1280)
([#1281 top-level patterns](https://github.com/mizchi/vibe-lang/issues/1281) is
implemented, and the block in chapter 03 is runnable now).

For a more exhaustive reference see [docs/cheatsheet.md](../cheatsheet.md),
bearing in mind that parts of it run ahead of the implementation — where they
disagree, this tutorial's actual output is the truth.

## Ambiguous syntax and known traps

Confirmed and written down while revising this tutorial. Each item that has a
runnable example in the text has been verified there with its real output
(`vibe run` / `output`):

- **`break(a, b)` is not symmetric with `continue(a, b)`**: `continue(a, b)`
  passes the loop's next state (multi-argument, like a call), whereas the
  parentheses in `break(a, b)` are ordinary expression parentheses, so what
  `break` receives is **one tuple** `(a, b)`. The syntax decision is tracked in
  [#1284](https://github.com/mizchi/vibe-lang/issues/1284).
  [02 Control flow](02_control_flow.vibe.md#loop--tail-recursion-with-parameters).

The three items below used to be listed here and have been dropped: runnable
examples confirm they do not reproduce on the current compiler (#1270).

- Naming top-level functions `f` / `g` produced a broken wasm module
  ([#1203](https://github.com/mizchi/vibe-lang/issues/1203)) — they work
  correctly even alongside `compose`/`flip`.
- `Double` could not be interpolated with `\{expr}` or printed via
  `Double::to_string` ([#1153](https://github.com/mizchi/vibe-lang/issues/1153))
  — both work, and chapter
  [01 Values and functions](01_values_functions.vibe.md#values-and-primitive-types)
  runs them.
- `Array::push` on a raw `Array` was backend-dependent
  ([#1285](https://github.com/mizchi/vibe-lang/issues/1285)) — the compiler
  tests now pin it as the same in-place append on linear, RC and wasm-gc.
  [03 Data](03_data.vibe.md#accumulate-with-arraybuilder).
