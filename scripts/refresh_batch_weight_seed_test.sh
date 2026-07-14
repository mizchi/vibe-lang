#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFRESH_SCRIPT="$SCRIPT_DIR/refresh_batch_weight_seed.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_batch_weight_seed.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/lib/@vibe/compiler" "$TMP_ROOT/out" "$TMP_ROOT/scripts"
touch "$TMP_ROOT/lib/@vibe/compiler/keep_test.vibe"
touch "$TMP_ROOT/lib/@vibe/compiler/new_split_test.vibe"
touch "$TMP_ROOT/lib/@vibe/compiler/s5_test.vibe"
touch "$TMP_ROOT/lib/@vibe/compiler/s5_wasm_test.vibe"
touch "$TMP_ROOT/lib/@vibe/compiler/codegen_parser_test.vibe"

cat > "$TMP_ROOT/scripts/test_batch_weights.seed.json" <<'EOF'
{
  "lib/@vibe/compiler/keep_test.vibe": 100,
  "lib/@vibe/compiler/removed_test.vibe": 999,
  "lib/@vibe/compiler/not_a_test.vibe": 50,
  "lib/@vibe/compiler/s5_test.vibe": 888,
  "lib/@vibe/compiler/codegen_parser_test.vibe": 777
}
EOF

cat > "$TMP_ROOT/out/selfhost_test_batch_weights.json" <<EOF
{
  "lib/@vibe/compiler/keep_test.vibe": 321,
  "${TMP_ROOT//\\/\\\\}/lib/@vibe/compiler/new_split_test.vibe": 654,
  "lib/@vibe/compiler/missing_test.vibe": 777,
  "lib/@vibe/compiler/s5_wasm_test.vibe": 777,
  "lib/@vibe/compiler/codegen_parser_test.vibe": 666
}
EOF

VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SELFHOST_BATCH_WEIGHT_CACHE="$TMP_ROOT/out/selfhost_test_batch_weights.json" \
VIBE_SELFHOST_BATCH_WEIGHT_SEED="$TMP_ROOT/scripts/test_batch_weights.seed.json" \
bash "$REFRESH_SCRIPT" >/dev/null

node - "$TMP_ROOT/scripts/test_batch_weights.seed.json" <<'EOF'
const fs = require("node:fs")
const seedPath = process.argv[2]
const actual = JSON.parse(fs.readFileSync(seedPath, "utf8"))
const expected = {
  "lib/@vibe/compiler/new_split_test.vibe": 654,
  "lib/@vibe/compiler/keep_test.vibe": 321,
}
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error("unexpected refreshed seed")
  console.error(JSON.stringify(actual, null, 2))
  process.exit(1)
}
EOF

echo "refresh-selfhost-batch-weight-seed self-test: ok"
