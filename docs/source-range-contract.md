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
| `vibe symbols` (batch) | `PATH NAME KIND START END` | byte offset | 0 | half-open |
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

## `vibe grep` ranges identify source occurrences

Matches and captures carry `start` and `end` as 0-based, half-open **byte**
offsets. The parser records the consumed tokens for each occurrence, including
literals and closing punctuation. For `let x = add(1, 2)`, the relevant JSON
fields are:

```json
{"start":8,"end":17,"synthetic":false,"text":"add(1, 2)","captures":{"a":{"text":"1","start":12,"end":13,"synthetic":false},"b":{"text":"2","start":15,"end":16,"synthetic":false}}}
```

Slicing the UTF-8 source bytes at `start:end` recovers `add(1, 2)`, `1`, and
`2`. Equal literals at different sites retain different ranges. Comments and
whitespace inside an occurrence belong to its range; surrounding trivia does
not. Grouping parentheses or a block around a call do not change that
call's occurrence: `(f(1))` matches `f(1)`. A surrounding expression that needs
those delimiters includes them, as in `(f(1))(2)` or `(1 + 2) * 3`.
A block containing a binding retains its whole scope: capturing the argument
of `f({ let n = 1; n + 2 })` slices to `{ let n = 1; n + 2 }`. An implicit
continuation introduced by binding lowering has no independently written
expression and is synthetic. The explicit `let*` pattern identifies the
binding statement itself.

`text` remains the printer's normalized representation. For `f( a  +  b )`,
the capture's text is `(a + b)` while its source slice is `a  +  b`. Never
compute an end from the length of `text`. A lowered construct can also print
differently from the source occurrence that produced it.

An `args` capture spans its contiguous source arguments, including the commas
and trivia between them. An empty capture has a zero-width range at the next
argument, or at the closing delimiter. Lowering can reorder arguments: in
`1 |> f(2)`, the captured positional values still slice to `1` and `2`, but
the combined lowered argument list `1, 2` has no contiguous source occurrence.
That list is synthetic.

Generated nodes with no source occurrence, and captures with no single source
interval, report `"start":null,"end":null,"synthetic":true`. For example,
the `true` arm generated by `value is None` is synthetic. A synthetic match
also reports `line` and `col` as `null`; the text lane writes `<synthetic>` in
place of `line:col`. Neither lane invents a position or emits a negative numeric
offset. A source literal such as `3 + 4` is located.

The tooling parser is opt-in (`parse_source_with_ranges`). Its source metadata
is independent of the compiler's identifier anchors and never reaches the
checker or code generator. Typed grep filters retain their existing checker
anchor contract: a literal's source range alone does not supply an inferred
type at a site where the checker has no anchor.

`grep_source_ranges_test.vibe` pins source slices, names, patterns, types,
interpolation, grouping, and generated nodes. The existing grep tests cover
source `perform`/`throw`, pattern diagnostics, typed filters, and skipped-file
warnings. `scripts/check_source_range_contract.sh` (check 11) verifies full
ranges through the CLI and compares synthetic output in text and JSON.

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
