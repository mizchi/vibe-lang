#!/usr/bin/env bash
# A top-level `fn X` in the shipped library replaces the builtin named X for
# the WHOLE linked program -- including at call sites in files that never
# imported it, and in programs that only imported some unrelated name from the
# same package. Nothing diagnoses it.
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
while IFS= read -r f; do
  awk -v path="$f" '
    match($0, /^(export )?fn [A-Za-z_][A-Za-z0-9_:]*[ \t]*[(\[]/) {
      s = $0
      sub(/^(export )?fn[ \t]+/, "", s)
      sub(/[ \t]*[(\[].*$/, "", s)
      print path " " s
    }
  ' "$f" >> "$tmp/defs.txt"
done < "$tmp/files.txt"

# The allowlist is `<path> <name>` with an optional `#` comment; blank lines
# and full-line comments are ignored.
if [ -f "$ALLOWLIST" ]; then
  awk '{ sub(/#.*$/, ""); if (NF >= 2) print $1 " " $2 }' "$ALLOWLIST" > "$tmp/allowed.txt"
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
  echo "  Rename the function, or delete it and let the builtin answer. A caller" >&2
  echo "  that imports ANY name from the same package inherits this override at" >&2
  echo "  every call site in its program, with no diagnostic." >&2
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
