#!/usr/bin/env python3
"""Patch helper for scripts/vibe_inspect_update.sh (#1061 follow-up).

`inspect(value, content)` (lib/@vibe/core/assert.vibe) prints
    inspect mismatch:
      actual:   <ACTUAL>
      expected: <EXPECTED>
and then traps on a mismatch. This script reads that captured stdout on
stdin, re-escapes <EXPECTED> into vibe's string-literal syntax (matching
lib/@vibe/compiler/fmt/format.vibe's write_escaped_char rules: \\, ", \\n,
\\t, \\r) to find the exact `content` literal currently sitting in the
source file (first occurrence), and replaces it with the re-escaped
<ACTUAL>.

No AST/CST span tracking is used -- EString carries no byte offset today,
so this is a plain textual first-occurrence replacement, not a
position-based patch. Two inspect() calls in the same file with
byte-identical `content` only get the first one patched per invocation;
scripts/vibe_inspect_update.sh's outer loop re-converges across
iterations since each run's trap always surfaces the next distinct
mismatch. A run whose <ACTUAL> text itself contains the literal
substring "\\n  expected: " defeats the block parser below.

Prints "patched" and rewrites the file on success, "no-match" (file left
untouched) when the captured output has no recognizable mismatch block
or the expected literal cannot be found verbatim in the source.
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


def quote(text):
    return '"' + "".join(ESCAPES.get(c, c) for c in text) + '"'


def main():
    if len(sys.argv) != 2:
        print("usage: vibe_inspect_update_patch.py <source.vibe> < captured_stdout", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    captured = sys.stdin.read()
    m = MISMATCH_RE.search(captured)
    if not m:
        print("no-match")
        return
    actual, expected = m.group(1), m.group(2)
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    old_lit = quote(expected)
    idx = src.find(old_lit)
    if idx < 0:
        print("no-match")
        return
    new_lit = quote(actual)
    patched = src[:idx] + new_lit + src[idx + len(old_lit):]
    with open(path, "w", encoding="utf-8") as f:
        f.write(patched)
    print("patched")


if __name__ == "__main__":
    main()
