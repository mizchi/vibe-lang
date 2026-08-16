#!/usr/bin/env bash
# #1970: an empty selector list must not trip Bash 3.2 `set -u`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test-affected.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Intercept node so the test stays a shell contract, not a graph walk.
# The argv sink is baked into the stub; the parent script does not export it.
cat >"$TMP/node" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" >"$TMP/argv.last"
exit 2
EOF
chmod +x "$TMP/node"

# macOS ships Bash 3.2; that is the version that treats empty "${arr[@]}"
# as unbound under `set -u`. Prefer it when present.
if [ -x /bin/bash ]; then
  BASH_BIN=/bin/bash
else
  BASH_BIN=bash
fi

set +e
PATH="$TMP:$PATH" "$BASH_BIN" "$ROOT/scripts/test_affected.sh" --dry-run \
  >"$TMP/out.empty" 2>"$TMP/err.empty"
empty_rc=$?
set -e

if grep -q 'unbound variable' "$TMP/err.empty"; then
  echo "test_affected_test: empty selector list unbound under $BASH_BIN (#1970)" >&2
  cat "$TMP/err.empty" >&2
  exit 1
fi
if [ "$empty_rc" -ne 0 ]; then
  echo "test_affected_test: empty --dry-run should exit 0 after undetermined selection, got $empty_rc" >&2
  cat "$TMP/err.empty" >&2
  exit 1
fi
cp "$TMP/argv.last" "$TMP/argv.empty"
if [ ! -s "$TMP/argv.empty" ]; then
  echo "test_affected_test: expected the selector to be invoked with no extra args" >&2
  exit 1
fi
if grep -q -- '--changed' "$TMP/argv.empty"; then
  echo "test_affected_test: empty invocation forwarded selector flags" >&2
  cat "$TMP/argv.empty" >&2
  exit 1
fi

set +e
PATH="$TMP:$PATH" "$BASH_BIN" "$ROOT/scripts/test_affected.sh" --dry-run --explain \
  >"$TMP/out.explain" 2>"$TMP/err.explain"
explain_rc=$?
set -e
cp "$TMP/argv.last" "$TMP/argv.explain"
if [ "$explain_rc" -ne 0 ]; then
  echo "test_affected_test: --explain --dry-run should exit 0, got $explain_rc" >&2
  cat "$TMP/err.explain" >&2
  exit 1
fi
if ! grep -qx -- '--explain' "$TMP/argv.explain"; then
  echo "test_affected_test: --explain was not forwarded to the selector" >&2
  cat "$TMP/argv.explain" >&2
  exit 1
fi

echo "test_affected_test: ok"
