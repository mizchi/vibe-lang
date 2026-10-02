# vibe release roadmap

> The version ladder is ADR-0109; this file is the working detail behind it.
> Design decisions go in [adr.md](../design/adr.md), tasks in GitHub Issues.

## Version ladder

The repository's first stable version tag was `v0.0.1`
(2026-04-14, from the retired MoonBit host). `v0.1.0-rc.1`, `v0.1.0-rc.2` and
`v0.1.0-rc.3` were published as pre-releases. Older labels such as "0.1.0
sign-off", "0.2.0" and "0.3.0 GA" in planning documents did not denote
published releases. The ladder below numbers releases by what actually ships.

| version | meaning | state |
| --- | --- | --- |
| `v0.0.1` | The one historical release (MoonBit host era) | tagged 2026-04-14 |
| `0.0.x` | Everything since: the selfhost cutover and all development, including the content once prepared as "0.3.0 GA" | never released |
| `0.1.0-rc.1` | The first candidate to publish assets | published 2026-09-21 as a pre-release; superseded |
| `0.1.0-rc.2` | The second candidate | published 2026-09-28 as a pre-release; superseded |
| `0.1.0-rc.3` | The third candidate; prebuilt installs take the CLI compiler built from the release's own source (#3252) | published 2026-09-30 as a pre-release |
| **`0.1.0`** | **The first release usable by anyone but the author** | the tag and the verification of the published install remain in #2834; see [release-notes-0.1.0.md](../../user/getting-started/release-notes-0.1.0.md) |
| `0.2.0` | Structured concurrency, a type system aimed at formalization, a dedicated agent harness | after 0.1.0 |
| `1.0.0` | Maturity. Not a synonym for the first public release | unscheduled |

Work that carries no release commitment — internal compiler optimization,
architecture experiments, repository tooling, stdlib additions — lives in the
[Backlog (unscheduled) milestone](https://github.com/mizchi/vibe-lang/milestone/4)
rather than in a version above. It is not a fourth rung of the ladder.

`runtime/vibe`'s `VIBE_VERSION` names the version being prepared: the current
candidate's `0.1.0-rc.N`, and `0.1.0` for the final tag.
`scripts/build_release_assets.sh` requires `VIBE_VERSION` to equal the tag being
built, so a candidate cannot be published under the release's own number, and
`scripts/check_version_ladder.sh` keeps this table, the launcher, and the
release notes from drifting apart (a pre-release is reduced to the release it
documents, so a pre-release is checked against the 0.1.0 notes). `release.yml`
marks any tag carrying a SemVer pre-release suffix as a GitHub **pre-release**,
so a candidate never becomes the "Latest release" the README's installer
resolves to.

### A candidate number is spent once

The repository has GitHub's **immutable releases** enabled. That is what the
draft-then-promote shape in `release.yml` exists for -- a published release
will not accept an asset, so every file has to be attached while the release is
still a draft -- but it has a second consequence that is easy to learn the
expensive way: **a tag that has ever carried a published release cannot be
re-created, and deleting the release does not free it.** `git push` rejects the
re-push with `GH013 ... Cannot create ref due to creations being restricted`,
and `settings/rules` shows no ruleset to point at, because the restriction is
not expressed as one.

So a botched candidate is not retried under its own number; the candidate line
moves up. `0.1.0-rc.0` was published with zero assets by the pre-#2951
workflow, which is the only reason the first candidate with assets is rc.1.

A candidate also names one commit. Once main moves past that commit, the
candidate describes a tree nobody is going to ship, and a candidate exists to
be hunted for bugs. rc.2 and rc.3 each moved the line for that reason, not
because the previous candidate failed.

The rule this section encodes: **every new candidate costs a number, so cut
one when the tree is worth hunting, not on a schedule.**

### What promotes an rc to the release

The rc exists because "every checklist item is ticked" and "we have looked for
bugs" are different claims. A feature-complete candidate whose failure modes
nobody went hunting for is not a release; the project's own priority order says
the worst way to break is to be **silently wrong**, and a checklist cannot find
those — it can only confirm the things someone already thought to write down.

So the rc is promoted by a **bug hunt**, not by more features:

1. **Differential fuzzing finds nothing new.** `tests/fuzz/run_fuzz.sh`
   compiles one generated program four ways (bump, RC, wasm-gc, FS-linked) and
   requires all four to agree; the generator is trap-free by construction, so
   any runtime trap is a compiler bug. Run the generative mode and the
   `--mutate` parser-robustness mode against the **candidate's own stage2** —
   not the committed seed, which is a different compiler (see the
   "Which compiler answered?" rule in AGENTS.md).
2. **Every finding is triaged, not merely counted.** Reduce it
   (`tests/fuzz/reduce.py`), classify it, and either fix it or file it with the
   three triage axes. A finding parked without a decision is the checklist
   failure this rung exists to prevent.
3. **The suspicious places are examined directly**, since fuzzing only reaches
   what the generator emits. What is known to be thin gets looked at on
   purpose rather than waited on.

A finding that turns out to be a pre-existing limitation with a written reason
does not block promotion; an unexplained divergence between two lanes does.

Each campaign's compiler identity, commands, counts and finding triage are
recorded on [#2834](https://github.com/mizchi/vibe-lang/issues/2834), next to
the install, registry round-trip and release-gate evidence. Read the current
state there rather than from a copy here.

The stable surface that the `0.1.0` tag freezes is
[stable-surface.md](../../user/reference/stable-surface.md) (ADR-0057). While the toolchain
is on 0.x, SemVer shifts one step: a breaking change to that surface is a
**Minor** bump, a compatible change is a **Patch**.

### What 0.1.0 has to be true of

"Usable by anyone but the author" is the bar, so the criteria are about
someone else's first hour, not about compiler internals. #2834 records the
evidence for each.

1. **Install and run on a machine that is not the author's.** The README's
   installer installs a published release with no checkout, and `release.yml`
   installs the freshly published release on Ubuntu and macOS and runs a
   program with it.
2. **Package distribution end to end** — `vibe new` / `add` / `fetch` /
   `publish` against an isolated registry, with dependencies pinned by content
   hash in the root `index.vpkg` (ADR-0065, ADR-0063/0064, ADR-0070). The
   `require` line is the lock; there is no lock file.
3. **The book reads true.** Every ` ```vibe run ` block is compiled by doctest,
   and the Japanese translation records the same output
   (`pkf run check-tutorial-translation-parity`).
4. **The stable surface is real** — every name in
   [stable-surface.md](../../user/reference/stable-surface.md) §3 resolves in the shipped
   compiler (`pkf run check-freeze-surface`).
5. **Editor integration** — `vibe lsp` plus the query primitives
   (`vibe check` / `symbols` / `type-at` / `binding-at` / `deps` / `grep`).
6. **Apache License 2.0.** The `0.1.0` tag does not ship under MIT.
7. **One entry spelling.** `fn main allows Console` / `test "n" allows Http`
   is what every document teaches and the only spelling the compiler reads
   (ADR-0088): `with` on an entry is a parse error naming the edit.
8. **The seed is fetchable.** The release tag that `bootstrap/seed.json` pins
   exists, so a cold checkout does not rebuild the seed from source
   (`scripts/ensure_seed.sh`'s rebuild fallback is for the window inside a
   bump, not for a release).
9. **The browser playground runs the shipped language.** Its compiler
   component is built from the candidate stage2, and CI runs every preset in
   Chromium against the built assets rather than only type-checking their
   source.

### Release scope

The [0.1.0 milestone](https://github.com/mizchi/vibe-lang/milestone/2) is the
release scope; [#2834](https://github.com/mizchi/vibe-lang/issues/2834) owns
the final acceptance evidence. An issue assigned to the milestone is resolved,
or removed from it with a written scope reason, before the tag. Query the
milestone instead of copying its contents here — a copied list is stale the day
the first item closes.

Internal compiler optimization is indexed by
[#2833](https://github.com/mizchi/vibe-lang/issues/2833) under the
[Backlog (unscheduled) milestone](https://github.com/mizchi/vibe-lang/milestone/4).
The 128 MiB per-unit compiler, per-module compilation, and broader body
relocation are measured backlog, not implicit prerequisites for 0.1.0.
Compiler size, mid-size memory and incremental build KPIs are observed, not
promised. Preserve the existing cold/warm selfhost metrics and choose
additional CI observation according to its cost; do not add an expensive
benchmark lane merely to complete an inventory.

### What 0.2.0 holds

ADR-0109 gives 0.2.0 three themes:

1. **Shared-nothing structured concurrency** as the public model — `Task`
   bound to a generative nursery, typed channels, `Send`, cooperative
   cancellation ([ADR-0068 detail](../design/concurrency.md)). JSPI + Worker,
   the WASI Component Model, and shared-everything threads are interchangeable
   lowerings of that semantics; none of them is a blocker. The
   `@vibe/concurrent` core (`TaskGroup`, `TaskHandle`, channels,
   `Parallel::map`, the `Send` rule) is already on the 0.1.0 stable surface
   (#3172, stable-surface §3.1); the suspendable-task lane and the WASI 0.3
   component surface are not (stable-surface §6).
2. **A type system designed for formalization** — the redesign that follows the
   type-soundness ADR series, aimed at a specification that can be mechanically
   checked.
3. **A dedicated agent harness** — for AI agents writing and verifying vibe.
   Its predecessor, the language evaluation loop `eval/lang-review/`, already
   runs.

The [0.2.0 milestone](https://github.com/mizchi/vibe-lang/milestone/3) is the
live list of scheduled work; read it there.

---

## Where the detail lives

This file answers one question: **what has to be true for the next release.**
It stays short because every other kind of detail has a better home:

| you want | read |
| --- | --- |
| why a design is the way it is | [adr.md](../design/adr.md) |
| what is being worked on now | GitHub Issues and milestones (queries in [issue-triage.md](issue-triage.md)) |
| how a decision was reached | the issue thread, and `git log` |
| what the language can do today | [cheatsheet.md](../../user/reference/cheatsheet.md), [book/en](../../../book/en) |
| what 0.1.0 promises not to break | [stable-surface.md](../../user/reference/stable-surface.md) |
| how to prioritise an issue | [issue-triage.md](issue-triage.md) |
