#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_REAL="$TMP_DIR/flaker-real.js"
cat >"$FAKE_REAL" <<'JS'
import { fileURLToPath } from "node:url";

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  console.log(process.argv.slice(2).join("\n"));
}
JS

chmod +x "$FAKE_REAL"
ln -s "$FAKE_REAL" "$TMP_DIR/flaker"

OUT="$(PATH="$TMP_DIR:$PATH" "$ROOT_DIR/scripts/flaker_run.sh" --dry-run --explain)"
EXPECTED="$(printf 'run\n--dry-run\n--explain')"
if [[ "$OUT" != "$EXPECTED" ]]; then
  printf 'flaker_run_test: unexpected argv forwarding\nexpected:\n%s\nactual:\n%s\n' "$EXPECTED" "$OUT" >&2
  exit 1
fi

echo "flaker_run_test: ok"
