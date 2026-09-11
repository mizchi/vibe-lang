# ADR-0088: capability authorization surface — `allows` at the entry, optional capabilities, `perform?`, and preflight authorization

Status: partial (the surface below is built; the production grant ladder is #2332)

Date: 2026-07-31, revised 2026-09-11

Related: #1218, ADR-0043 (absorbed), ADR-0071 (effectset), ADR-0075 (`.vibex`
runtime contract), ADR-0084 (effect classes / entry-row admission), ADR-0085
(`Exception[E]`). Background and alternatives:
[effect-taxonomy-review.md](effect-taxonomy-review.md).

## Context

A vibe effect row does two jobs that look alike and are not. On a called
function it is a **requirement**: the caller has to supply every label in it,
by handling the effect or by carrying the label in its own row. On an entry
point — `fn main`, `fn _start`, a `test` / `bench` / `example` block — there
is no caller. The row is what the run **grants**: the host capabilities the
program may use, plus what the runtime boundary brings in on its own
(`Exception`, `Async`).

One keyword for both hid the difference. `fn main with Console` read as if
`main` were asking someone above it for the terminal, when it is the place
the terminal is handed out. ADR-0075 already treats the entry row as the
executable's contract (`Entry.requires ⊆ ComposedHost.provides`), and
Deno-style authorization needs a place where authority *starts*.

An earlier revision of this ADR split one row into two clauses by effect
class — `with A allows C`, algebraic effects in `with`, capabilities in
`allows`, everywhere a row may appear. That put the audit line inside every
signature but answered the wrong question: what a reader needs to know at a
signature is whether it asks for authority or hands it out, and that is a
property of the declaration's position, not of the effect's class.

## Decision

### 1. `allows` is the row of an entry point; `with` is the row of a called function

- An entry point writes its whole row with `allows`:

  ```vibe skip
  // doctest-skip: form catalogue
  fn main allows Console + Fs::read_file? {
    ..
  }

  fn _start() -> Int allows Fs {
    ..
  }

  test "hits the network" allows Http {
    ..
  }
  ```

  `allows ()` is the explicitly empty grant, like `with ()`.

- A called function, a function type, a closure annotation, a trait method
  and a `.vpkg` contract declaration write `with`. `allows` there is a parse
  error that names the edit — for a contract declaration whatever its name,
  since a package publishes requirements and a callable API function that
  happens to be called `main` is not an entry point (the contract parser
  refuses the keyword itself, `signature_allows_keyword_at`):

  ```text
  `allows` grants authority and is written on an entry point only (`fn main`,
  `fn _start`, `test`, `example`, `bench`); `helper` requires its effects from
  the caller -- write `with` here and grant the effect at the entry
  ```

- The combined `with A allows C` is not a spelling and is refused by name.

- **One representation.** The parser stores an `allows` row exactly as it
  stores a `with` row (the comma-joined labels every consumer already reads),
  so entry admission (#1683), the `Async` and exception boundaries the entry
  wrapper installs, WIT projection, the entry execution cache and the `.vpkg`
  contract hash see one row and cannot drift between the two keywords. The
  keyword is decided by position when the row is read and when it is printed;
  nothing downstream needs to know which one was written.

- `allows` is a **contextual keyword**, not reserved: it is recognized only
  where an entry row may begin, so `let allows = 7` keeps compiling.

- The AST printer prints the row back with the keyword its position
  dictates — `allows` on `main` / `_start` and on a `test` / `bench` /
  `example` block, `with` elsewhere — and `vibe normalize` never drops a
  block's row (the block rows travel in the parse's trailing
  `STestEffectRows` marker, which `print_program` and the normalizer
  register with the printer before printing; `register_block_rows`).

### 2. What an entry may grant

Every label on an entry row must have an owner the run can bring in
(ADR-0084's admission rule, unchanged in substance):

| label | owner | on the row |
| --- | --- | --- |
| `Console`, `Fs`, `Fs::read_file`, `Http`, … (`standard_effect_policy.vibe`) | the host / provider | granted; `Provider::op` must be an operation the provider owns, or the grant is refused |
| `Exception`, `Exception[E]` | the entry boundary (an escaping throw becomes a diagnosed failure) | granted |
| `Async` | the runtime driver | granted |
| an `effectset` the program declares | expanded before any check (ADR-0071) | its members, one by one |
| a user-declared effect (`Ask`, `Ask::Get`) | nobody outside the program | refused: handle it before the entry (`handle .. with Ask`) |
| a row variable | no caller to instantiate it | refused |

The `effectset` row is how a program extends the vocabulary on its own side:
`effectset AppCaps = { Console, Fs::read_file }` then `fn main allows AppCaps`
and `test "n" allows AppCaps` — one spelling at every entry, expanded before
admission so it grants exactly its members.

The table is one policy for every entry (`entry_grant_errors`): `fn main` /
`fn _start` are admitted on their declared row, a `test` / `bench` / `example`
block on the row after its name. `test "x" allows Ask::Get` is refused with
the `handle` edit exactly as `fn main allows Ask::Get` is — the block row used
to pass straight into the body walk, so it authorized a `perform` that no
handler would ever catch and the test trapped at run time. A user effect
performed in a block body without a handler gets the same `handle` edit,
not an `allows` edit that the admission would then refuse; the diagnostics
name the block as written (`entry point test "x" cannot discharge ..`).

### 3. Optional capability: the `?` grade

- `?` marks an `allows` item optional (`Fs::read_file?`, or `Fs?` for every
  operation of the provider). The grade is a property of the grant; it does
  not distribute through an effectset name.
- **Strict grade match**: `perform? Fs::read_file(..)` requires an optional
  grant for that operation and returns `Attempt[T, E]` (`Granted(T)` /
  `NotGranted` / `Errored(E)`, a closed enum in `@vibe/core`); a plain call
  under an optional grant is refused with both edits named (`perform?`, or
  drop the `?`). `perform?` on a required grant is refused too: the type
  would claim a reachability it does not have.
- A called function may *require* the optional grade (`fn cached() -> .. with
  Fs::read_file?`) and perform `perform?` itself. The graded subset rule is
  the lattice `Optional ⊑ Required`: a caller satisfies an optional
  requirement with either grade of the label **or of its provider** —
  `allows Fs::read_file?`, `allows Fs::read_file`, `allows Fs?` and `allows
  Fs` all satisfy `with Fs::read_file?`; the grade is stripped and the usual
  provider-to-operation containment applies. The reverse is not coverage:
  `allows Fs::read_file?` does not satisfy `with Fs?`. An optional grant
  never satisfies a required requirement or a plain call, and the refusal
  quotes the grant as written (``is granted as optional (`allows Fs?`)``, so
  the "drop the `?`" edit names that label).
- A `perform?` is refused where its `NotGranted` arm could never run, for
  the same reason `perform?` on a required grant is: **directly in a `test`
  / `bench` / `example` block**, because a test artifact runs with full
  authority and resolves every optional grant to `Granted`
  (`optional_perform_artifact_resolution`); and **under a row that also
  grants the operation or its provider as required** (`allows Fs +
  Fs::read_file?`, or a block's ambient `Fs` next to its own
  `Fs::read_file?`), because Required is the join and absorbs the optional
  grade. The message names the absorbing grant and the two edits: call the
  operation plainly, or move the `perform?` into a function that requires
  `with Op?` (which a block may call — the helper's `perform?` is honest
  about the helper's own requirement, and the block grants it).
- `?` on `Exception` / `Async` / a user effect is refused: optionality is a
  grant concept, and those are not granted by a host. The check reaches
  every row position — a binding's own row, a callback parameter's row, a
  return type's, a closure literal's annotations, a type alias, a struct
  field, an enum payload, a trait or effect operation signature — because
  the parser accepts the grade in any `with` row and the checker is the
  only place that knows which labels have a host.

### 4. Resolution ladder — build → apply → instantiate, never mid-run

Unchanged. An optional grant is resolved exactly once at the earliest phase
available and is invariant for the run (ADR-0075): build flags (`--allow-*`
/ `--deny-*`, the L1 that absorbed ADR-0043) const-fold the `perform?`
match and DCE the dead arm; apply records `BindingLock.optional_resolution`;
instantiate performs one preflight before the first instruction of `main`
(non-TTY: unresolved Optional → `NotGranted`, unresolved Required → abort,
naming the flag). A non-interactive compile today lowers an unresolved
optional operation to `NotGranted` on both backends (#2236); the production
wiring of the ladder is #2332.

### 5. `with` on an entry is a parse error

`fn main with ..`, `fn _start() -> T with ..` and `test` / `bench` /
`example` `"n" with ..` are refused by the parser, which names the whole
edit: `` `fn main` is an entry point and grants its row, so the keyword is
`allows`: write `fn main allows Console` ``. The row is read before the
refusal, braced or not, so the message carries the row as it must be written
rather than a keyword to change and then a row to rewrite
(`entry_with_row_message`). A bodyless `.vpkg` declaration keeps `with` on
any name, `main` included: it is a requirement its importers see, never an
entry. The compiler's own sources spell their entries `allows` since the
bootstrap bump to `seed/entry-allows-2026-09-11` (#2654), the first seed
that reads the keyword.

## Consequences

- The book, README, cheatsheet and the spec teach one entry spelling, and it
  says what the row is.
- The entry row hint says `allows`: `hint: add 'allows Console + Fs::read_file'
  to 'main'`, `hint: declare 'fn main allows Fs::read_file'`; a called
  function's hint keeps saying `with`.
- The WIT world of a `.vibex` is projected from its `allows` row, which is
  the contract the run preflights.
- A grant naming an operation its provider does not own (`allows
  Console::Get` with no `effect Console` in the program) is refused rather
  than admitted by prefix, so the contract cannot list authority that does
  not exist.
- `test {}` / `bench {}` keep ambient full authority; a declared row widens
  it ([spec/test-example-capabilities.md](spec/test-example-capabilities.md)).

## Non-goals

- Resource-kind surface syntax (`Fs[CacheDir]`, ADR-0094).
- Mid-run grant / revoke / re-prompt.
- A grant record file.
- A finer grant lattice than Required / Optional.
- Handler semantics (ADR-0050 / 0071 / 0076).
- User-declared capabilities provided by the host. A user effect whose
  operations are host imports (a WIT interface the runtime satisfies, or a
  provider composed at the root per ADR-0075) would be the same `allows` row
  with a new owner class; the declaration form and the runner-side import
  injection are open and have their own issue.

## Formal contract

ADR-0084's Lean layer (`formal/VibeFormal/Effect/Taxonomy*.lean`,
`Capability/TaxonomyBridge.lean`) is extended with the grade: the lattice
`Optional ⊑ Required` (join = Required) is preserved by effectset expansion
and normalization; projecting `Entry.requires` onto its Required members
preserves ADR-0075 preflight acceptance; resolving an Optional to
`NotGranted` at L1 only shrinks the requirement set; a checker that lets a
plain `perform` ride an Optional grant accepts a run without authority
(strict grade match's counterexample). `formal/oracle/effect-taxonomy.tsv`
carries the grade column.

## Pinned by

- `lib/@vibe/compiler/tests/parser_test.vibe` (the grammar: entry heads,
  `allows ()`, the refusals, contextual `allows`, `?` on a grant only);
- `lib/@vibe/compiler/tests/checker_entry_effect_test.vibe` (admission,
  the optional-grant refusal, unknown provider operations, effectset grants,
  the entry-aware hints; block-row admission, provider-wide optional grants
  and the grade check in nested rows —
  `fixtures/typecheck/{test_allows_user_effect,entry_optional_provider_grant,optional_grade_nested_row}.vibe`
  pin the same three on the fixture lane);
- `lib/@vibe/compiler/runtime/deprecated_scan_test.vibe` (the legacy-spelling
  warning);
- `lib/@vibe/compiler/tests/perform_question_lowering_test.vibe`,
  `fixtures/typecheck/perform_question_not_lowered.vibe` (the `NotGranted`
  lowering);
- `book/en/09_capabilities.vibe.md` (doctest and its skip blocks' quoted
  diagnostics) and `scripts/test_vibe_install_hello.sh` (the taught entry row
  across README, install, cheatsheet and the book).
