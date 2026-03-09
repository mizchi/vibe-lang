#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/rename_builtins.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_rename_builtins_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

cd "$TMP_ROOT"
git init -q

cat > sample.mbt <<'EOF'
///|
fn sample() -> String {
  let code = "map_set(m, key, value)"
  let untouched = map_set
  #|map_set(m, key, value)
  code
}
EOF

cat > sample.vibe <<'EOF'
let update = (m: Map[String, Int]) -> Map[String, Int] {
  map_set(m, "k", 1)
}
EOF

mkdir -p .claude
cat > .claude/ignored.mbt <<'EOF'
///|
fn ignored() -> String {
  "map_set(m, key, value)"
}
EOF

python3 "$PY_SCRIPT" --dry-run > dry_run.log

if ! rg -q 'WOULD MODIFY: sample.mbt' dry_run.log; then
  echo "rename-builtins test: dry-run did not report sample.mbt" >&2
  cat dry_run.log >&2
  exit 1
fi

if ! rg -q 'WOULD MODIFY: sample.vibe' dry_run.log; then
  echo "rename-builtins test: dry-run did not report sample.vibe" >&2
  cat dry_run.log >&2
  exit 1
fi

if rg -q '\.claude/ignored.mbt' dry_run.log; then
  echo "rename-builtins test: dry-run should ignore .claude/" >&2
  cat dry_run.log >&2
  exit 1
fi

python3 "$PY_SCRIPT" >/dev/null

if ! rg -q 'Map::set\(m, key, value\)' sample.mbt; then
  echo "rename-builtins test: .mbt string literal was not rewritten" >&2
  cat sample.mbt >&2
  exit 1
fi

if ! rg -q '^  #\|Map::set\(m, key, value\)$' sample.mbt; then
  echo "rename-builtins test: .mbt #| line was not rewritten" >&2
  cat sample.mbt >&2
  exit 1
fi

if ! rg -q '^  let untouched = map_set$' sample.mbt; then
  echo "rename-builtins test: .mbt code identifier should stay unchanged" >&2
  cat sample.mbt >&2
  exit 1
fi

if ! rg -q 'Map::set\(m, "k", 1\)' sample.vibe; then
  echo "rename-builtins test: .vibe file was not rewritten" >&2
  cat sample.vibe >&2
  exit 1
fi

if ! rg -q 'map_set\(m, key, value\)' .claude/ignored.mbt; then
  echo "rename-builtins test: excluded .claude file should stay unchanged" >&2
  cat .claude/ignored.mbt >&2
  exit 1
fi

echo "rename-builtins test: ok"
