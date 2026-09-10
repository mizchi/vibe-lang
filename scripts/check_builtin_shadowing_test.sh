#!/usr/bin/env bash
# Self-test for check_builtin_shadowing.sh (#2248: a gate means nothing until
# it is shown it CAN fail).
#
# Every case MUTATES a real tree and asserts the gate rejects it, and every
# case first asserts the mutation actually landed -- an edit that matches
# nothing passes while proving nothing, which is the failure #2248 records.
#
# The value-alias case (kind 13) is the one that matters most: the lexical
# scan this gate replaces passed on exactly that shape, so a self-test that
# only covers `fn` would certify the same hole.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# #2252: never inherit the knobs under test. Each case sets them explicitly.
unset BUILTIN_SHADOW_ALLOWLIST BUILTIN_SHADOW_ROOT BUILTIN_SHADOW_EXPECTED_UNREADABLE || true

GATE="$ROOT_DIR/scripts/check_builtin_shadowing.sh"
WORK="$ROOT_DIR/_build/_builtin_shadowing_selftest"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# A tree the gate must accept: one file, nothing the registry owns.
fresh_tree() { # <dir>
  rm -rf "$1"; mkdir -p "$1"
  printf 'export fn unrelated_helper(n: Int) -> Int {\n  n + 1\n}\n' > "$1/clean.vibe"
}

empty_allowlist() { # <path>
  printf '# self-test allowlist\n' > "$1"
}

# run_gate <tree> <allowlist> -> prints output, returns the gate's status
run_gate() {
  BUILTIN_SHADOW_ROOT="$1" BUILTIN_SHADOW_ALLOWLIST="$2" \
    bash "$GATE" 2>&1 || return $?
}

TREE="$WORK/tree"
ALLOW="$WORK/allow.txt"

# --- 0. GREEN control -------------------------------------------------------
# Without this every case below could "pass" on a gate that rejects anything.
fresh_tree "$TREE"; empty_allowlist "$ALLOW"
if out="$(run_gate "$TREE" "$ALLOW")"; then
  ok "a tree with no shadowing is accepted"
else
  bad "the clean control was rejected: $out"
fi

# --- 1. kind 12: a `fn` shadowing a builtin ---------------------------------
fresh_tree "$TREE"; empty_allowlist "$ALLOW"
printf 'export fn String::length(s: String) -> Int {\n  -1\n}\n' > "$TREE/shadow_fn.vibe"
if ! grep -q 'fn String::length' "$TREE/shadow_fn.vibe"; then
  bad "mutation 1 did not land"
elif out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "a \`fn String::length\` shadow was accepted: $out"
else
  case "$out" in
    *"String::length"*) ok "a \`fn\` shadowing a builtin is rejected, and named" ;;
    *) bad "rejected, but did not name String::length: $out" ;;
  esac
fi

# --- 2. kind 13: a VALUE ALIAS shadowing a builtin --------------------------
# The shape the removed regex missed (`export let Fs::exists = exists`).
fresh_tree "$TREE"; empty_allowlist "$ALLOW"
printf 'fn local_exists(p: String) -> Bool {\n  String::length(p) > 0\n}\n\nexport let Fs::exists = local_exists\n' > "$TREE/shadow_alias.vibe"
if ! grep -q 'let Fs::exists' "$TREE/shadow_alias.vibe"; then
  bad "mutation 2 did not land"
elif out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "a VALUE ALIAS shadow was accepted -- this is the regex's blind spot: $out"
else
  case "$out" in
    *"Fs::exists"*) ok "a value-alias (kind 13) shadow is rejected, and named" ;;
    *) bad "rejected, but did not name Fs::exists: $out" ;;
  esac
fi

# --- 3. an allowlist row with a reason suppresses exactly that name ---------
fresh_tree "$TREE"
printf 'export fn String::length(s: String) -> Int {\n  -1\n}\n' > "$TREE/shadow_fn.vibe"
printf '# self-test allowlist\nString::length deliberate, for the self-test\n' > "$ALLOW"
if out="$(run_gate "$TREE" "$ALLOW")"; then
  ok "an allowlisted name with a reason is accepted"
else
  bad "an allowlisted name was still rejected: $out"
fi

# --- 4. an allowlist row with NO reason is rejected -------------------------
fresh_tree "$TREE"
printf 'export fn String::length(s: String) -> Int {\n  -1\n}\n' > "$TREE/shadow_fn.vibe"
printf '# self-test allowlist\nString::length\n' > "$ALLOW"
if out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "a reasonless allowlist row was accepted: $out"
else
  case "$out" in
    *"no reason"*) ok "an allowlist row with no reason is rejected" ;;
    *) bad "rejected, but not about the missing reason: $out" ;;
  esac
fi

# --- 5. a STALE allowlist row is rejected -----------------------------------
# The list shrinks only; a row that outlives its subject must not linger.
fresh_tree "$TREE"
printf '# self-test allowlist\nString::length it was removed from the tree, so this row is stale\n' > "$ALLOW"
if out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "a stale allowlist row was accepted: $out"
else
  case "$out" in
    *"no longer declared"*) ok "a stale allowlist row is rejected" ;;
    *) bad "rejected, but not about staleness: $out" ;;
  esac
fi

# --- 6. an UNREADABLE file fails, rather than being skipped -----------------
# A file the sweep cannot parse had its declarations inspected by nobody.
# Silence there is "unchecked", not "clean".
fresh_tree "$TREE"; empty_allowlist "$ALLOW"
printf 'export fn broken( {\n' > "$TREE/unparseable.vibe"
if ! grep -q 'fn broken(' "$TREE/unparseable.vibe"; then
  bad "mutation 6 did not land"
elif out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "an unreadable file was skipped silently: $out"
else
  case "$out" in
    *"could not be read"*) ok "an unreadable file fails the gate instead of being skipped" ;;
    *) bad "rejected, but not about the unreadable file: $out" ;;
  esac
fi

# --- 7. an EMPTY sweep fails ------------------------------------------------
# "Nothing came back" must never read as "nothing is wrong".
rm -rf "$TREE"; mkdir -p "$TREE"; empty_allowlist "$ALLOW"
if out="$(run_gate "$TREE" "$ALLOW")"; then
  bad "an empty sweep was accepted as clean: $out"
else
  case "$out" in
    *"produced nothing"*) ok "an empty sweep fails instead of passing vacuously" ;;
    *) bad "rejected, but not about the empty sweep: $out" ;;
  esac
fi

# --- 8. a compiler that cannot sweep a directory REFUSES, not grinds --------
# Batch symbols is #2381; the committed seed predates it and reads a directory
# as a file. The per-file fallback covers small trees (every case above runs
# through it when this suite is handed a seed), but it must never silently
# re-pay the ~17 minutes #2381 removed. Pinned with the seed explicitly and a
# cap of 0, so the assertion does not depend on which compiler is ambient.
fresh_tree "$TREE"; empty_allowlist "$ALLOW"
if [ -s "$ROOT_DIR/bootstrap/seed/compiler.wasm" ]; then
  if out="$(BUILTIN_SHADOW_STAGE2="$ROOT_DIR/bootstrap/seed/compiler.wasm" \
            BUILTIN_SHADOW_FALLBACK_CAP=0 \
            BUILTIN_SHADOW_ROOT="$TREE" BUILTIN_SHADOW_ALLOWLIST="$ALLOW" \
            bash "$GATE" 2>&1)"; then
    bad "past the fallback cap the gate passed instead of refusing: $out"
  else
    case "$out" in
      *"fallback cap"*) ok "past the fallback cap the gate refuses, naming the fix" ;;
      *) bad "refused, but not about the cap: $out" ;;
    esac
  fi
else
  bad "no committed seed to pin the no-batch lane against"
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
