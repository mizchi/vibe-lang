#!/usr/bin/env bash
# A top-level `fn X::y` in the shipped library replaces the builtin named X::y
# for the WHOLE linked program -- including at call sites in files that never
# imported it, and in programs that only imported some unrelated name from the
# same package. Nothing diagnoses it.
#
# A BARE name (`eq`, `not`, `println`) is contained to its own file. Measured
# 2026-08-28 on four names; the split is recorded in the allowlist. The gate
# reports both shapes because that containment is an observed property of
# today's resolver rather than a stated rule, but only the qualified ones can
# surprise a dependent.
#
# Measured (2026-08-28, stage2 of 3725175): with
# `import @vibe/builtin { String::trim }` and nothing else, a sparse
# `String::index_of` over a 22 KiB haystack went from 0.8 us to 174 us (~218x)
# because the package's scalar re-implementation took over, and
# `String::split(s, "")` changed from a hard trap into `["abc"]`. Same source,
# two behaviours, decided by an unrelated import.
#
# So: `lib/**` must not define a name the builtin registry already owns.
# scripts/builtin_shadowing_allowlist.txt records the ones that predate this
# gate. Entries may be REMOVED, never added.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

REGISTRY="lib/@vibe/compiler/core/builtin_registry.vibe"
ALLOWLIST="${VIBE_SHADOW_ALLOWLIST:-scripts/builtin_shadowing_allowlist.txt}"
LIB_ROOT="${VIBE_SHADOW_LIB_ROOT:-lib}"

if [ ! -f "$REGISTRY" ]; then
  echo "check_builtin_shadowing: registry not found: $REGISTRY" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Set operations are done in awk, not with sort/comm. Under `pkf` this
# container resolves `sort` to a nix build that cannot load its own libc; a
# gate that silently produced an empty corpus there would pass while checking
# nothing (#2252: a gate must not assume the environment it runs in).

# Builtin names: the registry's `("NAME", CtFn(...)` rows.
awk '
  match($0, /^[ \t]*\("[A-Za-z_][A-Za-z0-9_:]*",[ \t]*CtFn/) {
    s = $0
    sub(/^[^"]*"/, "", s)
    sub(/".*$/, "", s)
    print s
  }
' "$REGISTRY" > "$tmp/builtins.txt"

if [ ! -s "$tmp/builtins.txt" ]; then
  echo "check_builtin_shadowing: read 0 builtin names from $REGISTRY -- the row" >&2
  echo "  shape must have changed. Refusing to pass on an empty corpus." >&2
  exit 2
fi

# Library definitions. Generated bundles are compiler OUTPUT, not source:
# they carry the same text as string literals and are not hand-edited.
find "$LIB_ROOT" -name '*.vibe' -type f \
  ! -name 'compiler_sources_bundle.vibe' \
  ! -name 'cli_adapter_bundle.vibe' \
  ! -name 'selfbuild_runtime_entry_bundle.vibe' \
  ! -name '_cli_adapter_module_source.vibe' \
  > "$tmp/files.txt"

if [ ! -s "$tmp/files.txt" ]; then
  echo "check_builtin_shadowing: no .vibe files under $LIB_ROOT" >&2
  exit 2
fi

: > "$tmp/defs.txt"
: > "$tmp/unreadable.txt"
# Top-level declarations, read line by line. This is a LEXICAL scan, and the
# hazard with those is the one they cannot see: a shape not encoded by the
# pattern is missed in silence, and a silent miss is indistinguishable from a
# clean tree (#2248).
#
# `vibe grep` cannot host this rule -- it rejects `fn` outright ("`fn` starts a
# DECLARATION, and a pattern must be a single EXPRESSION"), and points at `vibe
# symbols`, which is AST-derived and exact. Measured 2026-08-28: `vibe symbols`
# costs ~1.08 s per file with no batch mode (extra file arguments are ignored,
# a directory is refused), so the 966 files under lib/ would take ~17 minutes.
# A filter sound enough to preserve the answer -- any file containing a
# registry name anywhere -- keeps 889 of them. That is not a gate. Filed as
# #2381 (no batch mode; extra arguments are also accepted and ignored).
#
# So the scan stays lexical and is made unable to miss QUIETLY instead. Every
# column-0 line is classified, and anything the scanner cannot classify is a
# FAILURE, not a skip. A new declaration keyword, or a shape this does not
# encode, stops the gate and says so.
#
# The forms that matter start at column 0, optionally after a closing brace on
# the same line (`} fn collect_...` and `] let parse_...` both occur in lib/),
# and optionally behind `export`.
while IFS= read -r f; do
  awk -v path="$f" '
    # Column 0 only; indented lines are inside a declaration.
    /^[ \t]/ { next }
    /^[ \t]*$/ { next }
    {
      line = $0
      # A declaration may follow closers on the same line.
      sub(/^[})\]]+[ \t]*/, "", line)
      if (line ~ /^\/\//) next          # comment
      if (line ~ /^#/) next             # attribute (#deprecated, #zero_alloc)
      if (line == "") next              # the line was only closers
      # Trailing clauses of the declaration that just closed, not a new one:
      # `} derive (Show)`, `} with { Exception::Throw(_) => ... }`.
      if (line ~ /^(derive|with)[ \t({]/) next
      # Not a word start -> continuation of a multi-line string literal etc.
      if (line !~ /^[A-Za-z_]/) next

      sub(/^export[ \t]+/, "", line)
      if (line == "") next
      if (line !~ /^[A-Za-z_]/) next

      # Binds a callable name in the value namespace.
      if (match(line, /^(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+/)) {
        kw = substr(line, 1, RLENGTH)
        rest = substr(line, RLENGTH + 1)
        if (match(rest, /^[A-Za-z_][A-Za-z0-9_:]*/)) {
          name = substr(rest, RSTART, RLENGTH)
          form = (kw ~ /fn/) ? "fn" : "let"
          print path " " name " " form
        } else {
          print path ":" FNR " cannot read the bound name from: " $0 > "/dev/stderr"
          print "unreadable"
        }
        next
      }

      # Declaration keywords that bind no callable value name.
      if (line ~ /^(test|bench|import|declare|struct|enum|impl|type|effect|trait|handle|module)[ \t({"]/) next
      if (line ~ /^(test|bench|import|declare|struct|enum|impl|type|effect|trait|handle|module)$/) next
      if (line ~ /^export[ \t]*[{(]/) next

      print path ":" FNR " unclassified column-0 declaration: " $0 > "/dev/stderr"
      print "unreadable"
    }
  ' "$f" 2>> "$tmp/unreadable_detail.txt" | while IFS= read -r out; do
      if [ "$out" = "unreadable" ]; then
        echo "x" >> "$tmp/unreadable.txt"
      else
        echo "$out" >> "$tmp/defs.txt"
      fi
    done
done < "$tmp/files.txt"

if [ -s "$tmp/unreadable.txt" ]; then
  echo "check_builtin_shadowing: FAIL -- the scanner could not classify some column-0 lines:" >&2
  cat "$tmp/unreadable_detail.txt" >&2
  echo "" >&2
  echo "  A lexical scan that skips what it cannot read is indistinguishable from" >&2
  echo "  a clean tree. Teach the classifier the new shape (and add a case to" >&2
  echo "  scripts/check_builtin_shadowing_test.sh) rather than widening the skip." >&2
  exit 1
fi

# The allowlist is `<path> <name>` with an optional `#` comment; blank lines
# and full-line comments are ignored.
if [ -f "$ALLOWLIST" ]; then
  awk '{ sub(/#.*$/, ""); if (NF >= 3) print $1 " " $2 " " $3 }' "$ALLOWLIST" > "$tmp/allowed.txt"
else
  : > "$tmp/allowed.txt"
fi

# hits = definitions whose name is a builtin (deduplicated in awk).
#
# Each pass keys off FILENAME rather than `NR == FNR`. That idiom reads the
# SECOND file as if it were the first whenever the first is empty (NR never
# advanced, so NR == FNR still holds) -- which here would have meant "no
# allowlist entries" silently becoming "every finding is allowlisted". The
# self-test's empty-allowlist case caught exactly that.
awk -v first="$tmp/builtins.txt" '
  FILENAME == first { b[$0] = 1; next }
  ($2 in b) && !seen[$0]++ { print }
' "$tmp/builtins.txt" "$tmp/defs.txt" > "$tmp/hits.txt"

# new = hits not on the allowlist; stale = allowlist entries with no hit.
awk -v first="$tmp/allowed.txt" '
  FILENAME == first { a[$0] = 1; next }
  !($0 in a) { print }
' "$tmp/allowed.txt" "$tmp/hits.txt" > "$tmp/new.txt"
awk -v first="$tmp/hits.txt" '
  FILENAME == first { h[$0] = 1; next }
  !($0 in h) && !seen[$0]++ { print }
' "$tmp/hits.txt" "$tmp/allowed.txt" > "$tmp/stale.txt"

status=0

if [ -s "$tmp/new.txt" ]; then
  echo "check_builtin_shadowing: FAIL -- these library definitions replace a builtin program-wide:" >&2
  while IFS= read -r line; do
    echo "  $line" >&2
  done < "$tmp/new.txt"
  echo "" >&2
  echo "" >&2
  echo "  Rename the function, or delete it and let the builtin answer. For a" >&2
  echo "  QUALIFIED name (X::y), a caller that imports ANY name from the same" >&2
  echo "  package inherits this override at every call site in its program, with" >&2
  echo "  no diagnostic. A bare name is contained to its own file today, but that" >&2
  echo "  is an observed property of the resolver, not a promise." >&2
  status=1
fi

if [ -s "$tmp/stale.txt" ]; then
  echo "check_builtin_shadowing: FAIL -- allowlist entries that no longer exist:" >&2
  while IFS= read -r line; do
    echo "  $line" >&2
  done < "$tmp/stale.txt"
  echo "" >&2
  echo "  Delete these lines from $ALLOWLIST. The list ratchets down only." >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  hits_n="$(awk 'END { print NR }' "$tmp/hits.txt")"
  echo "check_builtin_shadowing: ok ($hits_n allowlisted, 0 new)"
fi

exit "$status"
