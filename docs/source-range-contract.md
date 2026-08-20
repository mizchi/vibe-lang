# Source ranges: one contract for the editor query surface

Every command under [Code Navigation](../CLAUDE.md) reports positions, and until
this document they never said what a position *means*. The result was not a gap
in the docs but a wrong statement in them: [editor-and-debugging.md](editor-and-debugging.md)
called `vibe symbols` and `vibe binding-at` offsets "char offsets" while the
implementation has always emitted **byte** offsets. On ASCII the two agree,
which is why the claim survived; one multi-byte comment above the code and
slicing by the reported range returns different text.

This page is the contract. It is measured, not designed — every row was read
off the shipped compiler, and
`lib/@vibe/compiler/tests/source_range_contract_test.vibe` slices the source by
each reported range and compares it to the token that range names, so the page
cannot drift back into being a claim.

## The rule

**A vibe source position is a byte position.** `String` is a byte string with
byte-offset indexing (ADR-0098), the parser records byte offsets, and every
query surface passes them through unconverted. Two spellings of the same thing:

- **offsets** — `START END`, a 0-based half-open byte interval. `substring(src,
  START, END)` is the token.
- **line/column** — 1-based line, 1-based **byte** column. `\r` is line content,
  so CRLF does not shift a column.

## Per surface

| surface | what it reports | unit | base | interval |
|---|---|---|---|---|
| `vibe symbols` | `NAME KIND START END` | byte offset | 0 | half-open |
| `vibe binding-at` | `START END` per occurrence | byte offset | 0 | half-open |
| `vibe escapes` | `NAME START END` | byte offset | 0 | half-open |
| `vibe allocs` | `FN SITE OFFSET` | byte offset | 0 | point |
| `vibe check` (text) | `line L:C-E:` | line, byte column | 1 | half-open |
| `vibe grep` (text) | `path:L:C:` | line, byte column | 1 | point |
| `vibe grep --json` | `line`, `col`, `start`, `end` | line + byte column, byte offset | 1 / 0 | see below |
| `vibe type-at` **in** | `<line> <col>` | line, byte column | 1 | — |
| `vibe binding-at` **in** | `<line> <col>` | line, byte column | 1 | — |

`vibe rc-classify` and `vibe rc-plan` report no positions at all.

This table is enforced. `scripts/check_source_range_contract.sh`
(`pkf run check-source-ranges`) probes every row against a source with two
4-byte emoji to the LEFT of the position under test, so the byte, codepoint and
UTF-16 columns are three different numbers — on an ASCII fixture all three
agree and the check would prove nothing, which its self-test pins as a failure.

## The one deliberate exception: LSP

`vibe check --single-file --json` and the `vibe lsp` server emit **LSP**
positions — 0-based lines, and columns in **UTF-16 code units**, per the
protocol. That is not this contract leaking; it is the boundary doing its job.
`lib/@vibe/lsp/lsp_server.vibe` converts in both directions
(`lsp_pos_to_byte_col`, `lsp_byte_col_to_utf16`) so the compiler underneath
stays byte-addressed.

Measured on `let bad = quux` preceded on the same line by two 4-byte emoji:

```
$ vibe check --single-file f.vibe
error: line 2:33-37: unknown name: quux                     # byte column 33

$ vibe check --single-file --json f.vibe
[{"range":{"start":{"line":1,"character":28}, ...            # UTF-16 unit 28
```

Byte 32, codepoint 26, UTF-16 unit 28 — three different numbers for one
position. Both outputs are right for their audience.

## What this means for a caller

**An editor must convert.** A client that computes a UTF-16 or codepoint column
and passes it to `vibe type-at` / `vibe binding-at` is asking about a
*different, earlier* position — the difference is exactly the continuation
bytes to its left. The commands do not error: they answer about the position
they were given. Empty output then reads as "nothing here", which is the CLI's
own spelling of *clean*, so the mistake is silent. Going through `vibe lsp`
instead is the way to avoid doing the conversion yourself.

## `vibe grep` ranges are a lower bound

`vibe grep` is the one surface whose range you cannot slice with, and the reason
is structural rather than a bug in the reporting.

**Only identifier-shaped AST nodes carry an offset.** `EInt`, `EFloat`,
`EString`, `EBool`, `EUnit` and `EStringInterp` carry none at all, so
`grep_expr_span` — which takes the min and max over the offsets it can find in
the matched subtree — cannot see a literal, and never sees punctuation. What it
returns is a **lower bound** on the match's true extent, and `text` is the
printer's canonical re-rendering of the matched node, not a slice of the file.
The two do not have to agree, and generally do not:

```vibe
fn add(a: Int, b: Int) -> Int {
  a + b
}

fn f() -> Int {
  let one = 1
  let two = 2
  add(one, two) + add(1, 2)
}
```

```
$ vibe grep --json --pattern 'add($(a:args))' span.vibe
{"start":89,"end":101,"synthetic":false,"text":"add(one, two)","captures":{"a":{"text":"one, two","start":93}}}
{"start":105,"end":108,"synthetic":false,"text":"add(1, 2)","captures":{"a":{"text":"1, 2","start":null}}}
```

The first range stops at 101, the end of `two` — one byte short of the closing
`)`, so slicing gives `add(one, two`. The second collapses to `add` (105–108),
because both operands are literals and neither is visible to the span. `start`
is exact in both; only `end` is short.

A capture goes one step further: it carries `start` and **no `end`**, so it
cannot be sliced at all, and `start` is `null` when the bound node has no
recorded offset — the literal case above. It used to render `-1`, chosen over
`0` so the output would not invent a plausible offset. Right intent, wrong
type: `-1` is still a *number*, and a consumer slicing `src[start:]` on it
reads from the end of the file rather than failing.

A match with NO recorded offset at all reports `null` in all four position
fields and `"synthetic":true` — the JSON spelling of what the text lane writes
as `<synthetic>` in place of `line:col`. The two output modes are checked
against each other by `scripts/check_source_range_contract.sh` (check 11), not
each against its own copy of the answer. JSON used to render `-1` in those
fields, with the same defect as the capture-level `-1` below: a number where an
offset goes.

`text` is a **printed form, not a source slice** (measured 2026-08-19).
`f( a  +  b )` captures as `(a + b)` — parens added, whitespace runs collapsed —
so `src[start : start + length(text)]` is not the captured source, and an `end`
cannot be derived from the text either. That is why the capture reports no
`end` rather than a computed one.

So: **`start` is a position you can trust, `end` is a floor, and `text` is the
description.** To recover the real extent you must re-lex; `lex_with_offsets`
already returns exact token starts *and* ends, which is why the fix is spans on
the AST nodes rather than better arithmetic here. `parse_program_spans` already
does exactly that for statements and is the precedent to follow.

Tracked as #1941 (the range) and #1943 (the capture range, "captures also lack
complete source ranges"). Pinned as measured behaviour, so the numbers above
cannot drift without a test failing.

An offset-less span is reported as `null` for a capture and `-1` for a hit
span (JSON), or `<synthetic>` (`vibe grep` text, #2035), and a still-unlocated diagnostic as the empty LSP range `0:0-0:0`
with `data.synthetic: true` (#2050). Those are the honest markers; a plausible
`0:0` is not one, and none of the surfaces above emit one any more.

## Every type error carries a position

A diagnostic with **no** position fails this contract more completely than one
in the wrong unit: there is nothing for a client to convert. Two shapes used to
escape, both because a literal value carries no offset slot in the AST:

- a **local** `let a: Int = "x"` — closed by anchoring the synthetic ascription
  call on the binder name (`ascribe_wrap`),
- a **top-level** `let a: Int = "x"` — closed by tagging the binder name with
  the `[@fn=NAME]` side channel, which `find_fn_anchor_off` already resolved for
  `fn name` *and* `let name`. The top-level lane keeps its annotation on `SLet`
  rather than going through `ascribe_wrap`, which is why it needed the second
  mechanism rather than the first.

The value's own offset still wins wherever it exists — `let a: Int = f()`
reports at `f()`, because that is where the edit goes. The binder is only the
fallback. Both are pinned by `scripts/check_source_range_contract.sh` checks 9
and 10, the second of which asserts the *failing* binder is named rather than
the first `let` in the file.
