#!/usr/bin/env bash
# Self-test for scripts/lint_method_style_naming.vibex (#3672 ported the lint).
#
# Runs the lint against a synthetic package tree under _build/ (the guest reads
# only inside the repository) instead of this repository, so the cases stay
# fixed while the real allowlist shrinks.
#
# The first case is why this file exists. @vibe/builtin's contract re-declares
# `type Int` / `type String` / ... so it reads as a self-contained surface, and
# the lint counted those as types the package OWNS -- so every
# `fn f(s: String, ...)` in it became a gap wanting a `String::f` companion,
# which is not a function anyone can write. That is 39 false positives, it
# reached main in #1614, and it went unnoticed for roughly 300 commits because
# this lint had no CI job and no test.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
TMP_REL="_build/method_naming_test.$$"
TMP="$ROOT_DIR/$TMP_REL"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts" "$TMP/lib/@vibe/demo"
allow="$TMP/scripts/method_style_naming_allowlist.txt"
: > "$allow"

run() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/lint_method_style_naming.vibex -- --root "$TMP_REL" 2>&1; }

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

# 0. The real tree passes.
real_out="$(bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/lint_method_style_naming.vibex 2>&1)" \
  || { echo "$real_out" >&2; echo "method-naming self-test: FAIL: the real tree must pass" >&2; exit 1; }
echo "method-naming self-test: ok: the real tree passes"

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

# 6. A positional receiver (ADR-0120, `_ recv: Type`) is still a receiver. The
#    shell lint's pattern required `name: Type` and stopped seeing these.
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn frob(_ w: Widget) -> Int
EOF
expect 1 "a positional receiver with no companion is a gap" "frob(recv: Widget, ...)"

# 7. A generic receiver with one argument list, and the count of what was
#    checked: `Widget[T]` counts, `Widget[Map[K, V]]` (a nested list) and a
#    second parameter of the type do not.
vpkg <<'EOF'
name = @vibe/demo
version = 0.1.0

opaque type Widget

fn spin(w: Widget[Int], n: Int) -> Int
fn Widget::spin(w: Widget[Int], n: Int) -> Int
fn nested(w: Widget[Map[Int, Int]]) -> Int
fn second(n: Int, w: Widget) -> Int
EOF
expect 0 "only first-parameter receivers with one argument list are recv-shaped" "checked 1 recv-shaped fn(s)"

# 8. A nested package's contract is in scope too.
mkdir -p "$TMP/lib/@vibe/demo/inner"
cat > "$TMP/lib/@vibe/demo/inner/index.vpkg" <<'EOF'
name = @vibe/demo/inner
version = 0.1.0

opaque type Gadget

fn tweak(g: Gadget) -> Int
EOF
expect 1 "a nested package's contract is scanned" "lib/@vibe/demo/inner/index.vpkg: tweak(recv: Gadget, ...)"
rm -rf "$TMP/lib/@vibe/demo/inner"

# 9. No contract at all is not a clean tree.
rm -f "$TMP/lib/@vibe/demo/index.vpkg"
expect 1 "a tree with no contract fails" "no index.vpkg files found"

echo "method-naming self-test: all cases passed"
