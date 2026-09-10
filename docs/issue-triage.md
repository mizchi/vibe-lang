# Issue triage — deciding kind and priority mechanically

Last updated: 2026-09-10 (applied state rewritten against the open set: **P0 is
empty**. The 2026-09-08 edition listed four P0s and eight P1s; of those twelve
rows, one moved to P1 on its own merits (#2378, once #2628 gave it an actionable
diagnostic) and the rest are closed. A table naming closed issues is worse than
no table -- it sends the next reader to work that is already done).

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

## Applied state as of 2026-09-08

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

### P0 — silently wrong (0)

Empty. Each of the four that stood here is now either fixed or **reported**, and
the distinction matters: three of them still describe a real defect, and what
changed is that the compiler says so. By this document's own axis that is the
P1 row ("you can notice, and you can work around it"), not the P0 one ("nobody
can notice").

| former P0 | what closed the P0 property |
|---|---|
| #2523 | #2612 refuses the bound at a non-scalar instantiation instead of comparing by reference identity. The dispatch is still missing — now P1 |
| #2475 | #2471 made the ambiguous rungs fail closed and #2475 moved the refusal to compile time with a message naming the edit. Both meanings still trap — now P1 |
| #2378 | #2628 made `vibe check` report a qualified `fn` definition of a builtin name. The name is still replaced program-wide if you ignore the warning — now P1 |
| #2381 | fixed: `vibe symbols` refuses an unrecognised argument and sweeps a directory in one process |

**Fail-closed is not the same as fixed**, and none of the three rows above should
be read as done. But it is the difference between a language that lies and one
that says it cannot answer, which is the difference this axis measures.

### P1 — crashes, or cannot be written (4)

| # | what |
|---|---|
| #2523 | `Eq` is a marker trait, so `[T: Eq]` cannot compare a user aggregate. The bound is refused (#2612); giving `Eq` a real `equals` method is the fix, and it is an ADR-level change to a builtin trait. **Order matters**: the operator→witness lowering has to exist BEFORE the method, or the guard stands down while nothing dispatches |
| #2475 | untyped-empty array pushes under a source-owned `struct Int` cannot tell a literal from the struct. Five attempts at the builtin-scalar marker failed five different ways; the consumers of a leaf spelling have to be enumerated first |
| #2378 | a qualified `fn` definition of a builtin name replaces it program-wide. Reported since #2628; open for whether to escalate to a rejection, and for whether the caller (not the definer) should hear about it |
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
| #2340 | SIMD-first data structures → #2347. #2348's two inline-wasm halves landed in #2399 / #2420; the issue itself carried a "Closing" comment for two days without the state change, applied 2026-09-08 |
| #2002 | documentation by audience → #2564, #2565, #2566, #2567. **The blocker is gone**: #2562's fail-closed classification gate landed in #2576, so the four moves are unblocked and can run in order (delete, then user, then internal/generated, then split the mixed ones) |
| #2001 | retire the scripts layer |

### Everything else

The rest of the open set is P2 outside a subtree — `gh issue list --state open
--label P2` is the list, and nothing in it blocks anything else. Small ones with
a stated, bounded scope, if you want one to start on: **#2442** (bare-name
builtin value forms, blocked only on teaching the lambda-site planner scope),
**#2555** (delete the sidecar codec's
hand-rolled renderer and unary counts — the bug they route around was a
misdiagnosis and is closed), **#2219** (its "after the next bootstrap bump"
precondition has fired — the committed seed emits the assert marker, so the
legacy block recognizer can go).

**The gate-wiring pair, both from #2579 and both worth doing in order.** #2579
wired all 19 previously-unreachable gate scripts into CI, so the count is zero
today — by hand, and the hand audit got one of ten entries wrong. **#2580** is
the mechanical replacement: a gate that fails when a `check_*` / `lint_*` script
is reachable from no workflow, which is what keeps the count at zero.
**#2581** is the other half of the same lesson: `check_portable_boundary.sh`
answers a semantic question with a text scanner, and its review ran to 53
findings — 52 fixed, one refused because measuring the emitted wasm showed the
gate was right. Its three comments are the acceptance list for the AST version.

**#1872 has no open parent.** Its parent #1770 closed, so the `effect Source`
design is invisible from every open epic even though its remaining steps are
written out. Either re-parent it or treat it as a standalone lane entry; do not
assume it is covered because it has a phase number.

Sequencing worth knowing: **#1953 comes after #2497 and #2498**, not beside
them. The two issues used to conflict — both moved the compiler's trace and
telemetry sinks, one behind `#cfg(telemetry)` and one behind a `Log` effect
whose handler is a parameter, so landing either invalidated the other's plan.
Settled 2026-09-06 in favour of `#cfg`: the sinks are #2498's, which absorbed
the three sharper acceptance criteria, and #1953 is now the configuration half
alone. That half gets *sharper* once the #2492 subtree lands, because what is
left in the configuration cells is then exactly the per-compilation set #2497
deliberately excludes from `#cfg` (`VIBE_CFG`, `VIBE_UNSTABLE`,
`VIBE_INTERNAL_TRUSTED_SOURCE`) — two of which carry authority, so a `Config`
row over them is a least-authority row in the literal sense.

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
| **A. eq dispatch** | `checker/checker_stmt.vibe`, `normalize/desugar_trait_dict.vibe` | #2523 (P1), then #2475 (P1), then #2501 | one lane, not two: the eq-row producer and its consumer are in these two files, and #2501 splits the second one, so it has to follow rather than run beside them |
| **B. parser** | `lib/@vibe/parser/**` | — | #2535 and #2527 both closed |
| **C. loader / module lane** | `runtime/runtime.vibe`, `runtime/typecheck_fs.vibe`, `entry/compiler/**` | #2521, #2555 | #2437 and #2449 both closed 2026-09-10; they ended at the same statement-merge shape, which is why they went together |
| **D. incremental / cache** | `runtime/typecheck_fs.vibe`, `cache/` | #1959 → #1960, #2388, #2510 | **same files as lane C**, so C and D serialize with each other |
| **E. codegen / RC** | `codegen/**` | #2389, #1980, #1934 | |
| **F. runtime / host** | `runtime/viberun`, abort provenance | #2199 (rides #1987), #2397 | |
| **G. CLI / editor queries** | `lib/@vibe/cli/**`, `entry/cli_cache` | #2378 (P1), #1943, #2499 | #2381 closed 2026-09-09 |
| **H. scripts / gates** | `scripts/**`, `tests/gates/**` | #2580, #2581, #2001 | #2580 before #2581: the reachability gate is cheap and keeps the wiring #2579 did from rotting, while #2581 needs a compiler-bearing job |
| **I. docs** | `docs/**`, `book/**` | #2002 → #2564, #2565, #2566, #2567 (in that order), #1346 | conflicts only on the cheatsheet. #2146 closed 2026-09-06 |

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
- **The state and the comments can disagree in both directions, so check both.**
  Two cases on 2026-09-08: #2348 carried a "Closing" comment for two days with
  the state never applied, and #2581 was closed by a merge although nothing about
  it was done.
- **Never write `#NNNN` after a closing verb you are negating.** #2581 was closed
  by a commit body reading *"This does not close #2581."* — GitHub's parser sees
  `close #2581` and does not see the `not`. The keywords are `close` / `closes` /
  `closed` / `fix*` / `resolve*`, anywhere in a commit body on the default branch.
  Spell it `does not close issue 2581`, with no `#`, when saying so. This
  repository writes commit bodies that explain what a change deliberately does
  NOT do, so the hazard is structural here rather than incidental.
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
