#!/usr/bin/env python3
"""vibe_md.py — executable-docs harness for *.vibe.md (#1142).

Extracts ```vibe fenced code blocks from a markdown file, compiles+runs
each one with the selfhost stage2 compiler, and for ```vibe run blocks
embeds the captured stdout into an adjacent ```output block — so a
*.vibe.md file's prose, code and shown results cannot drift apart.

Usage:
  python3 scripts/vibe_md.py check <file.vibe.md> [more...]   # verify (default gate; exits 1 on drift)
  python3 scripts/vibe_md.py write <file.vibe.md> [more...]   # run + rewrite ```output blocks in place

Block classification (info string on the opening ```vibe fence), same
convention as scripts/doctest_extract_run.sh:
  ```vibe        compile-check only (entry __no_entry__)         [default]
  ```vibe run    compile (entry _start) + execute; stdout captured
  ```vibe skip   excluded from verification (put the reason in a leading
                 comment on the block's first line)

A ```vibe run block must export `_start` (`with { Stdout }` etc. as
needed). The immediately following ```output fenced block (blank lines in
between are allowed; anything else breaks the association) holds the
embedded stdout:
  - `write` mode creates or updates it to match the actual run.
  - `check` mode compares actual stdout to it; a missing or stale ```output
    block is a FAIL (docs must show real output, not stale/omitted output).

Imports resolve as if the block's file sat at the repo root (a `lib`
symlink is placed in the scratch dir), matching doctest_extract_run.sh —
cross-package names need the package-style form (`import @vibe/prelude { .. }`),
not a relative path into another package (#729).

Env:
  VIBE_MD_STAGE2   compiler wasm to use. Default: newest
                   _build/selfhost/generations/*/stage2.wasm (by mtime),
                   falling back to bootstrap/seed/compiler.wasm.
  VIBE_MD_WORKDIR  scratch dir for extracted sources / wasm (default
                   _build/vibe_md/<pid>)
  VIBE_MD_KEEP=1   keep the work dir (default: removed on exit)
  VIBE_MD_TIMEOUT  per-block compile/run timeout in seconds (default 120)
"""
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FENCE_RE = re.compile(r"^(`{3,})\s*(\S*)\s*(.*)$")


def resolve_stage2():
    env = os.environ.get("VIBE_MD_STAGE2", "").strip()
    if env:
        return env
    gens_dir = os.path.join(ROOT, "_build/selfhost/generations")
    if os.path.isdir(gens_dir):
        candidates = []
        for name in os.listdir(gens_dir):
            gen_dir = os.path.join(gens_dir, name)
            wasm = os.path.join(gen_dir, "stage2.wasm")
            if os.path.isfile(wasm) and os.path.getsize(wasm) > 0:
                candidates.append((os.path.getmtime(gen_dir), wasm))
        if candidates:
            candidates.sort(reverse=True)
            return candidates[0][1]
    return os.path.join(ROOT, "bootstrap/seed/compiler.wasm")


class Block:
    """A fenced code block, recorded with its raw source lines (inclusive of fences)."""

    def __init__(self, lang, arg, start_line, code_lines):
        self.lang = lang
        self.arg = arg
        self.start_line = start_line  # 1-based line of the first code line
        self.code_lines = code_lines
        self.mode = None  # "check" | "run" | "skip" | None (not a vibe block)
        # populated during processing:
        self.compile_ok = None
        self.reason = None
        self.actual_stdout = None


def parse_blocks(text):
    """Split markdown text into a flat list of tokens:
    ('text', line) for ordinary lines, or ('block', Block) for a fenced block
    (vibe or otherwise — non-vibe fences are kept as opaque 'other' blocks so
    write-mode can reproduce them byte-for-byte via their own code_lines,
    fence marker included).
    """
    lines = text.splitlines()
    tokens = []
    i = 0
    n = len(lines)
    while i < n:
        m = FENCE_RE.match(lines[i])
        if not m:
            tokens.append(("text", lines[i]))
            i += 1
            continue
        fence = m.group(1)
        lang = m.group(2)
        arg = m.group(3).strip()
        open_line = lines[i]
        start_line = i + 2
        body = []
        j = i + 1
        closed = False
        while j < n:
            if re.match(r"^%s\s*$" % re.escape(fence), lines[j]):
                closed = True
                break
            body.append(lines[j])
            j += 1
        if not closed:
            # unterminated fence: treat rest of file as plain text, don't crash
            tokens.append(("text", lines[i]))
            i += 1
            continue
        close_line = lines[j]
        blk = Block(lang, arg, start_line, body)
        blk.open_line = open_line
        blk.close_line = close_line
        if lang == "vibe":
            if arg.startswith("run"):
                blk.mode = "run"
            elif arg.startswith("skip"):
                blk.mode = "skip"
            else:
                blk.mode = "check"
        elif lang == "output":
            blk.mode = "output"
        tokens.append(("block", blk))
        i = j + 1
    return tokens


def link_run_output_pairs(tokens):
    """Forward scan: associate each run-mode vibe block with an immediately
    following (blank lines only in between) unconsumed ```output block.
    Returns dict: id(run_block) -> output_block or None.
    """
    pairs = {}
    consumed = set()
    for idx, (kind, blk) in enumerate(tokens):
        if kind != "block" or blk.mode != "run":
            continue
        j = idx + 1
        while j < len(tokens):
            k2, b2 = tokens[j]
            if k2 == "text" and b2.strip() == "":
                j += 1
                continue
            break
        out_blk = None
        if j < len(tokens):
            k2, b2 = tokens[j]
            if k2 == "block" and b2.mode == "output" and id(b2) not in consumed:
                out_blk = b2
                consumed.add(id(b2))
        pairs[id(blk)] = out_blk
    return pairs


def sh(cmd, env=None, timeout=None):
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, env=env, timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        return 124, "", f"timeout after {timeout}s"


def link_sibling_dir(md_path, workdir):
    """Blocks are extracted straight into workdir's root (matching
    doctest_extract_run.sh), so a block's `./foo` import resolves against
    workdir, not against md_path's real directory. Symlink every non-.md
    sibling of md_path into workdir (idempotent) so relative imports to a
    doc's own support files (e.g. docs/tutorial/support/mathx.vibe) still
    resolve the same way they would for a real file living next to the doc.
    """
    src_dir = os.path.dirname(os.path.abspath(md_path))
    for name in os.listdir(src_dir):
        if name.endswith(".md"):
            continue
        link = os.path.join(workdir, name)
        if os.path.islink(link) or os.path.exists(link):
            continue
        os.symlink(os.path.join(src_dir, name), link)


def process_file(md_path, workdir, compiler, timeout, results):
    with open(md_path, encoding="utf-8") as f:
        text = f.read()
    tokens = parse_blocks(text)
    pairs = link_run_output_pairs(tokens)
    link_sibling_dir(md_path, workdir)

    base = re.sub(r"[^A-Za-z0-9_]", "_", os.path.splitext(os.path.basename(md_path))[0])
    n = 0
    for kind, blk in tokens:
        if kind != "block" or blk.mode not in ("check", "run", "skip"):
            continue
        n += 1
        label = f"{md_path}:{blk.start_line}"
        if blk.mode == "skip":
            results.append((label, "SKIP", None, blk))
            continue

        n_str = f"{n:02d}"
        src = os.path.join(workdir, f"{base}_b{n_str}_L{blk.start_line:04d}.vibe")
        with open(src, "w", encoding="utf-8") as f:
            f.write("\n".join(blk.code_lines) + "\n")
        out = src[:-len(".vibe")] + ".wasm"
        entry = "_start" if blk.mode == "run" else "__no_entry__"

        env = dict(os.environ)
        env["VIBE_PREOPEN_DIR"] = ROOT
        env["VIBE_FS_COMPILE"] = "1"
        env["VIBE_IMPORT_ABI"] = "raw"
        rc, cout, cerr = sh(
            ["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
             compiler, src, out, entry],
            env=env, timeout=timeout,
        )
        compile_ok = rc == 0 and os.path.getsize(out) > 0 if os.path.exists(out) else False
        if not compile_ok:
            diag_path = out + ".diag"
            reason = ""
            if os.path.exists(diag_path):
                with open(diag_path, encoding="utf-8", errors="replace") as f:
                    reason = f.readline().strip()
            if not reason:
                for l in (cout + cerr).splitlines():
                    if l.strip():
                        reason = l.strip()
                        break
            results.append((label, "FAIL", f"[compile] {reason or 'compile failure'}", blk))
            continue

        if blk.mode == "check":
            results.append((label, "PASS", None, blk))
            continue

        # run mode: invoke _start, capture stdout only (kept separate from
        # stderr on purpose — stdout is exactly what gets embedded).
        run_env = dict(os.environ)
        run_env["VIBE_PREOPEN_DIR"] = ROOT
        rc, rout, rerr = sh(
            ["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "_start", out],
            env=run_env, timeout=timeout,
        )
        if rc != 0:
            reason = ""
            for l in rerr.splitlines():
                low = l.lower()
                if "error" in low or "trap" in low or "unreachable" in low or "abort" in low:
                    reason = l.strip()
                    break
            if not reason:
                tail = [l for l in rerr.splitlines() if l.strip()]
                reason = tail[-1] if tail else "runtime failure"
            results.append((label, "FAIL", f"[run] {reason}", blk))
            continue

        blk.actual_stdout = rout
        out_blk = pairs.get(id(blk))
        expected = None
        if out_blk is not None:
            expected = "\n".join(out_blk.code_lines)
            if out_blk.code_lines:
                expected += "\n"
        actual = rout
        if expected is None:
            results.append((label, "FAIL", "[output] missing ```output block after ```vibe run (run `write` mode to generate it)", blk))
        elif expected != actual:
            diff = "\n".join(difflib.unified_diff(
                expected.splitlines(), actual.splitlines(),
                fromfile="embedded ```output", tofile="actual stdout", lineterm="",
            ))
            results.append((label, "FAIL", f"[output] embedded output is stale:\n{diff}", blk))
        else:
            results.append((label, "PASS", None, blk))

    return tokens, pairs


def rewrite_file(md_path, tokens, pairs):
    # A ```output block paired to a run block gets its content replaced IN
    # PLACE, at its own position in the token stream, rather than re-emitted
    # inline from the run block's branch -- reordering would separate it
    # from the blank line that used to precede it, doubling it up with the
    # blank line that used to follow, on every write. The run block (always
    # earlier in document order) stashes the new content on its paired
    # output block's `_replacement` attr; by the time the loop reaches that
    # output token, the replacement is already there.
    paired_output_ids = {id(ob) for ob in pairs.values() if ob is not None}
    out_lines = []
    for kind, blk in tokens:
        if kind == "text":
            out_lines.append(blk)
            continue
        # kind == "block"
        if blk.mode == "output" and id(blk) in paired_output_ids:
            out_lines.append(blk.open_line)
            out_lines.extend(getattr(blk, "_replacement", blk.code_lines))
            out_lines.append(blk.close_line)
            continue
        out_lines.append(blk.open_line)
        out_lines.extend(blk.code_lines)
        out_lines.append(blk.close_line)
        if blk.mode == "run" and blk.actual_stdout is not None:
            content_lines = blk.actual_stdout.splitlines()
            existing = pairs.get(id(blk))
            if existing is not None:
                existing._replacement = content_lines
            else:
                out_lines.append("")
                out_lines.append("```output")
                out_lines.extend(content_lines)
                out_lines.append("```")
    new_text = "\n".join(out_lines) + "\n"
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(new_text)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "write"):
        print(__doc__, file=sys.stderr)
        return 2
    mode = sys.argv[1]
    md_files = sys.argv[2:]

    compiler = resolve_stage2()
    if not os.path.isfile(compiler) or os.path.getsize(compiler) == 0:
        print(f"vibe_md: compiler wasm not found: {compiler}", file=sys.stderr)
        return 2

    workdir = os.environ.get("VIBE_MD_WORKDIR") or os.path.join(ROOT, "_build/vibe_md", str(os.getpid()))
    os.makedirs(workdir, exist_ok=True)
    compiler_copy = os.path.join(workdir, "compiler.wasm")
    shutil.copyfile(compiler, compiler_copy)
    lib_link = os.path.join(workdir, "lib")
    if os.path.islink(lib_link) or os.path.exists(lib_link):
        os.remove(lib_link)
    os.symlink(os.path.join(ROOT, "lib"), lib_link)

    timeout = int(os.environ.get("VIBE_MD_TIMEOUT", "120"))

    print(f"vibe_md: mode={mode} compiler={compiler}")
    total = 0
    fail = 0
    skipped = 0
    failures = []
    try:
        for md_path in md_files:
            if not os.path.isfile(md_path):
                print(f"vibe_md: no such file: {md_path}", file=sys.stderr)
                return 2
            results = []
            tokens, pairs = process_file(md_path, workdir, compiler_copy, timeout, results)
            if mode == "write":
                rewrite_file(md_path, tokens, pairs)
            for label, status, reason, blk in results:
                total += 1
                if status == "SKIP":
                    skipped += 1
                    print(f"SKIP  {label}")
                elif status == "FAIL":
                    if mode == "write" and reason and reason.startswith("[output]"):
                        # write mode just regenerated it — the write above
                        # already fixed staleness/missing blocks. Only a
                        # genuine compile/run failure stays fatal.
                        print(f"WROTE {label}")
                    else:
                        fail += 1
                        failures.append(f"{label} {reason}")
                        print(f"FAIL  {label} {reason}")
                else:
                    print(f"PASS  {label}")
    finally:
        if os.environ.get("VIBE_MD_KEEP", "0") != "1":
            shutil.rmtree(workdir, ignore_errors=True)

    print()
    print(f"vibe_md: {total} blocks — {total - fail - skipped} pass, {fail} fail, {skipped} skip")
    if fail > 0:
        print("vibe_md: failing blocks:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
