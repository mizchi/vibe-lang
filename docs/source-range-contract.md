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

## Known deviations

Two, both in `vibe grep --json`, both #1941 leftovers:

- `start` / `end` bound the match's **anchor token**, not the `text` field. For
  a match whose `text` is `ident(1)`, the range slices `ident`. Slicing by the
  reported range does not return the reported text.
- a capture is `{"text": ..., "start": ...}` with **no `end`**, so it cannot be
  sliced at all. `start` is `-1` for a capture with no recorded offset.

An offset-less span is reported as `-1` (JSON) or `<synthetic>` (`vibe grep`
text, #2035), and a still-unlocated diagnostic as the empty LSP range `0:0-0:0`
with `data.synthetic: true` (#2050). Those are the honest markers; a plausible
`0:0` is not one, and none of the surfaces above emit one any more.
