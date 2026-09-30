#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# 119/119. The buffer lane reports an unknown `derive`, and agrees with the
# build about it (#2317).
#
# `parse_contract_program` + `classify_contract_stmts` answer "is this shaped
# like a contract". They do not answer everything the loader does, so the
# buffer lane reported CLEAN for contracts `vibe check` refuses. Measured on a
# complete package before this: `derive(Foo)` -> `unknown trait: Foo` on the
# import lane and nothing on the buffer lane.
#
# ONLY the derive check. A duplicate-declaration check was implemented and
# removed: the loader accepts shapes it would have rejected -- a duplicated
# QUALIFIED declaration (`fn Map::get` twice) checks clean on the import lane
# while an unqualified one is refused, and a repeated legacy
# `let version: String` is filtered out entirely when the header carries a
# `version` directive. Deciding duplicates needs the loader's own rules, which
# is the shared-function work #2317 describes. A diagnostic on a contract the
# build accepts is worse than the missing one it was meant to add.
echo "[compiler-gate] 119/119 the buffer lane reports an unknown derive, and agrees with the build (#2317)"
csdir="_build/_gate_contract_semantic"
rm -rf "$csdir"; mkdir -p "$csdir/derive" "$csdir/clean" "$csdir/decoyderive" "$csdir/twoderive" "$csdir/multiderive"
cs_header='name = @gate/contractsem
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
cs_impl_a='export fn a(x: Int) -> Int {
  x + 1
}
'
printf '%s\nstruct P {\n  x: Int\n} derive(Foo)\n\nfn a(x: Int) -> Int\n' "$cs_header" > "$csdir/derive/index.vpkg"
printf '%s' "$cs_impl_a" > "$csdir/derive/impl.vibe"
printf '%s\nstruct P {\n  x: Int\n} derive(Eq)\n\nfn a(x: Int) -> Int\n' "$cs_header" > "$csdir/clean/index.vpkg"
printf '%s' "$cs_impl_a" > "$csdir/clean/impl.vibe"
# The name occurs EARLIER as an unrelated struct, so an anchor found by
# counting occurrences lands on the decoy instead of the derive clause.
printf '%s\nstruct Foo {\n  y: Int\n}\n\nstruct P {\n  x: Int\n} derive(Foo)\n\nfn a(x: Int) -> Int\n' "$cs_header" > "$csdir/decoyderive/index.vpkg"
printf '%s' "$cs_impl_a" > "$csdir/decoyderive/impl.vibe"
# Two clauses naming the same unknown trait: each diagnostic needs its own.
printf '%s\nstruct A {\n  x: Int\n} derive(Foo)\n\nstruct B {\n  y: Int\n} derive(Foo)\n\nfn a(x: Int) -> Int\n' "$cs_header" > "$csdir/twoderive/index.vpkg"
printf '%s' "$cs_impl_a" > "$csdir/twoderive/impl.vibe"
# One clause naming several unknown traits.
printf '%s\nstruct A {\n  x: Int\n} derive(Foo, Bar)\n\nfn a(x: Int) -> Int\n' "$cs_header" > "$csdir/multiderive/index.vpkg"
printf '%s' "$cs_impl_a" > "$csdir/multiderive/impl.vibe"
# Each bad contract refused by BOTH lanes, the clean one by neither. Asserting
# only the buffer lane would not notice the two drifting apart again, and
# asserting only that it refuses would not notice it refusing a VALID contract
# -- which is how the duplicate check was caught.
for probe in derive decoyderive twoderive multiderive clean; do
  rm -f "$csdir/$probe.imp" "$csdir/$probe.imp.diag" "$csdir/$probe.buf"
  if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$csdir/$probe/index.vpkg" "$csdir/$probe.imp" main >/dev/null 2>&1; then
    imp="clean"
  else
    imp="refused"
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$csdir/$probe/index.vpkg" "$csdir/$probe.buf" main >/dev/null 2>&1 || true
  if [ -s "$csdir/$probe.buf" ]; then buf="refused"; else buf="clean"; fi
  if [ "$probe" = clean ]; then want="clean"; else want="refused"; fi
  if [ "$imp" != "$want" ] || [ "$buf" != "$want" ]; then
    echo "[compiler-gate] FAIL: contract '$probe' -- import lane says $imp, buffer lane says $buf, both should say $want (#2317)" >&2
    cat "$csdir/$probe.imp.diag" >&2 2>/dev/null || true
    cat "$csdir/$probe.buf" >&2 2>/dev/null || true
    exit 1
  fi
done
# The message is the CHECKER's own -- `validate_derives` is exported for this,
# so the two lanes cannot word it differently.
if ! grep -qF 'unknown trait: Foo' "$csdir/derive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the buffer lane does not report an unknown derive with the checker's own message (#2317)" >&2
  cat "$csdir/derive.buf" >&2 || true
  exit 1
fi
# Anchored, not left at the synthetic 0:0. Line numbers below are read off the
# generated fixtures, not counted by hand -- an earlier version of this section
# asserted 12 and 16 for the twoderive clauses, which are on 11 and 15, and CI
# caught it.
if ! grep -q '^line 11:' "$csdir/derive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the unknown derive is not anchored on its derive clause (expected line 11) (#2317)" >&2
  cat "$csdir/derive.buf" >&2 || true
  exit 1
fi
if grep -q '^line 9:' "$csdir/decoyderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the unknown derive anchored on the unrelated 'struct Foo', not on the derive clause (#2317)" >&2
  cat "$csdir/decoyderive.buf" >&2 || true
  exit 1
fi
if ! grep -q '^line 15:' "$csdir/decoyderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the unknown derive is not anchored on its clause with a decoy present (expected line 15) (#2317)" >&2
  cat "$csdir/decoyderive.buf" >&2 || true
  exit 1
fi
if ! grep -q '^line 11:' "$csdir/twoderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the first of two identical unknown derives is not anchored on its own clause (expected line 11) (#2317)" >&2
  cat "$csdir/twoderive.buf" >&2 || true
  exit 1
fi
if ! grep -q '^line 15:' "$csdir/twoderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the SECOND identical unknown derive is not anchored on its own clause (expected line 15) (#2317)" >&2
  cat "$csdir/twoderive.buf" >&2 || true
  exit 1
fi
if ! grep -qF 'unknown trait: Bar' "$csdir/multiderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the second trait of a multi-name derive is not reported (#2317)" >&2
  cat "$csdir/multiderive.buf" >&2 || true
  exit 1
fi
if grep -q '^unknown trait' "$csdir/multiderive.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a multi-name derive left a diagnostic unanchored (#2317)" >&2
  cat "$csdir/multiderive.buf" >&2 || true
  exit 1
fi
# ...and NO committed contract in the tree may gain a diagnostic. A check that
# fires on real contracts is worse than one that never fires, and the probes
# above cannot see it.
cs_noisy=0
for contract in $(git ls-files 'lib/**/index.vpkg'); do
  rm -f "$csdir/tree.out"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$contract" "$csdir/tree.out" main >/dev/null 2>&1 || true
  if [ -s "$csdir/tree.out" ]; then
    echo "[compiler-gate] FAIL: committed contract $contract gained a diagnostic (#2317)" >&2
    cat "$csdir/tree.out" >&2
    cs_noisy=$((cs_noisy + 1))
  fi
done
if [ "$cs_noisy" -ne 0 ]; then
  exit 1
fi
rm -rf "$csdir"
echo "[compiler-gate] an unknown derive is refused by both lanes and anchored on its own clause; no committed contract regressed ok (#2317)"

# 120/120. A statement a contract may not contain is anchored on THAT
# statement, on both lanes' shared message (#2317).
#
# `classify_contract_stmts` throws an unlocated message. The buffer lane caught
# it in the same handler as a parse error, whose anchor is a token-prefix probe
# that can only reproduce PARSER throws -- so the probe missed, and the reader
# got the synthetic 0:0: the contract is broken, and nowhere to look. Measured
# before this: both lanes printed the message bare.
#
# The offset is now READ, not searched for. `parse_contract_program_spans`
# carries the token index each statement started at, and
# `contract_unsupported_stmt_index` asks the classifier itself which statement
# it stops on. Three attempts in the #2315 review to locate this by probing
# growing prefixes each produced a non-monotone predicate that binary search
# could resolve to VALID code, which is why searching is not used here.
echo "[compiler-gate] 120/120 an unsupported contract statement is anchored on that statement (#2317)"
clsdir="_build/_gate_contract_classify"
rm -rf "$clsdir"; mkdir -p "$clsdir"
cls_header='name = @gate/contractcls
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
cls_impl='export fn a(x: Int) -> Int {
  x + 1
}

export fn b(y: Int) -> Int {
  y
}
'
# `later`: the offending statement is the THIRD, so an anchor that always
# points at the first statement (or at offset 0) fails. `first`: it is the
# first, so an anchor that is off by one statement fails too. The pair pins the
# mapping in both directions; one alone does not.
mkdir -p "$clsdir/later" "$clsdir/first" "$clsdir/clean"
printf '%s\nfn a(x: Int) -> Int\n\nexport let z: Int = 5\n\nfn b(y: Int) -> Int\n' "$cls_header" > "$clsdir/later/index.vpkg"
printf '%s' "$cls_impl" > "$clsdir/later/impl.vibe"
printf '%s\nexport let z: Int = 5\n\nfn a(x: Int) -> Int\n\nfn b(y: Int) -> Int\n' "$cls_header" > "$clsdir/first/index.vpkg"
printf '%s' "$cls_impl" > "$clsdir/first/impl.vibe"
printf '%s\nfn a(x: Int) -> Int\n\nfn b(y: Int) -> Int\n' "$cls_header" > "$clsdir/clean/index.vpkg"
printf '%s' "$cls_impl" > "$clsdir/clean/impl.vibe"
cls_msg='unsupported statement in a contract file'
for probe in later first; do
  if [ "$probe" = later ]; then want_line='line 11:1:'; else want_line='line 9:1:'; fi
  rm -f "$clsdir/$probe.imp" "$clsdir/$probe.imp.diag" "$clsdir/$probe.buf"
  # The import lane is the oracle, asserted by MESSAGE. Its exit status alone
  # says nothing: a contract with an unimplemented declaration is refused
  # whatever else it contains, so a status check would pass without ever
  # reaching the classifier.
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$clsdir/$probe/index.vpkg" "$clsdir/$probe.imp" main >/dev/null 2>&1 || true
  if ! grep -qF "$cls_msg" "$clsdir/$probe.imp.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the import lane no longer refuses a top-level let in a contract ($probe) -- repoint this probe (#2317)" >&2
    cat "$clsdir/$probe.imp.diag" >&2 2>/dev/null || true
    exit 1
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$clsdir/$probe/index.vpkg" "$clsdir/$probe.buf" main >/dev/null 2>&1 || true
  if ! grep -qF "$cls_msg" "$clsdir/$probe.buf" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the buffer lane does not refuse a top-level let in a contract ($probe) (#2317)" >&2
    cat "$clsdir/$probe.buf" >&2 2>/dev/null || true
    exit 1
  fi
  if ! grep -q "^$want_line" "$clsdir/$probe.buf" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the unsupported statement ($probe) is not anchored on itself (expected $want_line) (#2317)" >&2
    cat "$clsdir/$probe.buf" >&2 2>/dev/null || true
    exit 1
  fi
done
# A contract with no forbidden statement stays clean on both lanes -- without
# this, a change that reported every contract would pass everything above.
rm -f "$clsdir/clean.imp" "$clsdir/clean.imp.diag" "$clsdir/clean.buf"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$clsdir/clean/index.vpkg" "$clsdir/clean.imp" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: the import lane refuses the CLEAN control contract -- the probes above are not valid (#2317)" >&2
  cat "$clsdir/clean.imp.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$clsdir/clean/index.vpkg" "$clsdir/clean.buf" main >/dev/null 2>&1 || true
if [ -s "$clsdir/clean.buf" ]; then
  echo "[compiler-gate] FAIL: a contract with no forbidden statement is reported by the buffer lane (#2317)" >&2
  cat "$clsdir/clean.buf" >&2
  exit 1
fi
rm -rf "$clsdir"
echo "[compiler-gate] an unsupported contract statement is refused by both lanes and anchored on itself, first or later ok (#2317)"

# 121/121. A type diagnostic about a contract's transparent types names the
# CONTRACT, not the generated module it was materialized into (#2317).
#
# A `.vpkg` whose contract declares transparent types is materialized into
# `.vibe/build/vpkg_types/types_<fingerprint>.vibe` (#1840), and the checker
# walks THAT. So `derive(Foo)` on a contract struct reported
# `.vibe/build/vpkg_types/types_114_….vibe: unknown trait: Foo` -- the reader
# is sent to a build artifact to go edit, and the file they wrote is not
# named at all. Measured before this, same fixture:
#
#   full lane    .vibe/build/vpkg_types/types_114_…vibe: unknown trait: Foo
#   buffer lane  line 11:10: unknown trait: Foo
#
# The stub's name is a fingerprint of (contract path, generated text), so it
# cannot be inverted -- the mapping comes from the registry that recorded it.
echo "[compiler-gate] 121/121 a type diagnostic names the contract, not the generated types module (#2317)"
dpvdir="_build/_gate_derive_provenance"
rm -rf "$dpvdir"; mkdir -p "$dpvdir/bad" "$dpvdir/clean"
dpv_header='name = @gate/derprov
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
dpv_impl='export fn a(x: Int) -> Int {
  x + 1
}
'
printf '%s\nstruct P {\n  x: Int\n} derive(Foo)\n\nfn a(x: Int) -> Int\n' "$dpv_header" > "$dpvdir/bad/index.vpkg"
printf '%s' "$dpv_impl" > "$dpvdir/bad/impl.vibe"
# A transparent struct with a derive the checker KNOWS, so the package still
# materializes a types module -- the control has to exercise the same path,
# or it only proves that a package with no types stays quiet.
printf '%s\nstruct P {\n  x: Int\n} derive(Eq)\n\nfn a(x: Int) -> Int\n' "$dpv_header" > "$dpvdir/clean/index.vpkg"
printf '%s' "$dpv_impl" > "$dpvdir/clean/impl.vibe"
rm -f "$dpvdir/bad.out" "$dpvdir/bad.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dpvdir/bad/index.vpkg" "$dpvdir/bad.out" main >/dev/null 2>&1 || true
dpv_report="$(cat "$dpvdir/bad.out.diag" 2>/dev/null || true)"
# The diagnostic must still FIRE. Asserting only "no generated path" would
# pass on a change that stopped reporting the unknown derive altogether, which
# is the cheap wrong answer here.
if ! printf '%s\n' "$dpv_report" | grep -qF 'unknown trait: Foo'; then
  echo "[compiler-gate] FAIL: the full lane no longer reports an unknown derive on a contract struct -- repoint this probe (#2317)" >&2
  printf '%s\n' "$dpv_report" >&2
  exit 1
fi
if printf '%s\n' "$dpv_report" | grep -qF 'vibe_vpkg_types/'; then
  echo "[compiler-gate] FAIL: the diagnostic still names the generated types module instead of the contract (#2317)" >&2
  printf '%s\n' "$dpv_report" >&2
  exit 1
fi
if ! printf '%s\n' "$dpv_report" | grep -qF "$dpvdir/bad/index.vpkg"; then
  echo "[compiler-gate] FAIL: the diagnostic does not name the contract the author wrote (#2317)" >&2
  printf '%s\n' "$dpv_report" >&2
  exit 1
fi
# ...and a contract whose derives are all known stays clean, so a change that
# reported every materialized package cannot pass the assertions above.
rm -f "$dpvdir/clean.out" "$dpvdir/clean.out.diag"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dpvdir/clean/index.vpkg" "$dpvdir/clean.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: a contract with a KNOWN derive is refused -- the control for the probe above is not valid (#2317)" >&2
  cat "$dpvdir/clean.out.diag" >&2 2>/dev/null || true
  exit 1
fi
# The LOCATED case moved to section 123 (#2317). This section asserted that a
# located diagnostic must NOT name the contract, which was right while the stub
# recorded no declaration positions: `locate_type_error` computes its line
# against the STUB, and pairing a contract path with a stub line is confidently
# wrong. The stub now records each declaration's contract line:col, so the
# remap is honest and section 123 asserts it -- including that the reported
# line is the declaration's own.
#
# Kept as one assertion rather than deleted outright: whatever else changes,
# a located diagnostic must not end up pointing at a file with a line from
# somewhere else, and the two sections must not both claim to own this. 123
# owns the positive; this owns the fallback, where a stub carries provenance
# but no declaration markers and therefore keeps its own path AND its own line
# together. That is the shape every stub written before those markers has.
locmarker="$dpvdir/nomarker"
mkdir -p "$locmarker/.vibe/build/vpkg_types"
locstub=".vibe/build/vpkg_types/types_nomarkerprobe.vibe"
rm -f "$locstub"
printf '// vibe: vpkg contract types module (#1840)\n// vibe: generated from %s/pkg/index.vpkg\nstruct T {\n  a: Int\n}\n\nstruct Box[T] {\n  b: T\n}\n\nfn main() -> Int {\n  0\n}\n' "$dpvdir" > "$locstub"
rm -f "$dpvdir/nomarker.out" "$dpvdir/nomarker.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$locstub" "$dpvdir/nomarker.out" main >/dev/null 2>&1 || true
nomarker_report="$(cat "$dpvdir/nomarker.out.diag" 2>/dev/null || true)"
if ! printf '%s\n' "$nomarker_report" | grep -q 'line [0-9]*:'; then
  echo "[compiler-gate] FAIL: the marker-less stub produced no located diagnostic -- repoint this probe (#2317)" >&2
  printf '%s\n' "$nomarker_report" >&2
  rm -f "$locstub"
  exit 1
fi
if printf '%s\n' "$nomarker_report" | grep -qF "$dpvdir/pkg/index.vpkg"; then
  echo "[compiler-gate] FAIL: a stub with NO declaration markers had its located diagnostic renamed to the contract, pairing it with a stub line (#2317)" >&2
  printf '%s\n' "$nomarker_report" >&2
  rm -f "$locstub"
  exit 1
fi
rm -f "$locstub"
# ...and a HAND-WRITTEN module that merely claims generated provenance is not
# believed (Codex review on #2324).
#
# The predicate used to be a substring test for `vibe_vpkg_types/`, so an
# ordinary source under a directory of that name could carry a
# `// vibe: generated from ...` comment and have its diagnostics attributed to
# whatever path the comment named -- a file the reader never edited. The marker
# is now trusted only for the exact path shape the loader itself writes.
mkdir -p "$dpvdir/vibe_vpkg_types"
cat > "$dpvdir/vibe_vpkg_types/spoof.vibe" <<'DPVEOF'
// vibe: vpkg contract types module (#1840)
// vibe: generated from lib/@gate/NOT_THIS_FILE/index.vpkg
struct P {
  x: Int
} derive(Foo)

fn main() -> Int {
  0
}
DPVEOF
rm -f "$dpvdir/spoof.out" "$dpvdir/spoof.out.diag"
# VIBE_CHECK_ONLY, deliberately: a plain compile of this file reports the bare
# `unknown trait: Foo` with NO path prefix at all, so the assertion below could
# never fire no matter what the predicate did. Measured -- the first draft of
# this probe used a plain compile and passed on a build that DOES believe the
# spoof. `check_module_impl`, which attaches the path, runs on the check lane.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dpvdir/vibe_vpkg_types/spoof.vibe" "$dpvdir/spoof.out" main >/dev/null 2>&1 || true
spoof_report="$(cat "$dpvdir/spoof.out.diag" 2>/dev/null || true)"
# It must still be diagnosed, or this probe proves nothing about attribution.
if ! printf '%s\n' "$spoof_report" | grep -qF 'unknown trait: Foo'; then
  echo "[compiler-gate] FAIL: the spoof fixture produced no unknown-derive diagnostic -- repoint this probe (#2324)" >&2
  printf '%s\n' "$spoof_report" >&2
  exit 1
fi
if printf '%s\n' "$spoof_report" | grep -qF 'NOT_THIS_FILE'; then
  echo "[compiler-gate] FAIL: a hand-written module's provenance comment was believed, attributing its diagnostic to another file (#2324)" >&2
  printf '%s\n' "$spoof_report" >&2
  exit 1
fi
# ...including one NESTED under the generated directory. Prefix plus extension
# alone still accepts `.vibe/build/vpkg_types/types_fake/source.vibe`, which is
# an ordinary file someone wrote; the loader only ever produces a single
# `types_<fingerprint>.vibe` basename there (Codex review on #2324).
# The fixture has to sit at the REAL relative path, because the predicate reads
# the path it is given -- no `cd` (this gate's `stage2_wasm` can be relative, so
# a subshell that changed directory would stop finding the compiler; measured in
# tests/gates/lib.sh, which sets it to `_build/_gate_lane_gen/stage2.wasm`).
# Only the `types_fake/` subdirectory is created and removed; the real generated
# stubs alongside it are untouched.
nesteddir=".vibe/build/vpkg_types/types_fake"
rm -rf "$nesteddir"; mkdir -p "$nesteddir"
cat > "$nesteddir/source.vibe" <<'DPVEOF'
// vibe: vpkg contract types module (#1840)
// vibe: generated from lib/@gate/NOT_THIS_FILE/index.vpkg
struct P {
  x: Int
} derive(Foo)

fn main() -> Int {
  0
}
DPVEOF
rm -f "$dpvdir/nested.out" "$dpvdir/nested.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nesteddir/source.vibe" "$dpvdir/nested.out" main >/dev/null 2>&1 || true
nested_report="$(cat "$dpvdir/nested.out.diag" 2>/dev/null || true)"
if ! printf '%s\n' "$nested_report" | grep -qF 'unknown trait: Foo'; then
  echo "[compiler-gate] FAIL: the nested spoof fixture produced no unknown-derive diagnostic -- repoint this probe (#2324)" >&2
  printf '%s\n' "$nested_report" >&2
  rm -rf "$nesteddir"
  exit 1
fi
if printf '%s\n' "$nested_report" | grep -qF 'NOT_THIS_FILE'; then
  echo "[compiler-gate] FAIL: a file NESTED under the generated directory had its provenance comment believed (#2324)" >&2
  printf '%s\n' "$nested_report" >&2
  rm -rf "$nesteddir"
  exit 1
fi
rm -rf "$dpvdir" "$nesteddir"
echo "[compiler-gate] a type diagnostic on a materialized contract names the contract when unlocated, keeps the generated path when located, ignores a hand-written provenance claim flat or nested, and a known derive stays clean ok (#2317, #2324)"

# 122/122. A duplicated bodyless declaration is refused by both lanes, with a
# message that names the duplication (#2317).
#
# The build already refused it -- through `contract_facade_source`, whose
# `allocated` list is set-like while `decls` counts multiplicity, so the count
# check trips and reports "some declarations have no implementation file" about
# a name that IS implemented. Measured before this, `fn plain` declared twice
# with a matching impl got exactly that: an edit that does nothing.
#
# Both lanes now decide it from `contract_effective_decls`, the SAME filter the
# facade builder applies -- which is the whole point of the shared function.
# The filter matters: a legacy `let version: String` under a real `version`
# directive is dropped before counting, so declaring THAT twice is accepted by
# the build, and a check counting raw declarations would refuse a contract the
# build takes. Measured both ways.
echo "[compiler-gate] 122/122 a duplicated contract declaration is refused by both lanes, and named (#2317)"
dupdir="_build/_gate_contract_dup"
rm -rf "$dupdir"; mkdir -p "$dupdir"
dup_header='name = @gate/contractdup
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
dup_mk() {
  mkdir -p "$dupdir/$1"
  printf '%s\n%s' "$dup_header" "$2" > "$dupdir/$1/index.vpkg"
  printf '%s' "$3" > "$dupdir/$1/impl.vibe"
}
dup_plain_impl='export fn plain(x: Int) -> Int {
  x + 1
}
'
dup_mk once 'fn plain(x: Int) -> Int
' "$dup_plain_impl"
dup_mk twice 'fn plain(x: Int) -> Int

fn plain(x: Int) -> Int
' "$dup_plain_impl"
# Qualified names go through the same facade allocation, so they duplicate the
# same way. An earlier reading of this row claimed they were accepted; that
# rested on a fixture whose impl did not match its contract at all.
dup_mk qtwice 'fn Int::twice(x: Int) -> Int

fn Int::twice(x: Int) -> Int
' 'export fn Int::twice(x: Int) -> Int {
  x + x
}
'
# The filtered shape: a legacy `let version: String` beside a real `version`
# directive is dropped before counting, so twice is FINE. This is the control
# that a raw-declaration count would fail.
dup_mk vtwice 'let version: String

let version: String

fn plain(x: Int) -> Int
' "$dup_plain_impl"
for probe in once twice qtwice vtwice; do
  if [ "$probe" = twice ] || [ "$probe" = qtwice ]; then want="refused"; else want="clean"; fi
  rm -f "$dupdir/$probe.imp" "$dupdir/$probe.imp.diag" "$dupdir/$probe.buf"
  if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dupdir/$probe/index.vpkg" "$dupdir/$probe.imp" main >/dev/null 2>&1; then
    imp="clean"
  else
    imp="refused"
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dupdir/$probe/index.vpkg" "$dupdir/$probe.buf" main >/dev/null 2>&1 || true
  if [ -s "$dupdir/$probe.buf" ]; then buf="refused"; else buf="clean"; fi
  if [ "$imp" != "$want" ] || [ "$buf" != "$want" ]; then
    echo "[compiler-gate] FAIL: contract '$probe' -- import lane says $imp, buffer lane says $buf, both should say $want (#2317)" >&2
    cat "$dupdir/$probe.imp.diag" >&2 2>/dev/null || true
    cat "$dupdir/$probe.buf" >&2 2>/dev/null || true
    exit 1
  fi
done
# The message must name the DUPLICATION. "no implementation file" is the old
# answer, and it points the reader at an edit that does nothing.
for lane in imp.diag buf; do
  if ! grep -qF "declares 'plain' more than once" "$dupdir/twice.$lane" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $lane lane does not name the duplication for a repeated declaration (#2317)" >&2
    cat "$dupdir/twice.$lane" >&2 2>/dev/null || true
    exit 1
  fi
  if grep -qF 'no implementation file' "$dupdir/twice.$lane" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $lane lane still blames a missing implementation for a duplicate (#2317)" >&2
    cat "$dupdir/twice.$lane" >&2 2>/dev/null || true
    exit 1
  fi
done
# Anchored on the REPEAT, not on the first declaration. `fn plain` is on lines
# 9 and 11 of the generated fixture; pointing at 9 would send the reader to the
# declaration they want to keep.
if ! grep -q '^line 11:1:' "$dupdir/twice.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the duplicate is not anchored on the repeated declaration (expected line 11) (#2317)" >&2
  cat "$dupdir/twice.buf" >&2 2>/dev/null || true
  exit 1
fi
# ...and a FILTERED declaration sharing the duplicate's name does not shift the
# anchor. A dropped legacy `let version: String` sits before two effective
# `let version: Int` declarations; counting name occurrences in the raw list
# would skip one and point at the first effective declaration -- the line the
# reader wants to keep (Codex review on #2328). `version` is on lines 9, 11 and
# 13; the repeat is 13.
dup_mk vfiltered 'let version: String

let version: Int

let version: Int

fn plain(x: Int) -> Int
' "$dup_plain_impl"
rm -f "$dupdir/vfiltered.buf"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dupdir/vfiltered/index.vpkg" "$dupdir/vfiltered.buf" main >/dev/null 2>&1 || true
if ! grep -qF "declares 'version' more than once" "$dupdir/vfiltered.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: two effective 'version' declarations beside a filtered one are not reported as a duplicate (#2328)" >&2
  cat "$dupdir/vfiltered.buf" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -q '^line 13:1:' "$dupdir/vfiltered.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a filtered declaration sharing the name shifted the duplicate anchor off the repeat (expected line 13) (#2328)" >&2
  cat "$dupdir/vfiltered.buf" >&2 2>/dev/null || true
  exit 1
fi
# ...and when a contract has BOTH faults, the two lanes recommend the SAME first
# edit. The loader checked duplicates before classifying while the buffer lane
# classified first, so one said "declared more than once" and the other
# "unsupported statement" about the same file (Codex review on #2328) -- a
# fresh instance of the divergence this work exists to close.
dup_mk both 'fn plain(x: Int) -> Int

fn plain(x: Int) -> Int

export let z: Int = 5
' "$dup_plain_impl"
rm -f "$dupdir/both.imp" "$dupdir/both.imp.diag" "$dupdir/both.buf"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dupdir/both/index.vpkg" "$dupdir/both.imp" main >/dev/null 2>&1 || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dupdir/both/index.vpkg" "$dupdir/both.buf" main >/dev/null 2>&1 || true
# Both must lead with the unsupported statement: it is the more basic fault,
# and the point is that they AGREE, not which one wins.
for lane in imp.diag buf; do
  if ! grep -qF 'unsupported statement in a contract file' "$dupdir/both.$lane" 2>/dev/null; then
    echo "[compiler-gate] FAIL: with a duplicate AND an unsupported statement, the $lane lane does not lead with the unsupported statement (#2328)" >&2
    cat "$dupdir/both.$lane" >&2 2>/dev/null || true
    exit 1
  fi
done
rm -rf "$dupdir"
echo "[compiler-gate] a duplicated contract declaration is refused by both lanes and anchored on the repeat; the filtered version shape stays accepted; both lanes agree on precedence ok (#2317, #2328)"

# 123/123. A LOCATED type diagnostic about a materialized contract names the
# contract, at the declaration the author wrote (#2317).
#
# #2324 remapped only UNLOCATED messages, because `locate_type_error` computes
# its line against the STUB and pairing a contract path with a stub line is
# confidently wrong. The stub now records each declaration's contract line:col
# beside it, so a located message can be remapped honestly.
#
# Declaration-granular, and the assertions say so: `print_stmt` rebuilds a
# declaration from the AST, so the column INSIDE it is gone. What is recovered
# is which declaration -- which is what the reader acts on, and the message
# already names the offending type parameter.
echo "[compiler-gate] 123/123 a located contract diagnostic names the contract at its declaration (#2317)"
mapdir="_build/_gate_decl_map"
rm -rf "$mapdir"; mkdir -p "$mapdir/pkg" "$mapdir/clean"
map_header='name = @gate/declmap
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
map_impl='export fn a(x: Int) -> Int {
  x + 1
}
'
# `struct Box[T]` is on line 13 of this fixture; `struct T` on line 9. The
# shadowing diagnostic is about Box, so line 13 is the answer and line 9 is the
# decoy an off-by-one declaration mapping would produce.
printf '%s\nstruct T {\n  a: Int\n}\n\nstruct Box[T] {\n  b: T\n}\n\nfn a(x: Int) -> Int\n' "$map_header" > "$mapdir/pkg/index.vpkg"
printf '%s' "$map_impl" > "$mapdir/pkg/impl.vibe"
printf '%s\nstruct P {\n  x: Int\n}\n\nfn a(x: Int) -> Int\n' "$map_header" > "$mapdir/clean/index.vpkg"
printf '%s' "$map_impl" > "$mapdir/clean/impl.vibe"
rm -f "$mapdir/pkg.out" "$mapdir/pkg.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mapdir/pkg/index.vpkg" "$mapdir/pkg.out" main >/dev/null 2>&1 || true
map_report="$(cat "$mapdir/pkg.out.diag" 2>/dev/null || true)"
# Still fires, and still LOCATED -- either failing would make the rest vacuous.
if ! printf '%s\n' "$map_report" | grep -qF 'shadows the declared type'; then
  echo "[compiler-gate] FAIL: the shadowing diagnostic no longer fires -- repoint this probe (#2317)" >&2
  printf '%s\n' "$map_report" >&2
  exit 1
fi
if ! printf '%s\n' "$map_report" | grep -q 'line [0-9]*:'; then
  echo "[compiler-gate] FAIL: the shadowing diagnostic is no longer located -- this probe no longer tests the remap (#2317)" >&2
  printf '%s\n' "$map_report" >&2
  exit 1
fi
if printf '%s\n' "$map_report" | grep -qF 'vibe_vpkg_types/'; then
  echo "[compiler-gate] FAIL: a located diagnostic still names the generated types module (#2317)" >&2
  printf '%s\n' "$map_report" >&2
  exit 1
fi
if ! printf '%s\n' "$map_report" | grep -qF "$mapdir/pkg/index.vpkg"; then
  echo "[compiler-gate] FAIL: a located diagnostic does not name the contract the author wrote (#2317)" >&2
  printf '%s\n' "$map_report" >&2
  exit 1
fi
# The DECLARATION, not merely some line of the contract. `struct Box[T]` is on
# line 13; line 9 is the other declaration and is what an off-by-one mapping
# would report.
if ! printf '%s\n' "$map_report" | grep -qF ': line 13:'; then
  echo "[compiler-gate] FAIL: the located diagnostic does not point at the declaration it is about (expected line 13) (#2317)" >&2
  printf '%s\n' "$map_report" >&2
  exit 1
fi
# ...and a contract with no such error stays clean, so a change that reported
# every materialized package cannot pass the assertions above.
rm -f "$mapdir/clean.out" "$mapdir/clean.out.diag"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mapdir/clean/index.vpkg" "$mapdir/clean.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: a contract with a plain transparent struct is refused -- the control is not valid (#2317)" >&2
  cat "$mapdir/clean.out.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$mapdir"
echo "[compiler-gate] a located contract diagnostic names the contract at its own declaration; a clean contract stays clean ok (#2317)"

# 124/124. An undeclared type head in a transparent contract type is refused
# by BOTH the import lane and the single-buffer/LSP lane (#2317).
#
# #2327 removed the generated types module's wildcard for a typo, so the full
# lane began refusing `Intt`. The buffer lane still ran only derive validation
# after parsing the same contract and reported it clean. This gate asserts the
# two answers by message, not merely status: a contract can fail later for an
# unrelated conformance reason, which would make a status-only probe vacuous.
echo "[compiler-gate] 124/124 contract unknown type heads are refused by the full and buffer lanes (#2317)"
utdir="_build/_gate_contract_unknown_type"
rm -rf "$utdir"; mkdir -p "$utdir/field" "$utdir/payload" "$utdir/clean" "$utdir/local"
ut_header='name = @gate/contractunknown
version = 0.0.1
description =
  #|gate-only package for #2317
deps = {}

generated_hash =
'
ut_impl='export fn plain(x: Int) -> Int {
  x + 1
}
'
printf '%s\nstruct Bad {\n  x: Intt\n}\n\nfn plain(x: Int) -> Int\n' "$ut_header" > "$utdir/field/index.vpkg"
printf '%s\nenum Bad {\n  V(Intt)\n}\n\nfn plain(x: Int) -> Int\n' "$ut_header" > "$utdir/payload/index.vpkg"
printf '%s\nstruct Good {\n  x: Array[Int]\n}\n\nfn plain(x: Int) -> Int\n' "$ut_header" > "$utdir/clean/index.vpkg"
printf '%s\ntype Remote\n\nstruct Good {\n  x: Remote\n}\n\nfn plain(x: Int) -> Int\n' "$ut_header" > "$utdir/local/index.vpkg"
for probe in field payload clean local; do
  if [ "$probe" = local ]; then
    printf 'export struct Remote {\n  value: Int\n}\n\n%s' "$ut_impl" > "$utdir/$probe/impl.vibe"
  else
    printf '%s' "$ut_impl" > "$utdir/$probe/impl.vibe"
  fi
  rm -f "$utdir/$probe.imp" "$utdir/$probe.imp.diag" "$utdir/$probe.buf"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$utdir/$probe/index.vpkg" "$utdir/$probe.imp" main >/dev/null 2>&1 || true
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$utdir/$probe/index.vpkg" "$utdir/$probe.buf" main >/dev/null 2>&1 || true
done
for lane in imp.diag buf; do
  if ! grep -qF "unknown type \`Intt\` in field \`x\` of struct \`Bad\`" "$utdir/field.$lane" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $lane lane does not reject an unknown contract field type (#2317)" >&2
    cat "$utdir/field.$lane" >&2 2>/dev/null || true
    exit 1
  fi
  if ! grep -qF "unknown type \`Intt\` in the payload of \`Bad::V\`" "$utdir/payload.$lane" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $lane lane does not reject an unknown contract payload type (#2317)" >&2
    cat "$utdir/payload.$lane" >&2 2>/dev/null || true
    exit 1
  fi
done
if ! grep -q '^line 9:1:' "$utdir/field.buf" 2>/dev/null || ! grep -q '^line 9:1:' "$utdir/payload.buf" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a buffer-lane unknown type is not anchored on its declaration (#2317)" >&2
  cat "$utdir/field.buf" "$utdir/payload.buf" >&2 2>/dev/null || true
  exit 1
fi
for probe in clean local; do
  if [ -s "$utdir/$probe.imp.diag" ] || [ -s "$utdir/$probe.buf" ]; then
    echo "[compiler-gate] FAIL: valid contract '$probe' gained a diagnostic (#2317)" >&2
    cat "$utdir/$probe.imp.diag" "$utdir/$probe.buf" >&2 2>/dev/null || true
    exit 1
  fi
done
rm -rf "$utdir"
echo "[compiler-gate] unknown contract field/payload types are refused by both lanes at the declaration; builtin and local provenance stay clean ok (#2317)"

# 125. #2391: FS-lane Double call-result offsets ride the MODULAR check
#      (compile_file_fs_mode_rc -- the lane `vibe test` / `vibe run` take by
#      default), and persistent-cache state must not change the emitted bytes.
#
#      Cold compile (empty cache: every module is checked in-process, offsets
#      come from the memo) vs warm compile (unified module cache
#      hit: both outputs come from the same persistent record) must emit byte-identical
#      wasm -- the reuse arms in runtime/typecheck_fs.vibe validate BOTH record
#      sections, so a half-populated cache re-checks instead of silently
#      degrading. Running the warm artifact proves the rendered Doubles (the
#      test file's inspect snapshots, including a call to an IMPORTED Double
#      function -- the shape only this lane has).
echo "[compiler-gate] 125/125 FS-lane Double call-result offsets ride the modular check (#2391)"
ffsdir="_build/_gate_float_call_offsets_fs"
rm -rf "$ffsdir"; mkdir -p "$ffsdir/cache"
for pass in cold warm; do
  VIBE_BUILD_CACHE_DIR="$ffsdir/cache" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    lib/@vibe/compiler/tests/float_call_offset_fs_lane_test.vibe "$ffsdir/$pass.wasm" __no_entry__ \
    >/dev/null 2>&1 || true
  if [ ! -s "$ffsdir/$pass.wasm" ]; then
    echo "[compiler-gate] FAIL: FS-lane float call-offset test did not compile ($pass, #2391)" >&2
    cat "$ffsdir/$pass.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
# #2546: each module publishes one v10 record, never a separate offsets file.
if find "$ffsdir/cache" -type f -name '*selfhost_module_typed_lowering_offsets_v1*' | grep -q .; then
  echo "[compiler-gate] FAIL: separate lowering cache files are still published (#2546)" >&2
  exit 1
fi
if ! grep -rl '^version' "$ffsdir/cache" | xargs grep -l '^version[[:space:]]10$' >/dev/null; then
  echo "[compiler-gate] FAIL: no unified module cache record was published (#2546)" >&2
  exit 1
fi
if ! cmp -s "$ffsdir/cold.wasm" "$ffsdir/warm.wasm"; then
  echo "[compiler-gate] FAIL: FS-lane output depends on persistent-cache state (#2391)" >&2
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ffsdir/warm.wasm" >"$ffsdir/run.log" 2>&1; then
  echo "[compiler-gate] FAIL: a Double reaching __to_string through a call renders as raw bits on the FS lane (#2391)" >&2
  cat "$ffsdir/run.log" >&2 || true
  exit 1
fi
# Torn/corrupted records must decode as MISSES, not as partial answers
# (#2425 review round 3): truncate every offsets record in the warm cache to
# its version and environment lines, removing the lowering section, then compile again. The envelope's
# required end marker rejects the truncation, the affected modules re-check,
# and the output stays byte-identical; a decoder that accepted the torn file
# would drop classifications and change the bytes. (Digit-level corruption is
# rejected by the v8 digest -- see the next mutation.)
found_record=0
while IFS= read -r sc_file; do
  found_record=1
  head -2 "$sc_file" > "$sc_file.torn" && mv "$sc_file.torn" "$sc_file"
done < <(grep -rl "^module_typed_lowering_offsets" "$ffsdir/cache" 2>/dev/null)
if [ "$found_record" != "1" ]; then
  echo "[compiler-gate] FAIL: no float-offsets records found to corrupt (#2391) -- the probe went stale" >&2
  exit 1
fi
VIBE_BUILD_CACHE_DIR="$ffsdir/cache" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  lib/@vibe/compiler/tests/float_call_offset_fs_lane_test.vibe "$ffsdir/torn.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ ! -s "$ffsdir/torn.wasm" ]; then
  echo "[compiler-gate] FAIL: FS-lane float call-offset test did not compile over torn records (#2391)" >&2
  cat "$ffsdir/torn.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! cmp -s "$ffsdir/cold.wasm" "$ffsdir/torn.wasm"; then
  echo "[compiler-gate] FAIL: a torn float-offsets record changed the emitted bytes (#2391)" >&2
  exit 1
fi
# Digit-level corruption inside an INTACT record must also decode as a miss
# (#2425 review round 5): the torn compile above re-warmed the cache, so flip
# one digit of the first offset row in every record (same length, so the
# count, the end marker and every other line survive) and compile again. Only
# the v8 digest can see this one -- the counts still match and the envelope is
# still well formed -- so it is the case that proves the digest is
# load-bearing. The module re-checks and the bytes stay identical; the v3
# decoder accepted this and the emitted bytes CHANGED (red-proven on #2425).
#
# #2555: a v8 row is ONE bare decimal per line. It was `off<TAB>off` while the
# envelope duplicated every row, and this recipe matched on that -- when the
# duplication went away the mutation silently matched nothing, which the
# "probe went stale" check below caught.
flipped_rows=0
while IFS= read -r sc_file; do
  before_first=$(awk -F'\t' 'NF == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$sc_file")
  awk -F'\t' 'BEGIN { OFS = "\t"; done = 0 }
    done == 0 && NF == 1 && $1 ~ /^[0-9]+$/ {
      first = substr($1, 1, 1)
      $1 = (first != "9" ? "9" : "1") substr($1, 2)
      done = 1
    }
    { print }' "$sc_file" > "$sc_file.flip" && mv "$sc_file.flip" "$sc_file"
  after_first=$(awk -F'\t' 'NF == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$sc_file")
  if [ -n "$before_first" ] && [ "$before_first" != "$after_first" ]; then
    flipped_rows=$((flipped_rows + 1))
  fi
done < <(grep -rl "^module_typed_lowering_offsets" "$ffsdir/cache" 2>/dev/null)
# The mutation must actually HIT (gate discipline: a red test that matched
# nothing proves nothing) -- the lane test's own modules carry offset rows, so
# at least one record's first row must now read differently than it did.
if [ "$flipped_rows" = "0" ]; then
  echo "[compiler-gate] FAIL: digit-flip mutation matched no record row (#2391) -- the probe went stale" >&2
  exit 1
fi
VIBE_BUILD_CACHE_DIR="$ffsdir/cache" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  lib/@vibe/compiler/tests/float_call_offset_fs_lane_test.vibe "$ffsdir/flipped.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ ! -s "$ffsdir/flipped.wasm" ]; then
  echo "[compiler-gate] FAIL: FS-lane float call-offset test did not compile over digit-flipped records (#2391)" >&2
  cat "$ffsdir/flipped.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! cmp -s "$ffsdir/cold.wasm" "$ffsdir/flipped.wasm"; then
  echo "[compiler-gate] FAIL: a digit-corrupted float-offsets record changed the emitted bytes (#2391)" >&2
  exit 1
fi
# Whole-row deletion inside an intact record must also decode as a miss
# (#2425 review round 6): the flipped compile re-warmed the cache, so delete
# the first offset row from every record (header, remaining rows, count line,
# and end marker all survive) and compile again. The declared count no longer
# matches the row set, the module re-checks, and the bytes stay identical.
deleted_rows=0
while IFS= read -r sc_file; do
  before_rows=$(awk -F'\t' 'NF == 1 && $1 ~ /^[0-9]+$/ { n += 1 } END { print n + 0 }' "$sc_file")
  awk -F'\t' 'BEGIN { done = 0 }
    done == 0 && NF == 1 && $1 ~ /^[0-9]+$/ { done = 1; next }
    { print }' "$sc_file" > "$sc_file.del" && mv "$sc_file.del" "$sc_file"
  if [ "$before_rows" -gt 0 ]; then
    deleted_rows=$((deleted_rows + 1))
  fi
done < <(grep -rl "^module_typed_lowering_offsets" "$ffsdir/cache" 2>/dev/null)
if [ "$deleted_rows" = "0" ]; then
  echo "[compiler-gate] FAIL: row-deletion mutation matched no record row (#2391) -- the probe went stale" >&2
  exit 1
fi
VIBE_BUILD_CACHE_DIR="$ffsdir/cache" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  lib/@vibe/compiler/tests/float_call_offset_fs_lane_test.vibe "$ffsdir/rowdel.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ ! -s "$ffsdir/rowdel.wasm" ]; then
  echo "[compiler-gate] FAIL: FS-lane float call-offset test did not compile over row-deleted records (#2391)" >&2
  cat "$ffsdir/rowdel.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! cmp -s "$ffsdir/cold.wasm" "$ffsdir/rowdel.wasm"; then
  echo "[compiler-gate] FAIL: a row-deleted float-offsets record changed the emitted bytes (#2391)" >&2
  exit 1
fi
rm -rf "$ffsdir"
echo "[compiler-gate] FS-lane Double call-result offsets + cache-state byte identity ok (#2391)"

# 126. #2391 slice 2: FS-lane String relational/`+` binops ride the SAME
#      modular check. The desugar tracker rewrites `a < b` / `a + b` to
#      str_lex_diff / String::concat only for operands it can classify
#      syntactically; the checker records every String binop's anchor in the
#      typed-lowering record (tags 1/2 of the enc encoding) and the FS merge
#      rewrites exactly those binops. Red-proven against the pre-channel
#      stage2: the lane test's inferred-lambda `<` answered `true` (address
#      order) where content says `false`, and the lambda `+` printed an empty
#      string. Cold vs warm byte identity pins cache-state independence for
#      the String half the same way block 125 pins it for the Double half.
echo "[compiler-gate] 126/126 FS-lane String binop channel rides the modular check (#2391)"
sbdir="_build/_gate_string_binop_fs"
rm -rf "$sbdir"; mkdir -p "$sbdir/cache"
for pass in cold warm; do
  VIBE_BUILD_CACHE_DIR="$sbdir/cache" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    lib/@vibe/compiler/tests/string_binop_typed_channel_fs_lane_test.vibe "$sbdir/$pass.wasm" __no_entry__ \
    >/dev/null 2>&1 || true
  if [ ! -s "$sbdir/$pass.wasm" ]; then
    echo "[compiler-gate] FAIL: FS-lane String binop channel test did not compile ($pass, #2391)" >&2
    cat "$sbdir/$pass.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
if ! cmp -s "$sbdir/cold.wasm" "$sbdir/warm.wasm"; then
  echo "[compiler-gate] FAIL: FS-lane String binop output depends on persistent-cache state (#2391)" >&2
  exit 1
fi
# The warm cache's records must actually carry String rows (enc tag 1 or 2),
# or the channel went inert and the run below proves nothing about it (gate
# discipline: assert the probe hit, not just that the answer looked right).
string_rows=0
while IFS= read -r sc_file; do
  file_rows=$(awk -F'\t' 'NF == 1 && $1 ~ /^[0-9]+$/ { if ($1 % 4 == 1 || $1 % 4 == 2) n += 1 } END { print n + 0 }' "$sc_file")
  string_rows=$((string_rows + file_rows))
done < <(grep -rl "^module_typed_lowering_offsets" "$sbdir/cache" 2>/dev/null)
if [ "$string_rows" = "0" ]; then
  echo "[compiler-gate] FAIL: no String binop rows in any typed-lowering record (#2391) -- the channel went inert" >&2
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$sbdir/warm.wasm" >"$sbdir/run.log" 2>&1; then
  echo "[compiler-gate] FAIL: a String binop the tracker cannot classify answered by address on the FS lane (#2391)" >&2
  cat "$sbdir/run.log" >&2 || true
  exit 1
fi
rm -rf "$sbdir"
echo "[compiler-gate] FS-lane String binop typed channel + cache-state byte identity ok (#2391)"
