# book-review — read-through evaluation of The Vibe Book

A repeatable scenario: read `book/en/` cover to cover the way a new user
would, record what the documents alone leave unclear or contradictory,
then measure each open question against the current compiler and grade
the diagnostics it produced. The output of a round is a findings file
plus a probe corpus that keeps the measured questions re-checkable.

This complements `eval/lang-review/`: lang-review starts from *tasks*
(write a program from a spec), book-review starts from *the book* (does
the narrative teach the language that actually ships, and does the
compiler answer well when a reader strays from the happy path).

## Structure

```
eval/book-review/
  README.md        # this file (how to run a round)
  probes/          # one .vibe file per measured question, self-describing header
  run_probes.sh    # compile/run every probe against the CURRENT stage2
  rounds/          # findings per round: <date>-rN.md
```

## Running a round

1. **Doc-only pass.** Read `book/en/` in `SUMMARY.md` order **without
   consulting the implementation**. Record, per chapter: claims a reader
   cannot verify from the book, spellings that conflict between
   chapters, and questions the text raises but never answers. This pass
   is the point of the scenario — do not skip ahead to the compiler,
   because knowing the answer changes what looks unclear.
2. **Probe pass.** Turn every *testable* question into a probe in
   `probes/`. A probe is a minimal `.vibe` file with a header comment
   naming the chapter, the question, and what the book led you to
   expect. One question per file.
3. **Measure.** Build a stage2 for this checkout (`pkf run generation` /
   `bash scripts/generations.sh build`), then:

   ```bash
   # from the repo root
   bash eval/book-review/run_probes.sh                                  # all probes
   bash eval/book-review/run_probes.sh eval/book-review/probes/p01_*    # one probe
   ```

   The script refuses to fall back to the committed seed silently — the
   subject is the current compiler's behavior and diagnostic text, so
   the compiler that answers must be the current one (the
   "which compiler answered?" trap; see `eval/lang-review/run_golden.sh`).
4. **Record.** Write `rounds/<date>-rN.md` with two sections: the
   doc-only findings, and the measured outcomes with a diagnostic
   quality grade per probe. Grade what the *reader who wrote that
   mistake* would experience:
   - **actionable** — the message names the edit that fixes it
   - **located** — it points at the right file position
   - **honest** — it does not claim something false about the program
5. **File and fix.** Real findings become GitHub issues (triaged per
   `docs/issue-triage.md`) or direct doc fixes. A book sentence
   contradicted by measurement is a bug in the book (its own
   introduction says so).
6. **Next round.** Re-read the chapters that changed, re-run the
   probes, append a new round file. Keep probe filenames stable across
   rounds so outcomes are comparable; add new probes rather than
   repurposing old ones.

## Probe conventions

- `probes/pNN_<slug>.vibe` — NN is stable across rounds.
- The header comment states: chapter, question, doc-derived expectation.
- Probes that are *expected* to fail to compile are still ordinary
  `.vibe` files — `run_probes.sh` reports compile failure plus the
  diagnostic, which is the measurement, not an error in the harness.
- Artifacts go to `_build/evalprobe-book/` (gitignored).

## Relation to the book's own gates

`scripts/vibe_md.sh check` proves the book's own examples run. It
proves nothing about the prose or about what happens *off* the shown
path — this scenario is for exactly that gap.
