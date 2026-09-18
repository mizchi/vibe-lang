# Frozen bench corpus (#2865)

Four byte-for-byte copies of real sources, read by the lex, parse and format
benchmark series in `lib/@vibe/compiler/*_bench.vibe`.

| file | copy of | bytes |
|---|---|---:|
| `small.vibe.txt` | `lib/@vibex/url/url.vibe` | 6.5 K |
| `lexer.vibe.txt` | `lib/@vibe/parser/lexer.vibe` | 53 K |
| `parser.vibe.txt` | `lib/@vibe/parser/parser.vibe` | 66 K |
| `checker.vibe.txt` | `lib/@vibe/compiler/checker/checker.vibe` | 532 K |

Each snapshot carries a ~950-byte banner, which is why the formatter's small
tier reads a 6.5 K source rather than the 438-byte file it used to: at that
size the corpus would have been 69% banner and the series would mostly have
measured comment handling.

`PROVENANCE.tsv` records each snapshot's source path, its sha256, its byte
count, the revision it was taken at, and the live source file's digest at that
moment.

The **sha256 is the identity** — it is what `--check` verifies, and it is what
survives a squash merge. `taken_at` is provenance only: this repository
squash-merges, so the commit a snapshot was cut from is rewritten and the
recorded SHA becomes unreachable. `source_sha256` is what answers "was this copy
faithful?" without needing that commit to exist.

## Why the copies exist

The series read the live files. A benchmark that is supposed to measure the
**parser** therefore took its **input** from whatever the checked-out tree held,
so every PR that edited the checker moved it. Measured on one compiler with only
the corpus swapped, across a single checker PR that grew `checker.vibe` by 9.7%:

| input | `parse_checker_vibe` B/op | `parse_only_checker_vibe` B/op |
|---|---:|---:|
| before | 4,926,112 | 2,340,328 |
| after | 5,780,608 (+17.3%) | 2,507,800 (+7.2%) |

The perf report flags a bytes-per-op move with a ⚠️, and that is the signal a
reviewer acts on. Every checker PR of any size tripped it, and a real parser
regression landing in the same PR as a checker edit was indistinguishable from
corpus growth. A measurement that cannot tell those apart is not one.

## Rules

- **Nothing imports or compiles these files.** The `.vibe.txt` extension keeps
  them out of every sweep that walks `*.vibe`, and keeps a stale copy of
  `checker.vibe` from turning up in a grep for live code as if it were live.
- **Do not edit them** — not to fix a warning, not to reformat, not to keep them
  in step with the source. That is the whole defect. `check_bench_corpus.sh`
  fails on any content change that `PROVENANCE.tsv` does not record.
- **Bumping resets the series.** Every bytes-per-op number taken before a bump is
  about a different input, so the pipeline's history across it is not a
  comparison.

## Bumping

```bash
bash scripts/bump_bench_corpus.sh          # freeze only MISSING snapshots
bash scripts/bump_bench_corpus.sh --all    # re-freeze every snapshot (a BUMP)
bash scripts/bump_bench_corpus.sh --check  # verify digests only
```

It rewrites the banners and `PROVENANCE.tsv` together, which is what lets the
gate tell a bump from an edit.

**The default is additive, and that is load-bearing.** Adding the fourth entry
re-froze the other three the first time it was tried, because `main` had changed
`checker.vibe` in between — silently resetting two series the change was not
about. Only `--all` is a bump.

Bump when the frozen program has drifted far enough from real code to stop
representing it — not to silence a flag, and never in a PR whose own numbers are
being read, because the bump and the change would move the series together.
Say so in the PR: the series restarts, and a reader comparing across the bump is
comparing two different questions.
