# Issue triage — deciding kind and priority mechanically

Last updated: 2026-08-25 (applied state rewritten against the open set;
the 2026-08-07 P0/P1 lists are closed).

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

## Applied state as of 2026-08-25

Open PRs occupy files. **Do not start a new branch on a file an open PR already
edits.** Merge or land that PR first, then take the leftover.

| occupied files | PR | what it is holding |
|---|---|---|
| `checker/checker_stmt.vibe` | [#2294](https://github.com/mizchi/vibe-lang/pull/2294) | #2290 / #2292. After merge: #2293 |
| `normalize/desugar_trait_dict.vibe`, `codegen/expr/compile_call.vibe`, `cli_adapter.vibe`, `cli_support.vibe`, `lsp/lsp_server.vibe`, `entry/source_compile/wasi_only/merge_sources.vibe`, fmt scripts | [#2296](https://github.com/mizchi/vibe-lang/pull/2296) | #2283, ADR-0068 opt-in, `vibe fmt` self-blame. CI is red (freeze-surface `Map::*` + `VIBE_UNSTABLE` selector). After merge: **P0 #2281**, then #2284 / #2285 / #2287 / #2297 / #2280 |

### P0 — silently wrong (1)

| # | wait for | what |
|---|---|---|
| #2281 | #2296 (`desugar_trait_dict.vibe`) | a parameterized alias wrapping a structural container (`type AL[V] = Array[V]`) loses structural `==` and answers by identity |

### P1 — crashes, or cannot be written (7)

| # | wait for | what |
|---|---|---|
| #2283 | in #2296 | a user-defined `assert_eq/2` is claimed by the builtin lowering |
| #2284 | after #2296 | ADR-0068 opt-in scans only the entry; a sibling import bypasses it |
| #2287 | after #2296 (`merge_sources.vibe`) | `export ./dep.vibe { cmp as compare }` dies at codegen |
| #2280 | after #2296 (`cli_adapter`) | `vibe check` cannot parse a `.vpkg` |
| #2293 | after #2294 | two imports binding the same local name still last-win |
| #2164 | after #2294 if it touches checker type names | contract transparent types have no provenance for typos |
| #2199 | rides #1987 | OOB abort names operation/index/length; source provenance and the `[crash debug]` dump remain |

### P2 carrying blocker (the entrance to a subtree)

| # | what it is holding up |
|---|---|
| #1959 | persist semantic module / SCC reuse (#1960) |

### epics (indexes, not things to work on)

#2002 docs audience / #2001 scripts layer / #2269 HKT / #1379 incremental

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
| **A. checker type-env** | `checker/checker_stmt.vibe` | #2294, then #2293 / #2164 | serialize on `checker_stmt` |
| **B. eq-shape / call / cli / merge** | `normalize/desugar_trait_dict.vibe`, `codegen/expr/compile_call.vibe`, `cli_*.vibe`, `merge_sources.vibe` | #2296, then **#2281**, then #2284 / #2285 / #2287 / #2297 / #2280 | P0 #2281 lives in `ty_to_eq_shape`; do not fork these files while #2296 is open |
| **D. incremental/cache** | `runtime/typecheck_fs.vibe`, `cache/` | #1959 → #1960 | |
| **F. runtime/host** | `runtime/viberun`, abort provenance | #2199 (rides #1987) | |

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
