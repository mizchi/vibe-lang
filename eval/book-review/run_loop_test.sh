#!/usr/bin/env bash
# Proves run_loop.sh fails on a mutated chapter and passes on a clean one.
# The fixture is not the real book. BOOK_REVIEW_ROOT points at a temp tree
# so a green run cannot be the script ignoring its input.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOOP="$ROOT/eval/book-review/loop.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/book/en" "$TMP/book/ja" "$TMP/eval/book-review/scores/chapters"

cat >"$TMP/book/SUMMARY.md" <<'EOF'
- [Ok](en/01_ok.md)
- [Bad](en/02_bad.md)
EOF

write_ok() {
  local lang="$1"
  cat >"$TMP/book/$lang/01_ok.md" <<'EOF'
# ok

See [the pair](../en/01_ok.md).

```vibe run
fn main() { println("ok") }
```

```output
ok
```

```vibe skip
// skip: shown for the diagnostic
fn main() { 1 }
```
EOF
}

write_ok en
write_ok ja
# The en file's link points at en; point ja at itself so both resolve.
sed -i.bak 's#(../en/01_ok.md)#(../ja/01_ok.md)#' "$TMP/book/ja/01_ok.md"
rm -f "$TMP/book/ja/01_ok.md.bak"

cat >"$TMP/book/en/02_bad.md" <<'EOF'
# bad

See [missing](no_such.md).

```vibe skip
fn main() { 1 }
```

```vibe run
fn main() { println("x") }
```
EOF

cat >"$TMP/book/ja/02_bad.md" <<'EOF'
# bad

```vibe run
fn main() { println("x") }
```

```output
x
```
EOF

export BOOK_REVIEW_ROOT="$TMP"
fail() { echo "run_loop_test: $1" >&2; exit 1; }

# The bad chapter must be the one that fails. A check that passes, or that
# fails only the good chapter, proves nothing.
rc=0
out="$(python3 "$LOOP" check 02_bad 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "check 02_bad exited $rc, want 1"
echo "$out" | grep -q "broken link" || fail "mutation did not report a broken link"
echo "$out" | grep -q "no \`// skip\` reason" || fail "mutation did not report a skip without a reason"
echo "$out" | grep -q "not followed by" || fail "mutation did not report a run without output"
echo "$out" | grep -q "fence counts differ" || fail "mutation did not report an en/ja fence mismatch"

rc=0
out="$(python3 "$LOOP" check 01_ok 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "check 01_ok exited $rc: $out"

# A mechanically broken chapter exits 1, even though scores are also missing.
rc=0
python3 "$LOOP" pass >/tmp/book-review-pass-mech.txt || rc=$?
[ "$rc" -eq 1 ] || fail "pass on a broken chapter exited $rc, want 1"
grep -q "mechanical FAIL: 02_bad" /tmp/book-review-pass-mech.txt \
  || fail "pass did not name the broken chapter"

# Repair 02 so a score can be current, then prove a stale blob is not
# counted. The repair is the control: the mutation above already failed.
cat >"$TMP/book/en/02_bad.md" <<'EOF'
# bad repaired

```vibe run
fn main() { println("x") }
```

```output
x
```
EOF
cp "$TMP/book/en/02_bad.md" "$TMP/book/ja/02_bad.md"

# Both chapters are mechanically clean and neither has a score. The pass
# must name the hole and exit 2, not average it in.
rc=0
BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" pass >/tmp/book-review-pass-gap.txt || rc=$?
[ "$rc" -eq 2 ] || fail "pass with no scores exited $rc, want 2"
grep -q "01_ok (missing)" /tmp/book-review-pass-gap.txt || fail "pass did not name the missing chapter"
grep -q "02_bad (missing)" /tmp/book-review-pass-gap.txt || fail "pass did not name the second missing chapter"

write_score() {
  local cid="$1" blob_json="$2" dest="$3"
  python3 - "$cid" "$blob_json" "$dest" <<'PY'
import json, sys
cid, blobs, dest = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
dims = {}
for name in (
    "prose_fidelity",
    "surface_agreement",
    "example_honesty",
    "learner_progression",
    "off_path_guidance",
):
    if name in ("prose_fidelity", "surface_agreement"):
        dims[name] = {"score": 4, "measured": True, "rationale": "fixture"}
    else:
        dims[name] = {"score": None, "measured": False, "rationale": "not this loop"}
json.dump(
    {"unit": "chapter", "chapter": cid, "blobs": blobs, "dimensions": dims},
    open(dest, "w"),
    indent=2,
)
PY
}

mkdir -p "$TMP/eval/book-review/scores/chapters/01_ok" \
  "$TMP/eval/book-review/scores/chapters/02_bad"
ok_blobs="$(BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" blob 01_ok)"
bad_blobs="$(BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" blob 02_bad)"
write_score 01_ok "$ok_blobs" "$TMP/eval/book-review/scores/chapters/01_ok/2026-01-01-r1.json"
# Stale on purpose: the good chapter's hash pasted onto the repaired chapter.
write_score 02_bad "$ok_blobs" "$TMP/eval/book-review/scores/chapters/02_bad/2026-01-01-r1.json"

status="$(BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" status)"
echo "$status" | grep -q "02_bad" || fail "status did not list 02_bad"
echo "$status" | awk '$1=="02_bad"{print $3}' | grep -qx "stale" \
  || fail "stale blob was not reported stale: $status"

BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" pass >/tmp/book-review-pass-stale.txt
rc=$?
[ "$rc" -eq 2 ] || fail "pass counted a stale chapter (exit $rc)"

write_score 02_bad "$bad_blobs" "$TMP/eval/book-review/scores/chapters/02_bad/2026-01-02-r2.json"
BOOK_REVIEW_DATE=2026-01-02 BOOK_REVIEW_ROOT="$TMP" python3 "$LOOP" pass --record \
  >/tmp/book-review-pass-ok.txt || fail "complete pass failed"
grep -q "chapters 2/2" /tmp/book-review-pass-ok.txt || fail "pass did not count both chapters"
[ -f "$TMP/eval/book-review/scores/passes/2026-01-02-r1.json" ] \
  || fail "pass --record did not write a file"
grep -q '"score": 4' "$TMP/eval/book-review/scores/passes/2026-01-02-r1.json" \
  || fail "recorded pass has no mean"

echo "ok"
exit 0
