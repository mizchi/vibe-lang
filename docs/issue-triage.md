# Issue triage — deciding kind and priority mechanically

Last updated: 2026-08-07 (after the first pass; four issues closed the same day
by done-verification, and the parallel-lane section added).

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

## Applied state as of 2026-08-07

### P0 — silently wrong (4)

| # | blocker | what |
|---|---|---|
| #1526 | | `==` gives three different answers for an Array (bare = reference / inside a struct or enum = structural / inside a tuple = reference). **The semantics are decided: unify on structural equality (ADR-0097)** — only the implementation is left |
| #1527 | | a `Bool` returned from a function interpolates as `1` / `0` |
| #1529 | | a bounded call `B::method(x)` breaks unless the struct the impl targets is first in the file |
| #1533 | ✔ | importing a non-exported name passes the checker. A prerequisite for the import-mandatory phase of ADR-0096 (#1455) |

(#1525, the local-enum miscompile, was resolved by the parser rejection in
`ab031d2` and is closed.)

### P1 — crashes, or cannot be written (7)

| # | blocker | what |
|---|---|---|
| #1536 | ✔ | see-through in the suspend CPS split. Row-free closure param flow, eager `Stream::next` retarget, and direct if-condition / match-scrutinee are done. Remaining: row-variable callee, residual literal-param flow, compound selection input |
| #1511 | | `handle`'s eligibility constraint slips past the type checker. (c) the error text is done; (b) is the same mechanism as a slice of #1536 |
| #1520 | | validating the builtin registry. Proposal 1 is done; remaining: a bulk tidy of 85 double declarations plus proposal 3's positive-example corpus |
| #1508 | | a test / bench that runs `Http`. The row syntax is done; remaining: `Http::*` lowering on the test/bench path |
| #1514 | | diagnostic positions come in three tiers (C is done, the rest is not) |
| #1446 | | accepting an abortive effect in a guard's else as divergence |
| #1553 | | 2.6 GiB guest heap on a cold cache. Decided: set no target figure yet; per-phase measurement plus a 3.5 GiB watch comes first |

(#1500 optional arguments and #1503 trait-instance resolution are implemented
and closed; #1547 finalizers was settled as "not now" and closed.)

### P2 carrying blocker (the entrance to a subtree)

| # | what it is holding up |
|---|---|
| #1541 | wasm-gc Phase C (#1542) / Phase D (#1543) |
| #1548 | incremental P0-3 (#1550) |
| #1549 | incremental P0-3 (#1550) |
| #1550 | incremental P3 codegen reuse (#1552) |

### epics (indexes, not things to work on)

#1230 async / #1238 formal / #1262 RC and region / #1331 wasm-gc /
#1341 ADR-0089 D3 / #1379 incremental

## How to use sub-issues

Build the tree with GitHub sub-issues. **The parent is an index; the children
are the units of work.**

```text
#1230 async umbrella
├── #1536 closure param in the suspend CPS   ← blocker
├── #1537 M-conc-2 CPS lowering
├── #1341 ADR-0089 D3 (itself an index)
│   ├── #1538 retire the eager Stream
│   ├── #1539 wire ByteStream to p3
│   └── #1540 unify serve / host-stream composition
└── #1342 generalize host async imports
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
| **A. checker/parser** | `lib/@vibe/compiler/checker/`, `parser/` | #1533; the check-phase detection of #1536(c) + #1511(b); #1520 proposal 3 | |
| **B. codegen (linear)** | `codegen/expr/compile_call.vibe`, `builtin_bodies/` | #1527, #1529, #1526 (ADR-0097 decided), #1538-1 | compile_call is a shared point, so serialize within the lane |
| **C. wasm-gc** | `codegen/gc/` | #1541 → #1542 | ADR-0095 structurally guarantees no conflict with linear |
| **D. incremental/cache** | `runtime/typecheck_fs.vibe`, `cache/` | #1548 → #1549 → #1550 | |
| **F. runtime/host** | `scripts/wasm_vibe_host_runner.js`, `runtime/viberun` | the measurement in #1553, #1540 | |

Within a lane the order is blocker first, then by priority. An entry added to a
gate script must always be **appended at the end** — inserting into the middle of
a list conflicts with the neighbouring lane.

## Limits of this classification

- The `blocker` edges are only the dependencies the issue bodies state
  explicitly. Implicit ones are not captured.
- Filing a new issue includes putting all three axes on it.
- Close only after confirming the fix commit is on main. (Verified 2026-08-07:
  #1500 = `36e7869`, #1503 = `d9a50f6` + `7585b74`, #1525 = `ab031d2`.
  #1508 / #1520 / #1514 landed only partly, so they stayed open.)

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
