# Issue triage — deciding kind and priority mechanically

Release scheduling is maintained in the [0.1.0 milestone](https://github.com/mizchi/vibe-lang/milestone/2)
and [0.2.0 milestone](https://github.com/mizchi/vibe-lang/milestone/3).
The 2026-09-15 audit replaced stale status tables with live issue queries.

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

## Release scheduling

Priority describes the symptom; a milestone describes when the work belongs.
An internal `blocker` is a dependency in its own subtree, not automatically a
release blocker. Every unresolved issue assigned to a release must be completed
or explicitly removed from that milestone before the tag.

**0.1.0** owns durable language/API/package/host contract decisions, defects in
the shipped synchronous surface, and bounded improvements with demonstrated
value. Its current work includes comparison witnesses (#2523), capability and
provider semantics (#2828, #1962, #1346), package identities (#2829), naming and
constructor decisions (#2830), ownership documentation (#2392), and diagnostic
locations (#2831). The final acceptance checklist is #2834.

**0.2.0** owns async/structured concurrency, WIT-derived async imports, TaskGroup
host waits, outbound async HTTP, suspend state and experimental WasmFX. The
synchronous host ABI and frozen authorization contract can be settled before
those implementations. The async host ABI has its own task, #2832.

**Backlog (unscheduled)** holds useful work carrying no release commitment:
internal compiler optimization, architecture experiments, repository tooling,
and stdlib additions. Examples are the per-module production driver (#2826),
measured compiler tuning (#2833), and internal artifact/TypeEnv redesigns. Keep
these experiments off by default until their correctness and cost criteria hold;
a successful experiment does not by itself create a release requirement.
Promote one to a release milestone only for a reproduced correctness or resource
failure, or a durable contract decision.

**No milestone** means the issue has not been scheduled yet, not that it was
judged unscheduled. Every open issue carries one of the three, so an empty
milestone is a triage gap: filing an issue includes choosing between 0.1.0,
0.2.0, and Backlog, the same way it includes the three axes above.

Use the current GitHub state instead of copying counts or lists of open PRs
into this document:

```bash
gh issue list --repo mizchi/vibe-lang --state open --milestone 0.1.0 --limit 200
gh issue list --repo mizchi/vibe-lang --state open --milestone 0.2.0 --limit 200
gh issue list --repo mizchi/vibe-lang --state open --milestone "Backlog (unscheduled)" --limit 200
gh issue list --repo mizchi/vibe-lang --state open --search "no:milestone" --limit 200
gh issue list --repo mizchi/vibe-lang --state open --label P0 --limit 200
gh pr list --repo mizchi/vibe-lang --state open --limit 100
```

Before working on a file, inspect open PRs and unmerged branch work that an
issue cites. Keep dependent edits in sequence; independent changes must preserve
the pending change and be checked for merge conflicts. A comment saying
"landed on a branch" is not evidence of inclusion in main.

## Maintaining an issue

- Keep its body about the current task, with explicit acceptance criteria.
  Fold corrections into the body instead of appending the same conclusion.
- When a long thread now tracks a different task, create a concise successor,
  transfer the remaining criteria and dependencies, and link both directions.
  Close the predecessor as superseded, not as completed implementation.
- Close as completed only after checking the implementation and its relevant
  regression coverage on main. A declaration, a PR description, or an oracle
  over a narrower lane is insufficient.
- Close as not planned when there is no worthwhile current workload. Record
  the measured reason and what would justify reconsideration; do not preserve
  an expensive task solely because it was once proposed.
- Internal refactors with negative measurements can remain experimental
  backlog. Do not turn historical regressions behind disabled switches into
  claims about today's default compiler.

## How to use sub-issues

Build the tree with GitHub sub-issues. **The parent is an index; the children
are the units of work.**

```text
#2494 compiler memory: bound the live set to one module
├── #2509 mid-size memory KPI on reserved pages   ← blocker
├── #2507 four build units along the existing seams
├── #2508 restate the self-build fixpoint per build unit
└── #2826 per-module production prelude
```

A parent issue's body holds **only where things stand and an index of its
children**; the history goes in comments. Piling a checklist into the body makes
"what do I do next" harder to read the more items land — the five-issue cleanup
(2026-08-07) was undoing exactly that state.

## Coordinating independent work

Changes to the same source, fixture registry, or contract documentation need
coordination. Check the actual files of current PRs rather than a stale lane
table. Compiler performance work often crosses checker, loader, lowering and
codegen boundaries; its index is #2833, and its bounded issues own the edits.

Within a dependency subtree, work on the blocker first and then use the
priority order. Preserve the ownership and diagnostic oracles when moving a
pass; a shorter file is not proof that its boundary is sound.

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

A runnable block in [The Vibe Book](../../../book/README.md) that stops working on
the current compiler is **P1 (cannot write it / it crashes)**: a reader
following the canonical tour cannot run it. If it type-checks and returns a
wrong value instead, it is **P0 (silent-wrong)** like anything else.

Label such issues `tutorial-breakage` so they are easy to find. The label does
not override priority — the order of work still falls out of P0 / P1 and
`blocker` exactly as above. Whether the answer is a compiler fix or a language
change follows the same triage, and the repository rule that an
implementation-driven restriction must not become something the tutorial asks
the reader to memorize.
