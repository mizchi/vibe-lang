"""Embed one ordered batch of compiler sources using the existing wire format."""

import os
import re
import sys


def render_sources(mode, records):
    if mode not in ("raw", "filtered") or len(records) % 3:
        raise ValueError("expected raw/filtered mode and binding/path/file triples")
    pattern = re.compile(r"^\s*(?:import|export)\s+\.[\w./\s-]+")
    for i in range(0, len(records), 3):
        binding, relpath, filepath = records[i:i + 3]
        with open(filepath, "r", encoding="utf-8") as source:
            content = source.read()
        # Relative imports are resolved by collect_merged_stmts. Contract
        # imports are declarations for the conformance desugar and stay raw.
        if mode == "filtered" and not filepath.endswith((".vibei", ".vpkg")):
            lines = []
            skipping = False
            depth = 0
            for line in content.splitlines(True):
                if line.lstrip().startswith("//"):
                    continue
                if not skipping and pattern.match(line):
                    depth = line.count("{") - line.count("}")
                    skipping = depth > 0
                    continue
                if skipping:
                    depth += line.count("{") - line.count("}")
                    if depth <= 0:
                        skipping = False
                    continue
                lines.append(line)
            content = "".join(lines)
        content = content.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        yield f'let {binding} = () -> (String, String) {{\n  ("{relpath}",\n"{content}")\n}}\n\n'


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: bundle_source_functions.py raw|filtered")
    records = os.fsdecode(sys.stdin.buffer.read()).split("\0")
    if records[-1] != "":
        raise ValueError("source records must end with a NUL separator")
    for function in render_sources(sys.argv[1], records[:-1]):
        sys.stdout.write(function)
