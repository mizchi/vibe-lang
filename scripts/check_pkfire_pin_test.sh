#!/usr/bin/env bash
# Red test for scripts/check_pkfire_pin.sh (#2645 follow-up).
#
# Every case mutates a real input and asserts the gate FAILS, and each mutation
# is verified to have landed before the gate is asked.
set -euo pipefail

unset VIBE_PKFIRE_PIN_ROOT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/check_pkfire_pin.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_pkfire_pin_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "check_pkfire_pin_test: FAIL: $*" >&2; exit 1; }

# A scratch tree that mirrors the real shape, so each case mutates one thing.
scaffold() {
  rm -rf "$TMP/tree"
  mkdir -p "$TMP/tree/.github/actions/setup-vibe" "$TMP/tree/.github/workflows" "$TMP/tree/.claude/hooks"
  printf '0.14.2\n' > "$TMP/tree/.github/pkfire-version"
  cat > "$TMP/tree/.github/actions/setup-vibe/action.yml" <<'YML'
runs:
  using: composite
  steps:
    - uses: mizchi/pkfire@v0.14.2
      with:
        version: 0.14.2
YML
  cat > "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'YML'
jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
        with:
          version: 0.14.2
YML
  printf 'PKF_VERSION="$(tr -d x < "$PROJECT_DIR/.github/pkfire-version")"\n' \
    > "$TMP/tree/.claude/hooks/session-start.sh"
}
run_gate() { VIBE_PKFIRE_PIN_ROOT="$TMP/tree" bash "$GATE" >"$TMP/out" 2>&1; }

# --- control: the REAL repository passes ---------------------------------
if ! bash "$GATE" >"$TMP/real.out" 2>&1; then
  cat "$TMP/real.out" >&2
  fail "control: the repository's own pin is rejected"
fi
echo "check_pkfire_pin_test: ok: control: the real repository passes"

# --- control 2: the scaffold passes --------------------------------------
scaffold
run_gate || { cat "$TMP/out" >&2; fail "control: the scaffold is rejected"; }
echo "check_pkfire_pin_test: ok: control: a well-formed scratch tree passes"

# --- case 1: the action ref disagrees with the pin file -------------------
scaffold
sed -i.bak 's/mizchi\/pkfire@v0.14.2/mizchi\/pkfire@v0.16.0/' "$TMP/tree/.github/actions/setup-vibe/action.yml"
grep -q 'pkfire@v0.16.0' "$TMP/tree/.github/actions/setup-vibe/action.yml" || fail "case 1: mutation did not land"
if run_gate; then fail "case 1: a ref that disagrees with the pin file was accepted"; fi
grep -q "v0.14.2" "$TMP/out" || fail "case 1: the message does not name the pinned version"
echo "check_pkfire_pin_test: ok: case 1: a ref disagreeing with the pin file is rejected"

# --- case 2: the version input is missing (the original bug) --------------
scaffold
sed -i.bak '/version: 0.14.2/d' "$TMP/tree/.github/workflows/pkfire-pkspec.yml"
grep -q 'version: 0.14.2' "$TMP/tree/.github/workflows/pkfire-pkspec.yml" && fail "case 2: mutation did not land"
if run_gate; then fail "case 2: a call site with no version input was accepted -- that IS the bug"; fi
grep -q "installs 'latest'" "$TMP/out" || fail "case 2: the message does not say why it matters"
echo "check_pkfire_pin_test: ok: case 2: a call site with no version input is rejected"

# --- case 3: the hook hardcodes a version instead of reading the file -----
scaffold
printf 'PKF_VERSION="0.14.2"\n' > "$TMP/tree/.claude/hooks/session-start.sh"
if run_gate; then fail "case 3: a hook hardcoding the version was accepted"; fi
echo "check_pkfire_pin_test: ok: case 3: a hook that restates the version is rejected"

# --- case 4: no pin file at all -> refuse, do not pass --------------------
scaffold
rm -f "$TMP/tree/.github/pkfire-version"
if run_gate; then fail "case 4: a tree with no pin file was accepted"; fi
echo "check_pkfire_pin_test: ok: case 4: a missing pin file is fatal"

# --- case 5: no call sites at all -> refuse, do not read as clean ---------
scaffold
rm -f "$TMP/tree/.github/actions/setup-vibe/action.yml" "$TMP/tree/.github/workflows/pkfire-pkspec.yml"
if run_gate; then fail "case 5: a tree with no pkfire call sites read as clean"; fi
grep -q "the scan did not run" "$TMP/out" || fail "case 5: the refusal does not say the scan found nothing"
echo "check_pkfire_pin_test: ok: case 5: no call sites refuses instead of passing"

# --- case 6: the gate must not count its own prose ------------------------
# The first draft matched the example inside its own comment and reported a
# call site pinned at "vX" (#2138 shape).
scaffold
printf '\n# uses: mizchi/pkfire@vNOPE (prose, not a call site)\n' >> "$TMP/tree/.github/workflows/pkfire-pkspec.yml"
run_gate || { cat "$TMP/out" >&2; fail "case 6: a commented-out example was counted as a call site"; }
echo "check_pkfire_pin_test: ok: case 6: a commented example is not a call site"

echo "check_pkfire_pin_test: ok (2 controls + 6 cases)"
