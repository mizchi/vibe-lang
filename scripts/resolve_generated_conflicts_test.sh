#!/usr/bin/env bash
# Unit test for scripts/resolve_generated_conflicts.sh.
#
# Covers the two paths that do NOT regenerate (regeneration itself is a plain
# generate_bundle.sh call, already covered by check_module_source_sync.sh):
#   1. clean tree -> no-op, exit 0
#   2. a hand-written file is still conflicted -> refuse, exit 1, stage nothing
#   3. only generated files conflicted -> classified as resolvable (checked by
#      running with a stubbed generate_bundle.sh so the test stays fast)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TARGET="$SCRIPT_DIR/resolve_generated_conflicts.sh"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  echo "resolve-generated-conflicts test: FAIL: $*" >&2
  exit 1
}

# A standalone repo mirroring only the paths the script cares about, so the test
# never touches the real worktree and needs no compiler.
REPO="$WORK/repo"
mkdir -p "$REPO/scripts" "$REPO/lib/@vibe/compiler/cache"
cd "$REPO"
git init -q .
git config user.email t@t
git config user.name t

cp "$TARGET" scripts/resolve_generated_conflicts.sh
# Stub: the real one needs the seed compiler. It only has to write the files the
# script stages, and prove it ran.
cat > scripts/generate_bundle.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "regenerated" > lib/@vibe/compiler/compiler_sources_bundle.vibe
echo "regenerated" > lib/@vibe/compiler/cli_adapter_bundle.vibe
echo "regenerated" > lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe
echo "regenerated" > lib/@vibe/compiler/_cli_adapter_module_source.vibe
echo "regenerated" > lib/@vibe/compiler/cache/codegen_fingerprint.vibe
echo "STUB-GENERATE-RAN"
STUB
# Stub: fmt is a no-op here; the real one needs the compiler.
cat > scripts/vibe_fmt.sh <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > scripts/check_vibe_fmt.sh <<'STUB'
#!/usr/bin/env bash
exit "${STUB_FMT_RC:-0}"
STUB

GEN=(
  lib/@vibe/compiler/compiler_sources_bundle.vibe
  lib/@vibe/compiler/cli_adapter_bundle.vibe
  lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe
  lib/@vibe/compiler/_cli_adapter_module_source.vibe
  lib/@vibe/compiler/cache/codegen_fingerprint.vibe
)
for f in "${GEN[@]}"; do echo base > "$f"; done
echo 'let x = 1' > lib/@vibe/compiler/hand_written.vibe
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

# --- 1. clean tree ---------------------------------------------------------
out="$(bash scripts/resolve_generated_conflicts.sh)" ||
  fail "clean tree should exit 0"
case "$out" in
  *"nothing to do"*) ;;
  *) fail "clean tree: unexpected output: $out" ;;
esac

# --- 2. hand-written file conflicted -> refuse -----------------------------
git checkout -q -b side
for f in "${GEN[@]}"; do echo side > "$f"; done
echo 'let x = 2' > lib/@vibe/compiler/hand_written.vibe
git commit -qam side
git checkout -q "$BASE"
git checkout -qB mainline
for f in "${GEN[@]}"; do echo mainline > "$f"; done
echo 'let x = 3' > lib/@vibe/compiler/hand_written.vibe
git commit -qam mainline
git merge --no-commit side >/dev/null 2>&1 || true

if bash scripts/resolve_generated_conflicts.sh >"$WORK/out2" 2>&1; then
  fail "should refuse while a hand-written file is conflicted"
fi
grep -q "hand_written.vibe" "$WORK/out2" ||
  fail "refusal should name the hand-written file: $(cat "$WORK/out2")"
grep -q "STUB-GENERATE-RAN" "$WORK/out2" &&
  fail "must not regenerate while a hand-written conflict is outstanding"
# The generated files must still be unmerged — nothing was staged.
git diff --name-only --diff-filter=U | grep -q "compiler_sources_bundle.vibe" ||
  fail "refusal must leave the generated conflicts unstaged"

# --- 3. only generated files conflicted -> regenerate + stage --------------
git checkout --theirs -- lib/@vibe/compiler/hand_written.vibe
git add lib/@vibe/compiler/hand_written.vibe
bash scripts/resolve_generated_conflicts.sh >"$WORK/out3" 2>&1 ||
  fail "should succeed once only generated files remain: $(cat "$WORK/out3")"
grep -q "STUB-GENERATE-RAN" "$WORK/out3" ||
  fail "should have regenerated: $(cat "$WORK/out3")"
if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
  fail "conflicts remain after resolve: $(git diff --name-only --diff-filter=U)"
fi
for f in "${GEN[@]}"; do
  [ "$(cat "$f")" = "regenerated" ] ||
    fail "$f should hold the regenerated content, not a merge side"
done
# Staged, so `git commit` finishes the merge with no further steps.
git diff --cached --name-only | grep -q "compiler_sources_bundle.vibe" ||
  fail "regenerated artifacts should be staged"

# --- 4. --regen on a clean, already-committed tip ---------------------------
# The case that bit #1276: a multi-commit rebase leaves the tip carrying a
# later commit's stale artifacts, with no conflict left to key off.
git commit -qm merged
for f in "${GEN[@]}"; do echo stale > "$f"; done
git commit -qam "tip with stale artifacts"
bash scripts/resolve_generated_conflicts.sh --regen >"$WORK/out4" 2>&1 ||
  fail "--regen should succeed on a clean tip: $(cat "$WORK/out4")"
grep -q "STUB-GENERATE-RAN" "$WORK/out4" ||
  fail "--regen should have regenerated: $(cat "$WORK/out4")"
for f in "${GEN[@]}"; do
  [ "$(cat "$f")" = "regenerated" ] || fail "--regen left $f stale"
done
git diff --cached --name-only | grep -q "compiler_sources_bundle.vibe" ||
  fail "--regen should stage the artifacts"

# --- 5. --regen refuses when lib/ is unformatted ----------------------------
git commit -qm regen
for f in "${GEN[@]}"; do echo stale2 > "$f"; done
git commit -qam "stale again"
if STUB_FMT_RC=1 bash scripts/resolve_generated_conflicts.sh --regen >"$WORK/out5" 2>&1; then
  fail "--regen should refuse while lib/ is unformatted"
fi
grep -q "pkf run fmt" "$WORK/out5" ||
  fail "refusal should point at pkf run fmt: $(cat "$WORK/out5")"
grep -q "STUB-GENERATE-RAN" "$WORK/out5" &&
  fail "--regen must not generate from unformatted source"

# --- 6. bad flag ------------------------------------------------------------
if bash scripts/resolve_generated_conflicts.sh --bogus >/dev/null 2>&1; then
  fail "an unknown flag should be rejected"
fi

echo "resolve-generated-conflicts test: ok"
