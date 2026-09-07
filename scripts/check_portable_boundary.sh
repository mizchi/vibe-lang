#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "selfhost-portable-boundary: $*" >&2
  exit 1
}

require_line() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "$pattern" "$ROOT_DIR/$file"; then
    fail "missing expected pure boundary: $label ($file)"
  fi
}

# A doc comment naming a native entry point is a REFERENCE, not a leak: the
# whole point of these files is to explain how they differ from the FS lane, so
# `-- see compile_file_fs_mode's comment` is exactly the prose we want. The scan
# strips `///` and `//` comment lines before matching. Code is what leaks
# capability; prose about code does not.
#
# It strips whole comment LINES only, not trailing comments after code -- a
# stripped tail would let `let x = 1 // perform Fs::read_file` hide a real call
# on the same line if the two were ever reordered. A comment line is the one
# shape that cannot execute.
forbid_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  # Reads the same normalized view as the row and authority scans -- strings
  # and comments removed, lines preserved so the report keeps its line numbers.
  # It used to drop only whole comment LINES, so an inert diagnostic such as
  # "do not generate perform Fs::read_file here" was reported as a leak, which
  # is a required gate rejecting an ordinary message.
  if boundary_scan_lines "$file" \
    | grep -En "$pattern" >/tmp/vibe_portable_boundary_hits.$$; then
    cat /tmp/vibe_portable_boundary_hits.$$ >&2
    rm -f /tmp/vibe_portable_boundary_hits.$$
    fail "native capability leaked into portable boundary: $label ($file)"
  fi
  rm -f /tmp/vibe_portable_boundary_hits.$$
}

native_effect_pattern='with \{[^}]*(Fs|Process|Socket|Net)|perform (Fs|Process|Socket|Http)::|compile_file_fs|session-http|daemon'

# The `with \{...\}` alternative above matches the HANDLER syntax
# (`try ... with { Exception::Throw(e) => ... }`), which is a different
# construct from an effect row. An effect ROW is unbraced and `+`-separated:
# `with Fs`, `with Exception + Fs`, `with Exception + Fs + Env`. Nothing
# matched that, so a boundary implementation could declare `with Fs` outright
# and this gate printed `ok` -- measured, not inferred.
#
# The row check below is an ALLOW-LIST, and that is the point. A deny-list of
# capability names is a proxy for "is this effect native", and it failed twice
# in a row: first it knew only the braced spelling (`with Fs` passed), then,
# rewritten as `Fs|Process|Socket|Net|Http`, it still passed `with Env` and
# `with Console` -- both capability builtins (AGENTS.md). Each fix closed the
# hole someone happened to look at. Enumerating what these boundaries MAY carry
# cannot silently miss a capability that does not exist yet: a new effect is
# rejected until someone decides it belongs, which is the safe direction.
#
# Exception is what the contract requires. Async is admitted because it is
# already used here (2 rows in preprocess_compile.vibe) and grants no host
# access by itself -- it is a scheduling effect, not a capability. Adding to
# this list is a deliberate act; that is the property being enforced.
PORTABLE_ALLOWED_EFFECTS='Exception|Async'

# The normalized view both boundary scanners read: string literals removed,
# comments removed to end of line, newlines flattened.
#
# ONE function on purpose. The row scan and the authority scan ask the same
# question of the same files, and when they each did their own normalization
# they drifted: a fix for a capability split across lines went into one and not
# the other, and the gap it left was a real bypass.
#
# Strings go first. A comment may contain a quote, but stripping it only eats
# the rest of a line that is already a comment; stripping comments first would
# truncate a string containing `//` (a URL). Neither scanned file has either
# today -- this is about which order stays correct when one appears.
#
# Why strings must be removed at all: the row scan reads the whole span from
# `with` to the body, so an inert message like "compile with Fs when requested"
# was captured and reported as `effect: Fs`. A required gate that fails on
# correct code is one that gets disabled (#2252), so a false positive here is
# not the safe direction -- it is a different way to lose the gate.
# The string pattern is escape-aware: `"([^"\\]|\\.)*"`. A plain `"[^"]*"`
# ended the literal at the backslash-escaped quote inside
# `"prefix \"with Fs\" suffix"` and left the inert text exposed, failing the
# gate on a perfectly ordinary diagnostic string.
#
# Every string form the lexer knows has to go, not just the double-quoted one:
# `#|` opens a RAW string that runs to end of line, and leaving it in made
# `#|compile with Fs when requested` report `effect: Fs`, `effect: when`,
# `effect: requested` -- a required gate rejecting an ordinary message.
#
# Whitespace is normalized for the same reason. The lexer treats a tab as
# whitespace (lib/@vibe/parser/lexer.vibe), so `with<TAB>Fs` is a legal row;
# matching the literal text "with " missed it entirely. Tabs, newlines and
# carriage returns all become spaces here, once, so nothing downstream has to
# remember that a separator might not be a space.
#
# Order: quoted strings, then raw strings, then comments. A `//` inside a raw
# string is removed with the raw string rather than mistaken for a comment.
# Drop what does not execute, keep what does. Line-preserving, so a report can
# still cite a line number.
#
# This replaced three `sed` passes, and the reason is a hole they created rather
# than a form they missed. `"\{perform Fs::ReadFile(path)}"` is an interpolation:
# the body between `\{` and `}` is CODE and runs. Removing the whole quoted
# token discarded it, so a real capability call inside one became invisible --
# and on cli_direct_component_entry.vibe, which is deliberately outside the
# effect-row allow-list, forbid_pattern is the only thing watching for exactly
# that. The regex made this gate weaker than it was before the change.
#
# One pass with an explicit mode stack handles it, and closes the neighbouring
# case for free: a string nested INSIDE an interpolation
# (`"\{String::concat("perform Fs::read_file", " is inert")}"`) has its literal
# text dropped while its own interpolations are kept.
#
# This is a scanner for one lexical construct with a decidable structure, not
# another attempt to model the effect-row grammar in a pattern. The distinction
# matters: the grammar attempts kept missing forms nobody had enumerated, while
# string nesting is closed by construction here.
boundary_scan_lines() { # <file>
  awk 'BEGIN { sp = 0; mode[0] = "code"; bdepth[0] = 0 }
  {
    line = $0; n = length(line); out = ""
    # State is initialized ONCE, not per line: a string literal may span
    # physical lines (measured -- it compiles), so resetting to code mode at
    # each record scanned the continuation as executable and reported inert
    # text as a leak. Comments and raw strings still end at EOL, which the
    # `break` below gives for free without carrying any state.
    i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      if (mode[sp] == "code") {
        if (c == "r" && substr(line, i + 1, 1) == "\"") {
          # Raw quoted string. lib/@vibe/parser/lexer.vibe scans to the next
          # quote with NO escape processing, so `r"trailing\"` ENDS at that
          # quote. Treating it as an ordinary string consumed the backslash and
          # quote together, stayed in string mode, and discarded every
          # declaration after it. `r` must be the whole identifier, matching the
          # lexer, so `var"` is not one.
          prev = (i > 1) ? substr(line, i - 1, 1) : " "
          if (prev !~ /[A-Za-z0-9_]/) {
            j = i + 2
            while (j <= n && substr(line, j, 1) != "\"") { j++ }
            out = out " "
            if (j <= n) { i = j + 1 } else { sp++; mode[sp] = "raw"; i = j }
            continue
          }
        }
        if (c == "\"") { sp++; mode[sp] = "str"; i++; continue }
        if (c == "#" && substr(line, i + 1, 1) == "|") { break }   # raw string to EOL
        if (c == "/" && substr(line, i + 1, 1) == "/") { break }   # comment to EOL
        if (c == "\047") {
          # A char literal is inert, and a brace inside one would otherwise be
          # counted as a real brace -- which skips every declaration after it,
          # since they all then look nested. \047 is the quote character:
          # writing it literally would end the single-quoted awk program.
          # Consumed ONLY when the shape actually matches, so a stray quote is
          # left alone rather than eating the code after it.
          if (substr(line, i + 1, 1) == "\\") {
            if (substr(line, i + 3, 1) == "\047") { out = out " "; i += 4; continue }
          } else if (substr(line, i + 2, 1) == "\047") { out = out " "; i += 3; continue }
          out = out c; i++; continue
        }
        if (c == "{") { bdepth[sp]++; out = out c; i++; continue }
        if (c == "}") {
          if (bdepth[sp] > 0) { bdepth[sp]--; out = out c }
          else if (sp > 0) { sp--; out = out " " }                 # end of interpolation
          else { out = out c }
          i++; continue
        }
        out = out c; i++; continue
      }
      # a raw string carries to the next quote, across lines, with no escapes
      if (mode[sp] == "raw") {
        if (c == "\"") { sp--; }
        i++; continue
      }
      # inside a string literal: the text is inert, the interpolations are not
      if (c == "\\") {
        if (substr(line, i + 1, 1) == "{") {
          sp++; mode[sp] = "code"; bdepth[sp] = 0; out = out " "; i += 2; continue
        }
        i += 2; continue
      }
      if (c == "\"") { if (sp > 0) sp--; i++; continue }
      i++
    }
    print out
  }' "$ROOT_DIR/$1"
}

boundary_scan_text() { # <file>
  boundary_scan_lines "$1" | tr '\n\t\r' '   '
}

# Every DECLARATION's own effect row, one per line.
#
# "The text from `with` to the next `{`" was wrong, and wrong in the expensive
# direction: a parameter carries its own row, so
#
#   fn probe(f: () -> Unit with Exception) -> Unit with Exception { f() }
#
# started at the PARAMETER's `with`, swallowed `) -> Unit`, and reported
# `effect: Unit` -- rejecting a legitimate higher-order helper. A required gate
# that blocks correct code is one that gets removed (#2252).
#
# The outer row is the one at parenthesis depth 0. That is a lexical property,
# not a guess at the grammar: parameter rows are inside `(...)` by
# construction, whatever shape they take. Everything up to the body brace is
# then the row, so separators, type arguments and qualified items still need no
# special handling.
#
# BRACE depth matters as well as paren depth. `handle { ... } with ReviewAsk
# { ... }` discharges an effect locally and is not a signature, but its `with`
# is at paren depth 0, so it was read as a declaration row and reported
# `effect: ReviewAsk` -- rejecting a helper that is pure precisely BECAUSE it
# handles the effect. A declaration's row sits before the body brace (brace
# depth 0); a handler clause is inside a body (depth >= 1).
#
# Consequence worth stating: an effect row on a nested function or lambda,
# being inside a body, is not scanned. That is a miss rather than a false
# positive -- the safe direction of the two -- and neither boundary has one.
#
# AMBIGUITY IS SKIPPED, NOT GUESSED. A return type may itself be a function
# type, and then the row belongs to the RETURNED value, not to the declaration:
#
#   fn make() -> (String) -> Unit with Log::Emit    # make is PURE
#
# (pinned by fixtures/typecheck/closure_row_return_position.vibe). That `with`
# is at parenthesis depth 0 like any other, so the scan reported `Log` and
# rejected a legitimate helper.
#
# Telling those apart is a question about the TYPE grammar -- arrow
# associativity -- not about lexical structure, and grammar is what this scan
# stopped modelling at review round 7 after six straight misses. So when more
# than one `->` appears at depth 0 before the `with`, the row is left
# unclassified rather than attributed to the declaration.
#
# That is deliberately a MISS: a boundary returning an effectful closure is not
# checked. The trade is explicit -- a miss is recorded in #2581, which will
# answer this from the AST; a false positive fails CI on correct code and gets
# the gate deleted (#2252). Between guessing wrong in the two directions, only
# one of them is recoverable.
boundary_effect_rows() { # reads normalized text on stdin
  awk '{
    s = $0; n = length(s); depth = 0; brace = 0; arrows = 0; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "(") { depth++; i++; continue }
      if (c == ")") { if (depth > 0) depth--; i++; continue }
      if (c == "-" && substr(s, i + 1, 1) == ">" && depth == 0 && brace == 0) {
        arrows++; i++; continue
      }
      if (c == "{") { if (brace == 0) { arrows = 0 }; brace++; i++; continue }
      if (c == "}") { if (brace > 0) brace--; i++; continue }
      if (depth == 0 && brace == 0 && substr(s, i, 5) == "with ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev ~ /[A-Za-z0-9_]/) { i++; continue }
        # more than one depth-0 arrow: the row may belong to a returned
        # function type, so leave it unclassified rather than guess
        if (arrows > 1) { i++; continue }
        j = i + 5; row = ""; d2 = 0
        while (j <= n) {
          cc = substr(s, j, 1)
          if (cc == "(") { d2++ }
          else if (cc == ")") { if (d2 > 0) { d2-- } else { break } }
          else if (d2 == 0 && (cc == "{" || cc == ";")) { break }
          row = row cc; j++
        }
        print row
        i = j
        continue
      }
      i++
    }
  }'
}

# Reject any effect row on a pure boundary that names something outside the
# allow-list. Comment lines are stripped first, as in forbid_pattern.
#
# Comments are dropped to end of line and the file flattened to one line before
# matching, for the same reason as forbid_capability_authority below: a row may
# be split after `+`. Measured -- this compiles, and a line-by-line scan matched
# `with Exception`, accepted it, and never associated the `Fs`:
#
#   fn probe() -> String with Exception +
#     Fs { ... }
forbid_foreign_effect_rows() { # <file> <label>
  local file="$1" label="$2" bad
  # This deliberately does NOT model the row grammar. Six review rounds went
  # into a regex that tried to, and each round found another form it did not
  # know: a row split after `+`, an item with type arguments
  # (`Exception[String] + Fs`), a qualified item (`Exception::Throw + Fs`).
  # Every patch was correct and none of them made the next one less likely,
  # because enumerating a grammar in a regex is the proxy -- the property is
  # "no capability name appears in this boundary's effect row".
  #
  # So: take the whole span from `with` to the start of the body, drop type
  # arguments and the `::op` suffix of a qualified item, and check EVERY
  # capability name in it. Separators are irrelevant -- `+`, newlines, or a
  # syntax `parse_effect_item` grows next week -- because nothing about the
  # row's shape is assumed. A name is either allow-listed or it is a leak.
  # Tokens are matched in EITHER case. An effect-row variable is lowercase
  # (`fn probe[e](f: () -> Unit with e) -> Unit with e`), and such a boundary
  # runs whatever effect its caller instantiates -- including Fs. Only matching
  # capitalized names silently dropped it. Unresolved is not portable, so the
  # allow-list rejects it like any other name it does not know.
  bad="$(boundary_scan_text "$file" \
    | boundary_effect_rows \
    | sed 's/\[[^]]*\]//g' \
    | sed 's/::[A-Za-z0-9_]*//g' \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
    | grep -vE "^($PORTABLE_ALLOWED_EFFECTS)$" \
    | sort -u)" || true
  if [ -n "$bad" ]; then
    echo "selfhost-portable-boundary: non-portable effect row in $label ($file)" >&2
    echo "$bad" | sed 's/^/  effect: /' >&2
    echo "  This boundary must stay in-memory. Drop the effect, or move the" >&2
    echo "  work behind a caller that already carries it. If the effect is" >&2
    echo "  genuinely portable, add it to PORTABLE_ALLOWED_EFFECTS with a" >&2
    echo "  reason -- deliberately, not to make this message go away." >&2
    exit 1
  fi
}

# The effect row is not the only way to reach a capability. `allows` grants
# capability AUTHORITY in the signature, separately from the row (ADR-0075/0084,
# #1961), and the granted operation is then called plainly -- not through
# `perform`:
#
#   fn main() -> String with () allows Fs::read_file { Fs::read_file("x") }
#
# so it matched neither the row allow-list nor `perform (Fs|...)::`, and the
# gate exited 0. Measured on preprocess_compile.vibe before this check.
#
# Neither pure boundary uses `allows` at all, so the allowed set here is empty:
# any capability authority is a leak by definition on a boundary whose contract
# is "stays in-memory". A capability name is CamelCase, which is what separates
# a real clause from English prose ("allows them to ..."); comment lines are
# stripped first regardless.
#
# The capability need not be adjacent to the keyword. Both of these compile
# (measured on a stage2 built from this checkout, `vibe test`):
#
#   fn probe() -> String with Exception allows
#     Fs::read_file { ... }              # newline
#   fn probe() -> String with Exception allows // note
#     Fs::read_file { ... }              # trailing comment, then newline
#
# so requiring adjacency on one line missed both. Comments are removed to end
# of line and the file is flattened to a single line before matching, which
# makes the check insensitive to whitespace and to anything commented out
# between the keyword and the capability. `/* ... */` needs no handling: vibe
# has no block comments, and that spelling does not parse at all
# (`expected an effect name in the effect row after 'with'`).
forbid_capability_authority() { # <file> <label>
  local file="$1" label="$2"
  if boundary_scan_text "$file" \
    | grep -oE '\ballows +[A-Z][A-Za-z0-9_:]*' >/tmp/vibe_portable_authority_hits.$$; then
    echo "selfhost-portable-boundary: capability authority granted in $label ($file)" >&2
    sed 's/^/  granted: /' /tmp/vibe_portable_authority_hits.$$ >&2
    rm -f /tmp/vibe_portable_authority_hits.$$
    # Matching happens on the flattened file, so the match itself carries no
    # position. Point at every line holding the keyword, which is where the
    # edit goes.
    grep -nE '\ballows\b' "$ROOT_DIR/$file" | sed 's/^/  at /' >&2 || true
    echo '  An `allows` clause hands this boundary host authority, which is' >&2
    echo "  what it must not have. Move the capability to a caller that is" >&2
    echo "  allowed to hold it and pass the result in." >&2
    exit 1
  fi
  rm -f /tmp/vibe_portable_authority_hits.$$
}

# The boundary is declared in the package CONTRACT (`index.vpkg`, ADR-0070),
# not in an `index.vibe` facade -- and its effect row is spelled `with
# Exception`, not `with { Error }` (ADR-0085). This gate asserted the older
# form at the older path for long enough that both had gone: it reported
# "missing expected pure boundary" for files that no longer exist, while every
# boundary it names was intact in the contract beside them. Nothing caught it
# because the gate runs in no CI job (#2577).
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source\(source: String\) -> Bytes with Exception$' \
  "compile_source stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi\(source: String, entry_name: String\) -> Bytes with Exception$' \
  "compile_source_wasi stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi_mode\(source: String, entry_name: String, mode: String\) -> Bytes with Exception$' \
  "compile_source_wasi_mode stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  '^export fn compile_source_wasi_only\(source: String, entry_name: String\) -> Bytes with Exception' \
  "compile_source_wasi_only stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/compiler/fs_compile/index.vpkg" \
  '^fn compile_with_closure_sources_wasi_mode_uncached\(main_source: String, main_path: String, sources: Array\[\(String, String\)\], entry_name: String, mode: String\) -> Bytes with Exception$' \
  "direct component closure compile stays in-memory"

forbid_pattern \
  "lib/@vibe/compiler/cli_direct_component_entry.vibe" \
  "$native_effect_pattern" \
  "direct component entry"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "$native_effect_pattern" \
  "source compile API"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "$native_effect_pattern" \
  "wasi source compile API"

# The row allow-list, on the two boundaries whose contract is "stays
# in-memory". Not applied to cli_direct_component_entry.vibe: that is the entry
# that DOES file IO and carries `with Exception + Fs` / `with Fs` legitimately
# at lines 304/322, so an allow-list there would fail the gate on correct code.
# It keeps forbid_pattern above, which bans the direct `perform Fs::` and the
# FS compile lane rather than the row.
# Authority first, then the row. The row span now runs from `with` to the body,
# so it also covers the capability named in an `allows` clause -- harmless as
# defence in depth, but it would report the generic "non-portable effect row"
# for a declaration whose actual problem is an authority grant. The specific
# diagnostic has to win, and the self-test asserts the message names `allows`,
# which is what caught this ordering.
forbid_capability_authority \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "source compile API"
forbid_capability_authority \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "wasi source compile API"

forbid_foreign_effect_rows \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "source compile API"
forbid_foreign_effect_rows \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "wasi source compile API"

echo "selfhost portable boundary: ok"
