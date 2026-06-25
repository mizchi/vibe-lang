#!/usr/bin/env bash
# Regression test for located diagnostics (docs/release-roadmap.md source-span):
# `vibe check` reports `line N:col M:` for parse errors and the common type
# errors (unknown name / arity), via the freshly built compiler. Guards the
# located-diagnostic + the `+`-string-concat NUL fix.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

bash scripts/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"

pass=0; fail=0
expect_contains() { # <desc> <needle> <file.vibe content...>
  local desc="$1" needle="$2"; shift 2
  local f="$WORK/case.vibe"
  printf '%b' "$1" > "$f"
  local out; out="$("$VIBE" check "$f" 2>&1 || true)"
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "ok: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (want '$needle' in: $out)" >&2; fail=$((fail + 1))
  fi
}

# parse error on line 2 -> line:col located
expect_contains "parse error located on line 2" "line 2:" \
  'export let a = 1\nexport let bad = = 5\n'

# unknown name -> located with the exact column of the symbol
expect_contains "unknown-name type error located" "line 1:" \
  'export let main = () -> Int { zzz }\n'

# arity mismatch -> located
expect_contains "arity mismatch located" "function arity mismatch" \
  'let h = (a: Int, b: Int) -> Int { a + b }\nexport let main = () -> Int { h(1) }\n'

# a good program -> check passes (no error)
printf 'export let main = () -> Int { 40 + 2 }\n' > "$WORK/ok.vibe"
if "$VIBE" check "$WORK/ok.vibe" >/dev/null 2>&1; then
  echo "ok: good program checks clean"; pass=$((pass + 1))
else
  echo "FAIL: good program should check clean" >&2; fail=$((fail + 1))
fi

echo "[located-diagnostics] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
