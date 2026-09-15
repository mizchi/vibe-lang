#!/usr/bin/env bash
# #2758: the gc backend's host-import list is encoded in FIVE places, and they
# must agree. Nothing checked that they do.
#
#   use_host      the || chain of used-builtin lookups that gates the block
#   host_defs     (name, params, ABSOLUTE import index, ret) per builtin
#   host_imports  (import name, type index) in the emitted order
#   the vector header literal  bytebuf_push_vec_header(imp_content, N)
#   hbo           the count, which every generated body index is offset by
#
# Disagreement is not a compile error -- it is a module that fails to
# instantiate, and the two failures look nothing alike:
#
#   vector header too low  "section was shorter than expected size
#                           (513 bytes expected, 491 decoded)"
#   hbo too low            "Compiling function #46 failed: not enough arguments
#                           on the stack for call (need 1, got 0)"
#
# Both were measured while adding ONE import in #2758, and the file's own
# comment already recorded a third occurrence from an earlier change -- it said
# FOUR places, having missed the vector header. A comment that has been wrong
# once is what this replaces.
#
# This reads the SOURCE, not a compiler, so it costs nothing and needs no
# generation. It is lexical on purpose: the question "do these literals agree"
# is answerable that way, where "is the emitted module well formed" is not.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SRC="${GC_HOST_IMPORT_COUNTS_SRC:-lib/@vibe/compiler/codegen/gc/backend_body.vibe}"
[ -f "$SRC" ] || { echo "gc-host-import-counts: FAIL: no such file: $SRC" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="replace").read()
fails = []

def die(msg):
    fails.append(msg)

# --- hbo -------------------------------------------------------------------
m = re.search(r"let hbo = if use_host \{\s*(\d+)\s*\}", src)
if not m:
    die("could not find `let hbo = if use_host { N }` -- the gate cannot read "
        "this file any more, which is UNCHECKED, not ok. Update the gate.")
    hbo = None
else:
    hbo = int(m.group(1))

# --- the vector header literal ---------------------------------------------
m = re.search(r"bytebuf_push_vec_header\(imp_content,\s*(\d+)\)", src)
if not m:
    die("could not find `bytebuf_push_vec_header(imp_content, N)`. Update the gate.")
    vec = None
else:
    vec = int(m.group(1))

# --- host_imports ----------------------------------------------------------
m = re.search(r"let host_imports = \[(.*?)\n    \]", src, re.S)
if not m:
    die("could not find the `host_imports` array. Update the gate.")
    imports = None
else:
    imports = re.findall(r'\("([^"]+)",\s*(\d+)\)', m.group(1))

# --- host_defs -------------------------------------------------------------
m = re.search(r"let host_defs = \[(.*?)\n    \]", src, re.S)
if not m:
    die("could not find the `host_defs` array. Update the gate.")
    defs = None
else:
    defs = re.findall(r'\("([^"]+)",\s*(\d+),\s*(\d+),\s*(\d+)\)', m.group(1))

if hbo is not None and imports is not None and len(imports) != hbo:
    die(f"hbo is {hbo} but host_imports has {len(imports)} entries. "
        f"Every generated body index is offset by hbo, so a low hbo makes the "
        f"module fail to instantiate with \"not enough arguments on the stack "
        f"for call\". Set hbo to {len(imports)}.")

if hbo is not None and vec is not None and vec != hbo + 1:
    die(f"the import vector header is {vec} but hbo is {hbo}; it must be "
        f"hbo + 1 = {hbo + 1} (the host imports plus fd_write). A low header "
        f"makes the module fail to instantiate with \"section was shorter than "
        f"expected size\".")

if defs is not None and hbo is not None:
    idxs = sorted(int(d[2]) for d in defs)
    if idxs != list(range(1, len(idxs) + 1)):
        dupes = sorted({i for i in idxs if idxs.count(i) > 1})
        die(f"host_defs import indices are not 1..N with no gaps: got {idxs}"
            + (f"; repeated: {dupes}" if dupes else ""))
    elif idxs and idxs[-1] != hbo:
        die(f"host_defs' highest import index is {idxs[-1]} but hbo is {hbo}. "
            f"These index the same list, so they must end at the same number.")

if fails:
    for f in fails:
        print(f"gc-host-import-counts: FAIL: {f}", file=sys.stderr)
    sys.exit(1)

print(f"gc-host-import-counts: ok (hbo={hbo}, host_imports={len(imports)}, "
      f"vector header={vec}, host_defs indices 1..{max(int(d[2]) for d in defs)})")
PY
