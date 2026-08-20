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
# The reference documents roughly half its APIs in PROSE rather than tables
# (#2138 review): Array, Map, Record, JSON, Lines, the builders, assertions.
# Discarding every non-table line left those free to drift while this gate
# reported success.
#
# A bare name there takes its receiver from the most recent `X::` seen, else
# from the bolded heading. That is the heuristic #2124 warned about -- a
# receiver "sticking" across sub-sections -- so it is confined to THIS section
# and to a strict `NAME (args) -> ret` shape, and a qualified name re-anchors
# the receiver (which is what keeps ArrayBuilder's `freeze` from being read as
# MapBuilder's). It is checked, not trusted: every extracted name goes to
# `lookup_builtin`, and one that resolves to nothing is reported like any other.
HEADING_RECEIVER = {"Array": "Array", "Map": "Map", "JSON": "Json"}
recv = None
for l in lines[start:end]:
    if not l.startswith("|"):
        hm = re.match(r'\s*\*\*([^*]+)\*\*', l)
        if hm:
            recv = HEADING_RECEIVER.get(hm.group(1).strip())
        for m in re.finditer(r'`([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)?)\s*:?\s*(\([^`]*\)\s*->\s*[^`]+)`', l):
            nm, sig = m.group(1), m.group(2).strip()
            if "::" in nm:
                recv = nm.split("::")[0]
                print(f"{nm}\t{sig}")
            else:
                print(f"{recv + '::' + nm if recv else nm}\t{sig}")
        continue
    cells = [c.strip() for c in l.strip().strip("|").split("|")]
    if len(cells) < 2:
        continue
    # Bare builtins (`sh`, `sh_lines`) live in the same tables as qualified ones.
    # Requiring `::` silently dropped them, and dropped a real mismatch with them.
    names = re.findall(r'`([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)?)`', cells[0])
    sigs = re.findall(r'`(\([^`]*\)\s*->\s*[^`]+)`', cells[1])
    # The tables carry the required effect in their own third column, and
    # `ret_type` strips `with ...` from the checker's side -- so documenting
    # `Console::write_stream` with `Process` changed nothing measurable
    # (#2138 review). Carry it through and compare it.
    eff = ""
    if len(cells) > 2:
        em = re.findall(r'`([A-Za-z_][A-Za-z0-9_:]*)`', cells[2])
        if len(em) == 1:
            eff = em[0]
    if len(names) == 1 and len(sigs) >= 1:
        pairs = [(names[0], sigs[0])]
    elif len(names) > 1 and len(sigs) == 1:
        pairs = [(n, sigs[0]) for n in names]
    elif len(names) > 1 and len(names) == len(sigs):
        pairs = list(zip(names, sigs))
    else:
        continue
    for n, sg in pairs:
        print(f"{n}\t{sg}\t{eff}")
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
# The probe's exit status is load-bearing, so it is NOT discarded. If it emits
# some rows and then traps -- a later `lookup_builtin` or `type_to_string` being
# what failed -- the file is non-empty and a naive "did it produce output?"
# check passes after comparing only a PREFIX. That is the same
# passes-vacuously failure this gate exists to prevent.
probe_rc=0
env VIBE_PREOPEN_DIR="$ROOT_DIR" CHEATSHEET_SIG_INPUT="_build/_cheatsheet_sig/pairs.tsv" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$WORK/probe.wasm" \
  > "$WORK/actual.tsv" 2>"$WORK/probe.err" || probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "cheatsheet-signatures: FAIL: the probe exited $probe_rc after emitting $(grep -c '' "$WORK/actual.tsv" 2>/dev/null || echo 0) of $pair_count rows" >&2
  head -3 "$WORK/probe.err" 2>/dev/null >&2 || true
  exit 1
fi
if [ ! -s "$WORK/actual.tsv" ]; then
  echo "cheatsheet-signatures: FAIL: the probe produced no output" >&2
  exit 1
fi

# The caveat paragraph: the one authoritative list of documented non-builtins.
python3 - "$DOC" "$WORK/actual.tsv" "$pair_count" <<'PY' || exit 1
import re, sys
doc = open(sys.argv[1], encoding="utf-8").read()

def ret_type(sig):
    # Everything after the LAST top-level `->`, with the effect row dropped: the
    # tables carry the row in their own column, so comparing it here would report
    # a difference in presentation rather than in meaning.
    # The LAST top-level `->`, i.e. outside any parentheses -- `rfind` alone
    # would already be right for a trailing callback-free return, but a
    # signature ending in a function type needs the depth check.
    depth, i = 0, -1
    for j, ch in enumerate(sig):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "-" and depth == 0 and sig[j:j + 2] == "->":
            i = j
    if i < 0:
        return None
    r = sig[i + 2:].strip()
    r = re.split(r'\s+with\s+', r)[0].strip()
    return "Unit" if r in ("()", "Unit") else r

def norm(t):
    """A type with variable NAMES erased but its constructors kept.

    Bailing out of a whole type because it mentions a variable (the first cut)
    accepted concrete drift around that variable -- the cheatsheet promising
    `(Map[K, V], K) -> V` while the builtin takes a `String` key was invisible
    that way. A documented variable is a promise of genericity, so it has to
    correspond to a variable on the other side, not to a concrete type.
    """
    t = t.strip()
    # The checker prints Unit as `()`; the document writes `Unit`. Now that
    # nested function types are compared, that difference shows up INSIDE a
    # callback (`(T) -> Unit` vs `(?) -> ()`) and is presentation, not drift.
    t = re.sub(r'\(\s*\)', 'Unit', t)
    # `?` is how the checker prints an un-instantiated variable; a lone capital
    # (optionally with digits) is how the document writes one.
    t = re.sub(r'(?<![A-Za-z0-9_])\?', 'VAR', t)
    t = re.sub(r'(?<![A-Za-z0-9_])[A-Z][0-9]?(?![A-Za-z0-9_])', 'VAR', t)
    return re.sub(r'\s+', '', t)

def compatible(doc, actual):
    """Whether the documented type and the checker's agree.

    The rule is ASYMMETRIC, because the two sides mean different things by a
    variable:

    * The checker prints `?` for anything it has not instantiated, including
      opaque handles. It carries no information, so it matches any documented
      type -- otherwise every `Array[T]` would "differ" from `Array[?]`.
    * A DOCUMENTED variable is a promise of genericity. It is satisfied by
      another variable, and NOT by a concrete type: the cheatsheet promising
      `Map::keys: (Map[K, V]) -> Array[K]` against an actual `Array[String]`
      is drift a reader hits the moment they use a non-String key.

    Bailing out of a whole type because it mentions a variable -- the first cut
    -- accepted exactly that.
    """
    d, a = norm(doc), norm(actual)
    if d == a or a == "VAR":
        return True
    # Structural: same shape with VAR matching only VAR.
    return re.sub(r'VAR', '#', d) == re.sub(r'VAR', '#', a)

def paren_body(sig):
    """The text inside the OUTERMOST parentheses, matched by balance.

    `[^)]*` stops at the first nested `)`, so `(Array[?], (?) -> Bool)` was read
    as `Array[?], (?` -- the callback's own return type and every parameter
    after it were invisible, and drift there compared equal (#2138 review).
    """
    i = sig.find("(")
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(sig)):
        if sig[j] == "(":
            depth += 1
        elif sig[j] == ")":
            depth -= 1
            if depth == 0:
                return sig[i + 1:j]
    return None

def params(sig):
    """The top-level parameter types, split on commas outside brackets."""
    inner = paren_body(sig)
    if inner is None:
        return None
    inner = inner.strip()
    if inner == "":
        return []
    out, depth, cur = [], 0, ""
    for ch in inner:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    # The document names its parameters (`(s: String, i: Int)`); the checker does
    # not. Compare the TYPES, so the two spellings of the same signature agree.
    return [re.sub(r'^[a-z_][A-Za-z0-9_]*\s*:\s*', '', t) for t in out]

def arity(sig):
    inner = paren_body(sig)
    if inner is None:
        return None
    inner = inner.strip()
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
# Everything from the marker to the next section, not just the first paragraph:
# the caveat groups its names by package, so it spans several. Reading one
# paragraph silently dropped every group but the first, which reads as "these
# names are undocumented" -- a failure that points at the document when the
# fault is here.
block_lines = []
for line in after.split("\n"):
    if line.startswith("**") or line.startswith("#"):
        break
    block_lines.append(line)
block = "\n".join(block_lines)
# Bare names too (`to_string`): a library function does not have to be
# qualified, and requiring `::` here would make one unlistable -- so it could
# never be reconciled and the gate would fail forever.
listed = set(re.findall(r'`([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)?)`', block))
if not listed:
    print("cheatsheet-signatures: FAIL: the import-required-builtins paragraph names no "
          "`Type::fn` at all, so this gate would accept anything", file=sys.stderr)
    sys.exit(1)

nonbuiltin, mismatch, compared, seen = set(), [], 0, 0
malformed = []
for line in open(sys.argv[2]):
    if not line.strip():
        continue
    seen += 1
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 4:
        # Never skipped silently: a row the probe could not render is a row this
        # gate did not check, and dropping it would shrink the corpus quietly.
        malformed.append(line.rstrip("\n")[:120])
        continue
    name, docsig, doceff, actual = parts
    if actual == "<not a builtin>":
        nonbuiltin.add(name)
        continue
    compared += 1
    ad, aa = arity(docsig), arity(actual)
    if ad != aa:
        mismatch.append((name, docsig, actual, f"{ad} args", f"{aa} args"))
        continue
    # Arity alone would have missed `sh`, documented `-> Unit` while the registry
    # returns `String`: same arity, different answer. Compare the return type too.
    rd, ra = ret_type(docsig), ret_type(actual)
    if rd and ra and not compatible(rd, ra):
        mismatch.append((name, docsig, actual, f"returns {rd}", f"returns {ra}"))
        continue
    # The documented effect column against the checker's row. Only when the
    # document names exactly one effect: a blank column claims nothing, and a
    # prose cell ("Console (legacy)") is not a row to compare.
    aeff = ""
    m_eff = re.search(r'\bwith\s+([A-Za-z_][A-Za-z0-9_:]*)\s*$', actual.strip())
    if m_eff:
        aeff = m_eff.group(1)
    if doceff and aeff and doceff != aeff:
        mismatch.append((name, docsig, actual, f"effect {doceff}", f"effect {aeff}"))
        continue
    # Arity plus return type still let a REORDERING through -- the review's
    # example, `String::substring` documented as `(Int, String, Int) -> String`,
    # has the same arity and the same return. Compare the parameter types too,
    # position by position, skipping any pair where either side is generic.
    pd, pa = params(docsig), params(actual)
    if pd is not None and pa is not None and len(pd) == len(pa):
        for i, (a, b) in enumerate(zip(pd, pa)):
            if compatible(a, b):
                continue
            mismatch.append((name, docsig, actual, f"arg {i + 1} is {a}", f"arg {i + 1} is {b}"))
            break

fails = 0
expected_rows = int(sys.argv[3])
if seen != expected_rows:
    print(f"cheatsheet-signatures: FAIL: the probe answered for {seen} of {expected_rows} extracted "
          f"pairs -- every pair must produce exactly one row, or the comparison covers only part "
          f"of the document", file=sys.stderr)
    fails = 1
for m in malformed:
    print(f"cheatsheet-signatures: FAIL: malformed probe row (want NAME\\tDOC\\tEFFECT\\tACTUAL): {m}", file=sys.stderr)
    fails = 1
for name, d, a, ad, aa in mismatch:
    print(f"cheatsheet-signatures: FAIL: {name} documented as {d} ({ad}) but the checker says {a} ({aa})", file=sys.stderr)
    fails = 1

missing = sorted(nonbuiltin - listed)
# `listed - nonbuiltin` conflates two states, and the message below asserted the
# wrong one of them: a caveat name the reference DOCUMENTS and the checker calls
# a builtin (drop it from the caveat), versus a caveat name the reference does
# not document at all -- about which nothing was measured. Reporting the second
# as "the checker says it IS a builtin now" is a claim this gate never checked.
documented = set()
for l in open(sys.argv[2]):
    parts = l.rstrip("\n").split("\t")
    if len(parts) == 4:
        documented.add(parts[0])
extra = sorted((listed - nonbuiltin) & documented)
undocumented = sorted(listed - nonbuiltin - documented)
if undocumented:
    print("cheatsheet-signatures: FAIL: the import caveat names these, but the Signature", file=sys.stderr)
    print("  reference gives them no signature -- nothing was measured about them. Give", file=sys.stderr)
    print("  each one a signature there, or drop it from the caveat:", file=sys.stderr)
    for n in undocumented:
        print(f"    {n}", file=sys.stderr)
    fails = 1
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
