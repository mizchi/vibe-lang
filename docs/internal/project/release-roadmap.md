# vibe release roadmap

> The version ladder is ADR-0109; this file is the working detail behind it.
> Design decisions go in [adr.md](../design/adr.md), tasks in GitHub Issues.

## Version ladder

The repository has published **exactly one** version tag: `v0.0.1`
(2026-04-14, from the retired MoonBit host). Every other number that appears in
older documents — "0.1.0 sign-off", "0.2.0", "0.3.0 GA" — was a label in a
document, never a release. The ladder below numbers releases by what actually
ships.

| version | meaning | state |
| --- | --- | --- |
| `v0.0.1` | The one historical release (MoonBit host era) | tagged 2026-04-14 |
| `0.0.x` | Everything since: the selfhost cutover and all development, including the content once prepared as "0.3.0 GA" ([archive/release-notes-0.3.0.md](../../archive/release-notes-0.3.0.md)) | never released |
| **`0.1.0-rc.0`** | **The candidate.** Everything 0.1.0 promises is implemented and its acceptance evidence is recorded; what has not happened yet is the bug hunt below | current target |
| `0.1.0` | **The first release usable by anyone but the author** | after the rc clears §"What promotes an rc to the release"; see [release-notes-0.1.0.md](../../user/getting-started/release-notes-0.1.0.md) |
| `0.2.0` | Structured concurrency, a type system aimed at formalization, a dedicated agent harness | after 0.1.0 |
| `1.0.0` | Maturity. Not a synonym for the first public release | unscheduled |

Work that carries no release commitment — internal compiler optimization,
architecture experiments, repository tooling, stdlib additions — lives in the
[Backlog (unscheduled) milestone](https://github.com/mizchi/vibe-lang/milestone/4)
rather than in a version above. It is not a fourth rung of the ladder.

`runtime/vibe` reports `0.1.0-rc.0`.
`scripts/build_release_assets.sh` requires `VIBE_VERSION` to equal the tag being
built, so a candidate cannot be published under the release's own number, and
`scripts/check_version_ladder.sh` keeps this table, the launcher, and the
release notes from drifting apart (a pre-release is reduced to the release it
documents, so `0.1.0-rc.0` is checked against the 0.1.0 notes). `release.yml`
marks any tag carrying a SemVer pre-release suffix as a GitHub **pre-release**,
so a candidate never becomes the "Latest release" the README's installer
resolves to.

### What promotes an rc to the release

The rc exists because "every checklist item is ticked" and "we have looked for
bugs" are different claims, and only the first one was true. A feature-complete
candidate whose failure modes nobody went hunting for is not a release; the
project's own priority order says the worst way to break is to be **silently
wrong**, and a checklist cannot find those — it can only confirm the things
someone already thought to write down.

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

The stable surface that the `0.1.0` tag freezes is
[spec/stable-surface.md](../../user/reference/stable-surface.md) (ADR-0057). While the toolchain
is on 0.x, SemVer shifts one step: a breaking change to that surface is a
**Minor** bump, a compatible change is a **Patch**.

### What 0.1.0 needs

"Usable by anyone but the author" is the bar, so the remaining work is about
someone else's first hour, not about compiler internals:

1. **Install and run on a machine that is not the author's.** The
   `cli-install` workflow already covers multi-OS install smoke; what it does
   not cover is the path a newcomer takes from the README to a running program.
2. **Package distribution end to end** — `vibe new` / `add` / `fetch` /
   `publish` against the registry slice that landed, with the lock file as the
   contract (ADR-0065, ADR-0063/0064, ADR-0070).
3. **The book reads true.** Every ` ```vibe run ` block is compiled by doctest,
   and the Japanese translation records the same output
   (`pkf run check-tutorial-translation-parity`).
4. **The stable surface is real** — every name in
   [spec/stable-surface.md](../../user/reference/stable-surface.md) §3 resolves in the shipped
   compiler (`pkf run check-freeze-surface`).
5. **Editor integration** — `vibe lsp` plus the query primitives
   (`vibe check` / `symbols` / `type-at` / `binding-at` / `deps` / `grep`).
6. **Apache License 2.0.** The `0.1.0` tag is the first release usable by
   anyone but the author; it does not ship under MIT.
7. **One entry spelling.** `fn main allows Console` / `test "n" allows Http`
   is what every document teaches and the only spelling the compiler reads
   (ADR-0088): `with` on an entry is a parse error naming the edit, since the
   bootstrap bump to `seed/entry-allows-2026-09-11` (#2654).
8. **The seed is fetchable.** The release tag that `bootstrap/seed.json` pins
   exists, so a cold checkout does not rebuild the seed from source
   (`scripts/ensure_seed.sh`'s rebuild fallback is for the window inside a
   bump, not for a release).

### Release work and durable decisions

The [0.1.0 milestone](https://github.com/mizchi/vibe-lang/milestone/2) is the
current release scope; [#2834](https://github.com/mizchi/vibe-lang/issues/2834)
owns the candidate's final acceptance evidence. Settle before the tag:

- Comparison witness semantics and derived implementations (#2523), including
  the existing fail-closed restrictions until dispatch is correct.
- Synchronous capability grants and host/provider ABI (#2828, #1962, #1346).
  #2828 tracks the newer instantiate-time proposal recorded by #2825; the
  ADR amendment is in PR #2811, which was still open at the 2026-09-15 audit.
  A branch decision is not a claim about current production lowering.
- Package/contract identity formats (#2829), public naming and constructor
  qualification (#2830), and the ownership surface (#2392).
- Stable-surface correctness, actionable diagnostics (#2820, #2831, #2199),
  and bounded quality improvements such as Array reservation (#2554), memo
  limits (#2521), builtin classification (#2584), and gate reachability (#2592).

The document organization work (#2002, #2565, #2566, #2567) has prepared branch
changes; it is complete only when those changes are reviewed and merged. Keep
the public contract and the book current as each release decision lands.

Internal compiler optimization is tracked separately by
[#2833](https://github.com/mizchi/vibe-lang/issues/2833), under the
[Backlog (unscheduled) milestone](https://github.com/mizchi/vibe-lang/milestone/4).
The 128 MiB per-unit compiler, per-module production prelude, complete TypeEnv
nodes, and broader body relocation are measured backlog, not implicit
prerequisites for 0.1.0.
Preserve the existing cold/warm selfhost metrics and choose additional CI
observation according to its cost; do not require a new expensive benchmark
lane merely to complete this inventory.

### What 0.2.0 holds

The [0.2.0 milestone](https://github.com/mizchi/vibe-lang/milestone/3) holds all
remaining async work: #1537, #2064, #2065, #2066, #2221, #2500 and #2832, plus
the async half of the standard-effect metadata migration (#1963). Existing async
APIs remain unstable in 0.1.0.

1. **Shared-nothing structured concurrency** — `Task` bound to a generative
   nursery, typed channels, `Send`, cooperative cancellation as the public
   model ([ADR-0068 detail](../design/concurrency.md)). JSPI + Worker, the WASI Component
   Model, and shared-everything threads are interchangeable lowerings of that
   semantics; none of them is a blocker. #488 stays an opt-in probe until its
   intrinsic/type gaps and the backend differential gate are resolved.
2. **A type system designed for formalization** — the redesign that follows the
   type-soundness ADR series, aimed at a specification that can be mechanically
   checked.
3. **A dedicated agent harness** — for AI agents writing and verifying vibe.
   Its predecessor, the language evaluation loop `eval/lang-review/`, already
   runs.

---

## Where the detail lives

This file answers one question: **what has to be true for the next release.**
It stays short because every other kind of detail has a better home:

| you want | read |
| --- | --- |
| why a design is the way it is | [adr.md](../design/adr.md) |
| what is being worked on now | GitHub Issues (`gh issue list --state open`) |
| how a decision was reached | the issue thread, and `git log` |
| what the language can do today | [cheatsheet.md](../../user/reference/cheatsheet.md), [book/en](../../../book/en) |
| what 0.1.0 promises not to break | [spec/stable-surface.md](../../user/reference/stable-surface.md) |
| how to prioritise an issue | [issue-triage.md](issue-triage.md) |
