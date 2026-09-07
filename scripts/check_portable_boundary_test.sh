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

# Refuse to run against a dirty tree: the restore below would discard the
# author's uncommitted work in these two files.
if ! git diff --quiet -- "$impl" "$contract"; then
  echo "portable-boundary-test: $impl or $contract has uncommitted changes." >&2
  echo "  This test mutates and restores them with 'git checkout'. Commit or" >&2
  echo "  stash first, so a restore cannot discard your work." >&2
  exit 2
fi

restore() { git checkout -q -- "$impl" "$contract" 2>/dev/null || true; }
trap restore EXIT

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

if [ "$fails" -ne 0 ]; then
  echo "portable-boundary-test: FAILED" >&2
  exit 1
fi
echo "portable-boundary-test: ok (control + 33 cases)"
