# eval — measurable loops for the language and its docs

Each directory is one question. A round writes a score file and a findings
file. The rubric's definitions stay fixed, so a later round can be compared
with an earlier one. Adding a dimension is allowed. Changing what an existing
dimension means is not.

Historical score JSON is a record of that round. Do not edit it when the
language moves. Write a new round.

| Suite | Question | Last scored | Scores |
| --- | --- | --- | --- |
| [lang-review](lang-review/README.md) | Is vibe usable as a language, independent of the book? Eight frozen dimensions. | 2026-08-13 r6, commit `47d021d` | `lang-review/scores/` |
| [book-review](book-review/README.md) | Does [the book](../book/en/) teach the language that ships, and is a reader who strays told the edit? Chapter loop or full read (`run_loop.sh`). | 2026-09-24. r5 is a partial book round. Chapter files are the ledger (`run_loop.sh status`). A pass is not a book score until every chapter is current. | `book-review/scores/` |
| [call-style](call-style/README.md) | Which call spelling can a reader recover with the least context? | 2026-07-28 r1 | `call-style/scores/` |
| [msr](msr/README.md) | After a second change, do the tests still pass? | 2026-07-22 r1 | `msr/scores/` |
| [lang-bench](lang-bench/README.md) | Same prompt, several languages. Relative, not absolute. | 2026-07-22 r1 | `lang-bench/results/` |

lang-review r6 is not a description of this checkout. Re-run it before citing
those numbers. book-review r5 read the equality chapters and the cheatsheet
sections they contradict. It did not re-run probes and it did not score the
other chapters. `book-review/coverage.md` says which chapters a later round
still has to read.

## What a round is not allowed to do

- Score a dimension the round did not measure. Use `"measured": false` and
  leave the score null. Do not copy the previous number into a new file and
  call it current. lang-review's carry-forward (`measured: false` plus the
  old number, labelled with the round it came from) is the exception, and
  only inside that suite.
- Measure with the committed seed, or with whatever `stage2.wasm` happens to
  be newest on disk. `scripts/resolve_stage2.sh`'s `resolve_stage2_strict`
  is the resolver that refuses both. `vibe check` is the type-check verb.
  `vibe diagnostics` is the deprecated alias.
- Treat `docs/internal/design/decisions.md`'s "marker-only, no trait methods"
  bullet as the current trait model. The builtin `Eq` dispatches (#2523).
  That file is a locked list that has not been revised.

## Gates that already cover part of this

`scripts/vibe_md.sh` checks `vibe run` blocks against their output.
`pkf run check-tutorial-translation-parity` checks that the English and
Japanese books run the same programs. Neither reads the prose. book-review
exists for that gap. lang-review's `run_golden.sh` and `run_repair.sh` are
in the compiler gate. The other suites are not, because a missing attempt
is not a failed build.
