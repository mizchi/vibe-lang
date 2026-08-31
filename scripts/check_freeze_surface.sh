#!/usr/bin/env bash
# Verify docs/spec/stable-surface.md against the compiler.
#
# That document is the only page in the tree that makes a SemVer promise, so a
# name listed there that does not resolve is the worst shape a documentation
# error can take: it promises not to break something that is already gone. Two
# such entries reached main and stayed -- `Result::and_then` (the type was
# removed in #1324) and the whole `Iterator::*` combinator layer (retired by
# ADR-0099) -- because nothing read the list back.
#
# The check DERIVES the symbol list from the document rather than restating it.
# A test that hard-codes the same names is a second copy that drifts: adding a
# row to the freeze list would not reach it. Here, adding a row is immediately
# checked.
#
# Existence probe: a bare reference (`let g = String::length`). What the probe
# can conclude from it changed in #2433, so read this before editing it.
#
# It used to read "resolves iff the name exists AS A VALUE", and treated the
# "not a value" diagnostic as a missing name -- #2275's rule, whose exemplar
# was `Map::get`: a real receiver, a real member, and still not a value.
#
# #2433 measured that NO builtin is a value on any lane. The indirect table is
# populated from user functions and lambdas only; builtin bodies sit below
# `func_offset` and carry no closure-env parameter. `let f = eq` emitted a
# module the runtime refused (`invalid signature index`) and
# `let h = String::length` trapped with `table index is out of bounds` -- so
# the checker now rejects every builtin used as a value, and "not a value" no
# longer separates `Map::get` from `String::length`. Under the old rule this
# gate would report the entire frozen surface missing.
#
# So the probe measures what it can still measure honestly: does the name
# EXIST as a builtin operation. Three answers, and each is positive evidence
# rather than an absence:
#
#   - silence          -- the name resolved as a value (a nullary constructor).
#   - "not a value"    -- the checker looked the name UP, found a builtin row,
#     naming the symbol      and refused the value position. Emitted only after
#                            `lookup_builtin_in_env` succeeded, so it proves
#                            existence. It must quote the probed symbol: a
#                            diagnostic about some other name says nothing here.
#   - anything else    -- missing. `unknown name` is the no-such-member case;
#                            the codegen ICE is the same hole leaking past the
#                            checker.
#
# The fail-open shape #2275 closed is still closed: silence is only accepted
# for a name that genuinely produced none, and a name that does not exist
# produces `unknown name`, never silence.
#
# Usage: bash scripts/check_freeze_surface.sh
#   FREEZE_DOC        override the document (default docs/spec/stable-surface.md)
#   FREEZE_CHEATSHEET override the index document (default docs/cheatsheet.md)
#   FREEZE_STAGE2     compiler wasm (default: VIBE_STAGE2_WASM, then newest generation, then seed)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DOC="${FREEZE_DOC:-docs/spec/stable-surface.md}"
[ -f "$DOC" ] || { echo "check-freeze-surface: no such document: $DOC" >&2; exit 1; }

# The cheatsheet's "Key Builtins" is the INDEX to the same surface, and #2124
# measured the two drifting in opposite directions: the cheatsheet called
# `String::replace` a builtin (it is `unknown name` without an import) while
# the freeze list omitted `byte_at` / `from_byte` (real builtins, outside the
# SemVer promise). One probe, both documents.
#
# Only `- **Type**: ...` bullets are read. Probing the whole section extracts
# 109 names, most of them nonsense (`Conversion::__add`, `Math::sh`,
# `Map::perform`) because it also holds prose, tables and code blocks, and a
# receiver sticks across them. The bullets alone give 31 names and no noise --
# which is why the symbol list was restructured into bullets.
CHEATSHEET="${FREEZE_CHEATSHEET:-docs/cheatsheet.md}"
[ -f "$CHEATSHEET" ] || { echo "check-freeze-surface: no such document: $CHEATSHEET" >&2; exit 1; }

# An EXPLICIT compiler that does not exist is an error, never a fallback. The
# silent-fallback version of this answered from the seed while the caller
# believed it was testing their build -- the same "which compiler answered?"
# trap CLAUDE.md documents for `vibe test`.
if [ -n "${FREEZE_STAGE2:-}" ]; then
  CLI="$FREEZE_STAGE2"
  [ -f "$CLI" ] || { echo "check-freeze-surface: FREEZE_STAGE2 does not exist: $CLI" >&2; exit 1; }
elif [ -n "${VIBE_STAGE2_WASM:-}" ]; then
  # CI shards put stage2 here, not under _build/selfhost/generations/.
  # Falling through to seed would calibrate Map::get against a compiler
  # that does not contain this checkout's checker (#2274 / #2275).
  CLI="$VIBE_STAGE2_WASM"
  [ -f "$CLI" ] || { echo "check-freeze-surface: VIBE_STAGE2_WASM does not exist: $CLI" >&2; exit 1; }
else
  CLI="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
  [ -n "$CLI" ] && [ -f "$CLI" ] || CLI="$ROOT_DIR/bootstrap/seed/compiler.wasm"
  [ -f "$CLI" ] || { echo "check-freeze-surface: no compiler wasm (build a generation or run ensure_seed.sh)" >&2; exit 1; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_freeze.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Section 3 only: the stdlib/prelude surface, which is the part made of symbol
# names. Sections 2/4/5 freeze syntax and CLI contracts, which are not
# name-shaped and are covered by their own gates.
#
# The document writes most entries as a TYPE HEADING plus bare names --
# `- **String** (...): \`length\`, \`concat\`, ...` -- so the extractor has to
# rejoin them into `String::length`. Extracting only the already-qualified
# names finds 4 of ~35, which would be a check that mostly does not run.
#
# A heading is a type when it is a capitalized identifier. `**I/O**` and
# `**@vibe/builtin helpers**` are prose groupings whose members are already
# written qualified, so their bare names are skipped rather than glued onto a
# nonsense receiver. `**Conversions**` and `**Iteration**` DO look like
# identifiers, so a bare name under them would be probed as `Iteration::fold`
# and fail. That is the safe direction -- it fails loudly and the fix is to
# qualify the name -- but it is why every name under a prose heading is written
# qualified.
# One pass emits both lists, because a single bullet can hold both: the String
# bullet freezes `length` / `concat` / ... on its first lines and says
# `replace` / `replace_all` are NOT frozen-as-builtins on a continuation line.
# So the frozen/not-frozen decision is per LINE, with the type heading
# inherited from the bullet the line belongs to.
freeze_lists="$WORK/lists"
FREEZE_DOC="$DOC" python3 - > "$freeze_lists" <<'PYEOF'
import os, re, sys

doc = open(os.environ["FREEZE_DOC"], encoding="utf-8").read()
m = re.search(r"^## 3\..*?(?=^## 4\.)", doc, re.S | re.M)
if not m:
    sys.exit("section 3 not found")

# A line saying a name is deliberately not frozen, or frozen only behind an
# import. These are the document's own words; adding a new way to say it here
# is how you exempt a symbol.
NEG = ("not frozen", "cannot be frozen")

recv = None
frozen, negated = set(), set()
for line in m.group(0).splitlines():
    head = re.match(r"- \*\*([A-Za-z][A-Za-z0-9_]*)\*\*", line)
    if line.startswith("- "):
        # `**変換**`, `**反復**`, `**I/O**` are prose groupings, not types --
        # their members are written qualified, so no receiver is inherited.
        recv = head.group(1) if head else None
    sink = negated if any(k in line for k in NEG) else frozen
    for tok in re.findall(r"`([^`]+)`", line):
        tok = tok.strip()
        if "::" in tok:
            base, _, rest = tok.partition("::")
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", base):
                continue
            for part in rest.split("/"):
                part = part.strip()
                if re.fullmatch(r"[a-z_][A-Za-z0-9_]*", part):
                    sink.add(base + "::" + part)
        elif recv and re.fullmatch(r"[a-z_][A-Za-z0-9_]*", tok):
            sink.add(recv + "::" + tok)

# A name in BOTH sets is the document contradicting itself -- one line freezes
# it, another says it is not frozen. Resolving that with a precedence rule
# would hide the contradiction, and it is how re-adding a deleted symbol
# slipped past an earlier draft of this check: `Result::and_then` was excluded
# because an older line still explained why it cannot be frozen.
for name in sorted(frozen & negated):
    print("C " + name)
for name in sorted(frozen - negated):
    print("F " + name)
for name in sorted(negated - frozen):
    print("N " + name)
PYEOF

mapfile -t syms < <(awk '$1=="F"{print $2}' "$freeze_lists")
mapfile -t negated < <(awk '$1=="N"{print $2}' "$freeze_lists")
mapfile -t conflicts < <(awk '$1=="C"{print $2}' "$freeze_lists")

if [ "${#conflicts[@]}" -gt 0 ]; then
  echo "check-freeze-surface: FAIL: $DOC says two different things about ${#conflicts[@]} name(s):" >&2
  printf '  %s\n' "${conflicts[@]}" >&2
  echo "check-freeze-surface: one line freezes it, another says it is not frozen. Decide which is true and delete the other line." >&2
  exit 1
fi

is_negated() {
  local n="$1" x
  for x in "${negated[@]:-}"; do [ "$x" = "$n" ] && return 0; done
  return 1
}

# The probe drives `cli_main` through the node host runner
# (scripts/run_wasm_vibe_host_runner.sh), NOT `runtime/vibe`. Same reason
# scripts/vibe_grep_bin.sh does: `runtime/vibe` needs a native `viberun`, which
# a CI job that only checks out the repo does not have -- and every probe then
# failed with "runner not found", output that contains no "unknown name" and so
# USED to count as a pass. That is the fail-open shape this repository keeps
# closing (#2108).
#
# The calibration below is the belt to that braces: whatever the runner
# situation, the check first proves it can tell a resolving name from a
# non-resolving one, and refuses to report anything if it cannot. It is what
# turned the CI failure into a loud one instead of a green run.
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
[ -f "$RUNNER" ] || { echo "check-freeze-surface: missing host runner: $RUNNER" >&2; exit 1; }

# True when the probe output says this name does not exist as a builtin
# operation. See the header for why "not a value" is EXISTENCE evidence rather
# than a missing name (#2433), and why it must quote the probed symbol.
#
# Order matters: the missing-name answers are tested FIRST, so a diagnostic
# that happens to contain both cannot be read as present.
probe_is_missing() { # probe_is_missing <output> <symbol>
  local out="$1" sym="$2"
  case "$out" in
    *"unknown name"*|*"internal compiler error"*|*"reached code generation"*) return 0 ;;
  esac
  if [ -z "$out" ]; then
    return 1
  fi
  case "$out" in
    *"not a value"*)
      case "$out" in
        *"$sym"*) return 1 ;;
        *) return 0 ;;
      esac ;;
  esac
  return 0
}

probe() { # probe <symbol> -> prints the checker's diagnostics
  printf 'fn __freeze_probe() -> Int {\n  let __g = %s\n  1\n}\n' "$1" > "$WORK/probe.vibe"
  : > "$WORK/out"
  env -u VIBE_FS_COMPILE -u VIBE_NORMALIZE -u VIBE_TYPE_AT -u VIBE_BINDING_AT \
      -u VIBE_SYMBOLS -u VIBE_ESCAPES -u VIBE_ALLOCS -u VIBE_DEPS -u VIBE_GREP \
      VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw VIBE_PREOPEN_DIR="$WORK" \
      bash "$RUNNER" --invoke cli_main "$CLI" "$WORK/probe.vibe" "$WORK/out" >/dev/null 2>&1 || true
  cat "$WORK/out" 2>/dev/null || true
}

calib_present="$(probe "String::length")"
calib_absent="$(probe "String::__no_such_builtin__")"
calib_value="$(probe "None")"
if probe_is_missing "$calib_present" "String::length"; then
  echo "check-freeze-surface: FAIL: calibration -- String::length was reported missing, so the probe is not measuring what it claims:" >&2
  echo "  ${calib_present:-<no output>}" >&2
  exit 1
fi
if ! probe_is_missing "$calib_absent" "String::__no_such_builtin__"; then
  echo "check-freeze-surface: FAIL: calibration -- a symbol that cannot exist was not reported missing, so this check cannot detect anything:" >&2
  echo "  ${calib_absent:-<no output>}" >&2
  exit 1
fi
# The silence branch has to keep working on its own: a nullary constructor is
# the one population that still resolves as a value, and if it stopped being
# silent the classifier would be running on a single branch without saying so.
if [ -n "$calib_value" ] || probe_is_missing "$calib_value" "None"; then
  echo "check-freeze-surface: FAIL: calibration -- None no longer resolves silently as a value, so the probe's silence branch is untested:" >&2
  echo "  ${calib_value:-<no output>}" >&2
  exit 1
fi
# #2433: "not a value" is accepted only when it QUOTES the probed symbol.
# Re-read the calibration output against a symbol it does NOT name and require
# a missing verdict -- otherwise any builtin diagnostic would certify any name.
#
# Guarded on the branch actually being live. A compiler that predates #2433
# answers `String::length` with silence, and asserting this there would fail
# calibration for a reason that has nothing to do with the document -- the
# shape where a gate gets exempted because it breaks for an unrelated reason
# (#2252). Silence is already covered by the None calibration above.
case "$calib_present" in
  *"not a value"*)
    if ! probe_is_missing "$calib_present" "String::__freeze_calibration_other__"; then
      echo "check-freeze-surface: FAIL: calibration -- a diagnostic naming String::length certified an unrelated symbol, so the probe accepts output it did not ask for:" >&2
      echo "  ${calib_present:-<no output>}" >&2
      exit 1
    fi ;;
esac

checked=0; missing=()
for sym in "${syms[@]:-}"; do
  # `"${syms[@]:-}"` yields ONE EMPTY element when the array is empty, and that
  # element used to be probed like a symbol: `let __g = ` parses badly, the old
  # classifier saw no "unknown name" in the output and read it as resolving, so
  # a document with no frozen names reported `1 frozen symbol(s) resolve`. It
  # also defeated the vacuity guard below, which was measuring that artifact
  # rather than the document. The stricter #2433 classifier turned the silent
  # pass into a failure naming a blank symbol, which is how it was found.
  [ -n "$sym" ] || continue
  is_negated "$sym" && continue
  checked=$((checked + 1))
  if probe_is_missing "$(probe "$sym")" "$sym"; then
    missing+=("$sym")
  fi
done

# A section holding ONLY explicitly-not-frozen entries is asserting something
# real (those names are promised NOT to be frozen), so it is not vacuous. The
# vacuous case is a section from which nothing at all was extracted.
if [ "$checked" -eq 0 ] && [ "${#negated[@]}" -eq 0 ]; then
  echo "check-freeze-surface: FAIL: extracted 0 symbols from $DOC section 3 -- the check is asserting nothing" >&2
  exit 1
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-freeze-surface: FAIL: $DOC freezes ${#missing[@]} name(s) that do not resolve:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "check-freeze-surface: a frozen name promises SemVer stability. Remove the entry, or say on the same line why it is not frozen (the line must contain \"not frozen\" or \"cannot be frozen\")." >&2
  exit 1
fi

# The index document: every name it presents as a builtin must be one.
mapfile -t index_syms < <(FREEZE_CHEATSHEET="$CHEATSHEET" python3 - <<'PYEOF'
import os, re, sys

doc = open(os.environ["FREEZE_CHEATSHEET"], encoding="utf-8").read()
m = re.search(r"^## Key Builtins$.*?(?=^## )", doc, re.S | re.M)
if not m:
    sys.exit("no '## Key Builtins' section")

recv, names = None, set()
for line in m.group(0).splitlines():
    head = re.match(r"- \*\*([A-Za-z][A-Za-z0-9_]*)\*\*\s*:", line)
    if head:
        recv = head.group(1)
    elif not re.match(r"^\s+\S", line):
        # Not a bullet start and not an indented continuation: the bullet ended,
        # so the receiver must not leak into the prose and tables that follow.
        recv = None
    if recv is None:
        continue
    for tok in re.findall(r"`([^`]+)`", line):
        tok = tok.strip()
        if "::" in tok:
            base, _, rest = tok.partition("::")
            if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", base) and re.fullmatch(r"[a-z_][A-Za-z0-9_]*", rest):
                names.add(base + "::" + rest)
        elif re.fullmatch(r"[a-z_][A-Za-z0-9_]*", tok):
            names.add(recv + "::" + tok)

for n in sorted(names):
    print(n)
PYEOF
) || { echo "check-freeze-surface: FAIL: could not read $CHEATSHEET's Key Builtins index" >&2; exit 1; }

if [ "${#index_syms[@]}" -eq 0 ]; then
  echo "check-freeze-surface: FAIL: extracted 0 symbols from $CHEATSHEET's Key Builtins bullets -- that half of the check is asserting nothing" >&2
  exit 1
fi

index_missing=()
for sym in "${index_syms[@]}"; do
  [ -n "$sym" ] || continue
  if probe_is_missing "$(probe "$sym")" "$sym"; then
    index_missing+=("$sym")
  fi
done

if [ "${#index_missing[@]}" -gt 0 ]; then
  echo "check-freeze-surface: FAIL: $CHEATSHEET lists ${#index_missing[@]} name(s) as builtins that do not resolve:" >&2
  printf '  %s\n' "${index_missing[@]}" >&2
  echo "  A reader copies these. If the name needs an import, say so in the prose below the bullets instead of listing it as a builtin." >&2
  exit 1
fi

echo "check-freeze-surface: ok ($checked frozen symbol(s) resolve; ${#negated[@]} explicitly not frozen; ${#index_syms[@]} builtin(s) indexed in $CHEATSHEET resolve)"
