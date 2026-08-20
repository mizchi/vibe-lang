#!/usr/bin/env bash
# #2121: docs/cheatsheet.md's "Signature reference" tables, checked against the
# CHECKER's own builtin table instead of against a second hand-written copy.
#
# AGENTS.md sends every reader to the cheatsheet first, and doctest only
# compiles its ```vibe blocks -- it is blind to a table. Two kinds of drift are
# invisible without this:
#
#   1. a documented signature whose arity no longer matches the builtin
#   2. a name documented AS a builtin that is really a library function needing
#      an import. Calling one of those bare is `unknown name: X`, which reads to
#      a newcomer as a broken install rather than a missing import.
#
# (2) is not hypothetical: the caveat paragraph named `String::replace` and
# `String::replace_all` while `trim_start`, `trim_end` and `count` sat in the
# same tables, undistinguished, in the same state.
#
# The paragraph is the ONE authoritative list. This gate requires it to name
# exactly the documented non-builtins -- no more, no less -- so it cannot drift
# in either direction: a name that becomes a builtin must leave the paragraph,
# and a new library function must join it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DOC="docs/cheatsheet.md"
PROBE="scripts/cheatsheet_signature_probe.vibe"

STAGE2="${CHEATSHEET_SIG_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -f "$STAGE2" ] || { echo "cheatsheet-signatures: CHEATSHEET_SIG_STAGE2=$STAGE2 does not exist" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "${STAGE2:-}" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "cheatsheet-signatures: no compiler available" >&2; exit 1; }
fi

# Under the preopen dir, because the probe reads this path from inside wasm.
WORK="$ROOT_DIR/_build/_cheatsheet_sig"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fails=0
bad() { printf 'cheatsheet-signatures: FAIL: %s\n' "$1" >&2; fails=1; }

python3 - "$DOC" > "$WORK/pairs.tsv" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
try:
    start = next(i for i, l in enumerate(lines) if l.startswith("### Signature reference"))
    end = next(i for i, l in enumerate(lines) if i > start and l.startswith("## "))
except StopIteration:
    sys.exit(0)
for l in lines[start:end]:
    if not l.startswith("|"):
        continue
    cells = [c.strip() for c in l.strip().strip("|").split("|")]
    if len(cells) < 2:
        continue
    names = re.findall(r'`([A-Za-z_][A-Za-z0-9_]*::[A-Za-z0-9_]+)`', cells[0])
    sigs = re.findall(r'`(\([^`]*\)\s*->\s*[^`]+)`', cells[1])
    if len(names) == 1 and len(sigs) >= 1:
        pairs = [(names[0], sigs[0])]
    elif len(names) > 1 and len(sigs) == 1:
        pairs = [(n, sigs[0]) for n in names]
    elif len(names) > 1 and len(names) == len(sigs):
        pairs = list(zip(names, sigs))
    else:
        continue
    for n, s in pairs:
        print(f"{n}\t{s}")
PY

pair_count="$(grep -c '' "$WORK/pairs.tsv" || true)"
if [ "${pair_count:-0}" -lt 20 ]; then
  bad "extracted only ${pair_count:-0} name/signature pairs from $DOC -- the tables moved or changed shape, so this gate is asserting nothing"
  exit 1
fi

rm -f "$WORK/probe.wasm" "$WORK/probe.wasm.diag"
env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$PROBE" "$WORK/probe.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$WORK/probe.wasm" ]; then
  echo "cheatsheet-signatures: FAIL: the probe did not compile" >&2
  head -3 "$WORK/probe.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
env VIBE_PREOPEN_DIR="$ROOT_DIR" CHEATSHEET_SIG_INPUT="_build/_cheatsheet_sig/pairs.tsv" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$WORK/probe.wasm" \
  > "$WORK/actual.tsv" 2>/dev/null || true
if [ ! -s "$WORK/actual.tsv" ]; then
  echo "cheatsheet-signatures: FAIL: the probe produced no output" >&2
  exit 1
fi

# The caveat paragraph: the one authoritative list of documented non-builtins.
python3 - "$DOC" "$WORK/actual.tsv" <<'PY' || exit 1
import re, sys
doc = open(sys.argv[1], encoding="utf-8").read()

def arity(sig):
    m = re.match(r'\s*\(([^)]*)\)', sig)
    if not m:
        return None
    inner = m.group(1).strip()
    if inner == "":
        return 0
    depth, n = 0, 1
    for ch in inner:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            n += 1
    return n

# An explicit marker, not a prose match: the paragraph's wording is free to
# change (and to be translated) without silently emptying this set, which would
# make the check pass by asserting nothing.
MARK = "<!-- import-required-builtins:"
mi = doc.find(MARK)
if mi < 0:
    print("cheatsheet-signatures: FAIL: the <!-- import-required-builtins --> marker is gone from "
          "the document; without it this gate cannot tell which names are declared library functions",
          file=sys.stderr)
    sys.exit(1)
after = doc[doc.index("-->", mi) + 3:]
# The paragraph is the first non-empty block after the marker.
block = ""
for para in after.split("\n\n"):
    if para.strip():
        block = para
        break
listed = set(re.findall(r'`([A-Za-z_][A-Za-z0-9_]*::[A-Za-z0-9_]+)`', block))
if not listed:
    print("cheatsheet-signatures: FAIL: the import-required-builtins paragraph names no "
          "`Type::fn` at all, so this gate would accept anything", file=sys.stderr)
    sys.exit(1)

nonbuiltin, mismatch, compared = set(), [], 0
for line in open(sys.argv[2]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        continue
    name, docsig, actual = parts
    if actual == "<not a builtin>":
        nonbuiltin.add(name)
        continue
    compared += 1
    ad, aa = arity(docsig), arity(actual)
    if ad != aa:
        mismatch.append((name, docsig, actual, ad, aa))

fails = 0
for name, d, a, ad, aa in mismatch:
    print(f"cheatsheet-signatures: FAIL: {name} documented as {d} ({ad} args) but the checker says {a} ({aa} args)", file=sys.stderr)
    fails = 1

missing = sorted(nonbuiltin - listed)
extra = sorted(listed - nonbuiltin)
if missing:
    print("cheatsheet-signatures: FAIL: documented as a signature but NOT a builtin, and not named in the import caveat:", file=sys.stderr)
    for n in missing:
        print(f"    {n}   (calling it bare is `unknown name: {n}`)", file=sys.stderr)
    fails = 1
if extra:
    print("cheatsheet-signatures: FAIL: the import caveat names these, but the checker says they ARE builtins now:", file=sys.stderr)
    for n in extra:
        print(f"    {n}   (drop it from the caveat)", file=sys.stderr)
    fails = 1

if fails:
    sys.exit(1)
print(f"cheatsheet-signatures: ok ({compared} builtin signatures match by arity; "
      f"{len(nonbuiltin)} documented library functions all named in the import caveat)")
PY
