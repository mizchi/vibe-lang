#!/usr/bin/env bash
# #1348: mechanical detector for the inline-builtin CAPTURE gap.
#
# compile_call.vibe lowers some builtins INLINE (`!prefer_bound_call && fname
# == "X"`) instead of routing them through the func table. Such a name has no
# closure value, so the free-variable collector
# (codegen/common_analysis/common_analysis.vibe) must not record it as a
# capturable free variable -- otherwise a lambda that calls it captures a slot
# that holds nothing and the call lowers to a `call_indirect` of a nonexistent
# closure: an "invalid signature index" module or a "null function or function
# signature mismatch" trap at runtime.
#
# That gap has been reintroduced four separate times by adding an inline
# dispatch and forgetting the registration (#773 `not`/`add`/..., #1095
# `assert`, #1230 `Future::pending`/`Future::resolve`, #1218
# `Path::to_string`/`Path::is_absolute`), each found only when a user program
# crashed. This script enumerates the class instead:
#
#   inline-dispatched  AND NOT func-table-registered  AND NOT capture-registered
#
# Names that are legitimately outside the rule are listed, with a reason, in
# scripts/inline_builtin_capture_allowlist.txt. A NEW name appearing here is a
# latent closure miscompile -- add it to is_inlined_async_builtin /
# is_inlined_scalar_builtin, or to the allowlist with a measured reason.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CALL_SRC="lib/@vibe/compiler/codegen/expr/compile_call.vibe"
ANALYSIS_SRC="lib/@vibe/compiler/codegen/common_analysis/common_analysis.vibe"
REGISTRY_SRC="lib/@vibe/compiler/codegen/common_base/builtin_registry.vibe"
ALLOWLIST="scripts/inline_builtin_capture_allowlist.txt"

for f in "$CALL_SRC" "$ANALYSIS_SRC" "$REGISTRY_SRC"; do
  [ -f "$f" ] || { echo "check-inline-builtin-capture: missing $f" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Names dispatched INLINE by compile_call. Both spellings are used:
#    `!prefer_bound_call && fname == "X"` and the parenthesised
#    `!prefer_bound_call && (fname == "A" || fname == "B")` form. The second
#    grep would miss every name past the first without the `-o` split.
{
  grep -o '!prefer_bound_call && fname == "[^"]*"' "$CALL_SRC" |
    sed 's/.*fname == "//; s/"$//'
  grep -o '!prefer_bound_call && (fname == "[^)]*)' "$CALL_SRC" |
    grep -o 'fname == "[^"]*"' | sed 's/fname == "//; s/"$//'
} | sort -u > "$tmp/inline.txt"

if [ ! -s "$tmp/inline.txt" ]; then
  echo "check-inline-builtin-capture: FAIL: found no inline dispatches in $CALL_SRC" >&2
  echo "  (the '!prefer_bound_call && fname ==' spelling changed -- update this script)" >&2
  exit 1
fi

# 2. Names the capture analysis already knows to skip.
sed -n '/^fn is_inlined_async_builtin/,/^}/p;/^fn is_inlined_scalar_builtin/,/^}/p;/^fn is_inlined_simd_builtin/,/^}/p' "$ANALYSIS_SRC" |
  grep -o 'name == "[^"]*"' | sed 's/name == "//; s/"$//' | sort -u > "$tmp/registered.txt"

if [ ! -s "$tmp/registered.txt" ]; then
  echo "check-inline-builtin-capture: FAIL: found no registered names in $ANALYSIS_SRC" >&2
  exit 1
fi

# 3. Names present in the LINEAR func table (3rd field of the registry row
#    `(name, sig, in_linear_table, in_gc_table, checker_visible)`). A
#    func-table name is reached by the collector's own fn_names guard, so it
#    can never be captured by mistake and needs no registration.
grep -o '("[^"]*", *Ct[^,]*.*, *true, *\(true\|false\), *\(true\|false\))' "$REGISTRY_SRC" |
  sed 's/^("//; s/".*//' | sort -u > "$tmp/functable.txt"

# 4. Documented exclusions.
if [ -f "$ALLOWLIST" ]; then
  grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' |
    awk '{print $1}' | sort -u > "$tmp/allow.txt"
else
  : > "$tmp/allow.txt"
fi

comm -23 "$tmp/inline.txt" "$tmp/registered.txt" > "$tmp/step1.txt"
comm -23 "$tmp/step1.txt" "$tmp/functable.txt" > "$tmp/step2.txt"
comm -23 "$tmp/step2.txt" "$tmp/allow.txt" > "$tmp/gaps.txt"

# A name that left the inline dispatch but is still allowlisted is stale
# bookkeeping -- report it so the allowlist cannot rot into a list of names
# nobody can explain.
comm -13 "$tmp/inline.txt" "$tmp/allow.txt" > "$tmp/stale.txt"

status=0
if [ -s "$tmp/gaps.txt" ]; then
  echo "check-inline-builtin-capture: FAIL: inline-dispatched builtins that a closure would capture:" >&2
  sed 's/^/  - /' "$tmp/gaps.txt" >&2
  echo "" >&2
  echo "  Each is a latent closure miscompile (invalid signature index / null function)." >&2
  echo "  Fix: add it to is_inlined_async_builtin or is_inlined_scalar_builtin in" >&2
  echo "  $ANALYSIS_SRC, or record a measured reason in $ALLOWLIST." >&2
  status=1
fi
if [ -s "$tmp/stale.txt" ]; then
  echo "check-inline-builtin-capture: FAIL: allowlisted names that are no longer inline-dispatched:" >&2
  sed 's/^/  - /' "$tmp/stale.txt" >&2
  echo "  Remove them from $ALLOWLIST." >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "check-inline-builtin-capture: ok ($(wc -l < "$tmp/inline.txt" | tr -d ' ') inline dispatches, $(wc -l < "$tmp/allow.txt" | tr -d ' ') allowlisted)"
fi
exit "$status"
