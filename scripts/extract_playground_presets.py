#!/usr/bin/env python3
"""Extract the vibe source of each playground preset.

`playground/src/main.ts` holds its starter programs as TypeScript template
literals inside `const PRESETS: Preset[] = [...]`. This writes each one to its
own `.vibe` file under WORKDIR and prints a `<path>\t<id>` manifest, so
`scripts/check_playground_presets.sh` can type-check them.

usage: extract_playground_presets.py <main.ts> <workdir>
"""

import os
import re
import sys


def extract(text):
    """Yield (id, source) for every preset entry, in file order."""
    for m in re.finditer(r'id:\s*"([^"]+)"\s*,\s*source:\s*`', text):
        pid = m.group(1)
        i = m.end()
        buf = []
        # Read to the first UNESCAPED backtick, so a preset that contains an
        # escaped one still lands whole rather than being truncated at it.
        while i < len(text):
            c = text[i]
            if c == "\\":
                buf.append(text[i:i + 2])
                i += 2
                continue
            if c == "`":
                break
            buf.append(c)
            i += 1
        else:
            sys.exit(
                "[playground-presets] unterminated template literal for preset %r" % pid
            )
        yield pid, "".join(buf)


def main(argv):
    if len(argv) != 3:
        sys.exit("usage: extract_playground_presets.py <main.ts> <workdir>")
    src, work = argv[1], argv[2]
    with open(src, encoding="utf-8") as f:
        text = f.read()

    n = 0
    for pid, body in extract(text):
        if "${" in body:
            # The source is emitted verbatim; there is nothing here that could
            # resolve a TypeScript interpolation, and writing it out unresolved
            # would report a parse error against a line the file never contains.
            sys.exit(
                "[playground-presets] preset %r interpolates TypeScript (${...}); "
                "this extractor emits source verbatim and cannot resolve it" % pid
            )
        n += 1
        slug = re.sub(r"[^A-Za-z0-9_]", "_", pid)
        path = os.path.join(work, "preset_%02d_%s.vibe" % (n, slug))
        with open(path, "w", encoding="utf-8") as f:
            f.write(body + "\n")
        print("%s\t%s" % (path, pid))

    if n == 0:
        sys.exit(
            "[playground-presets] no presets matched -- did the PRESETS shape change?"
        )


if __name__ == "__main__":
    main(sys.argv)
