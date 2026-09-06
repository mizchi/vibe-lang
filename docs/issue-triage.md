# Issue triage — deciding kind and priority mechanically

Last updated: 2026-09-06 (applied state and lanes rewritten against the open
set; the 2026-08-25 lists named merged PRs and closed issues).

So that "what do I do next" does not have to be re-derived every time, **each
label means exactly one thing**. Every issue is labelled independently on three
axes — kind, priority, order — and **the order of work falls out of those three
mechanically**.

## Axis 1: kind

| label | meaning |
|---|---|
| `bug` | the implementation contradicts the intent: a wrong result, a crash, or something that should pass being rejected |
| `enhancement` | adds a new capability |
| `refactoring` | tidying with no behavior change |
| `epic` | an **index**. The real work is in the sub-issues |
| `performance` | speed or memory. May be combined with `bug` / `enhancement` |
| `runtime` | touches the execution substrate. An area tag; may be combined with others |

## Axis 2: priority (P0 / P1 / P2)

**Decided by how badly it breaks, and nothing else.** "Seems important" and
"I want this" do not enter into it.

| label | test | why this order |
|---|---|---|
| **P0** | **silently wrong** — returns a wrong value, miscompiles, or lets a wrong program past the checker and on downstream | Nobody can notice. The mistake gets in without the author doing anything wrong. The worst way a language can break |
| **P1** | **crashes, or cannot be written** — correct code is rejected, something type-checks and then dies in codegen, a diagnostic is not actionable, or a resource is running out | You can notice, and you can work around it. But it reliably damages the experience |
| **P2** | **new capability, exploration, future** — nothing that works today is broken | Doing it makes things better; not doing it tells no lies |

Judge from **the symptom the issue itself states**. Never "this is an important
feature, so P0" — that turns priority into preference.

## Axis 3: order (`blocker`)

`blocker` = **another open issue depends on it**. Independent of priority.

A `blocker` issue is "the first thing to do inside that subtree", not "the thing
to do right now". Conflating the two puts an experimental subtree's Phase A on
the same shelf as a real bug.

## Order of work (derived mechanically from the three axes)

```text
1. every P0
2. the P1s that carry blocker
3. the remaining P1s
4. pick a subtree to take on, and start from its blocker
```

An `epic` is an index, so it is never itself the thing to work on (look at its
sub-issues).

## Applied state as of 2026-09-06

**Rewrite this section; never append to it.** It is a snapshot of the open set,
and a snapshot that has drifted is worse than none — the 2026-08-25 edition sat
here for two weeks naming three merged PRs and five closed issues as the things
to do next, which is exactly the failure `AGENTS.md` describes for documents
that rot. If the tables below disagree with `gh issue list --state open`, the
tables are wrong. Regenerate them.

### Open PRs occupy files

**Do not start a new branch on a file an open PR already edits.** Land that PR
first, then take the leftover.

| occupied files | PR | what it is holding |
|---|---|---|
| `gen_eq_body` (codegen, RC lane) | [#2522](https://github.com/mizchi/vibe-lang/pull/2522) | #2474's runtime guard. **Decide before merging**: #2529 rejects that case at check time, so what is left for the guard is the flat single-source lane, at +312 B per emitted module |

### P0 — silently wrong (5)

| # | what |
|---|---|
| #2523 | `Eq` is a marker trait, so `[T: Eq]` compares a user aggregate by reference identity — and `derive (Eq)` does not even satisfy the bound. Giving `Eq` a real `equals` method is the fix, and it is an ADR-level change to a builtin trait |
| #2475 | untyped-empty array pushes under a source-owned `struct Int` cannot tell a literal from the struct |
| #2427 | the CLI-core build traps in `__rt_str_concat` with a corrupt `(ptr\|len)`; cross-cutting (parser anchors, checker offsets, RC shadow table have each been narrowed on it) |
| #2381 | `vibe symbols` silently ignores extra arguments, and has no batch mode |
| #2378 | a library `fn` silently replaces a same-named builtin program-wide |

### P1 — crashes, or cannot be written (4)

| # | what |
|---|---|
| #2535 | a module-level `let` initialized with two or more Bool literals (`[false, false]`) makes the next top-level item "unexpected token" |
| #2527 | defining a `fn` named `id` or `call` that returns `Expr` makes an unrelated file fail with "cannot interpolate a value of type `Expr`" |
| #2444 | `try { } with { }` says a handler arm must be fully qualified while the arm already is exactly that |
| #2199 | OOB aborts name operation / index / length but carry no source provenance (rides #1987) |

### P2 carrying `blocker` — the entrance to a subtree

| # | subtree it opens |
|---|---|
| #2509 | #2494 compiler memory. Every later change in that subtree needs this number to show it moved |
| #2500 | #2493 binary size. One effect lowering, not five (ADR-0076) |
| #2387 | #2386 design-level performance. Symbol interning |
| #1959 | the incremental planner; #1960 waits on it |

### epics — indexes, never the thing to work on

| # | subtree |
|---|---|
| #2386 | design-level performance → #2387 (blocker), #2388, #2389, #2390, #2391, #2392 |
| #2492 | build-time configuration, `VIBE_*` → `#cfg` → #2497, #2498, #2499 |
| #2493 | a compile-only artifact at or under 1.0 MB → #2500 (blocker), #2501 – #2506 |
| #2494 | compiler memory, 128 MB per unit of work → #2509 (blocker), #2507, #2508, #2510 |
| #2340 | SIMD-first data structures → #2347, #2348 |
| #2002 | documentation by audience |
| #2001 | retire the scripts layer |

### Everything else

The rest of the open set is P2 outside a subtree — `gh issue list --state open
--label P2` is the list, and nothing in it blocks anything else. Small ones with
a stated, bounded scope, if you want one to start on: **#2538** (a test that is
red on main and wired into no gate, so nothing has been protecting it),
**#2349** (`mapfile` keeps the formatter gates from running on macOS stock
bash), **#2437** and **#2449** (the module and inline lanes still compile with
their typed-lowering tables empty; both end at the same statement-merge shape,
so do them together), **#2442** (bare-name builtin value forms, blocked only on
teaching the lambda-site planner scope).

## How to use sub-issues

Build the tree with GitHub sub-issues. **The parent is an index; the children
are the units of work.**

```text
#2494 compiler memory: bound the live set to one module
├── #2509 mid-size memory KPI on reserved pages   ← blocker
├── #2507 four build units along the existing seams
├── #2508 restate the self-build fixpoint per build unit
└── #2510 per-module prelude
```

A parent issue's body holds **only where things stand and an index of its
children**; the history goes in comments. Piling a checklist into the body makes
"what do I do next" harder to read the more items land — the five-issue cleanup
(2026-08-07) was undoing exactly that state.

## Splitting for parallel work — lanes that do not conflict

How to divide work across several agents (or several PRs). **In practice
conflicts have only three surfaces: editing the same source file, appending to a
gate/fixture list, and adding to the cheatsheet** — the generated bundles are
untracked now, so the bundle conflict that used to be unavoidable no longer
exists structurally.

The rule: **issues that touch the same set of files go in the same lane and run
serially. Running across lanes is free.**

| lane | file area | issues | notes |
|---|---|---|---|
| **A. eq dispatch** | `checker/checker_stmt.vibe`, `normalize/desugar_trait_dict.vibe` | #2523 (P0), then #2475 (P0), then #2501 | one lane, not two: the eq-row producer and its consumer are in these two files, and #2501 splits the second one, so it has to follow rather than run beside them |
| **B. parser** | `lib/@vibe/parser/**` | #2535 (P1), #2527 (P1) | |
| **C. loader / module lane** | `runtime/runtime.vibe`, `runtime/typecheck_fs.vibe`, `entry/compiler/**` | #2437 → #2449, #2521 | #2437 and #2449 end at the same statement-merge shape; doing them apart means writing it twice |
| **D. incremental / cache** | `runtime/typecheck_fs.vibe`, `cache/` | #1959 → #1960, #2388, #2510 | **same files as lane C**, so C and D serialize with each other |
| **E. codegen / RC** | `codegen/**` | #2427 (P0, cross-cutting), #2389, #1980, #1934 | |
| **F. runtime / host** | `runtime/viberun`, abort provenance | #2199 (rides #1987), #2397 | |
| **G. CLI / editor queries** | `lib/@vibe/cli/**`, `entry/cli_cache` | #2381 (P0), #2378 (P0), #1943, #2499 | |
| **H. scripts / gates** | `scripts/**`, `tests/gates/**` | #2538, #2349, #2001 | |
| **I. docs** | `docs/**`, `book/**` | #2002, #2146, #1346 | conflicts only on the cheatsheet |

The #2386 perf subtree deliberately touches every lane — its slices land as many
small independent PRs, which is why `git log` on a file is worth a look before
starting on it even when no lane claims it.

Within a lane the order is blocker first, then by priority. An entry added to a
gate script must always be **appended at the end** — inserting into the middle of
a list conflicts with the neighbouring lane.

## Limits of this classification

- The `blocker` edges are only the dependencies the issue bodies state
  explicitly. Implicit ones are not captured.
- Filing a new issue includes putting all three axes on it.
- Close only after confirming the fix is on main **and in the tree**, not
  because a PR body said "Fixes #N". The 2026-09-06 sweep found four issues
  (#2404 / #2405 / #2407 / #2451) whose fixes had been on main for a week with
  the issues still open, and one (#2437) whose scope had been rewritten three
  times in comments while the body still described the original ask. A merged
  PR does not close an issue; a person does.
- **Restate a body when its comments have overtaken it.** A reader who has to
  reconstruct the current ask from a comment thread pays that cost every time.
  The body holds where things stand; the thread holds how it got there.

## `tutorial-breakage`

A runnable block in [The Vibe Book](../book/README.md) that stops working on
the current compiler is **P1 (cannot write it / it crashes)**: a reader
following the canonical tour cannot run it. If it type-checks and returns a
wrong value instead, it is **P0 (silent-wrong)** like anything else.

Label such issues `tutorial-breakage` so they are easy to find. The label does
not override priority — the order of work still falls out of P0 / P1 and
`blocker` exactly as above. Whether the answer is a compiler fix or a language
change follows the same triage, and the repository rule that an
implementation-driven restriction must not become something the tutorial asks
the reader to memorize.
