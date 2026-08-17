#!/usr/bin/env bash
# Self-test for #1988 option 1: SessionStart must persist a working
# VIBE_REVIEW_LINT_GREP_BIN, and scripts/vibe_grep_bin.sh must speak
# `vibe grep` without a native runtime/vibe runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT_DIR/.claude/hooks/session-start.sh"
GREP_BIN="$ROOT_DIR/scripts/vibe_grep_bin.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_session_start_grep.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "session-start-grep self-test: FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Invoker: fail closed, no `ok`, same CLI surface review_lint.vibex uses.
# ---------------------------------------------------------------------------
if [ ! -f "$GREP_BIN" ]; then
  fail "missing $GREP_BIN"
fi

: > "$TMP/probe.vibe"
printf 'fn probe() {\n  0\n}\n' > "$TMP/probe.vibe"

run_grep() {
  local status=0
  : > "$TMP/grep.out"
  : > "$TMP/grep.err"
  VIBE_CLI_WASM="${VIBE_CLI_WASM-}" \
    bash "$GREP_BIN" "$@" >"$TMP/grep.out" 2>"$TMP/grep.err" || status=$?
  return "$status"
}

# Explicit missing compiler: do not fall through to a lying success.
if VIBE_CLI_WASM="$TMP/missing-compiler.wasm" run_grep grep --pattern 'fn($(x:exp))' "$TMP/probe.vibe"; then
  fail "vibe_grep_bin.sh succeeded with a missing VIBE_CLI_WASM"
fi
if grep -qx 'ok' "$TMP/grep.out" "$TMP/grep.err"; then
  fail "vibe_grep_bin.sh printed ok after a missing compiler"
fi

# Missing pattern is a usage error, not a silent skip.
if run_grep grep "$TMP/probe.vibe"; then
  fail "vibe_grep_bin.sh accepted grep without --pattern"
fi

# --help must not need wasm (cheap probe surface).
if ! VIBE_CLI_WASM="$TMP/missing-compiler.wasm" run_grep grep --help; then
  fail "vibe_grep_bin.sh grep --help should exit 0 without a compiler"
fi
if ! grep -q -- '--pattern' "$TMP/grep.out"; then
  fail "vibe_grep_bin.sh --help did not mention --pattern"
fi
if grep -q 'runner-should-not-run' "$TMP/grep.out" "$TMP/grep.err"; then
  fail "vibe_grep_bin.sh --help invoked a runner"
fi

# --probe with an unusable compiler must fail closed.
if VIBE_CLI_WASM="$TMP/missing-compiler.wasm" run_grep --probe; then
  fail "vibe_grep_bin.sh --probe succeeded without a compiler"
fi
if grep -qx 'ok' "$TMP/grep.out" "$TMP/grep.err"; then
  fail "vibe_grep_bin.sh --probe printed ok after failure"
fi

# ---------------------------------------------------------------------------
# SessionStart persist / honesty.
# ---------------------------------------------------------------------------
FAKE="$TMP/fake-project"
mkdir -p "$FAKE/scripts"

cat > "$FAKE/scripts/ensure_generated.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE/scripts/ensure_generated.sh"

cat > "$FAKE/scripts/install_wasmtime_release.sh" <<'EOF'
#!/usr/bin/env bash
echo "session-start-grep self-test: install_wasmtime_release.sh should not run" >&2
exit 1
EOF
chmod +x "$FAKE/scripts/install_wasmtime_release.sh"

cat > "$FAKE/scripts/vibe_grep_bin.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--probe" ]; then
  if [ -f "$(dirname "$0")/.probe-fail" ]; then
    echo "probe failed" >&2
    exit 1
  fi
  exit 0
fi
echo "ok"
exit 0
EOF
chmod +x "$FAKE/scripts/vibe_grep_bin.sh"

run_hook() {
  local env_file="$1"
  : > "$env_file"
  HOME="$TMP/home" \
    CLAUDE_CODE_REMOTE=true \
    CLAUDE_PROJECT_DIR="$FAKE" \
    CLAUDE_ENV_FILE="$env_file" \
    bash "$HOOK"
}

# Local sessions must not persist anything.
: > "$TMP/local.env"
if ! HOME="$TMP/home" CLAUDE_PROJECT_DIR="$FAKE" CLAUDE_ENV_FILE="$TMP/local.env" bash "$HOOK"; then
  fail "SessionStart without CLAUDE_CODE_REMOTE exited non-zero"
fi
if [ -s "$TMP/local.env" ]; then
  fail "SessionStart without CLAUDE_CODE_REMOTE wrote $TMP/local.env"
fi

# Successful probe persists the invoker path.
if ! out="$(run_hook "$TMP/ok.env" 2>&1)"; then
  echo "$out" >&2
  fail "SessionStart with a working probe exited non-zero"
fi
if ! grep -q "VIBE_REVIEW_LINT_GREP_BIN=$FAKE/scripts/vibe_grep_bin.sh" "$TMP/ok.env"; then
  echo "$out" >&2
  cat "$TMP/ok.env" >&2
  fail "SessionStart did not persist VIBE_REVIEW_LINT_GREP_BIN after a successful probe"
fi

# Failed probe: WARNING, var unset (same honesty as #2034).
: > "$FAKE/scripts/.probe-fail"
if ! out="$(run_hook "$TMP/fail.env" 2>&1)"; then
  echo "$out" >&2
  fail "SessionStart with a failed probe must still exit 0"
fi
if grep -q 'VIBE_REVIEW_LINT_GREP_BIN=' "$TMP/fail.env"; then
  echo "$out" >&2
  cat "$TMP/fail.env" >&2
  fail "SessionStart persisted VIBE_REVIEW_LINT_GREP_BIN after a failed probe"
fi
if ! printf '%s\n' "$out" | grep -q 'WARNING'; then
  echo "$out" >&2
  fail "SessionStart did not print a WARNING when the grep probe failed"
fi

# ensure_generated failure: do not persist a lying path.
rm -f "$FAKE/scripts/.probe-fail"
cat > "$FAKE/scripts/ensure_generated.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
if ! out="$(run_hook "$TMP/nogen.env" 2>&1)"; then
  echo "$out" >&2
  fail "SessionStart with a failed ensure_generated must still exit 0"
fi
if grep -q 'VIBE_REVIEW_LINT_GREP_BIN=' "$TMP/nogen.env"; then
  echo "$out" >&2
  cat "$TMP/nogen.env" >&2
  fail "SessionStart persisted VIBE_REVIEW_LINT_GREP_BIN after ensure_generated failed"
fi

echo "session-start-grep self-test: ok"
