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

# Self-test hook ONLY: point the extractor at a staged registry.
REGISTRY="${VIBE_SHADOW_REGISTRY:-lib/@vibe/compiler/core/builtin_registry.vibe}"
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

# "Some rows parsed" is not "every row parsed". A row legally wrapped so that
# `CtFn` lands on the next line drops out of the protected set silently, and
# the non-empty check above still passes on the strength of its 171 siblings --
# so the builtin that row names stops being protected and nothing says so.
# Every line that OPENS a registry tuple must therefore also yield a name.
awk '
  match($0, /^[ \t]*\("[A-Za-z_][A-Za-z0-9_:]*",/) {
    s = $0
    sub(/^[^"]*"/, "", s)
    sub(/".*$/, "", s)
    print FNR " " s
  }
' "$REGISTRY" > "$tmp/registry_openers.txt"

awk -v first="$tmp/builtins.txt" '
  FILENAME == first { known[$0] = 1; next }
  !($2 in known) { print }
' "$tmp/builtins.txt" "$tmp/registry_openers.txt" > "$tmp/registry_unparsed.txt"

if [ -s "$tmp/registry_unparsed.txt" ]; then
  echo "check_builtin_shadowing: FAIL -- registry rows this could not classify:" >&2
  while IFS= read -r line; do
    echo "  $REGISTRY:$line" >&2
  done < "$tmp/registry_unparsed.txt"
  echo "" >&2
  echo "  Each names a builtin that would silently drop out of the protected" >&2
  echo "  set. Teach the extractor the row shape (a wrapped tuple, most" >&2
  echo "  likely) rather than letting the name go unguarded." >&2
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
    # Strip everything that can carry arbitrary text, so the scan below only
    # ever sees code. vibe has exactly four such forms -- `"..."` (lex_string),
    # \x27c\x27 (lex_char), `#|` to end of line (lex_multiline_string) and `//` to
    # end of line. There is no block comment: a lone `/` is division.
    #
    # Strings nest, because `\{ ... }` interpolation returns to code where
    # another string may open: `"a \{tag("b")} c"` is one string containing an
    # expression containing another string. The stack holds "S" for string and
    # "I" for interpolated code; only text outside every literal is emitted,
    # so nothing inside one reaches the depth counter or the matcher.
    function strip_trivia(s,   out, i, c, d, n, stack, top) {
      out = ""
      stack = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        d = length(stack)
        top = (d > 0) ? substr(stack, d, 1) : ""

        if (top == "S") {
          if (c == "\\") {
            if (substr(s, i + 1, 1) == "{") { stack = stack "I"; i++ }
            else { i++ }
            continue
          }
          if (c == "\"") { stack = substr(stack, 1, d - 1) }
          continue
        }

        if (c == "\"") { stack = stack "S"; continue }
        if (c == "\x27") {
          i++
          while (i <= n) {
            if (substr(s, i, 1) == "\\") { i += 2; continue }
            if (substr(s, i, 1) == "\x27") break
            i++
          }
          continue
        }
        # Inside an interpolation, a block\x27s braces are indistinguishable from
        # the interpolation\x27s own closer, so they have to be counted:
        # `"x \{if true { "ok" } else { "fn String::split" }} y"` ended the
        # interpolation at the FIRST `}` and read the second branch as
        # top-level code.
        if (top == "I" && c == "{") { stack = stack "I"; continue }
        if (top == "I" && c == "}") { stack = substr(stack, 1, d - 1); continue }
        if (d == 0 && c == "/" && substr(s, i + 1, 1) == "/") break
        if (d == 0 && c == "#" && substr(s, i + 1, 1) == "|") break
        if (d == 0) out = out c
      }
      return out
    }

    BEGIN { depth = 0 }

    # A binding shadows the builtin only if it is TOP LEVEL, and top level is
    # brace depth zero -- not column zero, which was a proxy for it. The proxy
    # needed a pile of scaffolding to stay honest (classify the head, refuse
    # what it cannot read) and still got both directions wrong: it missed
    # `#deprecated fn String::index_of(...)` because the line starts with an
    # attribute, and it reported the local `println` in
    # `fn f() -> Int { let println = 1; println }` as a program-wide override.
    #
    # Depth is the property itself, so the scaffolding is gone with it. Braces
    # inside strings, char literals and interpolations never reach the counter
    # (strip_trivia emits none of them), and `module` blocks -- the one other
    # nesting that could have held a declaration -- were removed in #728.
    {
      line = strip_trivia($0)
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "{" || c == "(" || c == "[") { depth++; continue }
        if (c == "}" || c == ")" || c == "]") { if (depth > 0) depth-- ; continue }
        if (depth != 0) continue

        # At depth 0: a value-namespace binding, optionally behind `export`
        # and/or attributes, which are ordinary tokens here.
        rest = substr(line, i)
        if (match(rest, /^(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+[A-Za-z_][A-Za-z0-9_:]*/)) {
          hit = substr(rest, RSTART, RLENGTH)
          # Must start at a token boundary, not inside a longer identifier.
          if (i > 1) {
            prev = substr(line, i - 1, 1)
            if (prev ~ /[A-Za-z0-9_:]/) continue
          }
          form = (hit ~ /^(rec[ \t]+)?fn[ \t]/) ? "fn" : "let"
          sub(/^(rec[ \t]+fn|fn|let[ \t]+rec|let)[ \t]+/, "", hit)
          print path " " hit " " form
          i += RLENGTH - 1
        }
      }

      # A declaration may wrap after its keyword -- `fn` on one line and
      # `String::index_of(...)` on the next is ONE declaration to the parser,
      # and this per-line scan sees neither half. Rather than accumulate tokens
      # across lines (a lexer, one more time), refuse the shape: code that ends
      # on a bare declaration keyword at depth 0 is something this cannot read.
      if (depth == 0 && line ~ /(^|[^A-Za-z0-9_:])(fn|let|export|rec)[ \t]*$/) {
        print "WRAPPED " path ":" FNR
      }
    }
    # Depth that does not return to 0 means the scanner lost track of the
    # delimiters -- a stripper bug, or a form it does not know. Everything
    # after the drift was scanned at the wrong depth and silently under-
    # reported, which is the failure mode this gate exists to not have. Say so
    # instead.
    END {
      if (depth != 0) {
        print "DRIFT " path " " depth
      }
    }
  ' "$f" >> "$tmp/defs.txt"
done < "$tmp/files.txt"

if grep -q "^WRAPPED " "$tmp/defs.txt" 2>/dev/null; then
  echo "check_builtin_shadowing: FAIL -- a declaration keyword ends a line:" >&2
  grep "^WRAPPED " "$tmp/defs.txt" | while IFS= read -r wline; do
    echo "  $wline" >&2
  done
  echo "" >&2
  echo "  The parser reads the keyword and the name on the next line as ONE" >&2
  echo "  declaration; this scan is per line and sees neither half, so a shadow" >&2
  echo "  written that way would pass unseen. Put the keyword and the name on" >&2
  echo "  the same line." >&2
  exit 1
fi

if grep -q "^DRIFT " "$tmp/defs.txt" 2>/dev/null; then
  echo "check_builtin_shadowing: FAIL -- brace depth did not return to zero:" >&2
  grep "^DRIFT " "$tmp/defs.txt" | while IFS= read -r line; do
    echo "  $line" >&2
  done
  echo "" >&2
  echo "  The scan tracks top level as brace depth, so a file whose delimiters" >&2
  echo "  do not balance was read at the wrong depth from that point on and" >&2
  echo "  may have under-reported. Teach strip_trivia the construct it is" >&2
  echo "  missing (and add a case to the self-test) rather than ignoring this." >&2
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
