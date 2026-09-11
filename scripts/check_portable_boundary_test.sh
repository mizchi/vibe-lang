#!/usr/bin/env bash
# check_portable_boundary_test.sh -- red test for check_portable_boundary.sh.
#
# Written when that gate was repaired (#2577). It had been asserting a
# two-generations-old shape of the boundary -- `export let name: (...) -> Bytes
# with { Error }` in an `index.vibe` facade -- after ADR-0070 moved the contract
# to `index.vpkg` and ADR-0085 replaced `Error` with `Exception`. So it reported
# "missing expected pure boundary" for files that no longer existed, while every
# boundary it names was intact in the contract beside them. It runs in no CI
# job, so nothing said so.
#
# Repairing a gate that has been dark is exactly when it needs a red test:
# "it says ok now" is equally consistent with "it was fixed" and "it was
# neutered". These four cases separate those, and the two mutation cases are
# the ones the repair could plausibly have broken.
#
# The gate scans the repository from its own location rather than a tree it is
# handed, so each case mutates a real file and restores it with `git checkout`.
# The restore runs on EXIT, so an interrupted run does not leave the tree
# modified.
#
# #2252: no environment is inherited -- this gate reads none, and the test sets
# none.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

gate="scripts/check_portable_boundary.sh"
impl="lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe"
contract="lib/@vibe/compiler/entry/source_compile/index.vpkg"
# The entry file is scanned too, and is deliberately outside the effect-row
# allow-list -- forbid_pattern is its only protection, which is what the
# native-call cases at the end exercise.
entry="lib/@vibe/compiler/cli_direct_component_entry.vibe"

# Refuse to run against a dirty tree: the restore below would discard the
# author's uncommitted work in these files.
if ! git diff --quiet -- "$impl" "$contract" "$entry"; then
  echo "portable-boundary-test: $impl, $contract or $entry has uncommitted changes." >&2
  echo "  This test mutates and restores them with 'git checkout'. Commit or" >&2
  echo "  stash first, so a restore cannot discard your work." >&2
  exit 2
fi

restore() { git checkout -q -- "$impl" "$contract" "$entry" 2>/dev/null || true; }
# The EXIT trap also sweeps the gate copies a case may leave behind. `set -e`
# can end the run between writing one and removing it, and a stray
# `scripts/.portable_boundary_*.sh` is then an untracked file that other gates
# scan -- a failure with nothing to do with what broke.
cleanup() { restore; rm -f scripts/.portable_boundary_*probe*.sh; }
trap cleanup EXIT

fails=0
pass() { printf 'portable-boundary-test: ok: %s\n' "$1"; }
fail() { printf 'portable-boundary-test: FAIL: %s\n' "$1" >&2; fails=1; }

# --- control, first: the unmutated tree passes -------------------------------
#
# Load-bearing. Three of the four cases assert a FAILURE, so a gate that
# rejected everything would make them all "pass" while proving nothing.

if bash "$gate" >/dev/null 2>&1; then
  pass "control: the unmutated tree passes"
else
  fail "control: the unmutated tree is rejected -- the red cases below prove nothing"
  bash "$gate" >&2 || true
fi

# --- case 1: a native capability in CODE is rejected -------------------------

printf '\nlet _portable_boundary_probe = perform Fs::read_file("x")\n' >> "$impl"
if bash "$gate" >/dev/null 2>&1; then
  fail "case 1: a 'perform Fs::read_file' in code passed"
else
  pass "case 1: a native capability in code is rejected"
fi
restore

# --- case 2: the same text in a COMMENT is accepted --------------------------
#
# The distinction the repair introduced, asserted rather than assumed. These
# files exist to explain how they differ from the FS lane, so prose naming a
# native entry point is the writing we want -- the gate was failing on
# "-- see `compile_file_fs_mode`'s comment, #2391". Case 1 is what keeps this
# from being a blanket exemption: strip comments, still catch code.

printf '\n/// prose naming perform Fs::read_file and compile_file_fs_mode\n' >> "$impl"
if bash "$gate" >/dev/null 2>&1; then
  pass "case 2: the same names in a comment are accepted"
else
  fail "case 2: a doc comment naming a native entry point was rejected as a leak"
fi
restore

# --- case 3: a boundary that gains an effect is rejected ---------------------
#
# The require_line half. `with Exception` becoming `with Fs` is the change this
# gate exists to catch, and it is the half that had rotted: it was matching a
# spelling no file in the tree had used for two ADRs.

sed 's/^fn compile_source(source: String) -> Bytes with Exception$/fn compile_source(source: String) -> Bytes with Fs/' \
  "$contract" > "$contract.probe"
mv "$contract.probe" "$contract"
if git diff --quiet -- "$contract"; then
  fail "case 3: the mutation did not land -- the assertion below would prove nothing"
else
  if bash "$gate" >/dev/null 2>&1; then
    fail "case 3: a boundary declaring 'with Fs' passed"
  else
    pass "case 3: a boundary that gains a native effect is rejected"
  fi
fi
restore

# --- case 4: an IMPLEMENTATION that declares a native effect row ------------
#
# The forbid_pattern half, which case 3 does NOT reach: case 3 edits the
# contract line, so require_line fails first and the gate's rejection says
# nothing about whether forbid_pattern recognizes the row syntax. It did not.
# Measured before the fix: appending this exact declaration left the gate
# printing `ok`, because native_effect_pattern only knew the braced
# `with { ... }` spelling -- which is the HANDLER syntax, not an effect row.
printf '\nexport fn probe_native() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_native\(\) -> Unit with Fs \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case 4: an implementation declaring 'with Fs' passed the gate"
  else
    pass "case 4: a native effect row in an implementation is rejected"
  fi
else
  fail "case 4: the mutation did not land -- the assertion below would prove nothing"
fi
restore

# --- case 5: a non-native effect row is still accepted -----------------------
#
# Case 4 alone is also satisfied by a matcher that rejects every `with` row, so
# this pins the other side: `with Exception` is what these boundaries are
# REQUIRED to carry, and must not start reading as a leak.
printf '\nexport fn probe_pure() -> Unit with Exception {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_pure\(\) -> Unit with Exception \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case 5: a non-native effect row is accepted"
  else
    fail "case 5: 'with Exception' was rejected as a native leak"
  fi
else
  fail "case 5: the mutation did not land -- the assertion above would prove nothing"
fi
restore

# --- cases 6-8: the allow-list rejects every non-portable capability --------
#
# `Fs` alone (case 4) is satisfied by a deny-list, which is what this gate had
# twice -- and both times it passed a capability nobody had thought to name.
# `Env` and `Console` are capability builtins (AGENTS.md) and both passed the
# Fs|Process|Socket|Net|Http matcher. `Nonsense` stands for the capability that
# does not exist yet: an allow-list must reject it without being taught to.
for eff in Env Console Nonsense; do
  printf '\nexport fn probe_%s() -> Unit with %s {\n  ()\n}\n' "$eff" "$eff" >> "$impl"
  if grep -qE "^export fn probe_$eff\(\) -> Unit with $eff \{$" "$impl"; then
    if bash "$gate" >/dev/null 2>&1; then
      fail "case: an implementation declaring 'with $eff' passed the gate"
    else
      pass "case: 'with $eff' is rejected by the allow-list"
    fi
  else
    fail "case: the 'with $eff' mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# --- case 9: an allowed effect in a COMPOUND row is still accepted -----------
#
# The row splitter has to handle `A + B`, not just a bare effect. If it did not,
# every compound row would read as one unknown name and the gate would reject
# code it must accept -- a gate that fails closed on correct input gets
# disabled, which is the outcome #2252 describes.
printf '\nexport fn probe_compound() -> Unit with Exception + Async {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_compound\(\) -> Unit with Exception \+ Async \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a compound row of allowed effects is accepted"
  else
    fail "case: 'with Exception + Async' was rejected -- the row splitter is wrong"
  fi
else
  fail "case: the compound-row mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 10: a native capability hidden in a compound row is caught ---------
#
# The converse of case 9, and the shape a real leak takes: the forbidden effect
# is not the first name in the row.
printf '\nexport fn probe_mixed() -> Unit with Exception + Fs {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_mixed\(\) -> Unit with Exception \+ Fs \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: 'with Exception + Fs' passed -- only the first effect is checked"
  else
    pass "case: a native effect later in a compound row is rejected"
  fi
else
  fail "case: the mixed-row mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 11-12: capability authority via `allows` -------------------------
#
# `allows` grants authority in the signature, separately from the effect row,
# and the operation is then called plainly rather than through `perform`. So it
# matched neither the row allow-list nor `perform (Fs|...)::`: measured, the
# gate exited 0 on a boundary that read a file.
for grant in 'Fs::read_file' 'Console::write_stream'; do
  printf '\nexport fn probe_allows() -> String with Exception allows %s {\n  ""\n}\n' "$grant" >> "$impl"
  if grep -qF "allows $grant {" "$impl"; then
    # Capture the diagnostic, not just the exit status. Checking only the
    # status let a broken message through once already: a backtick inside a
    # double-quoted echo ran `allows` as a command, so the gate printed
    # "allows: command not found" and "An  clause ...", and this case stayed
    # green. AGENTS.md requires the message name the edit that fixes it, so an
    # unreadable one is a defect the self-test has to be able to see.
    out="$(bash "$gate" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "case: a boundary granted 'allows $grant' passed the gate"
    elif printf '%s' "$out" | grep -q 'command not found'; then
      fail "case: the gate's own diagnostic is broken: $out"
    elif printf '%s' "$out" | grep -qF 'allows'; then
      pass "case: capability authority 'allows $grant' is rejected, with a readable message"
    else
      fail "case: rejected, but the message never says what was wrong: $out"
    fi
  else
    fail "case: the 'allows $grant' mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# --- case 13: English prose containing "allows" is still accepted -----------
#
# The clause is told from prose by the CamelCase capability name. Without this,
# the obvious fix (matching the bare word `allows`) would reject every comment
# that uses the English verb -- and the tree has several.
printf '\n/// This entry point allows them to compile without touching the host.\n' >> "$impl"
if grep -qF 'allows them to compile' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: prose using the word 'allows' is accepted"
  else
    fail "case: an English 'allows' in a comment was read as a capability grant"
  fi
else
  fail "case: the prose mutation did not land -- the assertion above proves nothing"
fi
restore

# --- cases 14-15: the capability need not be adjacent to `allows` -----------
#
# Both of these COMPILE -- verified with `vibe test` on a stage2 built from this
# checkout, not assumed -- and both slipped past the first version of the check,
# which required the capability to follow the keyword on the same line.
#
# (`allows /* c */ Fs::read_file` needs no case: vibe has no block comments, so
# it does not parse -- "expected an effect name in the effect row after 'with'".
# A case for it would assert a rejection the language already guarantees.)
printf '\nexport fn probe_nl() -> String with Exception allows\n  Fs::read_file {\n  ""\n}\n' >> "$impl"
if grep -qE 'allows$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: 'allows' with the capability on the NEXT LINE passed the gate"
  else
    pass "case: a capability on the next line is still rejected"
  fi
else
  fail "case: the newline mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_tc() -> String with Exception allows // note\n  Fs::read_file {\n  ""\n}\n' >> "$impl"
if grep -qF 'allows // note' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: 'allows' followed by a trailing comment passed the gate"
  else
    pass "case: a comment between the keyword and the capability is stripped"
  fi
else
  fail "case: the trailing-comment mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 16-17: an effect row split across lines --------------------------
#
# A row may be broken after `+`, and it compiles -- verified with `vibe test`.
# A line-by-line scan matched `with Exception`, accepted it, and never
# associated the `Fs` on the next line. Both directions are pinned: the split
# row must still be REJECTED when it names a capability, and still ACCEPTED
# when it does not, since flattening must not make the scanner blind or
# trigger-happy.
printf '\nexport fn probe_split() -> String with Exception +\n  Fs {\n  ""\n}\n' >> "$impl"
if grep -qE 'with Exception \+$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a row split after '+' hid a native effect from the gate"
  else
    pass "case: a native effect on the next line of a split row is rejected"
  fi
else
  fail "case: the split-row mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_split_ok() -> String with Exception +\n  Async {\n  ""\n}\n' >> "$impl"
if grep -qE 'with Exception \+$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a split row of allowed effects is accepted"
  else
    fail "case: 'with Exception +\\n Async' was rejected -- flattening broke acceptance"
  fi
else
  fail "case: the split-row mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 18-19: an effect item with type arguments ------------------------
#
# `parse_effect_item` accepts a generic item, and `with Exception[String] + Fs`
# compiles -- verified with `vibe test`. Matching bare identifiers stopped at
# the `[`, recorded the allowed `Exception`, and never saw the `Fs`. Both
# directions again: the generic form must not hide a capability, and must not
# start rejecting an allowed row either.
printf '\nexport fn probe_gen() -> Unit with Exception[String] + Fs {\n  ()\n}\n' >> "$impl"
if grep -qF 'with Exception[String] + Fs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a generic effect item hid the capability after it"
  else
    pass "case: a capability after a generic effect item is rejected"
  fi
else
  fail "case: the generic-item mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_gen_ok() -> Unit with Exception[String] + Async {\n  ()\n}\n' >> "$impl"
if grep -qF 'with Exception[String] + Async' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a generic item in an otherwise allowed row is accepted"
  else
    fail "case: 'with Exception[String] + Async' was rejected -- the type argument leaked into the name"
  fi
else
  fail "case: the generic-item mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 20-21: a qualified effect item -----------------------------------
#
# `parse_effect_item` accepts `Ident::Ident`, and `with Exception::Throw + Fs`
# compiles. This was the sixth form the old grammar-matching regex did not
# know, and the reason the scan stopped modelling the grammar: it now reads the
# whole span between `with` and the body and checks every capability name in
# it, so separators and item shapes do not matter. The allowed-qualified case
# is what proves the `::op` suffix is dropped rather than read as a name.
printf '\nexport fn probe_qual() -> Unit with Exception::Throw + Fs {\n  ()\n}\n' >> "$impl"
if grep -qF 'with Exception::Throw + Fs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a qualified effect item hid the capability after it"
  else
    pass "case: a capability after a qualified effect item is rejected"
  fi
else
  fail "case: the qualified-item mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_qual_ok() -> Unit with Exception::Throw {\n  ()\n}\n' >> "$impl"
if grep -qF 'with Exception::Throw {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a qualified allowed item is accepted"
  else
    fail "case: 'with Exception::Throw' was rejected -- the operation name was read as an effect"
  fi
else
  fail "case: the qualified-item mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 22-24: string literals are not effect rows -----------------------
#
# The converse direction, and the one that actually loses a gate: reading the
# whole span from `with` to the body captured an inert message such as
# "compile with Fs when requested" and reported `effect: Fs` on correct code.
# A required gate that fails on code that is fine gets disabled (#2252), so a
# false positive is not the safe side of this check -- it is a second way to
# lose it. Same for a string that happens to contain the word `allows`.
printf '\nexport fn probe_msg() -> String with Exception {\n  "compile with Fs when requested"\n}\n' >> "$impl"
if grep -qF 'compile with Fs when requested' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a string literal naming an effect is not read as a row"
  else
    fail "case: an inert string mentioning 'with Fs' failed the gate"
  fi
else
  fail "case: the string mutation did not land -- the assertion above proves nothing"
fi
restore

printf '\nexport fn probe_msg2() -> String with Exception {\n  "this allows Fs::read_file to run"\n}\n' >> "$impl"
if grep -qF 'this allows Fs::read_file to run' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a string literal naming an allows clause is not read as a grant"
  else
    fail "case: an inert string mentioning 'allows' failed the gate"
  fi
else
  fail "case: the string mutation did not land -- the assertion above proves nothing"
fi
restore

# Stripping strings must not become a way to HIDE a real row: a declaration
# that genuinely carries `with Fs` is still caught when a string sits beside it.
printf '\nexport fn probe_both() -> String with Fs {\n  "a harmless with Exception message"\n}\n' >> "$impl"
if grep -qF 'export fn probe_both() -> String with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a real 'with Fs' was hidden by the string strip"
  else
    pass "case: a real row is still caught when a string sits beside it"
  fi
else
  fail "case: the mixed mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 25: an effect-row variable ----------------------------------------
#
# `fn probe[e](f: () -> Unit with e) -> Unit with e` runs whatever effect its
# caller instantiates, Fs included, while naming no capability at all. Matching
# only capitalized names dropped it silently. Unresolved is not portable, so
# the allow-list rejects it like any other name it does not know.
printf '\nexport fn probe_rv[e](f: () -> Unit with e) -> Unit with e {\n  f()\n}\n' >> "$impl"
if grep -qF -- '-> Unit with e {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an effect-row variable passed the gate"
  else
    pass "case: an unresolved effect-row variable is rejected"
  fi
else
  fail "case: the row-variable mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 26: a parameter carries its own row -------------------------------
#
# THE false positive. "From `with` to the next `{`" started at the PARAMETER's
# row, swallowed `) -> Unit`, and reported `effect: Unit` on a legitimate
# higher-order helper. The outer row is the one at parenthesis depth 0.
printf '\nexport fn probe_cb(f: () -> Unit with Exception) -> Unit with Exception {\n  f()\n}\n' >> "$impl"
if grep -qF '(f: () -> Unit with Exception)' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a parameter's own effect row is not read as the declaration's"
  else
    fail "case: a higher-order helper with an effectful callback was rejected"
  fi
else
  fail "case: the callback mutation did not land -- the assertion above proves nothing"
fi
restore

# --- case 27: an escaped quote inside a string ------------------------------
#
# `"[^"]*"` ended the literal at the backslash-escaped quote and left the inert
# text exposed, so an ordinary diagnostic string failed the gate.
printf '\nexport fn probe_eq() -> String with Exception {\n  "prefix \\"with Fs\\" suffix"\n}\n' >> "$impl"
if grep -qF 'prefix \"with Fs\" suffix' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an escaped quote inside a string does not expose its text"
  else
    fail "case: a string containing an escaped quote failed the gate"
  fi
else
  fail "case: the escaped-quote mutation did not land -- the assertion above proves nothing"
fi
restore

# --- case 28: a raw string is a string too ----------------------------------
#
# `#|` opens a RAW string running to end of line. Normalization removed only
# double-quoted literals, so `#|compile with Fs when requested` was reported as
# `effect: Fs`, `effect: when`, `effect: requested` -- a required gate
# rejecting an ordinary message.
printf '\nexport fn probe_raw() -> String with Exception {\n  #|compile with Fs when requested\n}\n' >> "$impl"
if grep -qF '#|compile with Fs when requested' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a raw string is not read as an effect row"
  else
    fail "case: a '#|' raw string mentioning 'with Fs' failed the gate"
  fi
else
  fail "case: the raw-string mutation did not land -- the assertion above proves nothing"
fi
restore

# --- cases 29-30: a tab is whitespace ---------------------------------------
#
# The lexer treats a tab as whitespace, so `with<TAB>Fs` is a legal row.
# Matching the literal text "with " missed it and the gate exited 0. The same
# hid a tab-separated `allows` clause, so both keywords are pinned.
printf '\nexport fn probe_tab() -> Unit with\tFs {\n  ()\n}\n' >> "$impl"
if grep -qF $'with\tFs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a tab-separated effect row passed the gate"
  else
    pass "case: a tab after 'with' is still an effect row"
  fi
else
  fail "case: the tab mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_tab_allows() -> String with Exception allows\tFs::read_file {\n  ""\n}\n' >> "$impl"
if grep -qF $'allows\tFs::read_file' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a tab-separated 'allows' clause passed the gate"
  else
    pass "case: a tab after 'allows' is still a capability grant"
  fi
else
  fail "case: the tab-allows mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 31-32: forbid_pattern reads the same normalized view -------------
#
# forbid_pattern dropped only whole comment LINES, so an inert diagnostic
# containing `perform Fs::read_file` was reported as a leak. Case 1 already
# covers a comment; this covers a STRING, and the pair with case 32 is what
# keeps the fix from becoming a way to hide the real call.
printf '\nexport fn probe_pstr() -> String with Exception {\n  "do not generate perform Fs::read_file here"\n}\n' >> "$impl"
if grep -qF 'do not generate perform Fs::read_file here' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: 'perform Fs::' inside a string literal is not a leak"
  else
    fail "case: an inert string containing 'perform Fs::' failed the gate"
  fi
else
  fail "case: the string mutation did not land -- the assertion above proves nothing"
fi
restore

printf '\nexport fn probe_pcall() -> Unit with Exception {\n  perform Fs::read_file("x")\n}\n' >> "$impl"
if grep -qF 'perform Fs::read_file("x")' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a real 'perform Fs::' call was hidden by the string strip"
  else
    pass "case: a real 'perform Fs::' call is still a leak"
  fi
else
  fail "case: the call mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 33: a handler clause is not a declaration row ---------------------
#
# `handle { ... } with ReviewAsk { ... }` discharges an effect locally. Its
# `with` is at paren depth 0, so it was read as a signature and reported
# `effect: ReviewAsk` -- rejecting a helper that is pure BECAUSE it handles the
# effect. A declaration's row sits before the body brace; a handler is inside
# one, so brace depth tells them apart.
printf '\nexport fn probe_handle() -> Unit with Exception {\n  handle {\n    ()\n  } with ReviewAsk {\n    ReviewAsk::Ask(_k) => ()\n  }\n}\n' >> "$impl"
if grep -qF '} with ReviewAsk {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a handler clause is not read as a declaration effect row"
  else
    fail "case: a locally handled effect was reported as non-portable"
  fi
else
  fail "case: the handler mutation did not land -- the assertion above proves nothing"
fi
restore

# --- cases 34-35: an interpolation body executes ----------------------------
#
# `"\{ ... }"` is not inert: the body between `\{` and `}` is code and runs.
# Stripping the whole quoted token discarded it, so a real capability call
# inside one became invisible -- a hole the pre-PR gate did not have, since it
# stripped no strings at all. The pair keeps both directions honest: the
# executable body is scanned, the inert text around it is not.
printf '\nexport fn probe_interp_exec() -> String with Exception {\n  "\\{perform Fs::read_file("x")}"\n}\n' >> "$impl"
if grep -qF 'perform Fs::read_file' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a capability call inside an interpolation body was invisible"
  else
    pass "case: an interpolation body is scanned, not discarded with the string"
  fi
else
  fail "case: the interpolation mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_interp_inert() -> String with Exception {\n  "\\{String::concat("perform Fs::read_file", " is inert")}"\n}\n' >> "$impl"
if grep -qF 'is inert' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a string nested inside an interpolation is still inert"
  else
    fail "case: an inert literal nested in an interpolation failed the gate"
  fi
else
  fail "case: the nested-literal mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 36-37: a char literal is inert -----------------------------------
#
# A brace inside a char literal was counted as a real brace, so every
# declaration AFTER it looked nested and had its effect row skipped. One
# `'{'` anywhere in the file silently disabled the rest of the scan -- the
# worst kind of miss, since it is unbounded and invisible.
printf '\nfn brace_literal_probe() -> Char {\n  %s{%s\n}\n\nexport fn probe_after_char() -> Unit with Fs {\n  ()\n}\n' "'" "'" >> "$impl"
if grep -qF "export fn probe_after_char() -> Unit with Fs {" "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a brace in a char literal disabled the scan for everything after it"
  else
    pass "case: a char literal does not corrupt the brace depth"
  fi
else
  fail "case: the char-literal mutation did not land -- the assertion proves nothing"
fi
restore

# The converse: consuming a char literal must not eat the code after it, or the
# same declaration would go unscanned for the opposite reason.
printf '\nfn quote_char_probe() -> Char {\n  %s\\\\%s%s\n}\n\nexport fn probe_after_quote() -> Unit with Exception {\n  ()\n}\n' "'" "n" "'" >> "$impl"
if grep -qF "export fn probe_after_quote() -> Unit with Exception {" "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an escaped char literal is consumed without eating what follows"
  else
    fail "case: an escaped char literal broke the scan of the next declaration"
  fi
else
  fail "case: the escaped-char mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 38-39: a string literal may span physical lines ------------------
#
# Measured: a multi-line string compiles. Resetting lexical state at each awk
# record scanned the continuation as executable code and reported inert text as
# a leak. State is carried across records now -- and the second case is what
# keeps that from becoming a way to swallow the rest of the file: a real effect
# row AFTER a multi-line string must still be caught.
printf '\nexport fn probe_ml() -> String with Exception {\n  "line one\n  perform Fs::read_file continues here"\n}\n' >> "$impl"
if grep -qF 'continues here' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a multi-line string continuation is inert"
  else
    fail "case: the continuation of a multi-line string was scanned as code"
  fi
else
  fail "case: the multi-line mutation did not land -- the assertion above proves nothing"
fi
restore

printf '\nexport fn probe_ml2() -> String with Exception {\n  "line one\n  ends here"\n}\n\nexport fn probe_after_ml() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF 'export fn probe_after_ml() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a multi-line string swallowed everything after it"
  else
    pass "case: a declaration after a multi-line string is still scanned"
  fi
else
  fail "case: the after-multiline mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 40-41: a raw quoted string has no escapes ------------------------
#
# `r"..."` scans to the next quote with NO escape processing
# (lib/@vibe/parser/lexer.vibe), so `r"trailing\"` ENDS at that quote. Treating
# it as an ordinary string consumed the backslash and quote together, stayed in
# string mode, and discarded every declaration after it -- the unbounded shape
# of miss again, from a different construct.
printf '\nexport fn raw_probe() -> String with Exception {\n  r"trailing\\\\"\n}\n\nexport fn native_after_raw() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF 'export fn native_after_raw() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a raw string ending in a backslash disabled the scan after it"
  else
    pass "case: a raw quoted string ends at its quote, not at an escape"
  fi
else
  fail "case: the raw-string mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn raw_inert() -> String with Exception {\n  r"perform Fs::read_file is inert"\n}\n' >> "$impl"
if grep -qF 'r"perform Fs::read_file is inert"' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: raw string content is inert"
  else
    fail "case: the content of a raw string was scanned as code"
  fi
else
  fail "case: the raw-inert mutation did not land -- the assertion above proves nothing"
fi
restore

# --- case 42: a returned function type carries its own row ------------------
#
# `fn make() -> (String) -> Unit with Log::Emit` is PURE: the row belongs to
# the returned closure (fixtures/typecheck/closure_row_return_position.vibe).
# That `with` is at parenthesis depth 0 like any other, so it was reported as
# the declaration's row and a legitimate helper was rejected.
printf '\nexport fn make_logger() -> (String) -> Unit with Log::Emit {\n  (s) -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF -- '-> (String) -> Unit with Log::Emit {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a returned function type's row is not the declaration's"
  else
    fail "case: a pure helper returning an effectful closure was rejected"
  fi
else
  fail "case: the closure-return mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 43: THE COST OF CASE 42, pinned so it is visible ------------------
#
# Skipping the ambiguous multi-arrow shape means a boundary that returns an
# Fs-carrying closure is NOT checked, WHEN that is the only row in the
# signature. If the signature carries a second row, the last one is the
# declarations own and IS checked (cases 51-52) -- that narrowing came from
# review round 25, where skipping every row let a real leak through.
# This case asserts the remaining miss deliberately.
# It is not an endorsement: telling it from case 42 needs the type grammar, and
# grammar is what this scan stopped modelling. #2581 answers it from the AST.
#
# If a future change makes this REJECT, that is an improvement -- update this
# case rather than reverting the change. The point is that the gap is written
# down as a test, not left to be rediscovered.
printf '\nexport fn make_reader() -> (String) -> Unit with Fs {\n  (s) -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF -- '-> (String) -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: KNOWN MISS -- a returned Fs-carrying closure is not checked (#2581)"
  else
    fail "case: unexpected -- if this now rejects, update the case, do not revert"
  fi
else
  fail "case: the known-miss mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 44-45: arrow count belongs to ONE declaration --------------------
#
# The ambiguity guard reset only on `{`, so a bodyless declaration carrying an
# arrow (`type Cb = (Int) -> Int`) left the count at 1; the next function's own
# arrow made 2 and its row was skipped. An unrelated type alias silently
# disabled the check for the declaration after it. The count is anchored to
# `fn` now. Both directions, since the anchor could equally over-reset.
printf '\ntype Cb = (Int) -> Int\n\nexport fn rn_native() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'type Cb = (Int) -> Int' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a type alias with an arrow disabled the check for the next declaration"
  else
    pass "case: an arrow in a bodyless declaration does not leak into the next"
  fi
else
  fail "case: the alias mutation did not land -- the assertion proves nothing"
fi
restore

printf '\ntype Cb2 = (Int) -> Int\n\nexport fn rn_pure() -> Unit with Exception {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'type Cb2 = (Int) -> Int' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allowed row after a bodyless arrow declaration is still accepted"
  else
    fail "case: the arrow anchor made an allowed row reject"
  fi
else
  fail "case: the alias mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 46-47: a `where` contract follows the row ------------------------
#
# `fn f(x: Int) -> Int with Exception where { requires: x >= 0 }` -- the row
# ends at `where`, not at the contract's brace. Including it reported
# `effect: where` and rejected a legitimate design-by-contract declaration.
printf '\nexport fn checked(x: Int) -> Int with Exception where { requires: x >= 0 } {\n  x\n}\n' >> "$impl"
if grep -qF 'with Exception where { requires:' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a where contract is not part of the effect row"
  else
    fail "case: a declaration with a where contract was rejected"
  fi
else
  fail "case: the where mutation did not land -- the assertion above proves nothing"
fi
restore

# The row before a `where` must still be checked, or stopping early becomes a
# way to hide one.
printf '\nexport fn checked_bad(x: Int) -> Int with Fs where { requires: x >= 0 } {\n  x\n}\n' >> "$impl"
if grep -qF 'with Fs where { requires:' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native row before a where contract was skipped"
  else
    pass "case: the row before a where contract is still checked"
  fi
else
  fail "case: the where mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 48-50: whitespace in a native call -------------------------------
#
# `perform  Fs::ReadFile` (two spaces), a tab, and a newline separator all
# compile, and all bypassed a pattern matching exactly one literal space. The
# newline case additionally needs the FLATTENED view: a line-oriented grep
# cannot see a match that spans lines, so forbid_pattern now checks both.
#
# These run against the entry file rather than "$impl": cli_direct_component_entry
# is deliberately outside the effect-row allow-list, so forbid_pattern is its
# ONLY protection, which is what makes this class of miss matter there.
printf '\nexport fn probe_sp2(p: String) -> String with Fs {\n  perform  Fs::ReadFile(p)\n}\n' >> "$entry"
if grep -qF 'perform  Fs::ReadFile(p)' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native call with two spaces passed the gate"
  else
    pass "case: repeated whitespace in a native call is still a leak"
  fi
else
  fail "case: the two-space mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_spnl(p: String) -> String with Fs {\n  perform\n    Fs::ReadFile(p)\n}\n' >> "$entry"
if grep -qE '^  perform$' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native call split across lines passed the gate"
  else
    pass "case: a native call split across lines is still a leak"
  fi
else
  fail "case: the newline mutation did not land -- the assertion proves nothing"
fi
restore

# And the converse, so widening the separator does not start flagging prose.
printf '\nexport fn probe_sp_str() -> String with Exception {\n  "do not perform  Fs::ReadFile here"\n}\n' >> "$entry"
if grep -qF 'do not perform  Fs::ReadFile here' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: the same text inside a string is still not a leak"
  else
    fail "case: an inert string with a spaced native call failed the gate"
  fi
else
  fail "case: the string mutation did not land -- the assertion above proves nothing"
fi
restore

# --- cases 51-52: a multi-arrow signature may still carry its OWN row -------
#
# The ambiguity skip added at review round 21 dropped EVERY row in a
# multi-arrow signature. But `fn f() -> (String) -> Unit with Exception with Fs`
# has two: the first binds to the returned function type, the LAST is f own row.
# Skipping both let a boundary carry Fs unnoticed -- a miss in exactly what this
# gate is for, introduced by the guard meant to prevent a false positive.
#
# The rule now: one row in a multi-arrow signature is the closures (skip, case
# 42); two or more means the last is the declarations (check).
printf '\nexport fn probe_two_rows() -> (String) -> Unit with Exception with Fs {\n  (s) -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF 'with Exception with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a multi-arrow signature hid the function own native row"
  else
    pass "case: the last row of a multi-arrow signature is the declaration own"
  fi
else
  fail "case: the two-row mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport fn probe_two_ok() -> (String) -> Unit with Exception with Async {\n  (s) -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF 'with Exception with Async {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a multi-arrow signature whose own row is allowed is accepted"
  else
    fail "case: an allowed last row in a multi-arrow signature was rejected"
  fi
else
  fail "case: the two-row mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 53-54: rows are matched against arrow LAYERS, not counted --------
#
# Round 25 used "two or more rows means the last is the declarations". Round 26
# found the counterexample: `-> () -> () -> Unit with Exception with ReviewAsk`
# has two rows and BOTH belong to the nested closures, so that rule rejected a
# pure helper.
#
# The invariant instead: each arrow layer after the declarations own can carry
# one row, so the returned function types absorb at most (arrows - 1). The
# declaration owns a row only when rows >= arrows, and then it is the last.
#
#   arrows 1, rows 1 -> own      arrows 2, rows 1 -> none
#   arrows 2, rows 2 -> own      arrows 3, rows 2 -> none
#   arrows 3, rows 3 -> own
printf '\nexport fn probe_nested_pure() -> () -> () -> Unit with Exception with ReviewAsk {\n  () -> {\n    () -> {\n      ()\n    }\n  }\n}\n' >> "$impl"
if grep -qF 'with Exception with ReviewAsk {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: two rows absorbed by two closure layers leave the declaration pure"
  else
    fail "case: a pure helper returning nested effectful closures was rejected"
  fi
else
  fail "case: the nested mutation did not land -- the assertion above proves nothing"
fi
restore

# And the converse at the same arrow depth, so the invariant is not just
# "three arrows means never check".
printf '\nexport fn probe_nested_own() -> () -> () -> Unit with Exception with Async with Fs {\n  () -> {\n    () -> {\n      ()\n    }\n  }\n}\n' >> "$impl"
if grep -qF 'with Exception with Async with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a third row at three arrows is the declaration own and was skipped"
  else
    pass "case: rows beyond the closure layers are the declaration own"
  fi
else
  fail "case: the nested-own mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 55-56: a type argument is not a return-type layer ----------------
#
# Round 27. The arrow layers of case 53 are counted by scanning for `->` at
# parenthesis depth 0 -- but brackets were not tracked, so the arrow inside
# `Array[() -> Unit]` counted as a layer of its own. `-> Array[() -> Unit] with
# Fs` then read as arrows 2 against rows 1, which is the "returned closure owns
# it" shape, and the declaration's native row went unchecked.
#
# A type ARGUMENT is not a layer: nothing is returned through it that could own
# a row. Brackets now nest like parens, so the arrow inside them is invisible
# to the count and the row is the declaration's.
printf '\nexport fn probe_brk_native() -> Array[() -> Unit] with Fs {\n  []\n}\n' >> "$impl"
if grep -qF -- '-> Array[() -> Unit] with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an arrow inside a type argument hid the declaration native row"
  else
    pass "case: an arrow inside a type argument is not a return-type layer"
  fi
else
  fail "case: the bracket mutation did not land -- the assertion proves nothing"
fi
restore

# The converse at the same shape, so the fix is not "brackets mean reject".
printf '\nexport fn probe_brk_ok() -> Array[() -> Unit] with Async {\n  []\n}\n' >> "$impl"
if grep -qF -- '-> Array[() -> Unit] with Async {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allowed row on a bracketed return type is accepted"
  else
    fail "case: an allowed row on a bracketed return type was rejected"
  fi
else
  fail "case: the bracket mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 57-60: a row belongs to a declaration KIND -----------------------
#
# Round 28, and a false positive: `type ReviewCallback = () -> Unit with
# ReviewAsk` is one arrow and one row, which is the "the row is the
# declaration's own" shape, so a harmless alias failed the required job on
# correct code. Naming a type performs nothing -- the row belongs to the
# aliased function type, the same reason the lone row of a returned closure is
# skipped (case 42).
printf '\ntype ReviewCallback = () -> Unit with ReviewAsk\n' >> "$impl"
if grep -qF -- 'type ReviewCallback = () -> Unit with ReviewAsk' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an effectful type alias is not a boundary row"
  else
    fail "case: a type alias naming an effect failed the gate"
  fi
else
  fail "case: the alias mutation did not land -- the assertion proves nothing"
fi
restore

# The miss that suppressing `type` opened, and which the fix above had to close
# in the same commit. Measured: with only the flush guard, this went from
# REJECT to ACCEPT. The normalized text has no line breaks, so the alias's row
# scan ran straight through the following `fn ` -- which is where the reset
# lives -- and the whole native declaration was read as part of the alias. A
# declaration keyword now ends a row.
printf '\ntype ReviewCallback2 = () -> Unit with ReviewAsk\n\nexport fn probe_after_alias() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export fn probe_after_alias() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an effectful alias swallowed the next declaration native row"
  else
    pass "case: a declaration keyword ends the preceding row"
  fi
else
  fail "case: the alias-then-native mutation did not land -- it proves nothing"
fi
restore

printf '\ntype ReviewCallback3 = () -> Unit with ReviewAsk\n\nexport fn probe_after_alias_ok() -> Unit with Async {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export fn probe_after_alias_ok() -> Unit with Async {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allowed declaration after an effectful alias is accepted"
  else
    fail "case: an allowed declaration after an effectful alias was rejected"
  fi
else
  fail "case: the alias-then-allowed mutation did not land -- it proves nothing"
fi
restore

# --- case 60: THE COST OF CASE 57, pinned so it is visible -------------------
#
# `type FsCallback = () -> Unit with Fs` is now accepted. That is the price of
# case 57 and it is the same trade as case 43: a type that names a native
# effect is not itself a boundary, and no text scan can tell whether the
# boundary ever hands one out. #2581 answers it from the AST, where the alias
# can be followed to the declaration that uses it.
#
# When #2581 lands this case flips to a rejection. UPDATE THE CASE, do not
# revert the fix -- accepting the alias is what keeps correct code building.
printf '\ntype FsCallback = () -> Unit with Fs\n' >> "$impl"
if grep -qF -- 'type FsCallback = () -> Unit with Fs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: KNOWN MISS -- a native effect named only by an alias (#2581)"
  else
    fail "case: the alias miss closed; flip this case to a rejection"
  fi
else
  fail "case: the alias-miss mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 61-63: a binding's initializer is not part of its row ------------
#
# Round 29, another false positive. `export let f: (Int) -> Unit with Exception
# = (x) -> { () }` ran the row scan past the type and into the value, so the
# lambda's parameter was reported as `effect: x` on a portable file.
#
# `=` ends the type and starts the value. Stopping the row there is not enough
# on its own: the initializer's arrow would still count as a return-type layer
# and push rows below arrows, skipping the declaration instead of reporting
# it. So `=` FLUSHES -- the row is attributed, then the value is scanned as
# what it is. `decl` survives the flush, because a type alias keeps its row
# after the `=`.
printf '\nexport let probe_bind_ok: (Int) -> Unit with Exception = (x) -> {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export let probe_bind_ok: (Int) -> Unit with Exception = (x) -> {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a binding initializer is not read as part of the effect row"
  else
    fail "case: a portable function binding was rejected, most likely as effect: x"
  fi
else
  fail "case: the binding mutation did not land -- the assertion proves nothing"
fi
restore

# The direction that matters more: flushing at `=` must not cost the row. A
# binding IS a boundary declaration -- unlike a type alias, it is a value a
# caller can reach -- so its native row is still reported.
printf '\nexport let probe_bind_native: (Int) -> Unit with Fs = (x) -> {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export let probe_bind_native: (Int) -> Unit with Fs = (x) -> {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native row on a function binding went unreported"
  else
    pass "case: a function binding native row is still the boundary own"
  fi
else
  fail "case: the native-binding mutation did not land -- it proves nothing"
fi
restore

# And the declaration after a binding is still its own, the same property
# case 58 pins for an alias.
printf '\nexport let probe_bind_then: (Int) -> Unit with Exception = (x) -> {\n  ()\n}\n\nexport fn probe_after_bind() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export fn probe_after_bind() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a binding swallowed the next declaration native row"
  else
    pass "case: a declaration after a binding keeps its own row"
  fi
else
  fail "case: the binding-then-native mutation did not land -- it proves nothing"
fi
restore

# --- cases 64-66: a raw identifier is the same name -------------------------
#
# Round 31. `lex_ident` (lib/@vibe/parser/lexer.vibe) turns `r#Exception` into
# TIdent("Exception") -- the exact token the plain spelling produces -- so the
# two ARE one name. Splitting the source text instead produced `r` and
# `Exception` as separate tokens and rejected a portable boundary as
# `effect: r`.
#
# The prefix is dropped once, in the lexical pass, so the fix is not confined
# to the direction that was reported: measured before it, `perform
# r#Fs::ReadFile(path)` in the entry file matched no native pattern and passed
# the gate outright (case 66). One spelling, one answer, every check.
printf '\nexport fn probe_raw_allowed() -> Unit with r#Exception {\n  ()\n}\n' >> "$impl"
if grep -qF -- '-> Unit with r#Exception {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a raw identifier spelling of an allowed effect is accepted"
  else
    fail "case: a raw identifier was split, most likely rejected as effect: r"
  fi
else
  fail "case: the raw-identifier mutation did not land -- it proves nothing"
fi
restore

printf '\nexport fn probe_raw_native() -> Unit with r#Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- '-> Unit with r#Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native effect spelled raw passed the allow-list"
  else
    pass "case: a raw identifier does not hide a native effect"
  fi
else
  fail "case: the raw-native mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nfn probe_raw_call() -> Unit {\n  perform r#Fs::ReadFile(path)\n}\n' >> "$entry"
if grep -qF -- 'perform r#Fs::ReadFile(path)' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native call spelled raw evaded the native-pattern scan"
  else
    pass "case: a raw identifier does not hide a native call either"
  fi
else
  fail "case: the raw-call mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 67-70: authority belongs to a declaration too --------------------
#
# Round 32. The `allows` check was a whole-file grep with no notion of
# declarations, so `type Cb = () -> Unit with Log::Emit allows Fs::read_file`
# was rejected -- authority that belongs to the aliased function type, exactly
# as its effect row does. `allows` in type position is legal and the parser has
# its own test for it (lib/@vibe/compiler/tests/parser_test.vibe, "#1345:
# `allows` works in type position too").
#
# The fix moved the collection into boundary_effect_rows, the one pass that
# knows which declaration a clause belongs to; the two checks now read the same
# tagged stream. Cases 11-15 still hold -- they are on `fn` declarations, which
# is the point.
printf '\ntype AllowsAlias = () -> Unit with Log::Emit allows Fs::read_file\n' >> "$impl"
if grep -qF -- 'type AllowsAlias = () -> Unit with Log::Emit allows Fs::read_file' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allows clause on a type alias is not the boundary authority"
  else
    fail "case: a legal allows clause in type position failed the gate"
  fi
else
  fail "case: the alias-allows mutation did not land -- it proves nothing"
fi
restore

# The miss that suppression could open, pinned in the same commit: an alias
# must not swallow the authority of the declaration after it.
printf '\ntype AllowsAlias2 = () -> Unit with Log::Emit allows Fs::read_file\n\nexport fn probe_after_allows_alias() -> String with Exception allows Console::write_stream {\n  ""\n}\n' >> "$impl"
if grep -qF -- 'allows Console::write_stream {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an alias swallowed the next declaration authority clause"
  else
    pass "case: a declaration after an allows alias keeps its own authority"
  fi
else
  fail "case: the alias-then-authority mutation did not land -- it proves nothing"
fi
restore

# A BINDING is a boundary declaration, so its authority is still reported --
# the same split as case 62 draws for rows.
printf '\nexport let probe_bind_allows: (Int) -> Unit with Exception allows Fs::read_file = (x) -> {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export let probe_bind_allows: (Int) -> Unit with Exception allows Fs::read_file = (x) -> {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: authority on a function binding went unreported"
  else
    pass "case: a function binding authority clause is still the boundary own"
  fi
else
  fail "case: the binding-allows mutation did not land -- it proves nothing"
fi
restore

# --- case 70: THE COST OF CASE 67, pinned so it is visible ------------------
#
# `type Cb = () -> Unit with () allows Fs` is now accepted. Same trade as cases
# 43 and 60: an alias is not itself a boundary, and no text scan can tell
# whether the boundary ever hands one out. #2581 answers it from the AST.
#
# When #2581 lands this flips to a rejection. UPDATE THE CASE, do not revert --
# accepting the alias is what keeps legal code building.
printf '\ntype AllowsAlias3 = () -> Unit with () allows Fs\n' >> "$impl"
if grep -qF -- 'type AllowsAlias3 = () -> Unit with () allows Fs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: KNOWN MISS -- authority named only by an alias (#2581)"
  else
    fail "case: the alias authority miss closed; flip this case to a rejection"
  fi
else
  fail "case: the alias-authority-miss mutation did not land -- it proves nothing"
fi
restore

# --- case 71: authority is diagnosed AS authority ---------------------------
#
# Round 32, found by red-testing rather than by review: dropping the `allows`
# row terminator changed no verdict, so nothing failed -- the clause was simply
# swallowed into the effect row and rejected there instead, as
# `effect: allows` alongside `effect: Fs`. Same exit code, useless message: it
# names an effect that does not exist and no edit that fixes it, which is the
# defect AGENTS.md's actionable-diagnostic rule is about. Cases 11-12 could not
# see it because they assert only that the text `allows` appears somewhere.
#
# So this pins the CLAUSE being diagnosed as a clause.
printf '\nexport fn probe_auth_msg() -> String with Exception allows Fs::read_file {\n  ""\n}\n' >> "$impl"
if grep -qF -- 'allows Fs::read_file {' "$impl"; then
  out="$(bash "$gate" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "case: an authority clause passed the gate"
  elif printf '%s' "$out" | grep -qF 'granted: allows Fs::read_file'; then
    pass "case: an authority clause is diagnosed as authority, not as an effect"
  else
    fail "case: rejected, but not as an authority grant: $out"
  fi
else
  fail "case: the authority-message mutation did not land -- it proves nothing"
fi
restore

# --- cases 72-74: `perform?` invokes the same capability --------------------
#
# Round 33, a MISS and the sharpest one in this review: the native-call pattern
# spelled only `perform`, so `perform? Fs::read_file(path)` in the entry file
# passed the required gate outright. `perform?` is a different TOKEN (ADR-0088;
# the parser builds EIdent("perform?") at parser_expr_primary.vibe:803, and
# lib/@vibe/compiler/tests/perform_question_lowering_test.vibe pins its
# lowering) but it reaches the same capability, which is the only thing this
# gate is asking about.
#
# The suffix is normalized in the lexical pass rather than by adding `\??` to
# one regex, so the next reader of this text does not have to know that two
# spellings exist -- the same reason the raw-identifier prefix is dropped.
printf '\nfn probe_perform_q(path: String) -> Int with () allows Fs::read_file? {\n  let _ = perform? Fs::read_file(path)\n  0\n}\n' >> "$entry"
if grep -qF -- 'perform? Fs::read_file(path)' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an optional perform of a native capability passed the gate"
  else
    pass "case: perform? reaches the same capability and is rejected"
  fi
else
  fail "case: the perform? mutation did not land -- the assertion proves nothing"
fi
restore

# The normalization is lexical, so it must not reach inside a string. Same
# pairing as case 32 for the plain spelling.
printf '\nfn probe_perform_q_str() -> String {\n  "do not generate perform? Fs::read_file here"\n}\n' >> "$entry"
if grep -qF -- 'do not generate perform? Fs::read_file here' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: perform? inside a string literal is still inert"
  else
    fail "case: a string mentioning perform? was read as a native call"
  fi
else
  fail "case: the perform?-in-string mutation did not land -- it proves nothing"
fi
restore

# And a `?` that is NOT the perform suffix keeps its meaning: an optional
# parameter is ordinary code, not a capability call.
printf '\nfn probe_opt_param(x?: Int) -> Int {\n  0\n}\n' >> "$entry"
if grep -qF -- 'fn probe_opt_param(x?: Int) -> Int {' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an optional parameter is not touched by the perform? rule"
  else
    fail "case: an optional parameter was rejected"
  fi
else
  fail "case: the optional-parameter mutation did not land -- it proves nothing"
fi
restore

# --- cases 75-76: a raw keyword must not become scanner syntax --------------
#
# Round 34, and this one was made by round 31: stripping `r#` handed the
# scanner its own syntax. `r#where` is an identifier -- being an identifier is
# the whole point of the `r#` spelling -- but emitted bare it read as the
# contract keyword, so `with Exception + r#where + Fs` stopped at it and the
# native Fs after it was never seen. Measured: ACCEPT.
#
# An underscore is now appended to exactly the keywords the passes below react
# to. All of them require a following space, so the suffix defeats the match
# and leaves an ordinary identifier. Nothing is lost by not restoring the true
# name: no keyword is an allow-listed effect or a native capability, so an
# effect genuinely called `where` is rejected either way -- it is simply not
# `Exception` or `Async`.
printf '\neffect r#where {\n  Tick() -> Unit\n}\n\nexport fn probe_raw_kw() -> Unit with Exception + r#where + Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'with Exception + r#where + Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a raw keyword truncated the row and hid the native effect"
  else
    pass "case: a raw keyword does not terminate the effect row"
  fi
else
  fail "case: the raw-keyword mutation did not land -- the assertion proves nothing"
fi
restore

# Without the native effect: the raw keyword is itself an unresolved name, and
# unresolved is not portable -- the same rule as the row variable in case 25.
printf '\neffect r#where {\n  Tick() -> Unit\n}\n\nexport fn probe_raw_kw_only() -> Unit with Exception + r#where {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'with Exception + r#where {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an effect named by a raw keyword passed the allow-list"
  else
    pass "case: an effect named by a raw keyword is not allow-listed"
  fi
else
  fail "case: the raw-keyword-only mutation did not land -- it proves nothing"
fi
restore

# --- cases 77-78: `r#fn` is still the keyword -------------------------------
#
# Round 35, and round 34 made it: the underscore that stops a raw keyword from
# becoming syntax was applied to `fn` as well, but `r#fn` is the ONE raw
# spelling that IS the keyword. lex_ident returns TFn for it
# (lib/@vibe/parser/lexer.vibe, #1280 -- a binding named fn cannot be smuggled
# back in through r#). Suffixed to `fn_`, it stopped being the reset, so a
# preceding `type` alias kept decl = "type" and the following function's
# native row was suppressed. Measured: ACCEPT.
#
# The lesson is round 34's inverted: normalizing raw source needs the LEXER's
# rule for each name, not a rule about raw identifiers in general.
printf '\ntype LeadAlias = Int\n\nr#fn probe_raw_fn() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'r#fn probe_raw_fn() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: r#fn stopped being a declaration and the native row was skipped"
  else
    pass "case: r#fn is the function keyword, so the declaration is checked"
  fi
else
  fail "case: the r#fn mutation did not land -- the assertion proves nothing"
fi
restore

printf '\ntype LeadAlias2 = Int\n\nr#fn probe_raw_fn_ok() -> Unit with Async {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'r#fn probe_raw_fn_ok() -> Unit with Async {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allowed row on an r#fn declaration is accepted"
  else
    fail "case: an allowed row on an r#fn declaration was rejected"
  fi
else
  fail "case: the r#fn-allowed mutation did not land -- it proves nothing"
fi
restore

# --- cases 79-80: a declaration keyword follows any token boundary ----------
#
# Round 36. The `type` and `let` handlers required a preceding SPACE, chosen
# over the `fn ` handler's looser test so that a field access spelled `x.type`
# could not be read as a declaration. A semicolon is a legal separator, so
# `;type Cb = () -> Unit with ReviewAsk` was not recognised as an alias and its
# row was charged to the boundary -- measured, rejected as `effect: ReviewAsk`.
# The dot alone is excluded now.
printf '\n;type SemiAlias = () -> Unit with ReviewAsk\n' >> "$impl"
if grep -qF -- ';type SemiAlias = () -> Unit with ReviewAsk' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an alias after a top-level semicolon is still an alias"
  else
    fail "case: an alias introduced after a semicolon was charged to the boundary"
  fi
else
  fail "case: the semicolon-alias mutation did not land -- it proves nothing"
fi
restore

printf '\n;type SemiAlias2 = () -> Unit with ReviewAsk\n\nexport fn probe_after_semi_alias() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export fn probe_after_semi_alias() -> Unit with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: the alias after a semicolon swallowed the next declaration row"
  else
    pass "case: a declaration after a semicolon alias keeps its own row"
  fi
else
  fail "case: the semicolon-alias-then-native mutation did not land -- it proves nothing"
fi
restore

# --- cases 81-82: authority binds to an arrow layer, like a row -------------
#
# Round 37, and the other half of round 32: authority was collected per
# declaration but emitted regardless of the return-type arrows, so a pure
# helper that hands OUT an authorised closure was rejected as though it held
# the authority itself. `parse_type_impl` attaches the clause to the returned
# TyFn; the arithmetic is now the same as the row above (authn >= arrows).
printf '\nexport fn probe_returns_authorised() -> () -> Unit with () allows Fs::read_file {\n  () -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF -- '-> () -> Unit with () allows Fs::read_file {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: authority on a returned closure type is not the declaration own"
  else
    fail "case: a pure helper returning an authorised closure was rejected"
  fi
else
  fail "case: the returned-authority mutation did not land -- it proves nothing"
fi
restore

# The direction that must not regress with it: a HIGHER-ORDER declaration that
# really does hold the authority is still reported. The parameter's arrow is
# inside parentheses, so it is not a return-type layer and cannot absorb the
# clause.
printf '\nexport fn probe_ho_authority(g: () -> Unit) -> Unit with Exception allows Fs::read_file {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'export fn probe_ho_authority(g: () -> Unit) -> Unit with Exception allows Fs::read_file {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a higher-order declaration hid its own authority clause"
  else
    pass "case: a parameter arrow does not absorb the declaration authority"
  fi
else
  fail "case: the higher-order-authority mutation did not land -- it proves nothing"
fi
restore

# --- cases 83-84: authority rides the row it trails -------------------------
#
# Round 38, and the other half of round 37: comparing independent counts
# (authn >= arrows) was still wrong. `fn f() -> () -> Unit with Exception with
# () allows Fs::read_file` has two arrows, two rows and one clause -- the
# returned closure takes the first row, the declaration keeps the second AND
# the authority trailing it -- so one clause against two arrows read as "the
# closures", and the filesystem authority went unreported. Measured: ACCEPT.
#
# Each clause is now recorded against the row it follows, and the declaration
# reports the clause on the layer it actually owns. Counting was the proxy;
# the association is the property.
printf '\nexport fn probe_auth_layer() -> () -> Unit with Exception with () allows Fs::read_file {\n  () -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF -- 'with Exception with () allows Fs::read_file {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: authority on the declaration own row layer went unreported"
  else
    pass "case: authority trailing the declaration own row is reported"
  fi
else
  fail "case: the authority-layer mutation did not land -- it proves nothing"
fi
restore

# Round 37 must survive it: the SAME arrow count with the clause on the
# closure's layer stays accepted. These two differ only in which row the
# clause trails, which is exactly what the counting rule could not see.
printf '\nexport fn probe_auth_layer_closure() -> () -> Unit with () allows Fs::read_file {\n  () -> {\n    ()\n  }\n}\n' >> "$impl"
if grep -qF -- '-> () -> Unit with () allows Fs::read_file {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: authority on a returned closure layer is still not the declaration own"
  else
    fail "case: a pure helper returning an authorised closure was rejected again"
  fi
else
  fail "case: the closure-authority mutation did not land -- it proves nothing"
fi
restore

# --- cases 85-89: the entry file had only the `perform` ban ------------------
#
# Round 39, a P1 miss. `cli_direct_component_entry.vibe` is the one scanned
# file whose row allow-list is deliberately OFF -- it does file IO and says so,
# carrying `with Exception + Fs` -- so forbid_pattern was its only protection,
# and that banned `perform` spellings alone. A capability builtin is called as
# an ORDINARY FUNCTION (ADR-0084), so no `perform` appears:
#
#   fn f() -> Unit with () allows Console::write_stream {
#     Console::write_stream("boundary leaked")
#   }
#
# passed the required gate outright. Measured, and the shape is the one
# lib/@vibe/compiler/tests/checker_entry_effect_test.vibe accepts.
#
# Both halves are closed: the authority check now runs on this file too (it has
# no `allows` clause today, so any is a leak), and the call pattern gains the
# capability namespaces this boundary is not entitled to.
printf '\nfn probe_entry_console() -> Unit with () allows Console::write_stream {\n  Console::write_stream("boundary leaked")\n}\n' >> "$entry"
if grep -qF -- 'Console::write_stream("boundary leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: the entry file acquired console authority and passed the gate"
  else
    pass "case: console authority in the direct component entry is rejected"
  fi
else
  fail "case: the entry-console mutation did not land -- it proves nothing"
fi
restore

# The two halves separately, so neither is carried by the other.
#
# The authority probe grants `Fs::stat_token`, NOT Console, and that choice is
# the whole point: `Fs::` is deliberately outside the call pattern (case 88),
# so this is the only shape the authority check can be seen alone in. Written
# with Console it passed for the wrong reason -- the call pattern matched the
# capability name inside the clause -- and removing the authority check changed
# nothing, which is a green case proving nothing (the round-32 mistake).
#
# It is also the right rule and not just a convenient probe: this entry may
# CALL Fs under its declared `with Fs` row, and may not GRANT Fs authority
# outward. Performing under a declared row and handing the capability to a
# caller are different things.
printf '\nfn probe_entry_auth_only(p: String) -> Int with () allows Fs::stat_token {\n  Fs::stat_token(p)\n}\n' >> "$entry"
if grep -qF -- 'allows Fs::stat_token {' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an allows clause in the entry file passed the gate"
  else
    pass "case: an authority clause in the entry file is rejected on its own"
  fi
else
  fail "case: the entry-authority mutation did not land -- it proves nothing"
fi
restore

printf '\nfn probe_entry_call_only() -> Unit with Console {\n  Console::write_stream("leaked")\n}\n' >> "$entry"
if grep -qF -- 'Console::write_stream("leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a plain capability call in the entry file passed the gate"
  else
    pass "case: a plain capability call in the entry file is rejected on its own"
  fi
else
  fail "case: the entry-call mutation did not land -- it proves nothing"
fi
restore

# --- cases 88-89: what the entry file IS entitled to -------------------------
#
# `Fs::` is deliberately absent from that list. This entry does file IO and
# declares it, so a call inside its own contract must keep building -- it makes
# exactly one today, `Fs::stat_token`. A ban that also caught this would be the
# false positive the row allow-list was switched off to avoid.
printf '\nfn probe_entry_fs(p: String) -> Int with Fs {\n  Fs::stat_token(p)\n}\n' >> "$entry"
if grep -qF -- 'fn probe_entry_fs(p: String) -> Int with Fs {' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: the entry file own declared Fs contract still builds"
  else
    fail "case: the entry file declared Fs call was rejected"
  fi
else
  fail "case: the entry-fs mutation did not land -- it proves nothing"
fi
restore

printf '\nfn probe_entry_str() -> String {\n  "do not call Console::write_stream here"\n}\n' >> "$entry"
if grep -qF -- 'do not call Console::write_stream here' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a capability name inside a string is still inert in the entry file"
  else
    fail "case: a string naming a capability was read as a call"
  fi
else
  fail "case: the entry-string mutation did not land -- it proves nothing"
fi
restore

# --- cases 90-93: a forbidden lane is a name, not a substring ---------------
#
# Round 40, a false positive. The three lane names in native_effect_pattern
# were unanchored, so `daemon` matched inside `daemonless_probe` and
# `compile_file_fs` inside `compile_file_fsx_probe`: an ordinary helper whose
# name merely CONTAINS a forbidden lane failed the required job on correct
# code. They are anchored to token boundaries now.
#
# `my_daemon_helper` is the case that says why the anchor is the right shape
# rather than a longer list of exceptions -- an underscore is a word
# character, so the name simply has no boundary there.
for name in daemonless_probe my_daemon_helper compile_file_fsx_probe; do
  printf '\nfn %s() -> Bool {\n  false\n}\n' "$name" >> "$impl"
  if grep -qF "fn $name() -> Bool {" "$impl"; then
    if bash "$gate" >/dev/null 2>&1; then
      pass "case: a helper named $name is not a forbidden lane"
    else
      fail "case: $name was rejected because its name contains a lane"
    fi
  else
    fail "case: the $name mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# The direction the anchor must not cost: the lanes themselves are still
# forbidden. Without this the fix could have been "delete the alternative".
printf '\nfn probe_real_lane(p: String) -> Bool {\n  let _ = compile_file_fs(p)\n  false\n}\n' >> "$impl"
if grep -qF -- 'let _ = compile_file_fs(p)' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: the compile_file_fs lane passed after anchoring"
  else
    pass "case: the compile_file_fs lane is still forbidden"
  fi
else
  fail "case: the lane mutation did not land -- the assertion proves nothing"
fi
restore

# --- cases 94-95: a handler arm head names an operation, it does not call it -
#
# Round 42, a false positive. `handle { f() } with { Fs::ReadFile(_p) =>
# resume("ok") }` is a pure helper taking an Fs-effectful callback and
# discharging it locally -- nothing escapes -- yet the `with \{...\}`
# alternative saw `Fs` between the braces and rejected it. The spelling is
# pinned in lib/@vibe/fs/index_import_test.vibe.
#
# Measuring the neighbour found the SAME defect in the capability-namespace
# alternative added for the entry file one round earlier: a `Console::Write`
# arm head there was read as a call. Both are fixed by exempting the arm HEAD,
# which is decidable without parsing -- a qualified name whose argument list is
# immediately followed by `=>`.
printf '\nfn probe_handled_fs(f: () -> String with Fs) -> String with Exception {\n  handle {\n    f()\n  } with { Fs::ReadFile(_path) => resume("ok"); Fs::WriteFile(_p, _c) => resume(0); Fs::Exists(_p) => resume(true); Fs::Mkdir(_p) => resume(0) }\n}\n' >> "$impl"
if grep -qF -- 'Fs::ReadFile(_path) => resume("ok")' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an effect discharged by a local handler is not a leak"
  else
    fail "case: a helper handling Fs locally was rejected"
  fi
else
  fail "case: the handled-effect mutation did not land -- it proves nothing"
fi
restore

printf '\nfn probe_handled_console(f: () -> Unit with Console) -> Unit {\n  handle {\n    f()\n  } with { Console::Write(_s) => resume(()) }\n}\n' >> "$entry"
if grep -qF -- 'Console::Write(_s) => resume(())' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a handler arm head in the entry file is not a capability call"
  else
    fail "case: a Console arm head in the entry file was read as a call"
  fi
else
  fail "case: the entry handler mutation did not land -- it proves nothing"
fi
restore

# --- case 96: the arm BODY is not exempt ------------------------------------
#
# The exemption is the head only. A real capability call inside an arm body is
# still a leak, and without this the fix could have been "stop scanning
# handlers".
printf '\nfn probe_arm_body(f: () -> Unit with Console) -> Unit {\n  handle {\n    f()\n  } with { Console::Write(_s) => {\n    Console::write_stream("leaked")\n    resume(())\n  } }\n}\n' >> "$entry"
if grep -qF -- 'Console::write_stream("leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a capability call inside a handler arm body passed the gate"
  else
    pass "case: a handler arm body is still scanned"
  fi
else
  fail "case: the arm-body mutation did not land -- it proves nothing"
fi
restore

# --- cases 97-99: an impl block holds declarations --------------------------
#
# Round 41, a P1 miss. An impl method sits one brace deep, and the row scan
# guards everything on brace == 0, so a method could carry `with Fs` unseen --
# measured, the gate printed ok. The block is transparent now: its `{` does not
# open a body.
#
# `struct` / `enum` / `effect` bodies are NOT declarations in that sense and
# stay opaque. Case 99 is why they have to clear the flag: a block-less `impl
# Eq for Int` would otherwise hand its transparency to whatever brace came
# next, and the native row after it would be read at the wrong depth.
printf '\nexport trait ProbeReader {\n  read_it(Self, String) -> Int\n}\n\nexport struct ProbeR {\n  x: Int\n}\n\nimpl ProbeReader for ProbeR {\n  read_it(self, p) -> Int with Fs {\n    Fs::stat_token(p)\n  }\n}\n' >> "$impl"
if grep -qF -- 'read_it(self, p) -> Int with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an impl method carrying a native row passed the gate"
  else
    pass "case: an impl method row is checked like any other declaration"
  fi
else
  fail "case: the impl mutation did not land -- the assertion proves nothing"
fi
restore

printf '\nexport trait ProbeReader2 {\n  read_it(Self, String) -> Int\n}\n\nexport struct ProbeR2 {\n  x: Int\n}\n\nimpl ProbeReader2 for ProbeR2 {\n  read_it(self, p) -> Int with Async {\n    0\n  }\n}\n' >> "$impl"
if grep -qF -- 'read_it(self, p) -> Int with Async {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an impl method with an allowed row is accepted"
  else
    fail "case: an impl method with an allowed row was rejected"
  fi
else
  fail "case: the impl-allowed mutation did not land -- it proves nothing"
fi
restore

# The probe carries the row in a struct FIELD, not in a following function,
# and that is the whole point. Written as a following function it rejected
# either way -- the verdict came from the function, not from the struct -- so
# removing the clear changed nothing and the case proved nothing. A struct body
# is opaque, so a field row is invisible; the control below is the same struct
# with no impl before it, and the two must agree.
printf '\nexport trait ProbeMarker\n\nimpl ProbeMarker for Int\n\nexport struct HolderS {\n  f: () -> Unit with Fs\n}\n' >> "$impl"
if grep -qF -- 'export struct HolderS {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a block-less impl does not make the next brace transparent"
  else
    fail "case: a block-less impl leaked transparency into a struct body"
  fi
else
  fail "case: the block-less impl mutation did not land -- it proves nothing"
fi
restore

printf '\nexport struct HolderS2 {\n  f: () -> Unit with Fs\n}\n' >> "$impl"
if grep -qF -- 'export struct HolderS2 {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a struct field row is invisible, impl or no impl"
  else
    fail "case: a struct field row was read as the boundary own"
  fi
else
  fail "case: the struct-control mutation did not land -- it proves nothing"
fi
restore

# --- cases 101-102: a handler pattern nests -----------------------------
#
# Round 43. The arm-head exemption matched the argument list with `[^)]*`,
# which stops at the FIRST `)`. `Fs::ReadFile((_path)) =>` is a legal grouping
# -- parse_handle_arm delegates to the recursive pattern parser -- so the head
# survived the strip and the pure helper was rejected again.
#
# Parentheses are counted now instead of approximated, so the answer does not
# depend on the depth. The probe uses TWO levels deliberately: a fix that only
# allowed one more level than the reported counterexample would pass a
# one-level case and fail here.
printf '\nfn probe_nested_arm(f: () -> String with Fs) -> String with Exception {\n  handle {\n    f()\n  } with { Fs::ReadFile(((_p))) => resume("ok"); Fs::WriteFile(_a, _b) => resume(0); Fs::Exists(_p) => resume(true); Fs::Mkdir(_p) => resume(0) }\n}\n' >> "$impl"
if grep -qF -- 'Fs::ReadFile(((_p))) => resume("ok")' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a nested handler pattern is still an arm head"
  else
    fail "case: a nested handler pattern was read as a capability call"
  fi
else
  fail "case: the nested-pattern mutation did not land -- it proves nothing"
fi
restore

# And the body after a nested head is still scanned -- the strip must consume
# the head only, however deep its pattern goes.
printf '\nfn probe_nested_arm_body(f: () -> Unit with Console) -> Unit {\n  handle {\n    f()\n  } with { Console::Write((_s)) => {\n    Console::write_stream("leaked")\n    resume(())\n  } }\n}\n' >> "$entry"
if grep -qF -- 'Console::write_stream("leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a call after a nested arm head passed the gate"
  else
    pass "case: the body after a nested arm head is still scanned"
  fi
else
  fail "case: the nested-arm-body mutation did not land -- it proves nothing"
fi
restore

# --- cases 103-107: one authoritative view, one lane list, spaced `::` ------
#
# Round 44-46, three findings on one head.
#
# 103. The arm-head strip runs per RECORD, so an arm written across lines was
# stripped in the flattened view and not in the line-preserving one -- and both
# views used to decide the verdict, so the per-line leftovers rejected a pure
# helper. The flattened text is the line text with newlines turned into
# spaces, so it matches everything a line-oriented grep can and more: the
# verdict now comes from it alone, and the line view is read only to cite a
# line. Case 104 is the reason both existed -- a separator that spans lines.
printf '\nfn probe_split_arm(f: () -> Unit with Console) -> Unit {\n  handle {\n    f()\n  } with { Console::Write(\n    _s\n  ) => resume(()) }\n}\n' >> "$entry"
if grep -qF -- 'with { Console::Write(' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a handler arm head written across lines is still an arm head"
  else
    fail "case: an arm head split across lines was read as a capability call"
  fi
else
  fail "case: the split-arm mutation did not land -- it proves nothing"
fi
restore

printf '\nfn probe_split_perform(p: String) -> Bool {\n  let _ = perform\n    Fs::ReadFile(p)\n  false\n}\n' >> "$impl"
if grep -qF -- 'let _ = perform' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native call split across lines passed after the view change"
  else
    pass "case: the flattened view still catches a separator spanning lines"
  fi
else
  fail "case: the split-perform mutation did not land -- it proves nothing"
fi
restore

# 105. `session-http` was dropped from the lane list. Strings and comments are
# removed before the pattern runs, so in what remains that spelling can only be
# the subtraction `session - http` -- it is not one vibe identifier. A pattern
# that can only ever match something else is not a weaker check, it is a wrong
# one, and it rejected a helper returning that expression.
printf '\nfn probe_lane_sub(session: Int, http: Int) -> Int {\n  session-http\n}\n' >> "$impl"
if grep -qF -- 'session-http' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a subtraction is not the session-http lane"
  else
    fail "case: session - http was rejected as a native lane"
  fi
else
  fail "case: the lane-subtraction mutation did not land -- it proves nothing"
fi
restore

# 106-107. The lexer allows whitespace around `::`, so `Console :: write_stream`
# is the same call -- and in the entry file this pattern is the ONLY check for
# a plain capability call. Requiring adjacency left it open. The arm-head strip
# had to learn the same spacing, or fixing the pattern would have broken the
# handler again.
printf '\nfn probe_spaced_call() -> Unit with Console {\n  Console :: write_stream("leaked")\n}\n' >> "$entry"
if grep -qF -- 'Console :: write_stream("leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a spaced :: capability call passed the entry gate"
  else
    pass "case: whitespace around :: does not hide a capability call"
  fi
else
  fail "case: the spaced-call mutation did not land -- it proves nothing"
fi
restore

printf '\nfn probe_spaced_arm(f: () -> Unit with Console) -> Unit {\n  handle {\n    f()\n  } with { Console :: Write(_s) => resume(()) }\n}\n' >> "$entry"
if grep -qF -- 'Console :: Write(_s) => resume(())' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a spaced :: arm head is still an arm head"
  else
    fail "case: a spaced :: arm head was read as a capability call"
  fi
else
  fail "case: the spaced-arm mutation did not land -- it proves nothing"
fi
restore

# --- cases 108-109: the `daemon` lane named nothing --------------------------
#
# Round 47. Round 40 anchored the lane names to token boundaries, which stopped
# `daemon` matching INSIDE `daemonless_probe` -- necessary, and not sufficient.
# An exact identifier is still not a reference: `fn f(daemon: Int) -> Int {
# daemon }` is an ordinary parameter, and matching the token rejected it.
#
# What settles it is that `daemon` names NOTHING in this tree: every occurrence
# under lib/ is inside a comment, and comments are removed before the pattern
# runs, so the alternative could only ever match a name someone chose. Same
# wrong check as `session-http` in case 105, one round later and one level up.
printf '\nfn probe_param_daemon(daemon: Int) -> Int {\n  daemon\n}\n' >> "$impl"
if grep -qF -- 'fn probe_param_daemon(daemon: Int) -> Int {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an ordinary parameter named daemon is not a lane reference"
  else
    fail "case: a local named daemon was rejected as a native lane"
  fi
else
  fail "case: the daemon-parameter mutation did not land -- it proves nothing"
fi
restore

# `compile_file_fs` is the OPPOSITE case and stays unqualified: it is a real
# exported function (entry/compiler/file_compile, fs_compile), so a bare
# occurrence in a boundary file is a real reference -- including inside an
# `import { compile_file_fs }` list, which has neither `(` nor `::` after it.
# This pins the bare form, so a later "require a call shape" cannot pass by
# only keeping case 93 (the call) green.
printf '\nfn probe_lane_value() -> Bool {\n  let f = compile_file_fs\n  false\n}\n' >> "$impl"
if grep -qF -- 'let f = compile_file_fs' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a bare reference to the compile_file_fs lane passed the gate"
  else
    pass "case: a bare reference to a real lane is still a reference"
  fi
else
  fail "case: the lane-value mutation did not land -- it proves nothing"
fi
restore

# --- cases 110-112: a qualified row item may be spaced ----------------------
#
# Round 48, and the second place the same spacing assumption was wrong -- the
# direct-call pattern was the first, one round earlier. `parse_effect_item`
# consumes the `::` token regardless of source spacing (parser_base.vibe), so
# `with Exception :: Throw` is the same row as `with Exception::Throw`.
# Stripping only the ADJACENT `::op` left `Throw` to reach the allow-list as an
# effect of its own, and the row was rejected: `effect: Throw` on a portable
# boundary.
printf '\nexport fn probe_spaced_qualified() -> Unit with Exception :: Throw {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'with Exception :: Throw {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a spaced qualified row item is the same item"
  else
    fail "case: a spaced qualified row was rejected, most likely as effect: Throw"
  fi
else
  fail "case: the spaced-qualified mutation did not land -- it proves nothing"
fi
restore

# The strip must not become a way to hide the CAPABILITY either: only the
# `::op` suffix goes, never the head.
printf '\nexport fn probe_spaced_qualified_native() -> Unit with Fs :: ReadFile {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'with Fs :: ReadFile {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a spaced qualified NATIVE row passed the allow-list"
  else
    pass "case: spacing does not hide the capability in a qualified row"
  fi
else
  fail "case: the spaced-native mutation did not land -- it proves nothing"
fi
restore

printf '\nexport fn probe_spaced_compound() -> Unit with Exception :: Throw + Fs {\n  ()\n}\n' >> "$impl"
if grep -qF -- 'with Exception :: Throw + Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a native item beside a spaced qualified item was missed"
  else
    pass "case: the rest of a compound row survives the spaced strip"
  fi
else
  fail "case: the spaced-compound mutation did not land -- it proves nothing"
fi
restore

# --- cases 113-115: `impl` may be followed by `[` ---------------------------
#
# Round 49, and the third spacing variant in three rounds. `impl[T] Tr[T] for
# S[T]` is the generic form: the lexer emits TImpl then TLBracket, with no
# space required. Matching the literal `impl ` left that block opaque, so a
# method inside it could carry `with Fs` unseen -- measured, the gate printed
# ok. A keyword ends where the identifier characters end, not where a space
# happens to be.
printf '\nexport trait ProbeG[T] {\n  read_it(Self, String) -> Int\n}\n\nexport struct ProbeGS[T] {\n  x: T\n}\n\nimpl[T] ProbeG[T] for ProbeGS[T] {\n  read_it(self, p) -> Int with Fs {\n    Fs::stat_token(p)\n  }\n}\n' >> "$impl"
if grep -qF -- 'impl[T] ProbeG[T] for ProbeGS[T] {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a generic impl block stayed opaque and hid a native row"
  else
    pass "case: a generic impl[T] block is transparent like a plain one"
  fi
else
  fail "case: the generic-impl mutation did not land -- it proves nothing"
fi
restore

printf '\nexport trait ProbeG2[T] {\n  read_it(Self, String) -> Int\n}\n\nexport struct ProbeGS2[T] {\n  x: T\n}\n\nimpl[T] ProbeG2[T] for ProbeGS2[T] {\n  read_it(self, p) -> Int with Async {\n    0\n  }\n}\n' >> "$impl"
if grep -qF -- 'impl[T] ProbeG2[T] for ProbeGS2[T] {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: an allowed row in a generic impl block is accepted"
  else
    fail "case: an allowed row in a generic impl block was rejected"
  fi
else
  fail "case: the generic-impl-allowed mutation did not land -- it proves nothing"
fi
restore

# Dropping the trailing space cannot make the keyword match a longer name:
# `implicit_probe` starts with `impl` and is an ordinary function.
printf '\nfn implicit_probe() -> Bool {\n  false\n}\n' >> "$impl"
if grep -qF -- 'fn implicit_probe() -> Bool {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a name merely starting with impl is not an impl block"
  else
    fail "case: implicit_probe was read as an impl block"
  fi
else
  fail "case: the implicit-name mutation did not land -- it proves nothing"
fi
restore

# --- cases 116-118: the capability list is read, not restated ---------------
#
# Round 50. The entry file's namespace list was written by hand as
# Console|Env|Process|Socket|Http|Net. The real list --
# standard_host_provider_resource_defaults in
# lib/@vibe/compiler/core/standard_effect_policy.vibe (the parser's copy,
# capability_effect_name_list, went with ADR-0088) -- has TEN
# names: it also has Stdin, Stdout, Stderr and Profiler, which this boundary
# could therefore use unseen, and it does NOT have Net. Measured: `fn f() ->
# Int with Stdin { Stdin::read_char() }` compiles and the gate printed ok.
#
# The gate derives the list from that file now. Enumerating a list that lives
# somewhere else is the structure that produces the drift, so this removes the
# class rather than the four names -- a capability added to the compiler is
# covered here without anyone remembering to come back.
for cap in Stdin Stdout Stderr Profiler; do
  printf '\nfn probe_cap_%s() -> Unit with %s {\n  %s::write_all("x")\n}\n' "$cap" "$cap" "$cap" >> "$entry"
  if grep -qF "fn probe_cap_$cap() -> Unit with $cap {" "$entry"; then
    if bash "$gate" >/dev/null 2>&1; then
      fail "case: the entry file used $cap and passed the gate"
    else
      pass "case: $cap is a capability the entry file may not use"
    fi
  else
    fail "case: the $cap mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# The derived list must not swallow the file's own declared contract.
printf '\nfn probe_declared_fs(p: String) -> Int with Fs {\n  Fs::stat_token(p)\n}\n' >> "$entry"
if grep -qF -- 'fn probe_declared_fs(p: String) -> Int with Fs {' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: Fs is dropped from the derived list, as the contract requires"
  else
    fail "case: the derived list banned the entry file own declared Fs call"
  fi
else
  fail "case: the declared-Fs mutation did not land -- it proves nothing"
fi
restore

# And the reader must FAIL CLOSED, LOUDLY. An empty alternation would match
# nothing and the gate would print ok on everything, which is the worst
# outcome a derived list can have.
#
# The first version of this guard never fired: `set -e` killed the script on
# the reader's own pipeline first, so the gate exited 1 with NO message.
# Fail-closed and silent is not good enough -- silence is indistinguishable
# from unchecked, and the message is the part that says what to repair. Every
# stage of the reader is guarded so the check itself is what stops the run.
#
# The mutation renames the array in the gate's own copy, which is the shape
# change the guard exists for: the file is still readable, so nothing errors.
# The copy has to live beside the gate: it derives ROOT_DIR from BASH_SOURCE,
# so a copy in /tmp resolves every repository path against /tmp and fails for
# an unrelated reason -- which is how the first draft of this case "passed".
gate_tmp="scripts/.portable_boundary_reader_probe.$$.sh"
sed 's/standard_host_provider_resource_defaults/standard_host_provider_resource_defaults_RENAMED/' "$gate" > "$gate_tmp"
if ! grep -q 'standard_host_provider_resource_defaults_RENAMED' "$gate_tmp"; then
  fail "case: the capability-reader mutation did not land -- it proves nothing"
else
  out="$(bash "$gate_tmp" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "case: an unreadable capability list still passed the gate"
  elif printf '%s' "$out" | grep -qF 'cannot read standard_host_provider_resource_defaults'; then
    pass "case: an unreadable capability list fails closed, and says so"
  else
    fail "case: it failed closed but silently, which reads as unchecked: $out"
  fi
fi
rm -f "$gate_tmp"

# --- cases 122-125: the entry file gets the row check, with its contract -----
#
# Round 51, and the class I told the reviewer one round earlier was impossible
# here. That was true of the CALL and I stopped there: `println` has no
# namespace token, so no regex over the call reaches it. But the checker
# REQUIRES `with Stdout` on the declaration -- measured, `fn f() -> Unit {
# println("x") }` is rejected with "missing { Stdout }" -- and a row is a name
# the scanner can already read. The handle was one layer over from where I was
# looking.
#
# So the entry file gets the row check too, with an allow-list of what it IS
# entitled to (Exception, Fs, Async). It was exempt because a SHARED allow-list
# would have failed it on its own legitimate `with Exception + Fs`; that was
# right about the shared list and wrong about the check.
printf '\nfn probe_println_row() -> Unit with Stdout {\n  println("leaked")\n}\n' >> "$entry"
if grep -qF -- 'println("leaked")' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an unqualified capability builtin passed the entry gate"
  else
    pass "case: an unqualified builtin is caught by its declared row"
  fi
else
  fail "case: the println mutation did not land -- it proves nothing"
fi
restore

# The three effects it actually declares must keep building. This is the
# direction that kept the row check off this file for so long, so all three
# are pinned rather than sampled.
for row in 'Fs' 'Exception' 'Exception + Fs'; do
  printf '\nfn probe_entry_contract(p: String) -> Int with %s {\n  Fs::stat_token(p)\n}\n' "$row" >> "$entry"
  if grep -qF "with $row {" "$entry"; then
    if bash "$gate" >/dev/null 2>&1; then
      pass "case: the entry file may declare 'with $row'"
    else
      fail "case: the entry file own contract 'with $row' was rejected"
    fi
  else
    fail "case: the '$row' mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# And a capability it is NOT entitled to is now caught by the row, whatever the
# call looks like -- no namespace token needed.
printf '\nfn probe_entry_stdin_row() -> Unit with Stdin {\n  ()\n}\n' >> "$entry"
if grep -qF -- 'fn probe_entry_stdin_row() -> Unit with Stdin {' "$entry"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an excluded capability row passed the entry gate"
  else
    pass "case: an excluded capability is caught by the row alone"
  fi
else
  fail "case: the Stdin-row mutation did not land -- it proves nothing"
fi
restore

# --- cases 127-128: a closure LITERAL under `let` is code, not a type --------
#
# Round 52 asked for the row of `let stored = (p: String) -> Int with Fs {
# Fs::stat_token(p) }` to be suppressed, on the argument that storing an
# effectful function is pure, the same distinction already made for function
# type aliases (case: `type Cb = ...`) and returned closure types. The premise
# is right about the type system and wrong about this gate, and MEASUREMENT is
# what settles it -- the subject here is the emitted wasm host imports, so the
# question is what each shape imports, not what it evaluates.
#
# Compiled all four, each a whole program whose closure is NEVER CALLED, and
# grepped the module for the `fs_stat_token` host import:
#
#   type Cb = (String) -> Int with Fs                                  absent
#   fn make(g: (String) -> Int with Fs) -> (String) -> Int with Fs {g} absent
#   let stored: (String) -> Int with Fs = g        (annotation only)   absent
#   let stored = (p: String) -> Int with Fs { Fs::stat_token(p) }      PRESENT
#
# The first three are type positions with no code behind them. The fourth is a
# closure literal -- a body that gets emitted, and its import lands in the
# module whether or not anything invokes it. "Any function that invokes it must
# declare its own row" is true and not sufficient: nothing invokes this one and
# the boundary imports the filesystem anyway.
#
# So the row stays reported, and these cases pin it. If a later round makes
# `let` suppress its value row like `type` does, case 127 fails -- and that is
# the finding, not the fix.
printf '\nexport let stored = (p: String) -> Int with Fs { Fs::stat_token(p) }\n' >> "$impl"
if grep -qF -- 'export let stored = (p: String) -> Int with Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: a stored closure literal acquired Fs without being reported"
  else
    pass "case: a closure literal under 'let' is reported like any other body"
  fi
else
  fail "case: the stored-closure mutation did not land -- it proves nothing"
fi
restore

# The control for it: the same binding with a row the allow-list admits must
# still build. Without this the case above would also pass on a gate that
# rejected every `let`.
printf '\nexport let stored = (p: String) -> Int with Exception { String::length(p) }\n' >> "$impl"
if grep -qF -- 'export let stored = (p: String) -> Int with Exception {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a stored closure with an allowed row still builds"
  else
    fail "case: an allowed row on a stored closure was rejected"
  fi
else
  fail "case: the allowed-row mutation did not land -- it proves nothing"
fi
restore

# --- cases 129-132: an `effectset` alias resolves to its members -------------
#
# Round 53. `effectset PortableEffects = { Exception, Async }` (ADR-0071) plus
# `with PortableEffects` was rejected as `effect: PortableEffects` -- a false
# positive on a boundary whose every member is allow-listed.
#
# The tempting fix is to add the alias to PORTABLE_ALLOWED_EFFECTS, and it is
# the dangerous one: the list would then admit the NAME, so a later edit adding
# `Fs` to that set passes unseen. The members are read from the declaration
# instead. Cases 130 and 131 are that danger, pinned in both the direct and the
# transitive shape; 132 is the fail-closed direction for an alias the scanned
# file cannot see.
for probe in \
  'effectset PortableEffects = { Exception, Async };PortableEffects;accept' \
  'effectset SneakyEffects = { Exception, Fs };SneakyEffects;reject' \
  'effectset Inner = { Fs } effectset Outer = { Inner, Async };Outer;reject' \
  ';ImportedElsewhere;reject'
do
  decls="${probe%%;*}"; rest="${probe#*;}"
  row="${rest%%;*}"; want="${rest##*;}"
  printf '\n%s\n\nexport fn probe_set(x: Int) -> Int with %s {\n  x + 1\n}\n' "$decls" "$row" >> "$impl"
  if grep -qF "with $row {" "$impl"; then
    if bash "$gate" >/dev/null 2>&1; then
      if [ "$want" = "accept" ]; then
        pass "case: an effectset of allowed members is expanded, not rejected"
      else
        fail "case: '$row' hid a capability behind an effectset alias"
      fi
    else
      if [ "$want" = "reject" ]; then
        pass "case: '$row' is reported rather than taken at its name"
      else
        fail "case: a portable effectset alias was rejected"
      fi
    fi
  else
    fail "case: the '$row' mutation did not land -- it proves nothing"
  fi
  restore
done

# --- case 133: `where` must start at a token boundary ------------------------
#
# Found while measuring round 53, and worse than the finding that led to it.
# The `where` break in the row scanner was unanchored, so it matched INSIDE an
# effect name: `with Asyncwhere + Fs` broke at character 6, kept the row as
# `Async` -- which is allow-listed -- and dropped `+ Fs` entirely. Measured on
# c89c47367, with a boundary body that calls `Fs::stat_token`: the gate printed
# `ok`, EXIT=0. A silent miss, and the cheapest kind to introduce, since any
# effect whose name ends in `where` hides the rest of its own row.
#
# The three sibling breaks (`fn ` / `type ` / `let `) already made the token
# test; `where` was the one that did not. Cases 46-47 above keep the real
# contract form working.
printf '\neffect Asyncwhere {\n  Ping() -> Unit\n}\n\nexport fn probe_hidden(x: Int) -> Int with Asyncwhere + Fs {\n  Fs::stat_token("x") + x\n}\n' >> "$impl"
if grep -qF 'with Asyncwhere + Fs {' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: an effect name ending in 'where' hid the rest of the row"
  else
    pass "case: 'where' inside an effect name does not end the row"
  fi
else
  fail "case: the Asyncwhere mutation did not land -- it proves nothing"
fi
restore

# --- case 134: expansion happens BEFORE the allow-list ----------------------
#
# Cases 130-131 above pass on a gate with no expansion at all -- there the
# alias is rejected under its own name, for the wrong reason. So they do not
# actually prove the dangerous fix was avoided. This one does: it allow-lists
# the alias NAME, exactly what round 53 warned against, and asserts `Fs` is
# still reported. That can only hold if the members are resolved first.
#
# The gate is copied INSIDE scripts/ rather than to a temp dir: ROOT_DIR comes
# from BASH_SOURCE, so a copy under /tmp resolves the repository wrongly and
# fails for a reason that has nothing to do with the property (that mistake
# made an earlier probe "pass" while proving nothing).
probe_gate="scripts/.portable_boundary_allowlist_probe.$$.sh"
sed "s/^PORTABLE_ALLOWED_EFFECTS='Exception|Async'\$/PORTABLE_ALLOWED_EFFECTS='Exception|Async|SneakyEffects'/" \
  "$gate" > "$probe_gate"
if grep -qF "PORTABLE_ALLOWED_EFFECTS='Exception|Async|SneakyEffects'" "$probe_gate"; then
  printf '\neffectset SneakyEffects = { Exception, Fs }\n\nexport fn probe_set(x: Int) -> Int with SneakyEffects {\n  x + 1\n}\n' >> "$impl"
  # Capture, then grep. Piping the gate straight into grep looks equivalent
  # and is not: this harness runs under `set -o pipefail`, so the gate's own
  # exit 1 -- the whole point of the case -- makes the pipeline non-zero even
  # when grep matches, and the case reports the property ABSENT while it holds.
  probe_out="$(bash "$probe_gate" 2>&1 || true)"
  if printf '%s\n' "$probe_out" | grep -qE '^  effect: Fs$'; then
    pass "case: an allow-listed alias still reports the Fs inside it"
  else
    fail "case: allow-listing the alias name hid a capability member"
  fi
  restore
else
  fail "case: the allow-list mutation did not land -- it proves nothing"
fi
rm -f "$probe_gate"

if [ "$fails" -ne 0 ]; then
  echo "portable-boundary-test: FAILED" >&2
  exit 1
fi
echo "portable-boundary-test: ok (control + 134 cases)"
