#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-vibe"
cat >"$FAKE_BIN" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
SH
chmod +x "$FAKE_BIN"

OUT="$(VIBE_CLI_BIN_OVERRIDE="$FAKE_BIN" "$ROOT_DIR/scripts/run_cached_vibe.sh" alpha "two words")"

EXPECTED="$(printf '<alpha>\n<two words>')"
if [[ "$OUT" != "$EXPECTED" ]]; then
  printf 'run_cached_vibe_test: unexpected argv forwarding\nexpected:\n%s\nactual:\n%s\n' "$EXPECTED" "$OUT" >&2
  exit 1
fi

echo "run_cached_vibe_test: ok"
