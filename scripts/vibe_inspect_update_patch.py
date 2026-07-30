#!/usr/bin/env python3
"""Patch helper for scripts/vibe_inspect_update.sh (#1061 follow-up).

`inspect(value, content)` (lib/@vibe/core/assert.vibe) prints
    inspect mismatch:
      actual:   <ACTUAL>
      expected: <EXPECTED>
and then traps on a mismatch. This script reads that captured stdout on
stdin, re-escapes <EXPECTED> into vibe's string-literal syntax (matching
lib/@vibe/compiler/fmt/format.vibe's write_escaped_char rules: \\, ", \\n,
\\t, \\r) and finds the `content` argument it corresponds to.

The search is scoped to actual `inspect(...)` call sites (#1235 review,
P1): for each call, the string literal immediately before its closing
`)` is its `content` argument; only that position is eligible for
replacement. A whole-file substring search would instead rewrite the
first UNRELATED string literal with the same text anywhere in the file
(e.g. `let label = "old"` above `inspect(value, "old")`), silently
corrupting a value that has nothing to do with the snapshot.

No AST/CST span tracking is used -- EString carries no byte offset
today, so locating the call's argument list is done with a small
string-literal-aware paren scanner (find_call_end below), not a real
parse. Two DISTINCT inspect() calls with byte-identical `content` still
can't be told apart by text alone; the first one (in file order) is
patched, and scripts/vibe_inspect_update.sh's outer loop re-converges
across iterations since each run's trap surfaces the next distinct
mismatch. A run whose <ACTUAL> text itself contains the literal
substring "\\n  expected: " defeats the block parser below.

Prints "patched" and rewrites the file on success, "no-match" (file left
untouched) when the captured output has no recognizable mismatch block
or no `inspect(...)` call's content argument matches the expected text.
"""
import re
import sys

ESCAPES = {
    "\\": "\\\\",
    "\"": "\\\"",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}

MISMATCH_RE = re.compile(
    r"inspect mismatch:\n  actual:   (.*?)\n  expected: (.*)\Z", re.S
)

INSPECT_CALL_RE = re.compile(r"\binspect\s*\(")


def quote(text):
    return '"' + "".join(ESCAPES.get(c, c) for c in text) + '"'


def find_call_end(src, open_paren_idx):
    """Given the index of an `inspect(`'s opening `(`, return the index
    just past its matching `)`, skipping over paren/comma characters that
    appear inside nested string literals. Returns -1 if unbalanced."""
    i = open_paren_idx
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == "\\" else 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def find_content_arg_span(src, old_lit):
    """Return (start, end) of the FIRST inspect(...) call (in file order)
    whose content argument is exactly `old_lit`, or None."""
    for m in INSPECT_CALL_RE.finditer(src):
        open_idx = m.end() - 1
        call_end = find_call_end(src, open_idx)
        if call_end < 0:
            continue
        call_text = src[open_idx:call_end]
        # content is the LAST argument -> the rightmost occurrence of
        # old_lit inside this call, immediately (mod whitespace) before
        # the closing paren.
        pos = call_text.rfind(old_lit)
        if pos < 0:
            continue
        if not re.match(r"\s*\)\Z", call_text[pos + len(old_lit):]):
            continue
        abs_start = open_idx + pos
        return (abs_start, abs_start + len(old_lit))
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: vibe_inspect_update_patch.py <source.vibe> < captured_stdout", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    captured = sys.stdin.read()
    # println() (lib/@vibe/core/assert.vibe's inspect()) appends exactly one
    # trailing "\n" terminator after the whole diagnostic; strip only that
    # one so a snapshot value that itself legitimately ends in "\n" (#1235
    # review, P2) isn't truncated -- group(2) below runs to end-of-string.
    if captured.endswith("\n"):
        captured = captured[:-1]
    m = MISMATCH_RE.search(captured)
    if not m:
        print("no-match")
        return
    actual, expected = m.group(1), m.group(2)
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    span = find_content_arg_span(src, quote(expected))
    if span is None:
        print("no-match")
        return
    start, end = span
    patched = src[:start] + quote(actual) + src[end:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(patched)
    print("patched")


if __name__ == "__main__":
    main()
