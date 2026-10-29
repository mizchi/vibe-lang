#!/usr/bin/env bash
# check_scripts_readme.sh -- every script scripts/README.md names is in the
# tree (#2001, the README half of the deletion ratchet).
#
# scripts/README.md is the index a reader uses instead of `ls | grep`, and it
# had drifted the way an unchecked list drifts: measured on the day this gate
# was written, it named four scripts that did not exist
# (`monitor_wasm_bundle_size.sh`, `precompile.sh`, `test_vibe_cli_install.sh`,
# and the #715 reproduction that #2001 had just deleted). A name for a script
# that is gone sends the reader to `ls` anyway, and it is the same defect as a
# stale row in docs/README.md, which check_doc_classification.sh already
# refuses. This gate asks the corresponding question of scripts/README.md.
#
# What counts as a name: a backticked token ending in a script extension
# (`.sh` `.mjs` `.js` `.cjs` `.py` `.vibex`) or in one of the data extensions
# scripts carry beside them (`.tsv` `.txt`), or a pattern containing `*` whose
# extension is one of those or absent. A token about something else
# (`*_test.vibe`, `lib/**/*.vibe`, `docs/x.md`) is not this gate's subject and
# is left alone. The README abbreviates deliberately and the gate reads every
# abbreviation it accepts rather than skipping it:
#
#   `test_vibe_{alloc_site,mem,bench}.sh`  one brace group, every member must exist
#   `test_check_*` / `*_test.sh`           a glob, at least one file must match
#   `lib/@vibe/cli/fmt_entry.vibe`         a path, resolved from the repo root
#
# A name resolves under `scripts/`, under one `scripts/<subdir>/`, or as given
# from the repo root. Nested braces are REFUSED rather than guessed at: a
# scanner that stays silent about what it cannot read is indistinguishable from
# one that checked it (AGENTS.md, #2248). A README from which no name at all
# parses fails too, for the same reason.
#
# The README is the only input read for names; the tree is only asked "is it
# there". The gate names itself in the README like any other script, and that
# row is checked like any other -- there is no list of exemptions.
#
# VIBE_SCRIPTS_README_ROOT points the scan at a different tree (the self-test's
# synthetic one, or the pre-commit hook's staged snapshot).
#
# Usage: bash scripts/check_scripts_readme.sh [--list]
#   --list  print every name the README yields and what it resolved to, exit 0.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

list_mode=0
[ "${1:-}" = "--list" ] && list_mode=1

exec python3 - "${VIBE_SCRIPTS_README_ROOT:-$repo_root}" "$list_mode" <<'PY'
import glob, io, os, re, sys

tree_root, list_mode = sys.argv[1], sys.argv[2] == "1"
readme_rel = "scripts/README.md"
readme_abs = os.path.join(tree_root, readme_rel)

if not os.path.isfile(readme_abs):
    print(f"scripts-readme: {readme_rel} is missing under {tree_root}", file=sys.stderr)
    sys.exit(2)

text = io.open(readme_abs, encoding="utf-8").read()

EXT = re.compile(r"\.(sh|mjs|js|cjs|py|vibex|tsv|txt)$")
OTHER_EXT = re.compile(r"\.[A-Za-z0-9]+$")
TOKEN = re.compile(r"^[A-Za-z0-9_@*][A-Za-z0-9_@*{},./-]*$")
BRACE = re.compile(r"\{([^{}]*)\}")

names = []  # (line number, token as written)
for lineno, line in enumerate(text.split("\n"), start=1):
    for span in re.findall(r"`([^`\n]+)`", line):
        tok = span.strip()
        if not TOKEN.match(tok):
            continue
        if EXT.search(tok):
            names.append((lineno, tok))
        elif "*" in tok and not OTHER_EXT.search(tok.replace("*", "")):
            # A pattern with no extension (`test_check_*`, `bench_rc.*`) is
            # about scripts; one ending in `.vibe` or `.md` is not.
            names.append((lineno, tok))

if not names:
    print(f"scripts-readme: parsed no script names out of {readme_rel}. The gate "
          "would pass by seeing nothing, so it fails instead -- check that names "
          "are still written in backticks", file=sys.stderr)
    sys.exit(2)


def expand(tok):
    """One brace group, expanded; nested braces are refused (None)."""
    if "{" not in tok and "}" not in tok:
        return [tok]
    if tok.count("{") != 1 or tok.count("}") != 1:
        return None
    m = BRACE.search(tok)
    if not m or tok.index("{") > tok.index("}"):
        return None
    return [tok[:m.start()] + alt + tok[m.end():] for alt in m.group(1).split(",")]


def resolve(name):
    """Where a literal name lives, or None."""
    candidates = [os.path.join("scripts", name), name]
    if "/" not in name:
        candidates += [
            os.path.relpath(p, tree_root)
            for p in sorted(glob.glob(os.path.join(tree_root, "scripts", "*", name)))
        ]
    for c in candidates:
        if os.path.isfile(os.path.join(tree_root, c)):
            return c
    return None


def matches(pattern):
    """Files a glob names, under scripts/ or from the root."""
    found = sorted(glob.glob(os.path.join(tree_root, "scripts", pattern)))
    found += sorted(glob.glob(os.path.join(tree_root, pattern)))
    return [os.path.relpath(f, tree_root) for f in found if os.path.isfile(f)]


fails = 0
literal_count = 0
glob_count = 0
for lineno, tok in names:
    members = expand(tok)
    if members is None:
        print(f"scripts-readme: FAIL: {readme_rel}:{lineno} `{tok}` has nested or "
              "unbalanced braces, which this gate does not read. Spell the names "
              "out, or use one brace group.", file=sys.stderr)
        fails += 1
        continue
    for name in members:
        if "*" in name:
            glob_count += 1
            hits = matches(name)
            if list_mode:
                print(f"{tok}\t{name}\t{len(hits)} match(es)")
            if not hits:
                print(f"scripts-readme: FAIL: {readme_rel}:{lineno} `{tok}` -- the "
                      f"pattern `{name}` matches no file under scripts/ or the "
                      "repo root. Repoint it, or delete the mention.", file=sys.stderr)
                fails += 1
            continue
        literal_count += 1
        where = resolve(name)
        if list_mode:
            print(f"{tok}\t{name}\t{where or '(missing)'}")
        if where is None:
            print(f"scripts-readme: FAIL: {readme_rel}:{lineno} names `{name}`"
                  f"{'' if name == tok else f' (from `{tok}`)'}, and nothing is "
                  "there. Repoint it to the script's current name, or delete the "
                  "mention if the script is gone -- git history is the archive.",
                  file=sys.stderr)
            fails += 1

if list_mode:
    sys.exit(0)

if fails:
    print(f"scripts-readme: {fails} problem(s). scripts/README.md is the index a "
          "reader uses instead of `ls`; a name for a script that is not there "
          "sends them to `ls` anyway.", file=sys.stderr)
    sys.exit(1)

print(f"scripts-readme: ok ({literal_count} names and {glob_count} patterns in "
      f"{readme_rel} all resolve)")
PY
