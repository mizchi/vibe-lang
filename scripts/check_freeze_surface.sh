#!/usr/bin/env bash
# Verify docs/spec/1.0-freeze.md against the compiler.
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
# Existence probe: a bare reference (`let g = String::length`). It resolves iff
# the name exists, which is the question the document is making a promise
# about, and it needs no arity or argument types -- so the check works for a
# name it has never seen. Measured alternative rejected: grepping
# builtin_registry.vibe flags ~13 false misses (`Array::map`, `Int::to_string`,
# `Map::set`, ...) that reach a program by another route.
#
# Usage: bash scripts/check_freeze_surface.sh
#   FREEZE_DOC        override the document (default docs/spec/1.0-freeze.md)
#   FREEZE_STAGE2     compiler wasm (default: newest generation, then seed)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DOC="${FREEZE_DOC:-docs/spec/1.0-freeze.md}"
[ -f "$DOC" ] || { echo "check-freeze-surface: no such document: $DOC" >&2; exit 1; }

# An EXPLICIT compiler that does not exist is an error, never a fallback. The
# silent-fallback version of this answered from the seed while the caller
# believed it was testing their build -- the same "which compiler answered?"
# trap CLAUDE.md documents for `vibe test`.
if [ -n "${FREEZE_STAGE2:-}" ]; then
  CLI="$FREEZE_STAGE2"
  [ -f "$CLI" ] || { echo "check-freeze-surface: FREEZE_STAGE2 does not exist: $CLI" >&2; exit 1; }
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
# A heading is a type when it is a capitalized identifier. `**変換**`,
# `**反復**`, `**I/O**` and `**@vibe/builtin helper**` are prose groupings whose
# members are already written qualified, so their bare names are skipped rather
# than glued onto a nonsense receiver.
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
NEG = ("凍結できない", "凍結対象ではない", "ライブラリ関数")

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
case "$calib_present" in
  *"unknown name"*)
    echo "check-freeze-surface: FAIL: calibration -- String::length did not resolve, so the probe is not measuring what it claims:" >&2
    echo "  $calib_present" >&2
    exit 1 ;;
esac
if [ -n "$calib_present" ]; then
  echo "check-freeze-surface: FAIL: calibration -- probing a valid symbol produced output, so a real failure cannot be told apart:" >&2
  echo "  $calib_present" >&2
  exit 1
fi
case "$calib_absent" in
  *"unknown name"*) : ;;
  *)
    echo "check-freeze-surface: FAIL: calibration -- a symbol that cannot exist was not reported missing, so this check cannot detect anything:" >&2
    echo "  ${calib_absent:-<no output>}" >&2
    exit 1 ;;
esac

checked=0; missing=()
for sym in "${syms[@]:-}"; do
  is_negated "$sym" && continue
  checked=$((checked + 1))
  case "$(probe "$sym")" in
    *"unknown name"*) missing+=("$sym") ;;
  esac
done

if [ "$checked" -eq 0 ]; then
  echo "check-freeze-surface: FAIL: extracted 0 symbols from $DOC section 3 -- the check is asserting nothing" >&2
  exit 1
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-freeze-surface: FAIL: $DOC freezes ${#missing[@]} name(s) that do not resolve:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "check-freeze-surface: a frozen name promises SemVer stability. Remove the entry, or say on the same line why it is not frozen (凍結できない / 凍結対象ではない / ライブラリ関数)." >&2
  exit 1
fi

echo "check-freeze-surface: ok ($checked frozen symbol(s) resolve; ${#negated[@]} explicitly not frozen)"
