#!/usr/bin/env bash
# Red/green for the seed-manifest identity guard in
# scripts/build_compiler_seed_assets.sh (#2248 discipline: a guard means
# nothing until it is shown to fail).
#
# The guard's whole input is $TAG plus bootstrap/seed.json, so this runs the
# real script against a scratch PROJECT_ROOT holding a real manifest and a
# real (tiny) artifact. scripts/generate_bundle.sh is deliberately absent
# there: reaching it is how a passing guard is OBSERVED rather than assumed.
# A green case that merely "did not print the guard message" would also be
# satisfied by the script dying earlier, which is the proxy #2248 is about.
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

# A scratch tree: the script under test, a seed artifact, and a manifest whose
# sha256 matches it (so the PRE-EXISTING sha guard cannot be what fires).
setup_tree() {
  local dir="$1" name="$2" tag="$3"
  rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/bootstrap/seed"
  cp "$ROOT_DIR/scripts/build_compiler_seed_assets.sh" "$dir/scripts/"
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

PUBLISHING="demo-seed-2026-09-20"
GUARD_NAME="names a different seed than the tag being published"
GUARD_TAG="tags a different release than the one being published"
PAST_GUARD="compiler module source generation failed"

note "=== green: manifest agrees with the tag -> execution reaches past the guard ==="
setup_tree "$WORK/green" "$PUBLISHING" "seed/$PUBLISHING"
bash "$WORK/green/scripts/build_compiler_seed_assets.sh" "$PUBLISHING" "$WORK/green/out" \
  > "$WORK/green.log" 2>&1
note "  exit=$?"
must_not_contain "$WORK/green.log" "$GUARD_NAME"
must_not_contain "$WORK/green.log" "$GUARD_TAG"
must_contain     "$WORK/green.log" "$PAST_GUARD"

note "=== red 1: seed.name still names the PREVIOUS seed (the measured defect) ==="
setup_tree "$WORK/red1" "bytes-capacity-2026-09-15" "seed/$PUBLISHING"
bash "$WORK/red1/scripts/build_compiler_seed_assets.sh" "$PUBLISHING" "$WORK/red1/out" \
  > "$WORK/red1.log" 2>&1
rc=$?
note "  exit=$rc"
[ "$rc" != 0 ] && note "  ok   nonzero exit" || { note "  FAIL expected nonzero exit"; fail=1; }
must_contain     "$WORK/red1.log" "$GUARD_NAME"
must_not_contain "$WORK/red1.log" "$PAST_GUARD"

note "=== red 2: seed.tag points at another release ==="
setup_tree "$WORK/red2" "$PUBLISHING" "seed/some-other-seed-2026-01-01"
bash "$WORK/red2/scripts/build_compiler_seed_assets.sh" "$PUBLISHING" "$WORK/red2/out" \
  > "$WORK/red2.log" 2>&1
rc=$?
note "  exit=$rc"
[ "$rc" != 0 ] && note "  ok   nonzero exit" || { note "  FAIL expected nonzero exit"; fail=1; }
must_contain     "$WORK/red2.log" "$GUARD_TAG"
must_not_contain "$WORK/red2.log" "$PAST_GUARD"

note
if [ "$fail" = 0 ]; then note "[build-compiler-seed-assets-test] ok"; else note "[build-compiler-seed-assets-test] FAIL"; fi
exit "$fail"
