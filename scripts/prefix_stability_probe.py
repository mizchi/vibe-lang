#!/usr/bin/env python3
"""Measure codegen prefix-stability across a one-file edit (#2388).

Per-module codegen caching can only replay a cached function body when a
program edit leaves that body byte-identical.  This probe measures how true
that is today: it compiles an entry twice -- as-is, and with one appended
test block (a minimal "leaf edit") -- then diffs the two output wasms
function body by function body at identical indices.

Usage:
  python3 scripts/prefix_stability_probe.py <stage2.wasm> [entry.vibe]

Named functions pair by NAME and lambdas by their offset from each side's
`run` boundary (the +1 user function shifts every later raw index, so a
same-index comparison would invent diffs).  Exits 0 when nothing but the
`_start`/`run` entry glue differs across the one-test edit -- appending a
test must leave every existing body byte-identical once the index spaces
are pinned; any named or lambda body that differs is a failure.  The probe
forces VIBE_WASM_NAMES=1 on its compiles and fails closed if names are
still missing.

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
        # Attribution below reads the OUTPUT's name section; make sure the
        # compile emits one regardless of the ambient strip default.
        VIBE_WASM_NAMES="1",
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
        # imports resolve identically. mkstemp gives exclusive creation with
        # a unique name, so a stale sibling is never truncated and
        # concurrent probe runs cannot clobber each other's input.
        with open(entry) as f:
            src = f.read()
        fd, tweak_abs = tempfile.mkstemp(
            dir=os.path.dirname(entry),
            prefix="__prefix_probe_",
            suffix="_test.vibe",
        )
        # The runner resolves paths relative to VIBE_PREOPEN_DIR (the repo
        # root), so hand it the repo-relative spelling, not mkstemp's
        # absolute one.
        tweak = os.path.relpath(tweak_abs)
        with os.fdopen(fd, "w") as f:
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
    print(f"bodies: {len(bodies_a)} vs {len(bodies_b)}")

    # The appended test is one extra user function, and everything emitted
    # after the user block (_start, run, every lambda body) shifts by one
    # index in the candidate -- a same-index comparison would then match the
    # baseline's first lambda against the candidate's `run` and each lambda
    # against its predecessor, reporting spurious diffs for byte-identical
    # bodies. So nothing here compares by raw index: named functions pair by
    # NAME, and lambdas pair by their offset from each side's own `run`
    # boundary.
    #
    # Fail closed on missing names: with no name section nothing can be
    # paired, and the probe must say so rather than certify prefix stability
    # it never checked. Unverified and safe must not look alike.
    def named_bodies(wasm, bodies):
        imports = fn_import_count(wasm)
        names = fn_names(wasm)
        by_name = {}
        run_body = None
        for idx, nm in names.items():
            body_idx = idx - imports
            if 0 <= body_idx < len(bodies):
                by_name[nm] = body_idx
                if nm == "run":
                    run_body = body_idx
        return by_name, run_body

    by_name_a, run_a = named_bodies(A, bodies_a)
    by_name_b, run_b = named_bodies(B, bodies_b)
    if not by_name_a or not by_name_b or run_a is None or run_b is None:
        print(
            "FAIL: name section (or the `run` entry glue) is missing from an "
            "output -- nothing can be attributed; ensure the compile emits "
            "names (the probe sets VIBE_WASM_NAMES=1 itself, so this points "
            "at a naming gap in the output)"
        )
        return 1

    # Named functions, paired by name. `_start`/`run` embed entry-dependent
    # counts and always differ; they are reported informationally only.
    # Attribution: #716 renames every exported def of a non-entry file to
    # name_exp_<sanitized path> / name_dep_<sanitized path> (no `lib/`
    # anchor -- a fixtures/ entry pulls `_exp_fixtures_...`), so a mangling
    # marker means a module OTHER than the edited entry. Marker-less names
    # are the entry's own defs plus compiler-synthesized helpers
    # (comparators, specializations) -- those still count as failures, since
    # an unchanged synthesized body shifting means the tail is not pinned.
    shared = [nm for nm in by_name_a if nm in by_name_b]
    only_a = [nm for nm in by_name_a if nm not in by_name_b]
    only_b = [nm for nm in by_name_b if nm not in by_name_a]
    glue = {"_start", "run"}
    named_diffs = []
    for nm in shared:
        if bodies_a[by_name_a[nm]] != bodies_b[by_name_b[nm]]:
            named_diffs.append(nm)
    glue_diffs = [nm for nm in named_diffs if nm in glue]
    foreign = [nm for nm in named_diffs if nm not in glue and ("_exp_" in nm or "_dep_" in nm)]
    local = [nm for nm in named_diffs if nm not in glue and nm not in foreign]
    print(
        f"named: {len(shared)} paired by name, {len(named_diffs)} differ "
        f"({len(foreign)} foreign, {len(local)} entry/synthesized, "
        f"{len(glue_diffs)} entry glue); only-in-baseline {len(only_a)}, "
        f"only-in-candidate {len(only_b)} (the probe's own test is expected here)"
    )
    if only_a:
        print(f"  names only in baseline (unexpected): {only_a[:5]}")

    def diff_shape(nm):
        a, b = bodies_a[by_name_a[nm]], bodies_b[by_name_b[nm]]
        if len(a) != len(b):
            return f"len {len(a)}->{len(b)}"
        nd = sum(1 for j in range(len(a)) if a[j] != b[j])
        return f"{nd} byte(s)"

    for nm in foreign[:10]:
        print(f"  foreign diff: {nm[:90]}: {diff_shape(nm)}")
    for nm in local[:10]:
        print(f"  entry/synthesized diff: {nm[:90]}: {diff_shape(nm)}")

    # Lambda bodies carry no names; pair them by offset from each side's own
    # `run` boundary. The probe's appended test must not add lambdas, so a
    # count mismatch is a probe-corpus problem, not a stability verdict.
    lam_a = bodies_a[run_a + 1 :]
    lam_b = bodies_b[run_b + 1 :]
    if len(lam_a) != len(lam_b):
        print(
            f"FAIL: lambda counts differ ({len(lam_a)} vs {len(lam_b)}) -- the "
            f"probe edit must stay lambda-free for the regions to pair"
        )
        return 1
    lambda_diffs = [k for k in range(len(lam_a)) if lam_a[k] != lam_b[k]]
    print(f"lambdas: {len(lam_a)} paired by offset from run, {len(lambda_diffs)} differ")

    if foreign or local or lambda_diffs:
        print(
            f"FAIL: {len(foreign)} foreign named bodies, {len(local)} "
            f"entry/synthesized named bodies, and {len(lambda_diffs)} lambda "
            f"bodies differ across the one-test edit"
        )
        return 1
    print("ok: only the entry glue differs across the one-test edit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
