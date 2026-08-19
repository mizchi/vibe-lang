#!/usr/bin/env bash
# Self-test for scripts/lint_method_style_naming.sh.
#
# Runs the lint against a synthetic package tree instead of this repository, so
# the cases stay fixed while the real allowlist shrinks. The lint reads its
# scope with `git ls-files`, so the fixture has to be a git repository.
#
# The first case is why this file exists. @vibe/prelude's contract re-declares
# `type Int` / `type String` / ... so it reads as a self-contained surface, and
# the lint counted those as types the package OWNS -- so every
# `fn f(s: String, ...)` in it became a gap wanting a `String::f` companion,
# which is not a function anyone can write. That is 39 false positives, it
# reached main in #1614, and it went unnoticed for roughly 300 commits because
# this lint has no CI job and no test: the only thing it broke was
# `pkf run release-check`, which is a local sign-off nobody re-runs on a green
# tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/lint_method_style_naming.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_method_naming_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts" "$TMP/lib/@vibe/demo"
cp "$LINT" "$TMP/scripts/"
allow="$TMP/scripts/method_style_naming_allowlist.txt"
: > "$allow"

git -C "$TMP" init -q
git -C "$TMP" config user.email t@example.com
git -C "$TMP" config user.name t

run() { (cd "$TMP" && git add -A >/dev/null 2>&1; bash scripts/lint_method_style_naming.sh 2>&1); }

expect() { # expect <exit> <label> [needle]
  local want="$1" label="$2" needle="${3:-}" out rc
  set +e; out="$(run)"; rc=$?; set -e
  if [ "$rc" != "$want" ]; then
    echo "method-naming self-test: FAIL: $label -- exit $rc, wanted $want" >&2
    echo "$out" >&2
    exit 1
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" <<<"$out"; then
    echo "method-naming self-test: FAIL: $label -- output does not mention '$needle'" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "method-naming self-test: ok: $label"
}

vpkg() { cat > "$TMP/lib/@vibe/demo/index.vpkg"; }

# 1. A re-declared primitive is not a package-owned type. RED before the fix:
#    this reported `shout(recv: String, ...)` as a gap.
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

// Compiler-provided declarations intentionally exposed by this package.
type Int
type String

fn shout(s: String, loud: Bool) -> String
fn double(n: Int) -> Int
EOF
expect 0 "a re-declared primitive receiver is not a gap"

# 2. A type the package really owns still is. Without this the fix above would
#    read as "turn the lint off".
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn frob(w: Widget) -> Int
EOF
expect 1 "an owned-type receiver with no companion is a gap" "frob(recv: Widget, ...)"

# 3. ...and the companion the lint asks for clears it.
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn frob(w: Widget) -> Int
fn Widget::frob(w: Widget) -> Int
EOF
expect 0 "declaring Type::name clears the gap"

# 4. The allowlist is the other way to clear it, and stops being silent once
#    the companion exists.
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn frob(w: Widget) -> Int
EOF
printf 'lib/@vibe/demo/index.vpkg\tfrob\n' > "$allow"
expect 0 "an allowlisted gap is known debt, not a violation"

vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn frob(w: Widget) -> Int
fn Widget::frob(w: Widget) -> Int
EOF
expect 0 "a stale allowlist entry is reported" "these allowlist entries now have a Type::method companion"

# 5. A package-owned type that happens to share a name with a stdlib generic --
#    @vibe/wit_runtime's own `export enum Result` is the live instance -- must
#    keep being scanned. `Result` is deliberately not in the primitive list.
: > "$allow"
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

export enum Result

fn unwrap_or(r: Result, fallback: Int) -> Int
EOF
expect 1 "an owned type sharing a stdlib name is still scanned" "unwrap_or(recv: Result, ...)"

echo "method-naming self-test: all cases passed"
