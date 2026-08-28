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
# The exemptions that predate this gate are pinned in baseline_entries()
# below. Entries may be REMOVED, never added.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

REGISTRY="lib/@vibe/compiler/core/builtin_registry.vibe"
# The exemption set lives HERE, in the checker, not in a data file beside it.
#
# A count-based pin was the first attempt and it was a proxy, not the property:
# removing one legacy row while adding a row for a NEW shadow keeps the count
# equal, leaves both the `new` and `stale` sets empty, and passes. Cleanup
# became interchangeable capacity for a fresh program-wide override.
#
# Pinning the identities fixes that, and putting them in the checker is what
# keeps them pinned -- an exemption cannot be widened by editing a .txt that
# reads as routine; it takes a diff to this file, next to the reason it is
# refused. That is a review-visibility guarantee, not a cryptographic one: no
# lexical gate can stop someone who edits the gate. The point is that the edit
# must be made, and shows up as one.
#
# Format: <path> <name> <form>. Removing an entry is the only ordinary change.
#
# SHAPE of the name decides whether an entry can surprise a dependent.
# Measured 2026-08-28 on stage2 of 3725175, four names, each called both from
# its own file and from an importer that imports only an unrelated name:
#
#   String::index_of  qualified   importer got the local definition
#   String::trim      qualified   importer got the local definition
#   eq                bare        importer got the BUILTIN
#   not               bare        importer got the BUILTIN
#
# So a QUALIFIED (`X::y`) definition replaces the builtin for the whole linked
# program; a bare one is contained to its own file. The bare rows are listed
# because that containment is an observed property of today's resolver, not a
# stated rule.
#
# FORM of the declaration matters too. `fn` participates in name-to-fn-def
# resolution; a bare VALUE alias (`export let X::y = impl`) does not. Not a
# guess -- lib/@vibe/fs/fs.vibe carries the four `let` rows because wrapper fns
# there hijacked `perform Fs::<Op>` lowering into an arity-broken wasm call
# (#897). Those rows exist so the ratchet notices a conversion to `fn`.
baseline_entries() {
  cat <<'PINNED'
# qualified + fn: replaces the builtin program-wide. Both measured equivalent
# to their builtins (20/20 answers, including tab/LF/CR/VT/FF padding and the
# equality edge cases) and performance-neutral, so they are kept rather than
# deleted alongside the six scalar search re-implementations, which were
# neither.
lib/@vibe/builtin/string.vibe String::equals fn
lib/@vibe/builtin/string.vibe String::trim fn
# qualified + let: value aliases, deliberately NOT fns (#897)
lib/@vibe/fs/fs.vibe Fs::exists let
lib/@vibe/fs/fs.vibe Fs::read_file let
lib/@vibe/fs/fs.vibe Fs::stat_token let
lib/@vibe/fs/fs.vibe Fs::write_file let
# bare: contained to the defining file
lib/@vibe/cache/cache.vibe __compact_fingerprint_hash fn
lib/@vibe/compiler/core/polyfill.vibe __to_string fn
lib/@vibe/compiler/entry/compiler/fs_compile/closure_order.vibe resolve_path fn
lib/@vibe/console/io.vibe print fn
lib/@vibe/console/io.vibe println fn
lib/@vibe/module/path.vibe resolve_path fn
lib/@vibe/parser/polyfill.vibe __to_string fn
lib/@vibe/semver/semver.vibe eq fn
lib/@vibex/shell/commands.vibe print fn
lib/@vibex/shell/commands.vibe println fn
PINNED
}

# Self-test hook ONLY: replace the pinned set with a file's contents.
ALLOWLIST="${VIBE_SHADOW_ALLOWLIST:-}"
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
    # Drop string literals and line comments before anything looks at the text.
    # The scan below matches on raw characters, so without this a line like
    #   let diagnostic = "write fn String::index_of to override it"
    # or a trailing `// ... let String::contains ...` is reported as a
    # program-wide override -- a false FAIL on a required gate, from a file
    # that declares only `diagnostic`.
    # `Char` is a real type and `let c: Char = \x27"\x27` is valid source, so a
    # bare quote scan mistakes the char literal\x27s `"` for a string opener and
    # swallows the rest of the line -- including a declaration sharing it.
    # `#|` opens a raw string that runs to end of line (no escape processing),
    # so from here it behaves like a comment.
    function strip_trivia(s,   out, i, c, n, mode) {
      out = ""
      mode = ""                                   # "", "str", or "char"
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (mode != "") {
          if (c == "\\") { i++; continue }        # escape: skip the next char
          if (mode == "str" && c == "\"") { mode = "" }
          else if (mode == "char" && c == "\x27") { mode = "" }
          continue                                # literal bodies contribute nothing
        }
        if (c == "\"") { mode = "str"; continue }
        if (c == "\x27") { mode = "char"; continue }
        if (c == "/" && substr(s, i + 1, 1) == "/") { break }   # line comment
        if (c == "#" && substr(s, i + 1, 1) == "|") { break }   # raw string to EOL
        out = out c
      }
      return out
    }

    # Column 0 only; indented lines are inside a declaration.
    /^[ \t]/ { next }
    /^[ \t]*$/ { next }
    {
      line = strip_trivia($0)
      if (line ~ /^[ \t]*$/) next
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

      head = line
      sub(/^export[ \t]+/, "", head)

      # (1) Record EVERY value-namespace binding on the line, not just the
      # head. A line may carry several:
      # lib/@vibe/compiler/loader/loader.vibe:1217 is
      # `] let a: Array[String] = [] fn vpkg_types_registry_note(...) {`,
      # three declarations deep. Recording only the head missed the rest --
      # the exact failure this classifier exists to prevent. Scanning the
      # whole line also covers a binding that trails a non-declaration head.
      rest = line
      while (match(rest, /(^|[^A-Za-z0-9_:])(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+[A-Za-z_][A-Za-z0-9_:]*/)) {
        hit = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^[^A-Za-z_]/, "", hit)
        form = (hit ~ /^(rec[ \t]+)?fn[ \t]/) ? "fn" : "let"
        sub(/^(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+/, "", hit)
        print path " " hit " " form
      }

      # (2) Independently, refuse to pass over a head this cannot classify.
      # Silence is not safety: a skipped line is indistinguishable from a
      # clean one.
      if (head ~ /^(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+/) next
      if (head ~ /^(test|bench|import|declare|struct|enum|impl|type|effect|trait|handle|module)[ \t({"]/) next
      if (head ~ /^(test|bench|import|declare|struct|enum|impl|type|effect|trait|handle|module)$/) next
      if (head ~ /^[{(]/) next
      # `export { ... }` (publish a name) and `export ./dep.vibe { ... }` /
      # `export ../../pkg { ... }` (re-export a target) bind nothing here.
      if (head ~ /^[.\/@]/) next
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

# Entries are `<path> <name> <form>` with optional `#` comments.
if [ -n "$ALLOWLIST" ]; then
  cat "$ALLOWLIST" > "$tmp/raw_allowed.txt"
else
  baseline_entries > "$tmp/raw_allowed.txt"
fi
awk '{ sub(/#.*$/, ""); if (NF >= 3) print $1 " " $2 " " $3 }' "$tmp/raw_allowed.txt" > "$tmp/allowed.txt"

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
  echo "  Delete these lines from baseline_entries() in this script." >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  hits_n="$(awk 'END { print NR }' "$tmp/hits.txt")"
  echo "check_builtin_shadowing: ok ($hits_n pinned exemptions, 0 new)"
fi

exit "$status"
