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
# The head of a handler arm NAMES an operation being discharged; it is not a
# call of it. `handle { f() } with { Fs::ReadFile(_p) => resume("ok") }` is a
# pure helper taking an Fs-effectful callback and handling it locally, and
# nothing escapes -- yet the `with \{...\}` alternative saw `Fs` inside the
# braces and the capability-namespace alternative added for the entry file saw
# `Console::` in an arm head. Both rejected correct code.
#
# An arm head is decidable without parsing: a qualified name whose argument
# list is immediately followed by `=>`. Nothing else puts `=>` there -- a call
# result cannot be a pattern -- and the arm BODY is left untouched, so a real
# capability call inside one is still a leak.
strip_handler_arm_heads() {
  # The argument list is BALANCED, not `[^)]*`. `Fs::ReadFile((_path)) =>` is a
  # legal grouping -- parse_handle_arm delegates to the recursive pattern
  # parser -- and a regex that stopped at the first `)` left the head in place,
  # so a pure helper was rejected again. Parentheses are counted here rather
  # than approximated, which holds at any depth instead of one more than the
  # last counterexample.
  awk '{
    s = $0; n = length(s); out = ""; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c ~ /[A-Za-z_]/ && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_]/)) {
        j = i
        while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_]/) { j++ }
        jj = j
        while (jj <= n && substr(s, jj, 1) == " ") { jj++ }
        if (substr(s, jj, 2) == "::") {
          k = jj + 2
          while (k <= n && substr(s, k, 1) == " ") { k++ }
          ks = k
          while (k <= n && substr(s, k, 1) ~ /[A-Za-z0-9_]/) { k++ }
          if (k > ks) {
            m = k
            while (m <= n && substr(s, m, 1) == " ") { m++ }
            if (substr(s, m, 1) == "(") {
              d = 0
              while (m <= n) {
                cc = substr(s, m, 1)
                if (cc == "(") { d++ }
                else if (cc == ")") { d--; if (d == 0) { m++; break } }
                m++
              }
            }
            while (m <= n && substr(s, m, 1) == " ") { m++ }
            if (substr(s, m, 2) == "=>") {
              # A handler arm head: the operation is DISCHARGED here, not
              # called. Blank the head and leave the arrow, so the arm body
              # after it is still scanned.
              out = out " "
              i = m; continue
            }
          }
        }
        out = out substr(s, i, j - i); i = j; continue
      }
      out = out c; i++
    }
    print out
  }'
}
forbid_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  # Reads the same normalized view as the row and authority scans -- strings
  # and comments removed, lines preserved so the report keeps its line numbers.
  # It used to drop only whole comment LINES, so an inert diagnostic such as
  # "do not generate perform Fs::read_file here" was reported as a leak, which
  # is a required gate rejecting an ordinary message.
  # The VERDICT comes from the flattened view alone; the line-preserving one is
  # read only to cite a line. Both used to decide, and that was wrong in one
  # direction: the flattened text is the line text with newlines turned into
  # spaces, so anything a line-oriented grep can match it matches too -- but
  # not the reverse. A handler arm head written across lines is stripped in the
  # flat view and not in the per-line one, and the per-line leftovers were
  # rejecting a pure helper. One authoritative view, one answer.
  boundary_scan_lines "$file" | strip_handler_arm_heads | grep -En "$pattern" >/tmp/vibe_portable_boundary_hits.$$ || true
  flat_hit=0
  if boundary_scan_text "$file" | strip_handler_arm_heads | grep -Eq "$pattern"; then flat_hit=1; fi
  if [ "$flat_hit" -eq 1 ]; then
    if [ -s /tmp/vibe_portable_boundary_hits.$$ ]; then
      cat /tmp/vibe_portable_boundary_hits.$$ >&2
    else
      echo "  (match spans lines; no single line to cite)" >&2
    fi
    rm -f /tmp/vibe_portable_boundary_hits.$$
    fail "native capability leaked into portable boundary: $label ($file)"
  fi
  rm -f /tmp/vibe_portable_boundary_hits.$$
}

# Separators are `[[:space:]]+`, not one literal space. `perform  Fs::ReadFile`
# with two spaces, or a tab or newline after `perform`, all compile and all
# bypassed a pattern that matched exactly one space.
native_effect_pattern='with[[:space:]]*\{[^}]*(Fs|Process|Socket|Net)|perform[[:space:]]+(Fs|Process|Socket|Http)[[:space:]]*::|\bcompile_file_fs\b'

# `daemon` was dropped for the same reason as `session-http` below, one round
# later and one level up. Anchoring it to token boundaries (round 40) stopped
# it matching INSIDE a name, but an exact identifier is still not a reference:
# `fn f(daemon: Int) -> Int { daemon }` is an ordinary parameter, and matching
# the token rejected it -- an ordinary local name blocking a required job.
#
# What settles it is that `daemon` names nothing in this tree. Every occurrence
# under lib/ is inside a comment, and comments are removed before this pattern
# runs, so the alternative could only ever match a name someone chose. That is
# the same wrong check as `session-http`, not a weaker one.
#
# `compile_file_fs` STAYS, and stays unqualified, because it is the opposite
# case: a real exported function (entry/compiler/file_compile, fs_compile), so
# a bare occurrence in a boundary file is a real reference -- including in an
# `import { compile_file_fs }` list, which has neither `(` nor `::` after it.
# Requiring a call shape here would have traded a false positive nobody will
# write (a parameter named compile_file_fs) for a miss that is exactly how the
# lane would be reached.
#
# `session-http` was dropped from the lane list. Strings and comments are
# removed before this runs, so in the remaining text that spelling can only be
# the subtraction `session - http` -- it is not one vibe identifier, and a
# helper returning it was rejected as a lane leak. A pattern that can only ever
# match something else is not a weaker check, it is a wrong one.
#
# Whitespace is allowed around `::`. The lexer permits it, so `Console ::
# write_stream(...)` is the same call, and requiring adjacency left the entry
# file -- where this pattern is the only check for a plain capability call --
# open to it.
#
# The three lane names are anchored to token boundaries. Unanchored, `daemon`
# matched inside `daemonless_probe` and `compile_file_fs` inside
# `compile_file_fsx_probe`, so an ordinary helper whose name merely CONTAINS a
# forbidden lane failed the required job on correct code. A lane is a name, not
# a substring. `\b` is a GNU extension that check_gate_portability admits, and
# it is the boundary that matters here: `my_daemon_helper` keeps building
# because an underscore is a word character.
#
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
        # A RAW IDENTIFIER is the same name. `lex_ident` in
        # lib/@vibe/parser/lexer.vibe turns `r#Exception` into
        # TIdent("Exception") -- the exact token the plain spelling gives -- so
        # the two are one name to the compiler and must be one name here.
        # Splitting the source text instead produced `r` AND `Exception`, which
        # rejected a portable boundary as `effect: r`, and in the other
        # direction `perform r#Fs::ReadFile(p)` matched no native pattern at
        # all and passed. Dropping the prefix once, in the lexical pass, is
        # what makes every check downstream see what the compiler sees.
        # `r` must be the whole identifier, as in the raw-string branch above.
        if (c == "r" && substr(line, i + 1, 1) == "#" && substr(line, i + 2, 1) ~ /[A-Za-z0-9_]/) {
          prev = (i > 1) ? substr(line, i - 1, 1) : " "
          if (prev !~ /[A-Za-z0-9_]/) {
            j = i + 2; nm = ""
            while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_]/) { nm = nm substr(line, j, 1); j++ }
            # The WHOLE POINT of `r#` is that the name is a name and not the
            # keyword it is spelled like, so emitting it bare hands the
            # scanner its own syntax: `with Exception + r#where + Fs` became
            # `... where ...`, the row stopped at the contract terminator, and
            # the native Fs after it was never read. An underscore is appended
            # to exactly the keywords the passes below react to. Every one of
            # them requires a following space, so the suffix defeats the match
            # while leaving an ordinary identifier behind.
            #
            # Nothing is lost by not restoring the true name: none of these
            # keywords is an allow-listed effect or a native capability, so an
            # effect really called `where` is rejected either way -- it is
            # simply not `Exception` or `Async`. The suffix keeps the name
            # readable in the diagnostic instead of dropping it.
            # `r#fn` is the ONE raw spelling that is still the keyword:
            # lex_ident returns TFn for it (lexer.vibe, #1280 -- a binding
            # named fn cannot be smuggled back in through r#). Suffixing it
            # like the others cost the `fn ` reset, so a preceding type alias
            # kept decl = "type" and the functions native row was suppressed.
            # It is emitted as the keyword because that is what it IS.
            if (nm == "fn") {
              out = out "fn"
            } else if (nm == "let" || nm == "type" || nm == "with" \
                || nm == "where" || nm == "allows" || nm == "perform") {
              out = out nm "_"
            } else {
              out = out nm
            }
            i = j; continue
          }
        }
        # `perform?` is a DIFFERENT token from `perform` (ADR-0088; the parser
        # builds EIdent("perform?") at parser_expr_primary.vibe:803), but it
        # invokes the same capability, so it is the same thing to this gate.
        # The native-call pattern spelled only `perform`, so `perform?
        # Fs::read_file(path)` passed the required check outright. Normalizing
        # the suffix here, rather than adding `\\??` to one regex, is what
        # keeps the next consumer of this text from having to know that two
        # spellings exist -- the same reason the raw-identifier prefix is
        # dropped above.
        if (c == "?" && i > 7 && substr(line, i - 7, 7) == "perform" \
            && substr(line, i - 8, 1) !~ /[A-Za-z0-9_]/) { i++; continue }
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
    s = $0; n = length(s); depth = 0; brack = 0; brace = 0; implb = 0; impending = 0; arrows = 0; rown = 0; authn = 0; decl = ""; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "(") { depth++; i++; continue }
      if (c == ")") { if (depth > 0) depth--; i++; continue }
      # Brackets nest like parens. `-> Array[() -> Unit] with Fs` has an arrow
      # INSIDE the type argument; counting it made arrows 2 against 1 row, so
      # the row was written off as the returned closures and a native boundary
      # passed. A type argument is not a return-type layer.
      if (c == "[") { brack++; i++; continue }
      if (c == "]") { if (brack > 0) brack--; i++; continue }
      # An `impl` block holds DECLARATIONS, not statements. Its methods sit one
      # brace deep, so the brace == 0 guard below skipped every one of them and
      # a method could carry `with Fs` unseen. The block is made transparent
      # instead: its `{` does not open a body.
      #
      # `struct` / `enum` / `effect` bodies are NOT declarations in this sense
      # and must stay opaque, so they clear the flag -- an `impl Eq for Int`
      # with no block at all would otherwise hand its transparency to whatever
      # brace came next.
      if (depth == 0 && brack == 0 && brace == 0 && implb >= 0 && substr(s, i, 5) == "impl ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_.]/) { impending = 1 }
        i += 5; continue
      }
      if (depth == 0 && brack == 0 && brace == 0 \
          && (substr(s, i, 7) == "struct " || substr(s, i, 5) == "enum " \
              || substr(s, i, 7) == "effect ")) {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_.]/) { impending = 0 }
        i++; continue
      }
      if (depth == 0 && brack == 0 && brace == 0 && substr(s, i, 3) == "fn ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_]/) { arrows = 0; rown = 0; authn = 0; decl = "fn"; impending = 0 }
        i += 3; continue
      }
      # Which KIND of declaration a row was collected under.
      #
      # `type ReviewCallback = () -> Unit with ReviewAsk` is one arrow and one
      # row, the shape that means "the row is the declarations own" -- so the
      # alias was reported as a non-portable boundary and failed the required
      # job on correct code. The row belongs to the aliased function TYPE.
      # Naming a type performs nothing; the boundary is what a caller can
      # reach, and that is the same reason the lone row of a RETURNED closure
      # is skipped.
      #
      # `let ` resets alongside it, and must: without it an alias would
      # suppress the row of the next declaration when that one is a bodyless
      # `export let`, turning a false positive into a miss one declaration
      # later. A declaration with no keyword at all keeps being checked --
      # this suppresses `type` and nothing else.
      # A declaration keyword starts at any token boundary, not only after a
      # space: `;type Cb = () -> Unit with R` is legal, and requiring a space
      # missed it, so the aliases row was attributed to the boundary. The dot
      # stays excluded so a field access spelled `x.type` is not read as a
      # declaration.
      if (depth == 0 && brack == 0 && brace == 0 && substr(s, i, 5) == "type ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_.]/) { arrows = 0; rown = 0; authn = 0; decl = "type"; impending = 0 }
        i += 5; continue
      }
      if (depth == 0 && brack == 0 && brace == 0 && substr(s, i, 4) == "let ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_.]/) { arrows = 0; rown = 0; authn = 0; decl = "let"; impending = 0 }
        i += 4; continue
      }
      if (c == "-" && substr(s, i + 1, 1) == ">" && depth == 0 && brack == 0 && brace == 0) {
        arrows++; i++; continue
      }
      if (c == "{") {
        if (brace == 0) { flush(); arrows = 0; rown = 0; authn = 0; decl = "" }
        if (brace == 0 && impending) { implb++; impending = 0; i++; continue }
        brace++; i++; continue
      }
      if (c == "}") {
        if (brace > 0) { brace-- }
        else if (implb > 0) { flush(); arrows = 0; rown = 0; authn = 0; decl = ""; implb-- }
        i++; continue
      }
      if (c == ";" && depth == 0 && brack == 0 && brace == 0) { flush(); arrows = 0; rown = 0; authn = 0; decl = ""; i++; continue }
      # `=` ends the TYPE of a binding and starts its value. Without this,
      # `export let f: (Int) -> Unit with Exception = (x) -> { () }` ran the
      # row on to the initializer body and reported `effect: x` on a portable
      # file. The initializer arrow also inflated the layer count, so simply
      # stopping the row there would have skipped the declaration instead;
      # flushing at `=` reports the row and leaves the value to be scanned as
      # what it is. `decl` is NOT cleared -- `type Cb = () -> Unit with R` has
      # its row AFTER the `=`, and clearing it would re-open the alias false
      # positive one character later. A comparison operator is not a binding.
      if (c == "=" && depth == 0 && brack == 0 && brace == 0 \
          && substr(s, i + 1, 1) != "=" \
          && ((i > 1) ? substr(s, i - 1, 1) : " ") !~ /[=<>!+\-*\/%]/) {
        flush(); arrows = 0; rown = 0; authn = 0; i++; continue
      }
      # An `allows` clause grants host authority (ADR-0088). It is collected
      # HERE, in the one pass that knows which declaration it belongs to,
      # rather than by a separate whole-file grep -- that grep had no notion of
      # declarations, so it rejected `type Cb = () -> Unit with R allows Fs`,
      # authority that belongs to the aliased function type exactly as the row
      # does. A capability name is CamelCase; the uppercase test is what keeps
      # the English verb in prose from reading as a grant.
      if (depth == 0 && brack == 0 && brace == 0 && substr(s, i, 7) == "allows ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev !~ /[A-Za-z0-9_]/) {
          j = i + 7
          while (j <= n && substr(s, j, 1) == " ") { j++ }
          if (substr(s, j, 1) ~ /[A-Z]/) {
            name = ""
            while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_:]/) { name = name substr(s, j, 1); j++ }
            # Remember WHICH row this clause follows. An `allows` belongs to
            # the same function-type layer as the row it trails, so comparing
            # independent counts got `-> () -> Unit with Exception with ()
            # allows Fs::read_file` wrong: two arrows, two rows, one clause,
            # and the clause is the outer declarations along with the second
            # row. authn >= arrows was false and the authority went unreported.
            authbuf[++authn] = name; authrow[authn] = rown
            i = j; continue
          }
          i += 7; continue
        }
      }
      if (depth == 0 && brack == 0 && brace == 0 && substr(s, i, 5) == "with ") {
        prev = (i > 1) ? substr(s, i - 1, 1) : " "
        if (prev ~ /[A-Za-z0-9_]/) { i++; continue }
        j = i + 5; row = ""; d2 = 0
        while (j <= n) {
          cc = substr(s, j, 1)
          if (cc == "(") { d2++ }
          else if (cc == ")") { if (d2 > 0) { d2-- } else { break } }
          else if (d2 == 0 && (cc == "{" || cc == ";")) { break }
          else if (d2 == 0 && substr(s, j, 6) == "where " ) { break }
          # a following `with` starts a NEW row rather than continuing this
          # one: `-> (String) -> Unit with Exception with Fs` is two rows, and
          # collecting them as one made the count 1, which took the
          # single-row skip path and let Fs through
          else if (d2 == 0 && substr(s, j, 5) == "with " && substr(row, length(row), 1) ~ /[ ]/) { break }
          # A new declaration ends the row as surely as a body does. The
          # normalized text has no line breaks, so `type Cb = () -> Unit with
          # ReviewAsk` followed by `export fn f() -> Unit with Fs {` ran the
          # row scan straight through the `fn `, which is where the reset
          # lives -- the next declaration was then read as part of the alias
          # and its native row went unreported. No effect item contains these
          # keywords, so breaking on them costs nothing.
          else if (d2 == 0 && cc == "=" && substr(s, j + 1, 1) != "=" && substr(s, j - 1, 1) !~ /[=<>!+\-*\/%]/) { break }
          else if (d2 == 0 && substr(s, j, 7) == "allows " && substr(row, length(row), 1) ~ /[ ]/) { break }
          else if (d2 == 0 && substr(s, j, 3) == "fn " && substr(row, length(row), 1) ~ /[ ]/) { break }
          else if (d2 == 0 && substr(s, j, 5) == "type " && substr(row, length(row), 1) ~ /[ ]/) { break }
          else if (d2 == 0 && substr(s, j, 4) == "let " && substr(row, length(row), 1) ~ /[ ]/) { break }
          row = row cc; j++
        }
        rowbuf[++rown] = row
        i = j
        continue
      }
      i++
    }
    flush()
  }
  function flush(  k) {
    # Which of the rows collected for this declaration are the DECLARATIONS own?
    #
    # One depth-0 arrow: the signature is `fn f(...) -> T with R`, so every row
    # found belongs to f.
    #
    # More than one: the return type is itself a function type, and a row may
    # belong to it instead. With exactly one row -- `fn make() -> (String) ->
    # Unit with Log::Emit` -- it is the returned closures and f is pure, so it
    # is skipped. With two or more -- `fn f() -> (String) -> Unit with Exception
    # with Fs` -- the earlier ones bind to the inner function types and the LAST
    # one is f own row, so that one is checked. Skipping all of them, as this
    # did before, let a boundary carry Fs unnoticed.
    # Each arrow layer AFTER the declarations own can carry one row, so the
    # returned function types hold at most (arrows - 1) of them. The
    # declaration owns a row only when there are more rows than layers to
    # absorb them, and then it is the last.
    #
    #   -> Unit with Fs                                arrows 1, rows 1 -> own
    #   -> (String) -> Unit with Log                   arrows 2, rows 1 -> none
    #   -> (String) -> Unit with Exception with Fs     arrows 2, rows 2 -> own
    #   -> () -> () -> Unit with Exception with Ask    arrows 3, rows 2 -> none
    #
    # Counting rows against a fixed threshold instead got the last of those
    # wrong: two rows does not mean one of them is the declarations.
    if (decl != "type") {
      # Which layer, if any, is the declarations own? Rows are absorbed by the
      # returned function types first, so the declaration owns the LAST row
      # only when there are at least as many rows as arrow layers. With no row
      # at all it still owns the signature when there is a single layer -- an
      # `allows` can trail a bare return type.
      own = -1
      if (rown >= arrows && rown >= 1) { print "row:" rowbuf[rown]; own = rown }
      else if (rown == 0 && arrows <= 1) { own = 0 }
      # Authority rides the row it trails, so the declarations clause is the
      # one recorded against the declarations own layer. Emitting every clause
      # rejected a pure helper that merely hands out an authorised closure;
      # counting clauses against arrows instead missed the case where the
      # closure took the first row and the declaration kept the second.
      if (own >= 0) {
        for (k = 1; k <= authn; k++) {
          if (authrow[k] == own) { print "auth:" authbuf[k] }
        }
      }
    }
    rown = 0; authn = 0
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
  # arguments and the `::op` suffix of a qualified item -- whitespace around
  # the `::` included, because parse_effect_item consumes the token regardless
  # of spacing (parser_base.vibe), so `with Exception :: Throw` is the same row
  # as `with Exception::Throw`. Stripping only the adjacent form left `Throw`
  # to reach the allow-list as an effect of its own, and the row was rejected.
  # This is the second place the same spacing assumption was wrong; the direct
  # call pattern was the first.
  #
  # ...and check EVERY
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
    | sed -n 's/^row://p' \
    | sed 's/\[[^]]*\]//g' \
    | sed -E 's/[[:space:]]*::[[:space:]]*[A-Za-z0-9_]*//g' \
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
  # Declaration-aware, not a whole-file grep: boundary_effect_rows is the one
  # pass that knows which declaration a clause belongs to, and it tags what it
  # emits. The grep it replaced rejected an `allows` on a type alias, where the
  # authority belongs to the aliased function type -- the same reasoning that
  # already skips an alias's effect row.
  if boundary_scan_text "$file" \
    | boundary_effect_rows \
    | sed -n 's/^auth:/allows /p' >/tmp/vibe_portable_authority_hits.$$
    [ -s /tmp/vibe_portable_authority_hits.$$ ]; then
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

# The entry file gets one MORE alternative than the other two. Its row
# allow-list is deliberately off (see below), so a capability call there is not
# caught by the row -- and only `perform` spellings were banned, which left a
# plain `Console::write_stream(...)` free. That is a capability builtin, called
# as an ordinary function (ADR-0084), so no `perform` appears anywhere.
#
# `Fs::` is NOT in this list, on purpose: this entry is the one that does file
# IO and says so, carrying `with Exception + Fs` / `with Fs`. Its contract is
# exactly that row, so a call inside it is declared and the others are not. It
# makes exactly one capability call today, `Fs::stat_token`.
entry_native_pattern="$native_effect_pattern"'|(Console|Env|Process|Socket|Http|Net)[[:space:]]*::'
forbid_pattern \
  "lib/@vibe/compiler/cli_direct_component_entry.vibe" \
  "$entry_native_pattern" \
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
# The entry file too. Its row allow-list is off, but an `allows` clause is
# authority rather than an effect, and this boundary is not entitled to any:
# it has none today, and one appearing is a leak whatever its row says. Only
# `perform` spellings were banned here, so `allows Console::write_stream`
# passed the required gate outright.
forbid_capability_authority \
  "lib/@vibe/compiler/cli_direct_component_entry.vibe" \
  "direct component entry"
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
