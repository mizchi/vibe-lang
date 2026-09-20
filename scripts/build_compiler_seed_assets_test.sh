#!/usr/bin/env bash
# Red/green for the two seed-manifest guards (#2248 discipline: a guard means
# nothing until it is shown to fail -- and nothing good until it is shown NOT
# to fail on the inputs it must let through).
#
# There are two, in two scripts, because build_compiler_seed_assets.sh has two
# callers that pass a different KIND of tag:
#
#   build_seed_release_assets.sh -> the seed name   (array-capacity-2026-09-20)
#   build_release_assets.sh      -> the PRODUCT tag (v0.1.0)
#
# The first version of this guard compared the manifest's `seed.name` to that
# argument inside the shared script. Correct for the seed caller, always false
# for the product one: a local dry run of `build_release_assets.sh v0.1.0` on
# the candidate died with "seed.json names a different seed than the tag being
# published (seed.name=array-capacity-2026-09-20, publishing=v0.1.0)". Nothing
# in CI runs that script -- release.yml invokes it only on a `v*` tag push --
# so it would have surfaced when the release tag was pushed. Case 3 below is
# that regression, pinned.
#
# The shared script now checks only that the manifest is SELF-consistent
# (`seed.tag` == `seed/` + `seed.name`), which is the defect that actually
# shipped and is true for both callers. The seed-only half moved to the caller
# that knows it is publishing a seed.
#
# Each case runs the real script against a scratch PROJECT_ROOT holding a real
# manifest and a real (tiny) artifact whose sha matches, so the pre-existing
# sha guard cannot be what fires. scripts/generate_bundle.sh is deliberately
# absent there: reaching it is how a PASSING guard is observed rather than
# assumed. A green case that merely "did not print the guard message" would
# also be satisfied by the script dying earlier, which is the proxy #2248 is
# about.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-seed-assets-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }
must_contain() {
  if grep -qF "$2" "$1"; then note "  ok   log contains: $2"
  else note "  FAIL log missing: $2"; fail=1; fi
}
must_not_contain() {
  if grep -qF "$2" "$1"; then note "  FAIL log unexpectedly contains: $2"; fail=1
  else note "  ok   log free of: $2"; fi
}

setup_tree() {
  local dir="$1" name="$2" tag="$3"
  rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/bootstrap/seed"
  cp "$ROOT_DIR/scripts/build_compiler_seed_assets.sh" "$dir/scripts/"
  cp "$ROOT_DIR/scripts/build_seed_release_assets.sh" "$dir/scripts/"
  printf 'not-a-real-wasm\n' > "$dir/bootstrap/seed/compiler.wasm"
  local sha
  sha="$(sha256sum "$dir/bootstrap/seed/compiler.wasm" | cut -d' ' -f1)"
  cat > "$dir/bootstrap/seed.json" <<JSON
{
  "schema": 1,
  "policy": "rust-style-stage0-stage1-stage2",
  "seed": {
    "name": "$name",
    "tag": "$tag",
    "source_commit": "0000000000000000000000000000000000000000",
    "entry": "lib/@vibe/compiler/cli_support.vibe",
    "entry_name": "cli_main",
    "artifact": { "path": "bootstrap/seed/compiler.wasm", "sha256": "$sha" }
  }
}
JSON
}

SEED="demo-seed-2026-09-20"
INCONSISTENT="is internally inconsistent"
SEED_IDENTITY="names a different seed than the tag being published"
PAST_GUARD="compiler module source generation failed"

note "=== 1. green: a self-consistent manifest reaches past the shared guard ==="
setup_tree "$WORK/green" "$SEED" "seed/$SEED"
bash "$WORK/green/scripts/build_compiler_seed_assets.sh" "$SEED" "$WORK/green/out" > "$WORK/green.log" 2>&1
note "  exit=$?"
must_not_contain "$WORK/green.log" "$INCONSISTENT"
must_contain     "$WORK/green.log" "$PAST_GUARD"

note "=== 2. red: seed.tag names another release than seed.name (the shipped defect) ==="
setup_tree "$WORK/red1" "bytes-capacity-2026-09-15" "seed/$SEED"
bash "$WORK/red1/scripts/build_compiler_seed_assets.sh" "$SEED" "$WORK/red1/out" > "$WORK/red1.log" 2>&1
rc=$?
note "  exit=$rc"
[ "$rc" != 0 ] && note "  ok   nonzero exit" || { note "  FAIL expected nonzero exit"; fail=1; }
must_contain     "$WORK/red1.log" "$INCONSISTENT"
must_not_contain "$WORK/red1.log" "$PAST_GUARD"

note "=== 3. a PRODUCT tag must NOT be rejected (the regression this guard caused) ==="
# build_release_assets.sh passes `v0.1.0` here while the pinned seed is named
# something else entirely. That is the normal, correct state of the tree.
setup_tree "$WORK/prod" "array-capacity-2026-09-20" "seed/array-capacity-2026-09-20"
bash "$WORK/prod/scripts/build_compiler_seed_assets.sh" "v0.1.0" "$WORK/prod/out" > "$WORK/prod.log" 2>&1
note "  exit=$?"
must_not_contain "$WORK/prod.log" "$INCONSISTENT"
must_not_contain "$WORK/prod.log" "$SEED_IDENTITY"
must_contain     "$WORK/prod.log" "$PAST_GUARD"

note "=== 4. the seed caller still refuses publishing a seed its manifest does not name ==="
setup_tree "$WORK/red2" "bytes-capacity-2026-09-15" "seed/bytes-capacity-2026-09-15"
bash "$WORK/red2/scripts/build_seed_release_assets.sh" "seed/$SEED" > "$WORK/red2.log" 2>&1
rc=$?
note "  exit=$rc"
[ "$rc" != 0 ] && note "  ok   nonzero exit" || { note "  FAIL expected nonzero exit"; fail=1; }
must_contain     "$WORK/red2.log" "$SEED_IDENTITY"
must_not_contain "$WORK/red2.log" "$PAST_GUARD"

note "=== 5. the seed caller lets through the seed its manifest DOES name ==="
setup_tree "$WORK/green2" "$SEED" "seed/$SEED"
bash "$WORK/green2/scripts/build_seed_release_assets.sh" "seed/$SEED" > "$WORK/green2.log" 2>&1
note "  exit=$?"
must_not_contain "$WORK/green2.log" "$SEED_IDENTITY"
must_contain     "$WORK/green2.log" "$PAST_GUARD"

note
if [ "$fail" = 0 ]; then note "[build-compiler-seed-assets-test] ok"; else note "[build-compiler-seed-assets-test] FAIL"; fi
exit "$fail"
