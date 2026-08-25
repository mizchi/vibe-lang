# vibe release roadmap

> The version ladder is ADR-0109; this file is the working detail behind it.
> Design decisions go in [adr.md](adr.md), tasks in GitHub Issues.

## Version ladder

The repository has published **exactly one** version tag: `v0.0.1`
(2026-04-14, from the retired MoonBit host). Every other number that appears in
older documents — "0.1.0 sign-off", "0.2.0", "0.3.0 GA" — was a label in a
document, never a release. The ladder below numbers releases by what actually
ships.

| version | meaning | state |
| --- | --- | --- |
| `v0.0.1` | The one historical release (MoonBit host era) | tagged 2026-04-14 |
| `0.0.x` | Everything since: the selfhost cutover and all development, including the content once prepared as "0.3.0 GA" ([archive/release-notes-0.3.0.md](archive/release-notes-0.3.0.md)) | never released |
| **`0.1.0`** | **The first release usable by anyone but the author** | target; see [release-notes-0.1.0.md](release-notes-0.1.0.md) |
| `0.2.0` | Structured concurrency, a type system aimed at formalization, a dedicated agent harness | after 0.1.0 |
| `1.0.0` | Maturity. Not a synonym for the first public release | unscheduled |

Until the `0.1.0` tag is cut, `runtime/vibe` reports `0.1.0-dev`.
`scripts/build_release_assets.sh` requires `VIBE_VERSION` to equal the tag being
built, so a release cannot ship carrying `-dev`, and
`scripts/check_version_ladder.sh` keeps this table, the launcher, and the
release notes from drifting apart.

The stable surface that the `0.1.0` tag freezes is
[spec/stable-surface.md](spec/stable-surface.md) (ADR-0057). While the toolchain
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
   [spec/stable-surface.md](spec/stable-surface.md) §3 resolves in the shipped
   compiler (`pkf run check-freeze-surface`).
5. **Editor integration** — `vibe lsp` plus the query primitives
   (`vibe check` / `symbols` / `type-at` / `binding-at` / `deps` / `grep`).
6. **Apache License 2.0.** The `0.1.0` tag is the first release usable by
   anyone but the author; it does not ship under MIT.

### What 0.2.0 holds

1. **Shared-nothing structured concurrency** — `Task` bound to a generative
   nursery, typed channels, `Send`, cooperative cancellation as the public
   model ([ADR-0068 detail](concurrency.md)). JSPI + Worker, the WASI Component
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
| why a design is the way it is | [adr.md](adr.md) |
| what is being worked on now | GitHub Issues (`gh issue list --state open`) |
| how a decision was reached | the issue thread, and `git log` |
| what the language can do today | [cheatsheet.md](cheatsheet.md), [book/en](../book/en) |
| what 0.1.0 promises not to break | [spec/stable-surface.md](spec/stable-surface.md) |
| how to prioritise an issue | [issue-triage.md](issue-triage.md) |
