#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_runtime_fixtures}"
SNAPSHOT_FILE="${VIBE_SELFHOST_RUNTIME_FIXTURE_SNAPSHOT_FILE:-$PROJECT_ROOT/bench/golden/selfhost_runtime_fixture_snapshot.json}"
SHARD_SIZE="${VIBE_SELFHOST_RUNTIME_FIXTURE_SHARD_SIZE:-10}"
GENERATED_DIR="$PROJECT_ROOT/vibe/compiler/_generated_selfhost_runtime_fixtures"

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native src/cmd/vibe --warn-list '-29' >/dev/null
fi

cd "$PROJECT_ROOT"
mkdir -p "$OUT_DIR"
cleanup() {
  rm -rf "$GENERATED_DIR"
}
trap cleanup EXIT

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "selfhost runtime fixtures: missing snapshot: $SNAPSHOT_FILE" >&2
  echo "run: node scripts/update_selfhost_runtime_fixture_snapshot.mjs" >&2
  exit 1
fi

CANDIDATES_FILE="$OUT_DIR/candidate_paths.txt"
PASSED_PATHS_FILE="$OUT_DIR/passed_paths.txt"

VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY=1 \
node scripts/generate_selfhost_runtime_fixture_tests.mjs >"$CANDIDATES_FILE"

node - "$SNAPSHOT_FILE" "$CANDIDATES_FILE" "$PASSED_PATHS_FILE" <<'NODE'
const fs = require("node:fs");
const [snapshotPath, candidatesPath, passedPath] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
const current = fs.readFileSync(candidatesPath, "utf8").split("\n").map((line) => line.trim()).filter(Boolean);
const expected = snapshot.candidate_paths || [];
if (JSON.stringify(current) !== JSON.stringify(expected)) {
  console.error("selfhost runtime fixtures: candidate fixture set changed");
  console.error(`snapshot: ${snapshotPath}`);
  console.error("run: node scripts/update_selfhost_runtime_fixture_snapshot.mjs");
  process.exit(1);
}
const passed = snapshot.passed_paths || [];
if (passed.length === 0) {
  console.error("selfhost runtime fixtures: snapshot has no passed fixtures");
  process.exit(1);
}
fs.writeFileSync(passedPath, `${passed.join("\n")}\n`);
NODE

GENERATED_TESTS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  GENERATED_TESTS+=("$line")
done < <(
  VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE="$PASSED_PATHS_FILE" \
  VIBE_SELFHOST_RUNTIME_FIXTURE_SHARD_SIZE="$SHARD_SIZE" \
  node scripts/generate_selfhost_runtime_fixture_tests.mjs
)

VIBE_TEST_BACKEND="${VIBE_TEST_BACKEND:-compiled}" \
"$VIBE_BIN" test \
  "${GENERATED_TESTS[@]}"
