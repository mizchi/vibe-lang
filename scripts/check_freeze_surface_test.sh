#!/usr/bin/env bash
# Self-test for scripts/check_freeze_surface.sh.
#
# Runs the check against synthetic freeze documents rather than the real one,
# so the cases stay fixed while the real list changes. Every case is a way the
# check could be wrong, and the last three are ways an earlier draft WAS wrong:
# it passed with no runner (fail-open), it passed when a deleted symbol was
# re-frozen (a precedence rule hid the contradiction), and it silently answered
# from the seed when handed a compiler path that does not exist.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
CHECK="$ROOT_DIR/scripts/check_freeze_surface.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_freeze_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

doc() { # doc <body-of-section-3>
  cat > "$TMP/doc.md" <<EOF
# synthetic

## 3. section

$1

---

## 4. next
EOF
}

expect() { # expect <exit> <label> [needle]
  local want="$1" label="$2" needle="${3:-}" out rc
  set +e; out="$(FREEZE_DOC="$TMP/doc.md" bash "$CHECK" 2>&1)"; rc=$?; set -e
  if [ "$rc" != "$want" ]; then
    echo "freeze-surface self-test: FAIL: $label -- exit $rc, wanted $want" >&2
    echo "$out" >&2; exit 1
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" <<<"$out"; then
    echo "freeze-surface self-test: FAIL: $label -- output does not mention '$needle'" >&2
    echo "$out" >&2; exit 1
  fi
  echo "freeze-surface self-test: ok: $label"
}

# 1. A type heading plus bare names is the document's usual shape, and every
#    one of these resolves.
doc '- **String**: `length`, `concat`, `substring`'
expect 0 "a heading plus bare names all resolve"

# 2. The same shape with one name that cannot exist.
doc '- **String**: `length`, `no_such_builtin_here`'
expect 1 "a frozen name that does not resolve" "no_such_builtin_here"

# 3. Already-qualified names are read as-is.
doc '- **conv**: `Int::to_string`, `Double::to_int`'
expect 0 "qualified names are read directly"

# 4. `Foo::a/b/c` expands.
doc '- **builders**: `ArrayBuilder::new/push/freeze`'
expect 0 "slash-joined operations expand"

# 5. The document may say a name is deliberately not frozen.
doc '- **gone**: `Iterator::map` is not frozen'
expect 0 "an explicitly not-frozen name is not probed"

# 6. ...but not while also freezing it. That contradiction is what let a
#    deleted symbol back in.
doc '- **Result**: `and_then`
- **note**: `Result::and_then` cannot be frozen'
expect 1 "freezing and un-freezing the same name is a contradiction" "says two different things"

# 7. A section 3 with no symbols means the check is asserting nothing.
doc '(prose only, no symbols)'
expect 1 "an empty symbol set fails rather than passing vacuously" "asserting nothing"

# 8. An explicit compiler that does not exist is an error, not a fallback to
#    the seed -- otherwise the caller is told about a compiler they did not run.
doc '- **String**: `length`'
set +e
out="$(FREEZE_DOC="$TMP/doc.md" FREEZE_STAGE2="$TMP/nope.wasm" bash "$CHECK" 2>&1)"; rc=$?
set -e
if [ "$rc" = "0" ]; then
  echo "freeze-surface self-test: FAIL: a missing explicit compiler passed" >&2
  echo "$out" >&2; exit 1
fi
grep -qF "FREEZE_STAGE2 does not exist" <<<"$out" || {
  echo "freeze-surface self-test: FAIL: missing explicit compiler did not say so" >&2
  echo "$out" >&2; exit 1
}
echo "freeze-surface self-test: ok: a missing explicit compiler is an error"

# 9. A compiler that cannot run must fail the calibration, not report ok --
#    the fail-open shape #2108 closed elsewhere.
: > "$TMP/empty.wasm"
set +e
out="$(FREEZE_DOC="$TMP/doc.md" FREEZE_STAGE2="$TMP/empty.wasm" bash "$CHECK" 2>&1)"; rc=$?
set -e
if [ "$rc" = "0" ]; then
  echo "freeze-surface self-test: FAIL: an unusable compiler reported ok" >&2
  echo "$out" >&2; exit 1
fi
grep -qF "calibration" <<<"$out" || {
  echo "freeze-surface self-test: FAIL: an unusable compiler did not fail calibration" >&2
  echo "$out" >&2; exit 1
}
echo "freeze-surface self-test: ok: an unusable compiler fails calibration"

echo "freeze-surface self-test: all cases passed"
