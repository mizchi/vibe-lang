#!/usr/bin/env python3
"""Measure codegen prefix-stability across a one-file edit (#2388).

Per-module codegen caching can only replay a cached function body when a
program edit leaves that body byte-identical.  This probe measures how true
that is today: it compiles an entry twice -- as-is, and with one appended
test block (a minimal "leaf edit") -- then diffs the two output wasms
function body by function body at identical indices.

Usage:
  python3 scripts/prefix_stability_probe.py <stage2.wasm> [entry.vibe]

Prints total/identical/differing body counts, the byte shape of the first
few diffs, and exits 0 when every differing body belongs to the edited
entry itself (perfect prefix stability), 1 otherwise.  It needs the entry
compiled with a name section to attribute diffs (VIBE_WASM_NAMES=1 builds).

History: before the lambda_slot_base capacity reservation
(codegen/wasi/linked_compile.vibe), a one-test edit of
codegen_lexer_test.vibe left only 3633/4214 bodies identical -- the other
581 differed by exactly one lambda-slot immediate, because slots were
anchored to the exact function count.
"""
import json
import os
import subprocess
import sys
import tempfile


def read_leb(b, i):
    r = 0
    s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            return r, i
        s += 7


def sections(b):
    i = 8
    while i < len(b):
        sid = b[i]
        i += 1
        sz, i0 = read_leb(b, i)
        yield sid, i0, sz
        i = i0 + sz


def code_bodies(b):
    for sid, off, _sz in sections(b):
        if sid == 10:
            i = off
            n, i = read_leb(b, i)
            bodies = []
            for _ in range(n):
                bs, i = read_leb(b, i)
                bodies.append(b[i : i + bs])
                i += bs
            return bodies
    return []


def fn_import_count(b):
    count = 0
    for sid, off, _sz in sections(b):
        if sid == 2:
            j = off
            n, j = read_leb(b, j)
            for _ in range(n):
                ml, j = read_leb(b, j)
                j += ml
                nl, j = read_leb(b, j)
                j += nl
                kind = b[j]
                j += 1
                if kind == 0:
                    _, j = read_leb(b, j)
                    count += 1
                elif kind == 1:
                    j += 1
                    flags = b[j]
                    j += 1
                    _, j = read_leb(b, j)
                    if flags & 1:
                        _, j = read_leb(b, j)
                elif kind == 2:
                    flags = b[j]
                    j += 1
                    _, j = read_leb(b, j)
                    if flags & 1:
                        _, j = read_leb(b, j)
                elif kind == 3:
                    j += 2
    return count


def fn_names(b):
    names = {}
    for sid, off, sz in sections(b):
        if sid == 0:
            j = off
            nl, j = read_leb(b, j)
            if b[j : j + nl] != b"name":
                continue
            j += nl
            end = off + sz
            while j < end:
                kind = b[j]
                j += 1
                ssz, j = read_leb(b, j)
                if kind == 1:
                    k = j
                    cnt, k = read_leb(b, k)
                    for _ in range(cnt):
                        idx, k = read_leb(b, k)
                        ln, k = read_leb(b, k)
                        names[idx] = b[k : k + ln].decode(errors="replace")
                        k += ln
                j += ssz
    return names


def compile_entry(stage2, entry, out_path):
    env = dict(os.environ)
    env.update(
        VIBE_PREOPEN_DIR=os.getcwd(),
        VIBE_FS_COMPILE="1",
        VIBE_IMPORT_ABI="raw",
    )
    subprocess.run(
        [
            "node",
            "scripts/wasm_vibe_host_runner.js",
            "--invoke",
            "cli_main",
            stage2,
            entry,
            out_path,
            "__no_entry__",
        ],
        env=env,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    stage2 = sys.argv[1]
    entry = (
        sys.argv[2]
        if len(sys.argv) > 2
        else "lib/@vibe/compiler/tests/codegen_lexer_test.vibe"
    )
    with tempfile.TemporaryDirectory() as td:
        # The tweaked entry must sit in the same directory so its relative
        # imports resolve identically.
        tweak = os.path.join(
            os.path.dirname(entry), "__prefix_probe_tweak_test.vibe"
        )
        with open(entry) as f:
            src = f.read()
        with open(tweak, "w") as f:
            f.write(src)
            f.write('\n\ntest "prefix stability probe" {\n  inspect(1 + 1, "2")\n}\n')
        wa = os.path.join(td, "a.wasm")
        wb = os.path.join(td, "b.wasm")
        try:
            compile_entry(stage2, entry, wa)
            compile_entry(stage2, tweak, wb)
        finally:
            os.unlink(tweak)
        A = open(wa, "rb").read()
        B = open(wb, "rb").read()
    bodies_a = code_bodies(A)
    bodies_b = code_bodies(B)
    imports = fn_import_count(A)
    names = fn_names(A)
    n = min(len(bodies_a), len(bodies_b))
    diffs = [i for i in range(n) if bodies_a[i] != bodies_b[i]]
    print(f"bodies: {len(bodies_a)} vs {len(bodies_b)}; compared {n}")
    print(f"identical at same index: {n - len(diffs)}/{n}; differing: {len(diffs)}")
    # Attribution: #716 renames every exported def of a non-entry file to
    # name_exp_<path> / name_dep_<path>, so a mangled name marks a body from a
    # module OTHER than the edited entry (entry defs are never renamed).
    foreign = []
    for i in diffs:
        nm = names.get(i + imports, "?")
        if "_exp_lib_" in nm or "_dep_lib_" in nm:
            foreign.append((i, nm))
    for i, nm in foreign[:15]:
        a, b = bodies_a[i], bodies_b[i]
        bd = [
            (j, a[j], b[j])
            for j in range(min(len(a), len(b)))
            if a[j] != b[j]
        ]
        shape = f"{len(bd)} byte(s)" if len(a) == len(b) else f"len {len(a)}->{len(b)}"
        print(f"  foreign diff: body {i} ({nm}): {shape}")
    if foreign:
        print(
            f"FAIL: {len(foreign)} differing bodies belong to modules other than the edited entry"
        )
        return 1
    print("ok: every differing body belongs to the edited entry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
