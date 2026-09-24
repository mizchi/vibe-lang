# book-review rubric

Five dimensions, each 1–5. Frozen across rounds. Add a dimension if a round
cannot express a finding. Do not redefine an existing one.

This rubric does not replace `eval/lang-review/rubric.md`. lang-review asks
whether the language is usable when the only reference is the cheatsheet.
This one asks whether the book teaches that language, and whether the book,
the cheatsheet, and the Japanese translation agree on the facts a reader
would rely on.

Rounds 1–4 (2026-08-22 and 2026-08-23) predate this rubric. Do not invent
scores for them.

## Score bands

- **5** — A reader who trusts this text is not misled, and a deliberate
  mistake is answered with the edit.
- **4** — One minor staleness or one unanswered question. The happy path is
  true.
- **3** — Usable, with a known hole a careful reader can route around.
- **2** — A sentence a new reader will follow is false, or two surfaces
  teach opposite current facts.
- **1** — The text teaches a behavior that is silently wrong, or sends the
  reader to a document that no longer exists.

A round may score a dimension on a declared scope (a list of chapters, or
one cheatsheet section). The score is about that scope. It is not a
whole-book score unless `coverage.md` shows every chapter read in this
round or a carried round. Unread scope is `"measured": false` and `"score":
null`. Do not average unread chapters in as 5.

## Dimensions

### 1. prose_fidelity

Sentences that state what the compiler does are true of the current
compiler. A `vibe run` block is necessary and not sufficient: the prose
around it is the part no gate reads. A contradiction between a sentence and
a fixture, or between a sentence and a measurement the round ran, is a
defect. An unmeasured claim recorded as fact is a defect of the round, not
of the book — write it down as unchecked.

### 2. surface_agreement

One concept, one current fact, across `book/en/`, `book/ja/`, and
`docs/user/reference/cheatsheet.md`. The translation-parity gate checks that
the two books run the same programs. It does not check that the prose
teaches the same rule. A disagreement in which all three are wrong the same
way is prose_fidelity, not this dimension. This dimension is for surfaces
that contradict each other.

### 3. example_honesty

Every behavior the chapter asks the reader to rely on is either a `vibe run`
block with an `output` block, or a `vibe skip` block whose first line says
why it does not run and whose quoted diagnostic is what the current
compiler prints. A skip with no reason, or a quoted diagnostic the round
re-ran and did not see, costs a point. Do not score this dimension without
re-running the blocks in scope. The existing `vibe_md` gate is evidence for
`vibe run` blocks only.

### 4. learner_progression

Reading `book/SUMMARY.md` in order, each chapter uses only facts earlier
chapters taught, or it says it is looking ahead. Chapter 2 is allowed to
look ahead: its introduction says so. An unmarked use of a later concept,
or a forward pointer that never lands, is the defect. Score only chapters
the round actually read in order.

### 5. off_path_guidance

When the reader makes a mistake the chapter invites, the compiler's answer
is all three of: **actionable** (names the edit), **located** (points at
the right position), **honest** (does not say something false). The probe
corpus in `probes/` is the measurement. Each probe scores 0–3, one point
per property. The dimension score is `1 + 4 * (sum / (3 * n))`, rounded to
one decimal, on the probes the round re-ran. A probe that was not re-run
this round is not in `n`. An empty `n` is `"measured": false`.

## Two loops

The five dimensions above are what both loops score. A loop changes how
much of the book one run covers. It does not change what a point means.

### Chapter loop

One chapter, English and Japanese together. This is the edit loop.

```bash
bash eval/book-review/run_loop.sh check 16_equality   # links, fences, en/ja counts
# read the chapter, score, write scores/chapters/16_equality/<date>-rN.json
bash eval/book-review/run_loop.sh blob 16_equality    # paste blobs into that file
bash eval/book-review/run_loop.sh status
```

`check` is mechanical and exits 1 on a broken relative link, a
` ```vibe run ` with no ` ```output `, a ` ```vibe skip ` whose first line
is not `// skip`, or fence counts that differ between the languages. It
does not read prose. A green `check` is not a score.

The score file is `unit: "chapter"`. `blobs.en` and `blobs.ja` are
`git hash-object` of the two files (or `sha256:` when the tree is not
this repository). The next edit makes that file **stale**. Write a new
file. Do not edit the old one, and do not raise the score in the file
that describes the text you had not fixed yet.

`run_loop.sh status` is the ledger. `coverage.md` records the partial
r5 pass from before chapter files existed. It is not updated per chapter.

### Full read

A pass is the mean of **current** chapter scores. Current means the
blobs still match the files. A chapter with no file, a stale file, or an
unmeasured `prose_fidelity` / `surface_agreement` is a hole. The mean
does not include the hole, and it is not a book score until there is no
hole.

```bash
bash eval/book-review/run_loop.sh pass            # exit 2 while a chapter is open
bash eval/book-review/run_loop.sh pass --record   # writes scores/passes/ only when complete
```

`--record` needs `BOOK_REVIEW_DATE=YYYY-MM-DD`. Exit 1 means `check`
would fail. Exit 2 means the prose pass is incomplete. The other three
dimensions stay in the report with however many chapters measured them.
A null there does not by itself make the pass incomplete, because those
dimensions need a compiler run or a sequential re-read. Say so in the
chapter file. Do not fill them with 5.

`bash eval/book-review/run_loop_test.sh` mutates a fixture book and
checks that a broken chapter fails `check`, a stale blob is not counted,
and a pass with a hole exits 2.

## Running a round

1. Read `coverage.md`. Re-read every chapter whose source changed since
   `last_doc_pass`, plus any chapter never passed under this rubric. Do
   this before opening the compiler. Write down claims the book asserts
   and questions it raises but does not answer.
2. Check surface_agreement for those claims against the cheatsheet and the
   other language. A claim that survives that check and is still doubtful
   becomes a probe, not a guessed score.
3. Build a stage2 for this checkout and run `bash eval/book-review/run_probes.sh`.
   The script already refuses the seed and a stage2 from another commit.
4. Score only the dimensions the round measured. Write
   `scores/<date>-rN.json` and `rounds/<date>-rN.md`. Update `coverage.md`
   for the chapters actually read.
5. A false sentence is a bug in the book. Fix it in both languages in the
   same change, or file it. The score file records the text the round
   read. If the round also edits the book, say so, and do not raise the
   score inside that same file.

## Score file

```json
{
  "round": 5,
  "date": "2026-09-24",
  "commit": "<full sha>",
  "scope": ["book/en/16_equality.vibe.md"],
  "dimensions": {
    "prose_fidelity": {"score": 2, "measured": true, "rationale": "..."},
    "surface_agreement": {"score": 2, "measured": true, "rationale": "..."},
    "example_honesty": {"score": null, "measured": false, "rationale": "..."},
    "learner_progression": {"score": null, "measured": false, "rationale": "..."},
    "off_path_guidance": {"score": null, "measured": false, "rationale": "..."}
  },
  "notes": "one line"
}
```

## Reviewer prompt

> Read the chapters listed in this round's scope, in `book/SUMMARY.md`
> order, without consulting the compiler. Then check each behavioral claim
> against `docs/user/reference/cheatsheet.md` and `book/ja/` (or `book/en/`
> if you started from Japanese). Do not treat a cheatsheet sentence as true
> when a fixture in `fixtures/` or a test under `lib/@vibe/compiler/tests/`
> contradicts it — the fixture is the measurement, the sentence is a claim.
> Score with `eval/book-review/rubric.md`. Return only:
> `{"reviewer":"<name>","dimensions":{"<dim>":{"score":N|null,"measured":true|false,"rationale":"..."}},"findings":[{"severity":"major|minor","where":"path:line","summary":"...","evidence":"..."}]}`
> Do not edit the repository. Probes go in `_build/evalprobe-book/`.
