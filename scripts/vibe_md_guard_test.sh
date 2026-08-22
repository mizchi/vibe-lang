#!/usr/bin/env bash
# Self-test for scripts/vibe_md.sh's document-kind guard and for WHICH compiler
# answers a ```vibe run block (#2167).
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

# ---------------------------------------------------------------------------
# #2167: which compiler answers.
#
# The wrapper resolves a compiler; the tool (vibe_md.vibex resolve_stage2) used
# to resolve one of its OWN for the blocks. Nothing reconciled the two, so a
# caller could point VIBE_MD_COMPILER at a stage2 that rejects a block and be
# handed PASS by whatever generation happened to be newest on disk -- which is
# how a book chapter carrying an import the compiler rejects reported PASS.
# ---------------------------------------------------------------------------

header_compiler() { # header_compiler <vibe_md.sh stdout>
  sed -n 's/^vibe_md: mode=[^ ]* compiler=//p' <<<"$1" | head -1
}

# 6. The compiler named on the way in is the compiler the tool reports. The
#    copy is byte-identical to whatever the wrapper resolves by default, so the
#    content-addressed tool build is reused and this costs no compile -- only
#    the PATH differs, which is exactly the thing that used to be ignored.
: > "$TMP/empty.vibe.md"
set +e; out="$(bash "$SH" check "$TMP/empty.vibe.md" 2>/dev/null)"; set -e
default_compiler="$(header_compiler "$out")"
[ -n "$default_compiler" ] || fail "the tool did not report which compiler it used"
[ -s "$default_compiler" ] || fail "the reported compiler does not exist: $default_compiler"
cp "$default_compiler" "$TMP/pinned.wasm"
set +e; out="$(VIBE_MD_COMPILER="$TMP/pinned.wasm" bash "$SH" check "$TMP/empty.vibe.md" 2>/dev/null)"; set -e
[ "$(header_compiler "$out")" = "$TMP/pinned.wasm" ] ||
  fail "VIBE_MD_COMPILER did not reach the block lane (tool reported '$(header_compiler "$out")')"
echo "vibe-md-guard self-test: ok: VIBE_MD_COMPILER selects the compiler for the blocks too"

# 7. An explicit VIBE_MD_STAGE2 still overrides it -- the deliberate
#    two-compiler form, and now the only way to get one.
set +e
out="$(VIBE_MD_COMPILER="$default_compiler" VIBE_MD_STAGE2="$TMP/pinned.wasm" bash "$SH" check "$TMP/empty.vibe.md" 2>/dev/null)"
set -e
[ "$(header_compiler "$out")" = "$TMP/pinned.wasm" ] ||
  fail "VIBE_MD_STAGE2 no longer overrides the block compiler"
echo "vibe-md-guard self-test: ok: VIBE_MD_STAGE2 still overrides it"

# 8. Lane parity: the same source reaches the same verdict whether it is
#    compiled directly through `cli_main` or extracted from a ```vibe run
#    block. The probe uses a wrong import KIND (`type` for a struct, #2161)
#    because that is the class the two lanes were measured to disagree on.
#
#    This asserts AGREEMENT, not rejection, so it is independent of whether the
#    resolved compiler carries the check: a compiler without it must accept in
#    both lanes, one with it must reject in both. It fails exactly when the
#    lanes diverge.
PROBE="$ROOT_DIR/_build/vibe_md_guard"
rm -rf "$PROBE"
mkdir -p "$PROBE"
cat > "$PROBE/kind.vibe" <<'VIBE'
import @vibe/core { type MutMap }

fn main with Console {
  let m: MutMap[String, Int] = MutMap::new_string()
  MutMap::set(m, "a", 1)
  println("size = \{MutMap::size(m)}")
}
VIBE
{
  echo '# lane parity probe'
  echo
  echo '```vibe run'
  cat "$PROBE/kind.vibe"
  echo '```'
  echo
  echo '```output'
  echo 'size = 1'
  echo '```'
} > "$PROBE/kind.vibe.md"

set +e; md_out="$(bash "$SH" check "$PROBE/kind.vibe.md" 2>/dev/null)"; md_rc=$?; set -e
probe_compiler="$(header_compiler "$md_out")"
[ -n "$probe_compiler" ] || fail "the lane-parity run did not report its compiler"
rm -f "$PROBE/kind.wasm" "$PROBE/kind.wasm.diag"
set +e
env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$probe_compiler" \
  "$PROBE/kind.vibe" "$PROBE/kind.wasm" main >/dev/null 2>&1
cli_rc=$?
set -e
md_verdict=accepted; [ "$md_rc" = "0" ] || md_verdict=rejected
cli_verdict=accepted; [ "$cli_rc" = "0" ] && [ -s "$PROBE/kind.wasm" ] || cli_verdict=rejected
[ "$md_verdict" = "$cli_verdict" ] || fail "the two lanes disagree on the same source:
  cli_main   -> $cli_verdict (exit $cli_rc)
  vibe run   -> $md_verdict (exit $md_rc)
  compiler   -> $probe_compiler
  $(cat "$PROBE/kind.wasm.diag" 2>/dev/null)"
rm -rf "$PROBE"
echo "vibe-md-guard self-test: ok: cli_main and a \`\`\`vibe run block agree ($md_verdict) on an import kind"

echo "vibe-md-guard self-test: all cases passed"
