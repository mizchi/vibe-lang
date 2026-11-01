# ADR-0120: Argument labels are required at every call to a declaration

Status: proposed. It becomes accepted when the conditions in
[Acceptance](#acceptance) hold: the checker owns label resolution, every
call to a declaration in the tree carries its labels, and an unlabeled
argument to a labeled parameter is a build error.

Date: 2026-10-27

Tracking: #3650. Related: #3651 (builtin labels unchecked), #986, #1001, #1500, #1899, #1994, #2404, #2974, #3120, #3432,
ADR-0020 (pipe-first), ADR-0064 (`fn` declarations), ADR-0081 (canonical
method call), ADR-0117 (`_` as pipe slot and section).

## Context

Labels are optional today, and the parameter marker `x~` has almost no
effect. Measured on the committed seed at `db57c14`:

<!-- doctest-skip: measured call shapes, not a standalone program -->
```vibe skip
// doctest-skip: measured call shapes, not a standalone program
fn sub(x~: Int, y~: Int) -> Int { x - y }
fn plain(x: Int, y: Int) -> Int { x - y }

sub(1, 10)                   // -9: a `~` parameter accepts a positional argument (#1001)
sub(y = 1, x = 10)           // 9: reordered into declared order
plain(y = 1, x = 10)         // 9: any `fn` can be called by label (#986)
String::concat(b = "a", a = "b")  // "ab": builtin labels are not checked
```

Three things follow from this.

**An argument's meaning depends on its position, and position is where
argument bugs hide.** #1899 survived a "fix verified" claim because the test
used `x + y`, and a commutative operator gives the same answer whether or not
the arguments were reordered. Required labels turn that class of mistake into
a mismatch the checker reports. That matters most for the reader this project
designs for: an LLM in an edit-check loop gets a diagnostic that names the
parameter, instead of a program that compiles and gives the wrong answer.

**Builtin labels are silently wrong.** Builtins have no parameter names, so
any label is accepted and the arguments bind in the order they were written.
`String::concat(b = "a", a = "b")` answers `"ab"` with no diagnostic. Under
the issue triage rules this is a P0, and it is a bug today whatever this ADR
decides (#3651).

**Labels were resolved by a syntactic pass, removed in Phase 1c, with its own environment.**
`normalize/desugar/labeled_args.vibe`, `binder_authority.vibe` and the
label-name walk in `checker_stmt_labeled_name_check_expr.vibe` resolved a
callee by name before the checker ran. They tracked shadowing,
local lambdas and `let mut` rebinding themselves (`local_fn_tbl`,
`unstable_mut_tbl`). #986, #1899 and #1994 were each a silently misbound
argument caused by that resolver. Reordering also has a cost the reader has
to remember: arguments are evaluated in parameter order, not in the order
they are written (cheatsheet, "Labeled arguments"). The same shape of
syntactic pass, deleted in #2773, had let sixty-three routes past it.

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
for themselves: today only trailing optionals can be omitted.

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

## Implementation consequences

**Label resolution moves into the checker.** A declaration's binding records
its parameter labels and `_` positions. The checker validates each call
against the binding it already resolved for typing, then strips the labels.
After that, lowering sees positional arguments only, and omitted defaulted
or optional slots are filled by label at that point. The syntactic resolver
is deleted: about 2,300 lines in `labeled_args.vibe` and
`binder_authority.vibe`, plus the label walk in
`checker_stmt_labeled_name_check_expr.vibe`.

**Builtins get parameter names.** About 170 qualified builtins live in
`core/builtin_registry.vibe` and `checker/builtin_sigs/`. The P0 fix
(#3651: reject a builtin label that does not match its position) ships
first, on its own.

**The migration is mechanical and large.** Measured with
`vibe grep --pattern '$(f:id)($(a:args))'` over every tracked `.vibe` /
`.vibex` source at `db57c14`:

| Measure | Count |
|---|---:|
| Call sites | 269,278 |
| Calls with at least one argument, excluding constructors and `__` intrinsics | 227,347 in 4,366 files |
| ... of them in `lib/@vibe/compiler` | 153,172 |
| ... of them to builtins | 74,759 |
| Calls already labeled | about 100 |

The number of labels to insert depends on where D3's `_` lands:

| Rule | Labels |
|---|---:|
| Every argument | 416,222 |
| Every argument but the first of a `T::f` | 335,578 |
| Every argument but the first | 188,875 |

The first two rows are upper bounds. A function value called through a
variable needs no label, and the measurement did not separate those calls.

The rewrite is a codemod on the import-resolving lane. It uses the same
callee resolution as `vibe grep --where '$f = ..'` and edits by byte range,
so comments and layout survive. It is safe to re-run, so a conflicting PR
rebases by running it again.

**Bootstrap.** Labels in declared order already bind correctly on the
committed seed. That holds for builtins, which ignore the label, and for
named and imported functions, where an in-position label is checked and
stripped. So the migration does not wait for a seed bump. The `_`
declaration syntax does: the seed must parse `_ x: T` before the compiler's
own sources use it.

### Plan

1. **Checker owns labels.** Make the builtin-label P0 fix, give builtins
   parameter names, validate labels in the checker, fill omitted slots after
   checking, delete the syntactic resolver. No surface change yet.
2. **Warn, and provide the edit.** Teach `vibe check` to report a missing
   label as a warning, and land the codemod. Then parse `_ x: T` and bump
   the seed.
3. **Migrate.** Run the codemod package by package: `lib/`, then
   `fixtures/`, `bench/`, `examples/`, then `book/` and `docs/`, keeping the
   `book/en` and `book/ja` outputs identical. Each PR passes
   `pkf run release-check`.
4. **Enforce.** The warning becomes an error. Retire `x~` and the labeled
   function-type spelling. Rewrite the cheatsheet's labeled-argument
   sections and `syntax.md` to the final state.

Phase 1c (#3661) keeps the source argument order through checking. The
checker publishes a placement on each call that needs labels or optional
slots; lowering consumes its source indices and inserts `Some` / `None`.
The syntactic resolver and paired binder-authority normalization are removed.
Declaration reordering and opaque value-call behavior remain until Phase 4.
Rowless build lanes refuse labeled calls and ask for checked source.

## Acceptance

This becomes `accepted` when all of the following hold:

- No pass before the checker reads `ELabeledArg`. Labels are validated
  against the checker's resolved callee, and the fixtures for #986, #1899
  and #1994 still pass as answers.
- A builtin label that names no parameter, or names a different one, is a
  build error.
- `vibe check` rejects an unlabeled argument to a labeled parameter, a label
  on a `_` parameter or on a call through a value, and an out-of-order
  label. Each message names the edit.
- No call site in the tree needs the codemod, and `pkf run release-check`
  passes, including the seed→stage3 fixpoint.
- A self-compile of the migrated compiler is measured cold-vs-cold and
  warm-vs-warm against the pre-migration tree (#2393 protocol), and the
  result is recorded here.

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
- **`_` heuristics for the codemod.** Should a one-parameter function become
  `_` by default? This decides where the label count lands between 188,875
  and 335,578. It should be settled by measuring a sample package before
  the full run. The first sample is measured below; the rule is not yet
  chosen.

  `vibe refactor add-labels` (#3679) was run over `lib/@vibe/core` (65 files,
  all of them checked), at `main` 3f6a506 plus the codemod. Each policy
  names the slots it leaves positional. Builtins always use their own `_`
  slots. "After `_`" counts the calls that keep a positional slot beside a
  labeled one. The checker refuses that mix until #3681 lets the declaration
  mark the slot `_`, so the codemod reports those calls and leaves them for
  now.

  | `--positional` | Labels written now | More after `_` | Total |
  |---|---:|---:|---:|
  | `none` | 4,851 in 2,969 calls | 0 | 4,851 |
  | `receiver` (a `T::f` receiver) | 2,967 in 1,831 calls | 746 in 596 calls | 3,713 |
  | `receiver+single` (also a lone parameter) | 2,392 in 1,256 calls | 746 in 596 calls | 3,138 |

  Every policy skipped the same calls:
  - 62 calls through a local lambda, which D1 keeps positional;
  - 10 to 13 calls whose written arguments do not line up with the
    checker's, which are pipes and calls inside interpolation.

  On this package, `receiver+single` writes 35% fewer labels than labeling
  every argument. The receiver rule alone accounts for 1,138 of those
  1,713 labels, the lone-parameter rule for the other 575.
