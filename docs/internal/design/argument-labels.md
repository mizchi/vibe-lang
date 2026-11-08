# ADR-0120: Argument labels are required at every call to a declaration

Status: accepted (2026-11-08, main `1eebc3a`). The checker owns label
resolution, every call to a declaration in the tree carries its labels in
declared order, and each violation is a build error that names the edit.
The evidence for each condition is in [Acceptance](#acceptance).

Date: 2026-10-27

Tracking: #3650. Related: #3651 (builtin labels unchecked), #986, #1001, #1500, #1899, #1994, #2404, #2974, #3120, #3432,
ADR-0020 (pipe-first), ADR-0064 (`fn` declarations), ADR-0081 (canonical
method call), ADR-0117 (`_` as pipe slot and section).

## Context

Before this decision, labels were optional, and the parameter marker `x~`
had almost no effect. Measured on the committed seed at `db57c14`:

<!-- doctest-skip: measured call shapes, not a standalone program -->
```vibe skip
// doctest-skip: measured call shapes, not a standalone program
fn sub(x~: Int, y~: Int) -> Int { x - y }
fn plain(x: Int, y: Int) -> Int { x - y }

sub(1, 10)                   // -9: a `~` parameter accepts a positional argument (#1001)
sub(y = 1, x = 10)           // 9: reordered into declared order
plain(y = 1, x = 10)         // 9: any `fn` can be called by label (#986)
String::concat(b = "a", a = "b")  // "ab": builtin labels were not checked
```

Three things follow from this.

**An argument's meaning depends on its position, and position is where
argument bugs hide.** #1899 survived a "fix verified" claim because the test
used `x + y`, and a commutative operator gives the same answer whether or not
the arguments were reordered. Required labels turn that class of mistake into
a mismatch the checker reports. That matters most for the reader this project
designs for: an LLM in an edit-check loop gets a diagnostic that names the
parameter, instead of a program that compiles and gives the wrong answer.

**Builtin labels were silently wrong.** Builtins had no parameter names, so
any label was accepted and the arguments bound in the order they were
written. `String::concat(b = "a", a = "b")` answered `"ab"` with no
diagnostic. Under the issue triage rules that is a P0, so it was fixed first,
on its own (#3651).

**Labels were resolved by a syntactic pass with its own environment.**
`normalize/desugar/labeled_args.vibe` (removed in #3661), `binder_authority.vibe`
and the label-name walk in `checker_stmt_labeled_name_check_expr.vibe`
resolved a callee by name before the checker ran. They tracked shadowing,
local lambdas and `let mut` rebinding themselves (`local_fn_tbl`,
`unstable_mut_tbl`). #986, #1899 and #1994 were each a silently misbound
argument caused by that resolver. Reordering also had a cost the reader had
to remember: arguments were evaluated in parameter order, not in the order
they were written. The same shape of syntactic pass, deleted in #2773, had
let sixty-three routes past it.

## Decision

### D1. Labels belong to declarations, not to types

A call needs labels when its callee resolves to a **declaration**:

- a top-level `fn`;
- a top-level `let` whose initializer is a lambda literal (the form `fn`
  lowers to, ADR-0064);
- a namespaced `T::f`;
- a builtin;
- an imported function, including one declared in a `.vpkg` contract;
- a trait method.

A call through a **value** takes positional arguments only. That covers a
parameter, a local `let`-bound lambda, a struct field, and anything a
function returns. A label on such a call is an error whose message is the
edit: remove the label.

Function types carry no labels. This is the choice Swift made in SE-0111:
`(Int, Int) -> Int` is the type of `sub`, so passing `sub` as a value works
unchanged. The `x~` parameter marker and the labeled function-type spelling
`(x~: Int) -> Int` are retired. The parser rejects both with the replacement
spelling, the same way #2974 handled `x~: v` at a call site.

Enum constructors and algebraic effect operations stay positional. They are
constructors, not functions (#1458). Struct literals already name their
fields.

### D2. Labels are written in declaration order

The written order is the declared order, so written order is evaluation
order. A call whose labels are out of order is rejected, with a message that
names the move. Nothing reorders arguments, and the pre-check reorder pass is
deleted.

A parameter with a default (#3120), or an optional `x?` parameter (#1500),
may be omitted anywhere in the list, not only at the end. The labels that are
present identify which slots were given. This is the case where labels pay
for themselves: without labels, only trailing optionals could be omitted.

### D3. A declaration opts a parameter out with `_`

Every parameter is labeled by default, and its label is its name. A
declaration writes `_` before a parameter to make it positional:

<!-- doctest-skip: bodyless declarations, shown for their signatures -->
```vibe skip
// doctest-skip: bodyless declarations, shown for their signatures
fn Array::get[T](_ xs: Array[T], at: Int) -> T
fn Int::to_string(_ n: Int) -> String
fn greet(name: String, times: Int = 1) -> String

Array::get(xs, at = i)
Int::to_string(n)
greet(name = "hi", times = 3)
greet(name = "hi")
```

This keeps one spelling per callee, because the declaration fixes it. A
caller never chooses between a labeled and an unlabeled form. A label on a
`_` parameter, or a missing label on a labeled one, is an error.

The rule is mechanical. What the guidelines below add is advice, not a check.
A parameter should be `_` when the function's name already says what it is:

- the receiver of a `T::f`;
- the only argument of a conversion or predicate (`Int::to_string`,
  `String::length`);
- the operands of a symmetric operation (`Int::max(a, b)`).

External and internal names (`fn move(to point: Point)`) are not part of
this decision. See [Open questions](#open-questions).

### D4. Pipe and placeholders fill a slot by position

`x |> f(..)` fills the first parameter, so it requires that parameter to be
`_`. When it is labeled, the error names both edits: write the call directly,
or declare the parameter `_`. The ADR-0117 slot `_` takes the label of the
slot it stands in for: `xs |> Array::get(_, at = 0)` and
`Array::get(xs, at = _)` are both well formed.

### D5. One name, one signature

Labels do not overload. `f(x = 1)` and `f(y = 1)` cannot name two different
functions. Name resolution stays a function of the name alone, which is what
`vibe binding-at`, `vibe grep --where '$f = ..'` and the LSP already assume.

### D6. Labels are part of the public contract

A `.vpkg` declaration publishes its labels and its `_` positions. The
dependency's `param_names_marker` (#3432) already carries the names.
Renaming a labeled parameter of an exported function is a breaking change.
An `impl` method must use the trait method's labels and `_` positions, and a
mismatch is an error at the impl.

For a component export, a WIT parameter takes the vibe label, or the
internal name for a `_` parameter, mapped to kebab-case. The WIT is still
derived (ADR-0113).

### D7. Diagnostics lead with the edit

| Situation | Message names |
|---|---|
| Missing label | ``write `at = i` `` |
| Label on `_`, or on a call through a value | ``remove `at = ` `` |
| Out of order | ``move `b = ..` after `a = ..` `` |
| Unknown label | the declared labels, nearest first |
| Pipe into a labeled first parameter | the direct call, or `_` on the declaration |

## Implementation

**The checker owns labels.** A declaration's binding records its parameter
labels and `_` positions, and the binding header carries them across
imports and `.vpkg` contracts. The checker validates each call against the
callee it already resolved for typing and publishes a placement: for each
declared slot, the written argument that fills it, and whether that
argument is wrapped in `Some`. Omitted defaulted and optional slots are
recorded there too. Lowering consumes the placement, so it sees positional
arguments only, and inserts `Some` / `None`. It refuses a call that needs a
placement and has none, or whose placement would reorder the written
arguments. No pass before the checker reads a label. The syntactic resolver
(`labeled_args.vibe`, `binder_authority.vibe` and the checker's label-name
walk, about 2,300 lines) was deleted in #3661.

Lanes that lower without the checker (`*_unchecked_cached` and the grouped
merge) have no placement. They refuse a labeled call to an imported
function and ask for checked source.

**Builtins have parameter names.** Their `_` slots are part of the
signature in `core/builtin_registry.vibe` and `checker/builtin_sigs/`.

**Porting code uses two codemods.**

1. `vibe refactor mark-positional --write` declares `_` on every `T::f`
   receiver (a first parameter typed as the owner `T`) and on every lone
   parameter. It works in `.vibe` sources and in the `index.vpkg` contract
   alike.
2. `vibe refactor add-labels --write --positional=none` then writes the
   remaining labels.

Both run on the import-resolving lane. They edit by byte range, so comments
and layout survive, and they are safe to re-run. The tree itself carries no
call site either codemod would change.

### Measurements behind the decision

**Size.** The size of the change was measured with
`vibe grep --pattern '$(f:id)($(a:args))'` over every tracked `.vibe` /
`.vibex` source at `db57c14`, before any migration:

| Measure | Count |
|---|---:|
| Call sites | 269,278 |
| Calls with at least one argument, excluding constructors and `__` intrinsics | 227,347 in 4,366 files |
| ... of them in `lib/@vibe/compiler` | 153,172 |
| ... of them to builtins | 74,759 |
| Calls already labeled | about 100 |

How many labels that means depends on where D3's `_` lands. These are upper
bounds, because the measurement did not separate calls through a function
value, which need no label:

| Rule | Labels |
|---|---:|
| Every argument | 416,222 |
| Every argument but the first of a `T::f` | 335,578 |
| Every argument but the first | 188,875 |

**Which slots are `_`.** The rule follows the D3 guidance mechanically: a
receiver and a lone parameter are already named by the function. It was
chosen by measuring `lib/@vibe/core` (65 files, all of them checked) at
`main` 3f6a506 plus the codemod. Each policy names the slots it leaves
positional; builtins always use their own `_` slots.

| `--positional` | Labels written | Calls |
|---|---:|---:|
| `none` | 4,851 | 2,969 |
| `receiver` (a `T::f` receiver) | 3,713 | 2,427 |
| `receiver+single` (also a lone parameter) | 3,138 | 1,852 |

`receiver+single` writes 35% fewer labels than labeling every argument. The
receiver rule accounts for 1,138 of those 1,713 labels, and the
lone-parameter rule for the other 575.

## Acceptance

Accepted on 2026-11-08. Each condition, and the evidence for it, on main
`1eebc3a`:

- **No pass before the checker reads `ELabeledArg`.** The syntactic resolver
  and the binder-authority normalization were deleted in #3661.
  The passes that still run before the checker (`split_handler_or_arms`,
  `desugar_handled_host_calls`, the `inspect` expander) only rebuild the
  node; they do not read its label. The checker validates labels against
  the callee it resolved for typing and publishes a placement, and lowering
  refuses a call with no placement or with one that reorders arguments.
  The fixtures for #986, #1899 and #1994 still pass as answers.
- **A mismatched builtin label is a build error** (#3651).
- **Each misuse is refused with the edit.** Each case has
  `fixtures/typecheck/err_label_*` rows in `expected.tsv`:
  - a missing label (#3881);
  - a label on `_` (#3681);
  - a label on a call through a value, and the retired `x~` and labeled
    function-type spellings (#3899);
  - an out-of-order label (D2, #3903), including through a local type
    alias.
- **No call site needs the codemod.** The #3794 audit (#3914) swept the
  tree with `vibe check`, and every remaining label diagnostic is an
  intentional refusal fixture. `pkf run release-check` passes on a clean
  checkout of `1eebc3a`: 112 tasks, including
  `fixpoint ok: stage2==stage3`. CI on that commit, including all eight
  unit-test shards, is green (#3795).
- **The self-compile is measured** (below).

### Self-compile measurement

This compares two trees, each compiled by its own stage2:

- **A** is the pre-migration tree, `61d9a64`, the parent of #3723.
- **B** is the migrated tree, `1eebc3a`.

Each run compiles the selfcompile KPI input
(`lib/@vibe/compiler/tests/codegen_lexer_test.vibe`), whose import closure
is the compiler itself, through `scripts/selfcompile_kpi.sh`'s command. The
runs follow the #2393 protocol:

- Each pair uses its own fresh `VIBE_BUILD_CACHE_DIR`.
- The first run in that directory is cold and the second is warm.
- There are three pairs per tree, on one machine, run one after another.

Heap and pages are deterministic: every run of a tree gave the same value.
Wall time is the median.

| | A (pre-migration) | B (migrated) | Change |
|---|---:|---:|---:|
| Cold `heap_ptr` bytes | 1,055,563,104 | 1,285,065,760 | +21.7% |
| Cold memory pages | 18,663 | 27,994 | +50.0% |
| Cold wall, ms (6 runs) | 11,435 | 13,455 | +17.7% |
| Warm `heap_ptr` bytes | 616,566,832 | 763,029,336 | +23.8% |
| Warm memory pages | 12,442 | 12,442 | 0 |
| Warm wall, ms | 7,300 | 7,390 | +1.2% |
| Output wasm bytes | 6,270,279 | 6,627,758 | +5.7% |

The "6 runs" cold wall row pools all six cold KPI-script runs. A
cold-only pass gave medians of 10,660 and 12,930 ms.

**What the numbers cover.** A and B are 137 commits apart, and 17 of them
belong to this ADR, so the change is not the label cost alone. The
label-only part was measured on one stage2 over two input trees when the
KPI baseline was rebased (`bench/perf/heap_baseline.txt`):

- `lib/` outside the compiler, labeled (#3723): +2.1%.
- The compiler's own sources, labeled (#3748): +19.8% raw, and +11.3%
  after #3742 removed the checker's per-label allocations.

What remains is one more AST node per argument through every pass. The
cache hides most of it: the warm wall time is unchanged.

## Alternatives considered

- **Keep labels optional (status quo).** This leaves two spellings for every
  call, a positional default where argument bugs hide, and the syntactic
  resolver that produced #986, #1899 and #1994.
- **Label every argument with no opt-out.** This is 416,222 labels, and it
  means writing `Array::length(array = xs)` and `Int::to_string(n = x)`. The
  label adds nothing the function name did not already say.
- **Required but reorderable labels.** This keeps the pre-check reorder pass
  and the evaluation-order rule a reader has to remember. Swift fixes the
  order for the same reason.
- **Labels in function types (OCaml, MoonBit).** Passing `sub` where a
  `(Int, Int) -> Int` is expected would then need label-aware conversion,
  and every higher-order builtin would need labeled variants.

## Open questions

- **External and internal names** (`fn move(to point: Point)`). This is
  additive, so it can follow without breaking anything. It is not needed
  for the migration.
