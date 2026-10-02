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
  cat > "$TMP/tree/flake.nix" <<'NIX'
{
  inputs = {
    # pinned to the tag in .github/pkfire-version (v0.14.2)
    pkfire = {
      url = "git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.14.2";
    };
  };
}
NIX
  cat > "$TMP/tree/flake.lock" <<'LOCK'
{
  "nodes": {
    "pkfire": {
      "locked": { "url": "https://github.com/mizchi/pkfire", "ref": "refs/tags/v0.14.2", "type": "git" },
      "original": { "url": "https://github.com/mizchi/pkfire", "ref": "refs/tags/v0.14.2", "type": "git" }
    },
    "root": { "inputs": { "pkfire": "pkfire" } }
  },
  "root": "root",
  "version": 7
}
LOCK
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

# --- case 2b: a COMMENTED version input does not count (Codex review) ------
# The aggregate-count version of this gate reported "ok (2 call site(s),
# 2 pinned input(s))" for exactly this tree, while that action installed latest.
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read().replace("          version: 0.14.2", "          # version: 0.14.2")
open(p, "w").write(s)
PY2
grep -q '# version: 0.14.2' "$TMP/tree/.github/workflows/pkfire-pkspec.yml" || fail "case 2b: mutation did not land"
grep -qE '^[[:space:]]*version: 0.14.2' "$TMP/tree/.github/workflows/pkfire-pkspec.yml" && fail "case 2b: a real input is still present"
if run_gate; then
  cat "$TMP/out" >&2
  fail "case 2b: a COMMENTED version input was counted as a real one"
fi
grep -q "passes no 'with.version: 0.14.2'" "$TMP/out" || fail "case 2b: the message does not name the call site's missing input"
echo "check_pkfire_pin_test: ok: case 2b: a commented version input does not count"

# --- case 2c: the input must belong to THIS call site ---------------------
# Two call sites, one input between them: the count matches, the association
# does not.
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
p = sys.argv[1]
open(p, "w").write("""jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
      - uses: mizchi/pkfire@v0.14.2
        with:
          version: 0.14.2
""")
PY2
if run_gate; then
  cat "$TMP/out" >&2
  fail "case 2c: a call site with no input of its own was accepted"
fi
echo "check_pkfire_pin_test: ok: case 2c: an input belonging to another step does not count"

# --- case 2d: the key must live under `with:` (Codex review) --------------
# A step carrying `env:` with a version passed the step-window check while the
# action had no with.version at all, so it installed latest.
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
open(sys.argv[1], "w").write("""jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
        env:
          version: 0.14.2
""")
PY2
if run_gate; then
  cat "$TMP/out" >&2
  fail "case 2d: a version under env: was accepted as the action input"
fi
echo "check_pkfire_pin_test: ok: case 2d: a version outside with: does not count"

# --- case 2e: control -- the same value under `with:` IS accepted ----------
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
open(sys.argv[1], "w").write("""jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
        env:
          SOMETHING: 1
        with:
          version: 0.14.2
""")
PY2
run_gate || { cat "$TMP/out" >&2; fail "case 2e: a correctly nested with.version was rejected"; }
echo "check_pkfire_pin_test: ok: case 2e: with: nesting is what the gate accepts"

# --- case 2f: a BLOCK SCALAR containing the text is not an input (Codex) ---
# The indentation-only check could not tell `version: 0.14.2` inside another
# input's block scalar from the input itself; YAML can, because it is string
# content rather than a mapping entry. This is the case that made the gate a
# parser instead of a scanner.
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
open(sys.argv[1], "w").write("""jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
        with:
          release-notes: |
            version: 0.14.2
""")
PY2
if run_gate; then
  cat "$TMP/out" >&2
  fail "case 2f: a version inside a block scalar was counted as the action input"
fi
echo "check_pkfire_pin_test: ok: case 2f: block-scalar text is not a with.version"

# --- case 2g: control -- a real input beside a decoy block scalar ----------
scaffold
python3 - "$TMP/tree/.github/workflows/pkfire-pkspec.yml" <<'PY2'
import sys
open(sys.argv[1], "w").write("""jobs:
  lint:
    steps:
      - uses: mizchi/pkfire@v0.14.2
        with:
          release-notes: |
            version: 9.9.9
          version: 0.14.2
""")
PY2
run_gate || { cat "$TMP/out" >&2; fail "case 2g: a real with.version beside a decoy was rejected"; }
echo "check_pkfire_pin_test: ok: case 2g: a real input is still found beside a decoy"

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

# --- case 7: flake.nix pins another pkfire tag ---------------------------
scaffold
sed -i.bak 's/refs\/tags\/v0.14.2";/refs\/tags\/v0.16.0";/' "$TMP/tree/flake.nix"
grep -q 'refs/tags/v0.16.0";' "$TMP/tree/flake.nix" || fail "case 7: mutation did not land"
if run_gate; then fail "case 7: a flake.nix pkfire input disagreeing with the pin file was accepted"; fi
grep -q "flake.nix pins pkfire at 'git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.16.0'" "$TMP/out" || fail "case 7: the message does not name the flake.nix tag"
echo "check_pkfire_pin_test: ok: case 7: a flake.nix tag disagreeing with the pin file is rejected"

# --- case 7b: only the COMMENT names the tag -> no input found, refuse ----
# The scan is anchored to a `url =` assignment; a tag in prose must not count.
scaffold
python3 - "$TMP/tree/flake.nix" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read().replace('      url = "git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.14.2";\n', '')
open(p, "w").write(s)
PY2
grep -q 'url = ' "$TMP/tree/flake.nix" && fail "case 7b: mutation did not land"
grep -q 'v0.14.2' "$TMP/tree/flake.nix" || fail "case 7b: the comment naming the tag was lost"
if run_gate; then fail "case 7b: a flake.nix whose only pkfire tag is in a comment was accepted"; fi
grep -q "declares no" "$TMP/out" || fail "case 7b: the message does not say the input is missing"
echo "check_pkfire_pin_test: ok: case 7b: a tag named only in a comment does not count"

# --- case 7c: the right URL on ANOTHER input does not count (Codex review) -
# The pkfire input moves to a fork while a decoy input keeps the canonical URL;
# a scan of the whole file found the decoy and passed.
scaffold
python3 - "$TMP/tree/flake.nix" <<'PY5'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("github.com/mizchi/pkfire?ref", "github.com/someone/pkfire?ref")
s = s.replace("  inputs = {\n", '  inputs = {\n    decoy = {\n      url = "git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.14.2";\n    };\n', 1)
open(p, "w").write(s)
PY5
grep -q 'someone/pkfire' "$TMP/tree/flake.nix" || fail "case 7c: mutation did not land"
grep -q 'mizchi/pkfire?ref=refs/tags/v0.14.2' "$TMP/tree/flake.nix" || fail "case 7c: the decoy was not added"
if run_gate; then fail "case 7c: a pkfire input on a fork passed because another input carries the canonical URL"; fi
grep -q "someone/pkfire" "$TMP/out" || fail "case 7c: the message does not name the pkfire input's actual URL"
echo "check_pkfire_pin_test: ok: case 7c: only the pkfire input's own URL counts"

# --- case 7d: a dotted pkfire.url outside the block is refused -------------
# The gate reads the input in one form; another form is a named FAIL, not a
# spelling the scanner silently looks past.
scaffold
python3 - "$TMP/tree/flake.nix" <<'PY6'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  inputs = {\n", '  inputs = {\n    pkfire.url = "git+https://github.com/someone/pkfire?ref=refs/tags/v0.14.2";\n', 1)
open(p, "w").write(s)
PY6
grep -q '^    pkfire.url = ' "$TMP/tree/flake.nix" || fail "case 7d: mutation did not land"
if run_gate; then fail "case 7d: a pkfire.url outside the input block was accepted"; fi
grep -q "outside the input block" "$TMP/out" || fail "case 7d: the message does not name the expected form"
echo "check_pkfire_pin_test: ok: case 7d: pkfire.url outside the block is refused"

# --- case 8: flake.lock resolved another tag (lock not refreshed) ---------
scaffold
sed -i.bak 's/"ref": "refs\/tags\/v0.14.2", "type": "git" }/"ref": "refs\/tags\/v0.13.0", "type": "git" }/' "$TMP/tree/flake.lock"
grep -q 'v0.13.0' "$TMP/tree/flake.lock" || fail "case 8: mutation did not land"
if run_gate; then fail "case 8: a flake.lock resolving another pkfire tag was accepted"; fi
grep -q "flake.lock" "$TMP/out" || fail "case 8: the message does not name flake.lock"
echo "check_pkfire_pin_test: ok: case 8: a stale flake.lock ref is rejected"

# --- case 8b: flake.nix without flake.lock -> refuse, do not skip ---------
scaffold
rm "$TMP/tree/flake.lock"
[ -f "$TMP/tree/flake.nix" ] || fail "case 8b: the scaffold lost flake.nix"
[ -f "$TMP/tree/flake.lock" ] && fail "case 8b: mutation did not land"
if run_gate; then fail "case 8b: a flake with no lock was accepted"; fi
grep -q "flake.lock does not" "$TMP/out" || fail "case 8b: the message does not say the lock is missing"
echo "check_pkfire_pin_test: ok: case 8b: a missing flake.lock is rejected"

# --- case 8c: the root maps pkfire to ANOTHER node (Codex review) ---------
# nix resolves the input through the root node's mapping. A lock whose root
# points at a stale `pkfire_2` must fail even while `nodes.pkfire` is current.
scaffold
python3 - "$TMP/tree/flake.lock" <<'PY3'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["nodes"]["pkfire_2"] = {
    "locked": {"ref": "refs/tags/v0.13.0", "type": "git"},
    "original": {"ref": "refs/tags/v0.13.0", "type": "git"},
}
d["nodes"]["root"]["inputs"]["pkfire"] = "pkfire_2"
json.dump(d, open(p, "w"))
PY3
grep -q '"pkfire": "pkfire_2"' "$TMP/tree/flake.lock" || fail "case 8c: mutation did not land"
grep -q 'refs/tags/v0.14.2' "$TMP/tree/flake.lock" || fail "case 8c: the decoy current node was lost"
if run_gate; then fail "case 8c: a root input mapped to a stale node was accepted"; fi
grep -q "pkfire_2.locked ref" "$TMP/out" || fail "case 8c: the message does not name the node the root maps to"
echo "check_pkfire_pin_test: ok: case 8c: the root's input mapping decides which node is checked"

# --- case 8d: the root maps no pkfire input at all -> refuse ---------------
scaffold
python3 - "$TMP/tree/flake.lock" <<'PY4'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["nodes"]["root"]["inputs"]["pkfire"]
json.dump(d, open(p, "w"))
PY4
grep -q '"inputs": {}' "$TMP/tree/flake.lock" || fail "case 8d: mutation did not land"
if run_gate; then fail "case 8d: a lock whose root has no pkfire input was accepted"; fi
grep -q "maps no 'pkfire' input" "$TMP/out" || fail "case 8d: the message does not say the input is unmapped"
echo "check_pkfire_pin_test: ok: case 8d: an unmapped pkfire input is rejected"

# --- case 8e: the locked node is another repository at the same tag -------
# Comparing only `ref` let a lock resolved from a fork pass (Codex review).
scaffold
sed -i.bak 's#"url": "https://github.com/mizchi/pkfire"#"url": "https://github.com/someone/pkfire"#' "$TMP/tree/flake.lock"
grep -q 'someone/pkfire' "$TMP/tree/flake.lock" || fail "case 8e: mutation did not land"
grep -q '"ref": "refs/tags/v0.14.2"' "$TMP/tree/flake.lock" || fail "case 8e: the tag must stay current for this case to mean anything"
if run_gate; then fail "case 8e: a lock resolved from another repository at the same tag was accepted"; fi
grep -q "pkfire.locked url is 'https://github.com/someone/pkfire'" "$TMP/out" || fail "case 8e: the message does not name the locked repository"
echo "check_pkfire_pin_test: ok: case 8e: the locked repository must be mizchi/pkfire"

echo "check_pkfire_pin_test: ok (2 controls + 21 cases)"
