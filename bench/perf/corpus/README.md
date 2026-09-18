# Frozen bench corpus (#2865)

Three byte-for-byte copies of compiler sources, read by the lex and parse
benchmark series in `lib/@vibe/compiler/{lexer,parser}_bench.vibe`.

| file | copy of | role |
|---|---|---|
| `lexer.vibe.txt` | `lib/@vibe/parser/lexer.vibe` | small |
| `parser.vibe.txt` | `lib/@vibe/parser/parser.vibe` | medium |
| `checker.vibe.txt` | `lib/@vibe/compiler/checker/checker.vibe` | large |

`PROVENANCE.tsv` records each snapshot's source path, the revision it was taken
at, its sha256 and its byte count.

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
bash scripts/bump_bench_corpus.sh          # re-freeze from today's sources
bash scripts/bump_bench_corpus.sh --check  # verify digests only
```

It rewrites the banners and `PROVENANCE.tsv` together, which is what lets the
gate tell a bump from an edit.

Bump when the frozen program has drifted far enough from real code to stop
representing it — not to silence a flag, and never in a PR whose own numbers are
being read, because the bump and the change would move the series together.
Say so in the PR: the series restarts, and a reader comparing across the bump is
comparing two different questions.
