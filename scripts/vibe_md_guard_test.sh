#!/usr/bin/env bash
# Self-test for scripts/vibe_md.sh's document-kind guard.
#
# There are two doctest harnesses and they answer differently on the same
# document: handed `docs/cheatsheet.md`, vibe_md.sh reported "30 pass, 3 fail"
# for a document `pkf run doctest` calls clean (all 3 were the `lib` symlink
# and the declaration-only tolerance that doctest_extract_run.sh has and this
# one does not). The guard makes the mismatch impossible to hit silently.
#
# These cases are cheap on purpose: the guard runs before the tool is built,
# so a rejected path never pays for a compile.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SH="$ROOT_DIR/scripts/vibe_md.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_md_guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "vibe-md-guard self-test: FAIL: $1" >&2; exit 1; }

# 1. A prose document is refused, and the message names the other harness.
: > "$TMP/prose.md"
set +e; out="$(bash "$SH" check "$TMP/prose.md" 2>&1)"; rc=$?; set -e
[ "$rc" = "2" ] || fail "a prose .md was not refused (exit $rc)"
grep -qF "doctest_extract_run.sh" <<<"$out" || fail "the refusal does not name doctest_extract_run.sh"
grep -qF "$TMP/prose.md" <<<"$out" || fail "the refusal does not name the file"
echo "vibe-md-guard self-test: ok: a prose .md is refused, naming the other harness"

# 2. The real document this repository hits it with.
set +e; out="$(bash "$SH" check docs/cheatsheet.md 2>&1)"; rc=$?; set -e
[ "$rc" = "2" ] || fail "docs/cheatsheet.md was not refused (exit $rc)"
echo "vibe-md-guard self-test: ok: docs/cheatsheet.md is refused"

# 3. A `.vibe.md` passes the guard. Proven by what the failure is NOT: an
#    empty one gets past the guard and is answered by the tool, so the run
#    must not mention the guard's message.
: > "$TMP/empty.vibe.md"
set +e; out="$(bash "$SH" check "$TMP/empty.vibe.md" 2>&1)"; set -e
grep -qF "is not a *.vibe.md document" <<<"$out" && fail "a .vibe.md was refused by the guard"
echo "vibe-md-guard self-test: ok: a .vibe.md gets past the guard"

# 4. The guard covers every mode, not just `check` -- `fmt` would otherwise
#    REWRITE a document this harness does not understand.
for mode in write fmt fmt-check; do
  set +e; rc=0; out="$(bash "$SH" "$mode" "$TMP/prose.md" 2>&1)" || rc=$?; set -e
  [ "$rc" = "2" ] || fail "mode '$mode' did not refuse a prose .md (exit $rc)"
done
echo "vibe-md-guard self-test: ok: write/fmt/fmt-check are guarded too"

# 5. A mixed argument list is refused on the bad entry, before any work.
set +e; rc=0; bash "$SH" check book/en/03_values_functions.vibe.md "$TMP/prose.md" >/dev/null 2>&1 || rc=$?; set -e
[ "$rc" = "2" ] || fail "a mixed list was not refused (exit $rc)"
echo "vibe-md-guard self-test: ok: a mixed argument list is refused"

echo "vibe-md-guard self-test: all cases passed"
