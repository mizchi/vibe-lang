#!/usr/bin/env bash
# compiler-gate lane: late (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/late/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2


# 41. ADR-0069 Phase 1: `fn main {}` sugar + entry/top-level hardening.
#     (a) ok_fnmain: the paren-less/annotation-less `fn main with Stdout { .. }`
#         special form compiles as `let main: () -> Unit with Stdout` and the
#         synthesized `_start` runs it (output contains 42).
#     (b) bad_entry_typo: a nonexistent entry name is a COMPILE ERROR (it used
#         to silently fall through to an empty test-runner `_start`); only the
#         explicit `__no_entry__` sentinel builds a test runner (exercised all
#         over this gate, e.g. step 15c).
#     (c) bad_toplevel_expr / bad_toplevel_mut: top level is declarations only —
#         a top-level expression statement / `let mut` is rejected by the checker.
echo "[compiler-gate] 41/41 ADR-0069 fn main sugar + entry/top-level hardening"
a69dir="_build/_gate_adr69"
rm -rf "$a69dir"; mkdir -p "$a69dir"
cat > "$a69dir/ok_fnmain.vibe" <<'EOF'
fn main with Stdout {
  Stdout::write_stream("42\n")
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/ok_fnmain.vibe" "$a69dir/ok_fnmain.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$a69dir/ok_fnmain.wasm" ]; then
  echo "[compiler-gate] FAIL: fn main {} sugar did not compile" >&2
  cat "$a69dir/ok_fnmain.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a69_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$a69dir/ok_fnmain.wasm" 2>&1 || true)"
# `fn main` is `() -> Unit`: the program's own output must appear and the
# `_start` synthesis must NOT print the entry's return (a Unit entry used to
# get a stray trailing `0` line from the Int-return print_int convention,
# PR #834 review). Int-returning entries keep the print (see below).
if [ "$a69_out" != "42" ]; then
  echo "[compiler-gate] FAIL: fn main {} run output '$a69_out' (want exactly '42'; a trailing 0 line means the Unit entry hit print_int)" >&2
  exit 1
fi
# Int-returning `let main` keeps the historical return-print convention.
cat > "$a69dir/int_main.vibe" <<'EOF'
let main: () -> Int = () -> { 41 + 1 }
EOF
rm -f "$a69dir/int_main.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/int_main.vibe" "$a69dir/int_main.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$a69dir/int_main.wasm" ]; then
  echo "[compiler-gate] FAIL: Int-returning let main did not compile" >&2
  cat "$a69dir/int_main.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a69_int_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$a69dir/int_main.wasm" 2>&1 || true)"
if [ "$a69_int_out" != "42" ]; then
  echo "[compiler-gate] FAIL: Int-returning main output '$a69_int_out' (want '42' — the return-print convention must survive for Int entries)" >&2
  exit 1
fi
cat > "$a69dir/typo.vibe" <<'EOF'
let main: () -> Int = () -> { 42 }
EOF
rm -f "$a69dir/typo.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/typo.vibe" "$a69dir/typo.wasm" mian >/dev/null 2>&1 || true
if [ -s "$a69dir/typo.wasm" ]; then
  echo "[compiler-gate] FAIL: entry typo 'mian' compiled to a module (should be 'entry not found' error)" >&2
  exit 1
fi
if ! grep -q "not found" "$a69dir/typo.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: entry typo diag missing 'not found' message" >&2
  cat "$a69dir/typo.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$a69dir/toplevel_expr.vibe" <<'EOF'
let f = (n: Int) -> Int { n + 1 }
f(41)
export let _start: () -> Int = () -> { f(41) }
EOF
rm -f "$a69dir/toplevel_expr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/toplevel_expr.vibe" "$a69dir/toplevel_expr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$a69dir/toplevel_expr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level expression statement compiled (should be rejected, ADR-0069)" >&2
  exit 1
fi
cat > "$a69dir/toplevel_mut.vibe" <<'EOF'
let mut counter = 0
export let _start: () -> Int = () -> { counter }
EOF
rm -f "$a69dir/toplevel_mut.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/toplevel_mut.vibe" "$a69dir/toplevel_mut.wasm" _start >/dev/null 2>&1 || true
if [ -s "$a69dir/toplevel_mut.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level let mut compiled (should be rejected, ADR-0069)" >&2
  exit 1
fi
rm -rf "$a69dir"
echo "[compiler-gate] ADR-0069 fn main sugar + entry/top-level hardening ok"

# 42. #830 / #1281: `let record { .. } = <expr>` (record-pattern
# destructuring, #760) worked as a *local* `let` but used to hit a raw
# "expected = but got {" at the top level, and was then rejected with a
# located error. #1281 implements the multi-statement expansion it was
# waiting for, so the top-level form now COMPILES and RUNS: the record value
# lands in a hidden binding and each field name becomes its own positional
# `__rec_field` projection. Field patterns are positional (that is how the
# block-level desugar reads them too), so `record { name: n, ver: v }` binds
# slot 0 to `n` and slot 1 to `v`.
echo "[compiler-gate] 42/42 top-level record-pattern let (#830 / #1281)"
g830dir="_build/_gate_830"
rm -rf "$g830dir"; mkdir -p "$g830dir"
cat > "$g830dir/toplevel_record_destr.vibe" <<'EOF'
let r = record { name: "vibe", ver: 7 }
let record { name: n, ver: v } = r
export let _start: () -> Int = () -> { String::length(n) * 100 + v }
EOF
rm -f "$g830dir/toplevel_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g830dir/toplevel_record_destr.vibe" "$g830dir/toplevel_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g830dir/toplevel_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let record { .. } = ..' did not compile (#1281)" >&2
  cat "$g830dir/toplevel_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g830_top_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g830dir/toplevel_record_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g830_top_out" != "407" ]; then
  echo "[compiler-gate] FAIL: top-level record-pattern destructure output '$g830_top_out' (want 407, #1281)" >&2
  exit 1
fi
# The function-body form (the one #830 says already worked) must keep
# compiling AND running to the correct values -- this is the regression net
# for the working case, so a future change to the block-step record-destr
# desugar (parser_expr_dispatch.vibe StepRecordDestr/apply_record_destr)
# that breaks it fails here too, not just silently at the top level.
cat > "$g830dir/fnbody_record_destr.vibe" <<'EOF'
struct Rec { name: String; ver: Int }
fn describe(r: Rec) -> Int {
  let record { name: n, ver: v } = r
  String::length(n) * 100 + v
}
export let _start: () -> Int = () -> { describe(Rec::{ name: "vibe", ver: 7 }) }
EOF
rm -f "$g830dir/fnbody_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g830dir/fnbody_record_destr.vibe" "$g830dir/fnbody_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g830dir/fnbody_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: function-body 'let record { .. } = ..' did not compile" >&2
  cat "$g830dir/fnbody_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g830_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g830dir/fnbody_record_destr.wasm" 2>&1 || true)"
if [ "$g830_out" != "407" ]; then
  echo "[compiler-gate] FAIL: function-body record-pattern destructure output '$g830_out' (want '407' = length(\"vibe\")*100 + 7)" >&2
  exit 1
fi
rm -rf "$g830dir"
echo "[compiler-gate] top-level record-pattern let (#830 / #1281) ok"

# 43. #844 regression: a `let`-style annotation used to be able to LAUNDER a
#     generic struct's real type arguments. `resolve_type_expr` types a bare
#     (unparameterized) reference to a generic struct annotation as bare
#     `CtStruct(name)`, discarding #829's real instantiated args; `unify`'s
#     `CtStruct`/`CtNamed` bridge (core/types.vibe, needed for the LEGITIMATE
#     case guarded by gate sections 18/20 above -- a bare-`S`-typed trait
#     return accepting a freshly `S::{...}`-constructed `S[X]`) then re-unifies
#     that bare annotation with ANY later, unrelated instantiation by name
#     alone. `let x: Box = Box::{v:1}; let y: Box[String] = x; y.v` used to
#     compile clean and read a stored `Int` as a `String` at runtime.
#     `check_assignable`'s `type_is_ground`/`type_no_named` heuristic
#     (deliberately lenient for a still-rigid/uninstantiated type parameter,
#     e.g. the very `LazyIter`/`Option[(T, Int)]` shape sections 18/20 guard)
#     ALSO independently swallows this specific mismatch even once the real
#     type args are preserved, since it treats every `CtNamed` as non-ground
#     regardless of how concrete its arguments are -- so the fix has two
#     additive parts (checker.vibe: `preserve_generic_instantiation` +
#     `detect_narrowed_generic_mismatch`, applied at both the top-level `SLet`
#     path (checker_stmt.vibe) and the local-`let` ascription-lambda call
#     shape) instead of touching `resolve_type_expr`'s ~20 call sites or the
#     shared `type_is_ground` (both judged too wide-blast-radius to land in
#     one pass, and the latter is exactly what sections 18/20 above exist to
#     protect).
echo "[compiler-gate] 43/43 generic-struct annotation re-narrowing regression (#844)"
g844dir="_build/_gate_844"
rm -rf "$g844dir"; mkdir -p "$g844dir"
cat > "$g844dir/toplevel_narrow.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box = Box::{ v: 1 }
let y: Box[String] = x
export let _start: () -> Int = () -> { String::length(y.v) }
EOF
rm -f "$g844dir/toplevel_narrow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/toplevel_narrow.vibe" "$g844dir/toplevel_narrow.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g844dir/toplevel_narrow.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level annotation-laundered generic-struct re-narrowing compiled (#844 regressed)" >&2
  exit 1
fi
if ! grep -q "binding type mismatch" "$g844dir/toplevel_narrow.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: top-level #844 rejection lacks the expected diagnostic" >&2
  cat "$g844dir/toplevel_narrow.wasm.diag" 2>/dev/null >&2; exit 1
fi
cat > "$g844dir/local_narrow.vibe" <<'EOF'
struct Box[T] { v: T }
fn bad() -> Int {
  let x: Box = Box::{ v: 1 }
  let y: Box[String] = x
  String::length(y.v)
}
export let _start: () -> Int = () -> { bad() }
EOF
rm -f "$g844dir/local_narrow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/local_narrow.vibe" "$g844dir/local_narrow.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g844dir/local_narrow.wasm" ]; then
  echo "[compiler-gate] FAIL: local-let annotation-laundered generic-struct re-narrowing compiled (#844 regressed)" >&2
  exit 1
fi
if ! grep -q "binding type mismatch" "$g844dir/local_narrow.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: local-let #844 rejection lacks the expected diagnostic" >&2
  cat "$g844dir/local_narrow.wasm.diag" 2>/dev/null >&2; exit 1
fi
# Positive controls: legitimate bare/explicit generic-struct annotation uses
# that must NOT be over-rejected by the #844 fix.
cat > "$g844dir/ok_bare_roundtrip.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box = Box::{ v: 1 }
let y: Box = x
export let _start: () -> Int = () -> { y.v }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/ok_bare_roundtrip.vibe" "$g844dir/ok_bare_roundtrip.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g844dir/ok_bare_roundtrip.wasm" ]; then
  echo "[compiler-gate] FAIL: bare-to-bare generic-struct annotation round-trip over-rejected (#844 fix too aggressive)" >&2
  cat "$g844dir/ok_bare_roundtrip.wasm.diag" 2>/dev/null >&2; exit 1
fi
g844_ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g844dir/ok_bare_roundtrip.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g844_ok_out" != "1" ]; then
  echo "[compiler-gate] FAIL: bare-to-bare generic-struct round-trip returned '$g844_ok_out' (want 1)" >&2
  exit 1
fi
cat > "$g844dir/ok_matching.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box[Int] = Box::{ v: 41 }
let y: Box[Int] = x
export let _start: () -> Int = () -> { y.v + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/ok_matching.vibe" "$g844dir/ok_matching.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g844dir/ok_matching.wasm" ]; then
  echo "[compiler-gate] FAIL: explicit matching generic-struct instantiation over-rejected (#844 fix too aggressive)" >&2
  cat "$g844dir/ok_matching.wasm.diag" 2>/dev/null >&2; exit 1
fi
g844_ok2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g844dir/ok_matching.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g844_ok2_out" != "42" ]; then
  echo "[compiler-gate] FAIL: explicit matching generic-struct instantiation returned '$g844_ok2_out' (want 42)" >&2
  exit 1
fi
rm -rf "$g844dir"
echo "[compiler-gate] generic-struct annotation re-narrowing regression (#844) ok"

# 44. #1281 (was #859): top-level irrefutable pattern `let` -- tuple
#     `let (a, b) = pair`, named-struct `let Name::{ x, y } = v`, and
#     anonymous-record `let record { a, b } = r`. These used to parse and
#     type-check but had no codegen case (a raw "undefined variable" crash),
#     so they were rejected outright; they are now expanded by the parser
#     into a hidden binding for the value plus one projection binding per
#     name. Refutable patterns stay rejected with a clear, LOCATED error.
# 43b. #1078: two enums declaring a same-named variant in one compiled unit
#      is a hard, descriptive error naming both enums -- previously the
#      flat name-keyed env silently resolved every bare construction to the
#      LAST-registered signature, producing an arity/argument-type mismatch
#      pointing at the WRONG declaration (or a silent wrong-tag miscompile
#      when signatures matched). Unrelated packages meet in one unit via
#      the merge/flatten lane, which is how #1078 was originally hit.
echo "[compiler-gate] 43b/43 enum constructor name collision rejection (#1078)"
g1078dir="_build/_gate_1078"
rm -rf "$g1078dir"; mkdir -p "$g1078dir"
cat > "$g1078dir/ctor_collision.vibe" <<'EOF'
enum AEnum {
  Mk(Int)
}

enum BEnum {
  Mk(String, String)
}

fn use_a() -> AEnum {
  Mk(1)
}

export let main = () -> Int {
  let a = use_a()
  1
}
EOF
rm -f "$g1078dir/ctor_collision.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g1078dir/ctor_collision.vibe" "$g1078dir/ctor_collision.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1078dir/ctor_collision.wasm" ]; then
  echo "[compiler-gate] FAIL: same-named variant across two enums compiled (should be rejected, #1078)" >&2
  exit 1
fi
if ! grep -q "constructor name collision" "$g1078dir/ctor_collision.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: ctor-collision diag missing the descriptive #1078 message (still the misleading wrong-declaration mismatch?)" >&2
  cat "$g1078dir/ctor_collision.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$g1078dir"
echo "[compiler-gate] enum constructor name collision rejection ok (#1078)"

echo "[compiler-gate] 44/44 top-level irrefutable pattern let (#1281)"
g859dir="_build/_gate_859"
rm -rf "$g859dir"; mkdir -p "$g859dir"
# #1281 (was #859): a top-level irrefutable pattern `let` now compiles and
# runs. The parser expands it into a hidden binding holding the value plus one
# projection binding per name, so codegen still needs no top-level `SLetPat`
# case -- and the value is evaluated exactly ONCE (pinned below), which is the
# property a naive "repeat the RHS per name" expansion would break.
cat > "$g859dir/toplevel_tuple_destr.vibe" <<'EOF'
let (a, b) = (10, 32)
export let _start: () -> Int = () -> { a + b }
EOF
rm -f "$g859dir/toplevel_tuple_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_tuple_destr.vibe" "$g859dir/toplevel_tuple_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_tuple_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let (a, b) = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_tuple_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_tuple_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level tuple-pattern destructure output '$g859_out' (want 42, #1281)" >&2
  exit 1
fi
cat > "$g859dir/toplevel_struct_destr.vibe" <<'EOF'
struct Pair { x: Int; y: Int }
let Pair::{ x, y } = Pair::{ x: 10, y: 32 }
export let _start: () -> Int = () -> { x + y }
EOF
rm -f "$g859dir/toplevel_struct_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_struct_destr.vibe" "$g859dir/toplevel_struct_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_struct_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let Name::{ .. } = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_struct_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_struct_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level struct-pattern destructure output '$g859_out' (want 42, #1281)" >&2
  exit 1
fi
cat > "$g859dir/toplevel_record_destr.vibe" <<'EOF'
let record { a, b } = record { a: 10, b: 32 }
export let _start: () -> Int = () -> { a + b }
EOF
rm -f "$g859dir/toplevel_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_record_destr.vibe" "$g859dir/toplevel_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let record { .. } = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_record_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level record-pattern destructure output '$g859_out' (want 42, #1281)" >&2
  exit 1
fi
# The value is evaluated ONCE, however many names the pattern binds: `mk`
# appends to a log, so a re-evaluated RHS shows up as a second entry (242).
cat > "$g859dir/toplevel_destr_once.vibe" <<'EOF'
let log = []

fn mk() -> (Int, Int) {
  Array::push(log, 1)
  (10, 32)
}

let (a, b) = mk()

export let _start: () -> Int = () -> { a + b + Array::length(log) * 100 }
EOF
rm -f "$g859dir/toplevel_destr_once.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_destr_once.vibe" "$g859dir/toplevel_destr_once.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_destr_once.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level destructure of a call did not compile (#1281)" >&2
  cat "$g859dir/toplevel_destr_once.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_destr_once.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "142" ]; then
  echo "[compiler-gate] FAIL: top-level pattern let evaluated its value $((g859_out / 100)) times (want 1, output '$g859_out' vs 142, #1281)" >&2
  exit 1
fi
# A REFUTABLE pattern is still rejected -- it can fail to match, and a
# top-level binding has nowhere to fail to.
cat > "$g859dir/toplevel_refutable_destr.vibe" <<'EOF'
let Some(a) = Some(42)
export let _start: () -> Int = () -> { a }
EOF
rm -f "$g859dir/toplevel_refutable_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_refutable_destr.vibe" "$g859dir/toplevel_refutable_destr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g859dir/toplevel_refutable_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let Some(a) = ..' compiled (refutable, should be rejected, #1281)" >&2
  exit 1
fi
if ! grep -q "requires an irrefutable pattern" "$g859dir/toplevel_refutable_destr.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: refutable top-level pattern let diag missing the clear #1281 message" >&2
  cat "$g859dir/toplevel_refutable_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The function-body forms (which already worked, per the #859 writeup) must
# keep compiling AND running to the correct values -- the regression net for
# the working case, so a future change to the block-step destructure desugar
# (parser_expr_dispatch.vibe apply_record_destr/apply_struct_destr) that
# breaks it fails here too, not just silently at the top level.
cat > "$g859dir/fnbody_tuple_destr.vibe" <<'EOF'
fn compute() -> Int {
  let (a, b) = (10, 32)
  a + b
}
export let _start: () -> Int = () -> { compute() }
EOF
rm -f "$g859dir/fnbody_tuple_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/fnbody_tuple_destr.vibe" "$g859dir/fnbody_tuple_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/fnbody_tuple_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: function-body 'let (a, b) = ..' did not compile" >&2
  cat "$g859dir/fnbody_tuple_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/fnbody_tuple_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: function-body tuple-pattern destructure output '$g859_out' (want 42)" >&2
  exit 1
fi
rm -rf "$g859dir"
echo "[compiler-gate] top-level irrefutable pattern let (#1281) ok"

# 45/45 (#897 Phase 4, ADR-0070): every directory in the repo must have
# migrated off the old index.vibei/bare-index.vibe facade to a proper
# index.vpkg contract. This is the CI-required half of the diagnostic
# implemented in loader/loader.vibe's find_missing_vpkg_dirs (Phase 1) --
# a passive `vibe check` command is easy to forget to run by hand, so once
# Phase 3 finished migrating all 76 directories this became a required gate
# to prevent a future PR from silently reintroducing a plain index.vibe dir.
# 44b. #944 (ADR-0073 stage B): checked-Error row discipline is ON by
#      default -- a row-less caller of a `with Error` function is
#      rejected with the row-mismatch diagnostic; VIBE_CHECK_ERROR_ROW=0
#      is the opt-out escape hatch that restores the old exemption; a
#      caller that discharges via `handle .. with Error` compiles and
#      runs under the default.
echo "[compiler-gate] 44b/44 checked-Error row discipline default-on (#944 stage B)"
g944dir="_build/_gate_944"
rm -rf "$g944dir"; mkdir -p "$g944dir"
cat > "$g944dir/leak.vibe" <<'EOF'
fn boom(x: Int) -> Int with Exception {
  if x == 0 {
    throw("zero")
  }
  x
}

fn pure_caller(x: Int) -> Int {
  boom(x)
}

export let main = () -> Int {
  pure_caller(1)
}
EOF
cat > "$g944dir/discharged.vibe" <<'EOF'
fn boom(x: Int) -> Int with Exception {
  if x == 0 {
    throw("zero")
  }
  x
}

export let main = () -> Int {
  handle {
    boom(1)
  } with Exception {
    Throw(_) => 0
  }
}
EOF
rm -f "$g944dir/leak_off.wasm"
VIBE_CHECK_ERROR_ROW=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/leak.vibe" "$g944dir/leak_off.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944dir/leak_off.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_CHECK_ERROR_ROW=0 opt-out did not restore the old exemption (#944)" >&2
  cat "$g944dir/leak_off.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$g944dir/leak_on.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/leak.vibe" "$g944dir/leak_on.wasm" main >/dev/null 2>&1 || true
if [ -s "$g944dir/leak_on.wasm" ]; then
  echo "[compiler-gate] FAIL: default-on checked-Error mode did not reject the row-less caller (#944)" >&2
  exit 1
fi
if ! grep -q "missing { Exception }" "$g944dir/leak_on.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: checked-Error rejection diag missing the row-mismatch message (#944)" >&2
  cat "$g944dir/leak_on.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$g944dir/discharged.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/discharged.vibe" "$g944dir/discharged.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944dir/discharged.wasm" ]; then
  echo "[compiler-gate] FAIL: checked-Error mode rejected a handle-with-Error discharge (over-strict, #944)" >&2
  cat "$g944dir/discharged.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g944_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g944dir/discharged.wasm" 2>&1 | tail -1)"
if [ "$g944_out" != "1" ]; then
  echo "[compiler-gate] FAIL: checked-Error discharged sample got '$g944_out' (want 1)" >&2
  exit 1
fi
rm -rf "$g944dir"
echo "[compiler-gate] opt-in checked-Error row discipline ok (#944 stage A)"

# 44c. #944 (ADR-0073 stage C, "entry boundary A"): an entry declared
#      `with Error` whose Throw escapes must produce the stderr diagnostic and
#      a non-zero shell status, including through the result-less `_start`
#      launcher ABI.
echo "[compiler-gate] 44c/44 entry-boundary Error handler (#944 stage C)"
g944cdir="_build/_gate_944c"
rm -rf "$g944cdir"; mkdir -p "$g944cdir"
# #1571: the entry-boundary behaviour (stderr diagnostic + process status) is
# asserted below, so the fixture carries no `__DATA__` tail any more and is
# compiled AS-IS -- no `sed` strip, no temp copy.
rm -f "$g944cdir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/entry_error_boundary.vibe "$g944cdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: entry_error_boundary.vibe did not compile (#944 stage C)" >&2
  cat "$g944cdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g944cdir/out.wasm" >"$g944cdir/stdout.txt" 2>"$g944cdir/stderr.txt"; then
  echo "[compiler-gate] FAIL: entry_error_boundary exited 0 through _start (#1945)" >&2
  exit 1
fi
if ! grep -q "vibe: uncaught error: boom" "$g944cdir/stderr.txt"; then
  echo "[compiler-gate] FAIL: entry_error_boundary stderr missing the boundary diagnostic (#944 stage C)" >&2
  cat "$g944cdir/stderr.txt" >&2 || true
  exit 1
fi
# #1372 review (Codex P1): the same boundary arm also catches every TYPED
# `Exception[E]` (ADR-0085's runtime has a single abortive tag and no kind
# discriminator, and the erased `Error` spelling is compatible with every
# kind). Writing that enum payload straight to `Stderr::write_stream`
# decoded the pointer as a packed `(ptr<<32)|len` string and printed
# unrelated memory.
#
# #1374: the throw site now records the payload's static type name, so the
# boundary names the KIND rather than printing a decimal that reads like a
# message. Three distinct outputs are pinned below, and each one fails
# differently if the channel breaks:
#   - typed enum payload -> `vibe: uncaught error: <Boom>`. A regression to
#     the raw payload prints memory; a regression to #1375's blind
#     `__to_string` prints a decimal. Neither matches.
#   - String payload -> `vibe: uncaught error: plain boom`, byte for byte
#     what it printed before either fix. This is the additivity check: the
#     overwhelmingly common case must not have moved.
rm -f "$g944cdir/typed.wasm" "$g944cdir/typed_stderr.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_entry_boundary_typed_payload.vibe "$g944cdir/typed.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/typed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_entry_boundary_typed_payload.vibe did not compile (#1372 review)" >&2
  cat "$g944cdir/typed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g944cdir/typed.wasm" >"$g944cdir/typed_stdout.txt" 2>"$g944cdir/typed_stderr.txt"; then
  echo "[compiler-gate] FAIL: typed-payload entry boundary exited 0 (#1945)" >&2
  exit 1
fi
if [ "$(head -n 1 "$g944cdir/typed_stderr.txt")" != 'vibe: uncaught error: <Boom>' ]; then
  echo "[compiler-gate] FAIL: a TYPED exception escaping the entry did not name its kind -- the boundary is reading the payload as a string, or the #1374 kind side channel is not reaching it" >&2
  head -c 400 "$g944cdir/typed_stderr.txt" >&2 || true
  exit 1
fi
# #1374 additivity: a String payload must print verbatim, exactly as it did
# before the kind channel existed.
rm -f "$g944cdir/strp.wasm" "$g944cdir/strp_stderr.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_entry_boundary_string_payload.vibe "$g944cdir/strp.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/strp.wasm" ]; then
  echo "[compiler-gate] FAIL: err_entry_boundary_string_payload.vibe did not compile (#1374)" >&2
  cat "$g944cdir/strp.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g944cdir/strp.wasm" >"$g944cdir/strp_stdout.txt" 2>"$g944cdir/strp_stderr.txt"; then
  echo "[compiler-gate] FAIL: String-payload entry boundary exited 0 (#1945)" >&2
  exit 1
fi
if [ "$(head -n 1 "$g944cdir/strp_stderr.txt")" != 'vibe: uncaught error: plain boom' ]; then
  echo "[compiler-gate] FAIL: a String exception escaping the entry no longer prints verbatim -- #1374's kind dispatch changed the common case (want 'vibe: uncaught error: plain boom')" >&2
  head -c 400 "$g944cdir/strp_stderr.txt" >&2 || true
  exit 1
fi
rm -rf "$g944cdir"
echo "[compiler-gate] entry-boundary Error handler ok (#944 stage C, typed payload #1372, kind channel #1374)"
bash scripts/test_uncaught_exception_exit.sh "$stage2_wasm"

# 44d. #1087: a NON-tail `throw` inline in a `handle .. with Error` body
#      must abort the body -- the arm's value (1) is the handle's result,
#      not the body's continuation value (41). The ADR-0076 Phase 2 inliner
#      used to splice the arm in place of the perform (resumptive
#      semantics), running the arm but discarding its value; Error arms are
#      now excluded from that pass (idp_arms_discharge_error).
echo "[compiler-gate] 44d/44 with-Error non-tail throw abort (#1087)"
g1087dir="_build/_gate_1087"
rm -rf "$g1087dir"; mkdir -p "$g1087dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. Entry is `__no_entry__`, which synthesizes
# the test-block runner; a mismatch prints inspect's own actual/expected
# (1 vs 41) from inside the run and fails it.
rm -f "$g1087dir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_error_nontail.vibe "$g1087dir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$g1087dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail.vibe did not compile (#1087)" >&2
  cat "$g1087dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! g1087_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g1087dir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail want 1, NOT 41 -- a non-tail throw in a with-Error handle body ran the body's continuation instead of aborting to the arm's value (#1087; check idp_arms_discharge_error in inline_direct_perform.vibe)" >&2
  echo "$g1087_out" >&2
  exit 1
fi
rm -rf "$g1087dir"
echo "[compiler-gate] with-Error non-tail throw abort ok (#1087)"

# 44e. #1092: `vibe diagnostics` on a file whose FIRST error sits past a
#      multi-KB prefix must report it, not blow the wasm call stack. The
#      prelude's String::index_of (and its sibling scanners) used to recurse
#      once per scanned character via a local `let rec` closure -- a
#      call_indirect self-call the top-level-only TCO pass never loop-ifies
#      -- so the located-error path (which searches the whole source text)
#      crashed with "RangeError: Maximum call stack size exceeded" at a
#      ~4-5KB error offset (lsp_server.vibe was undiagnosable). The prelude
#      scanners are iterative now; this pins that.
echo "[compiler-gate] 44e/44 diagnostics on multi-KB source with a late error (#1092)"
g1092dir="_build/_gate_1092"
rm -rf "$g1092dir"; mkdir -p "$g1092dir"
{
  i=0
  while [ $i -lt 300 ]; do
    printf 'fn f%d(x: Int) -> Int {\n  x + %d\n}\n\n' "$i" "$i"
    i=$((i + 1))
  done
  printf 'fn g(n: Int) -> Int {\n  unknown_name_xyz(n)\n}\n'
} > "$g1092dir/src.vibe"
rm -f "$g1092dir/diag.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g1092dir/src.vibe" "$g1092dir/diag.txt" >/dev/null 2>&1 || true
if [ ! -f "$g1092dir/diag.txt" ]; then
  echo "[compiler-gate] FAIL: diagnostics crashed on a ~11KB source with a late error (#1092 regressed -- check the prelude string scanners for reintroduced per-char recursion)" >&2
  exit 1
fi
if ! grep -q "unknown name: unknown_name_xyz" "$g1092dir/diag.txt"; then
  echo "[compiler-gate] FAIL: diagnostics on the late-error source missed the error (#1092)" >&2
  cat "$g1092dir/diag.txt" >&2 || true
  exit 1
fi
rm -rf "$g1092dir"
echo "[compiler-gate] diagnostics on multi-KB source ok (#1092)"

echo "[compiler-gate] 45/45 missing index.vpkg scan (#897 Phase 4)"
vpkgdir="_build/_gate_vpkg_scan"
rm -rf "$vpkgdir"; mkdir -p "$vpkgdir"
VIBE_MISSING_VPKG_SCAN=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ROOT_DIR" "$vpkgdir/scan.out" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$vpkgdir/scan.out" ]; then
  echo "[compiler-gate] FAIL: missing-vpkg scan produced no output" >&2
  cat "$vpkgdir/scan.out.diag" 2>/dev/null >&2
  exit 1
fi
if ! grep -q "^ok: no directories missing index.vpkg" "$vpkgdir/scan.out"; then
  echo "[compiler-gate] FAIL: directories still missing index.vpkg (#897 Phase 4):" >&2
  cat "$vpkgdir/scan.out" >&2
  exit 1
fi
rm -rf "$vpkgdir"
echo "[compiler-gate] missing index.vpkg scan (#897 Phase 4) ok"

# 46/46. Ctor Double-field match binding under RC (#1062; reverted attempt
#        PR #1068 / commit 0269998). A pattern-bound constructor field
#        (`Circle(r) => r * r`) was never registered into the float-local-slot
#        tracking `let`-bound floats get, so a Double-typed field fell through
#        to the integer-multiply path -- under RC that multiplies two boxed-
#        float POINTERS together, producing a bogus pointer that traps with
#        "memory access out of bounds" when dereferenced. The first fix
#        attempt (PR #1068) added CompileCtx.ctor_float_fields +
#        bind_match_pat's ctor_field_is_float consumer and correctly fixed
#        this repro, but was reverted: the broader
#        "scripts/unit_test_runner.sh" allowlist (462 files) showed ~37-39
#        unrelated failures in parser/checker/printer tests that this gate's
#        OWN narrower checks never exercised. Root cause of THAT regression:
#        float_local_slots was never pruned at match-arm / if-else boundaries
#        the way int_local_slots / agg_local_slots already are, so a sibling
#        arm's non-float field reusing the same local slot number as an
#        earlier arm's Double-typed bind inherited a stale "floatish" mark and
#        took the f64 path for ordinary integer arithmetic (see
#        float_log_reset_above in codegen/common_base/common_base.vibe, and
#        fixtures/ctor_float_sibling_arm_slot_test.vibe which pins that class
#        of bug directly, RC-independent). This gate compiles+runs the
#        original #1062 repro under VIBE_RC=1 -- the OOB-trap-specific
#        manifestation the issue was filed for.
echo "[compiler-gate] 46/46 ctor Double-field match binding under RC (#1062)"
c1062dir="_build/_gate_ctor_double_field_rc"
rm -rf "$c1062dir"; mkdir -p "$c1062dir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_ctor_double_field_match_test.vibe" "$c1062dir/c1062.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$c1062dir/c1062.wasm" ]; then
  echo "[compiler-gate] FAIL: ctor Double-field match fixture did not compile under RC" >&2
  cat "$c1062dir/c1062.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$c1062dir/c1062.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: ctor Double-field match fixture trapped under RC (#1062 regressed)" >&2; exit 1
fi
rm -rf "$c1062dir"
echo "[compiler-gate] ctor Double-field match binding under RC (#1062) ok"

# 47/47. Self-hosted `vibe lsp` (lib/@vibe/lsp/lsp_server.vibe,
#        #lsp-selfhost): a full JSON-RPC 2.0 / Content-Length-framed
#        initialize -> didOpen -> hover -> shutdown -> exit round trip,
#        driven via scripts/wasm_vibe_host_runner.js's VIBE_STDIN_BYTES
#        batch-feed (the same "vibe.*" linear-backend stdin host imports a
#        real editor's live pipe exercises under viberun -- this gate proves
#        the wasm-level protocol/dispatch logic; it doesn't need viberun
#        itself, which compiler_gate.sh has no other dependency on and
#        this sandbox doesn't have installed). Checks the hover response
#        contains the correct inferred type for a simple two-arg function --
#        this specific assertion is also a regression lock for the
#        closure-crossing-a-HOF-parameter trap fixed while landing this
#        feature (lsp_run_with_handler dispatches via a plain Int tag, not
#        an effectful closure VALUE passed through a HOF parameter -- see
#        that function's own doc comment for why: the closure-value form
#        compiled fine and even ran fine under this same Node dev-runner,
#        but trapped ("indirect call type mismatch") under real wasmtime,
#        the still-open GENERAL case issue #1070 describes).
echo "[compiler-gate] 47/47 self-hosted vibe lsp: initialize/didOpen/hover/shutdown/exit round trip"
lspgatedir="_build/_gate_lsp_selfhost"
rm -rf "$lspgatedir"; mkdir -p "$lspgatedir"
python3 - "$lspgatedir/input.bin" <<'PYEOF'
import json, sys

def frame(obj):
    body = json.dumps(obj)
    b = body.encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

sample_source = "let add = (a: Int, b: Int) -> Int { a + b }\n\nexport let main = () -> Int { add(1, 2) }\n"
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate.vibe", "languageId": "vibe", "version": 1, "text": sample_source}
    }}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 0, "character": 5}
    }}),
    # parity slice 2: completion / signatureHelp / workspace-symbol.
    # signatureHelp position: line 2 "export let main = () -> Int { add(1, 2) }",
    # character 34 = just after "add(" -- callee backscan must find `add` and
    # ask the checker for its type.
    frame({"jsonrpc": "2.0", "id": 4, "method": "textDocument/completion", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 2, "character": 0}
    }}),
    frame({"jsonrpc": "2.0", "id": 5, "method": "textDocument/signatureHelp", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 2, "character": 34}
    }}),
    frame({"jsonrpc": "2.0", "id": 6, "method": "workspace/symbol", "params": {"query": "ad"}}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
PYEOF
lsp_out="$lspgatedir/output.bin"
VIBE_STDIN_BYTES="$(cat "$lspgatedir/input.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" > "$lsp_out" 2>"$lspgatedir/stderr.log"
if ! grep -q '"id":1,"result"' "$lsp_out" 2>/dev/null && ! grep -q '"id": 1, "result"' "$lsp_out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp did not answer initialize" >&2
  cat "$lspgatedir/stderr.log" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -q '(Int, Int) -> Int' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp hover response missing/wrong (want '(Int, Int) -> Int')" >&2
  cat "$lsp_out" >&2
  exit 1
fi
# parity slice 2 assertions: completion offers the document's own `add`
# declaration AND a language keyword; signatureHelp resolves the callee and
# renders "add: (Int, Int) -> Int"; workspace/symbol finds `add` in the open
# doc with its location.
if ! grep -Eq '"label": ?"add"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp completion missing document symbol 'add'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"label": ?"handle"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp completion missing keyword item 'handle'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"label": ?"add: \(Int, Int\) -> Int"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp signatureHelp missing 'add: (Int, Int) -> Int' (callee backscan or type_at regressed)" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"name": ?"add"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp workspace/symbol missing 'add'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
rm -rf "$lspgatedir"
echo "[compiler-gate] self-hosted vibe lsp round trip ok (incl. completion/signatureHelp/workspace-symbol)"

# 48/48. ADR-0068 `Send` marker (docs/concurrency.md "`Send` と capture
#        safety"): compiler-judged structural marker for task/channel
#        message safety. Positive: primitives, tuples, Option/Result, and
#        immutable structs/enums (incl. generic instantiation + recursive
#        enum) satisfy `[T: Send]` (fixtures/send_bound_structural.vibe,
#        compiled AND run: 42). Negative: Array (mutable interior),
#        mut-field struct, and closure are rejected with the standard
#        `no impl `Send` for `...`` diagnostic; a user `impl Send` is
#        rejected as such (Send cannot be user-implemented). Judgment is
#        type_send_ok in checker/checker_trait.vibe, wired into
#        check_program_bounds (checker_stmt.vibe).
echo "[compiler-gate] 48/48 ADR-0068 Send marker (structural judgment + rejections)"
senddir="_build/_gate_send_marker"
rm -rf "$senddir"; mkdir -p "$senddir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/send_bound_structural.vibe "$senddir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$senddir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_structural.vibe did not compile -- structural Send acceptance regressed" >&2
  cat "$senddir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! send_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$senddir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: send_bound_structural got '$send_pos_out' (want 42)" >&2
  echo "$send_pos_out" >&2
  exit 1
fi
# #1571: the expectation for each rejection is `$needle` right here, so these
# fixtures no longer carry an unread `__DATA__` error_contains copy and are
# compiled AS-IS -- no `sed` strip, no temp copy.
send_check_reject() {
  local fixture="$1" needle="$2" tag="$3"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$fixture" "$senddir/$tag.wasm" main >/dev/null 2>&1 || true
  if [ -s "$senddir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$needle" "$senddir/$tag.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $fixture did not produce the expected diagnostic ($needle)" >&2
    cat "$senddir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
}
send_check_reject "err_type_send_array_bound.vibe" 'no impl `Send` for `Array[Int]`' "arr"
send_check_reject "err_type_send_mut_struct_bound.vibe" 'no impl `Send` for `Counter`' "mut"
send_check_reject "err_type_send_closure_bound.vibe" 'no impl `Send` for `' "clos"
send_check_reject "err_type_send_user_impl.vibe" '`Send` is a compiler-judged structural marker' "impl"
# #1090 review: the coinductive guard keys on constructor + ARGS — a
# recursive occurrence with different arguments must still be checked.
send_check_reject "err_type_send_nonregular_recursion.vibe" 'no impl `Send` for `LoopT[Int]`' "nonreg"
# #1090 review: bounds are enforced on the IMPORT (check_program_with_env /
# FS) path too — a consumer importing a [T: Send] fn must not bypass it.
cat > "$senddir/send_dep.vibe" <<'SENDDEP'
export let want_send = [T: Send](x: T) -> T { x }
SENDDEP
cat > "$senddir/send_use.vibe" <<'SENDUSE'
import ./send_dep.vibe { want_send }

fn main {
  let _ = want_send([1, 2, 3])
  ()
}
SENDUSE
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$senddir/send_use.vibe" "$senddir/send_use.wasm" main >/dev/null 2>&1 || true
if [ -s "$senddir/send_use.wasm" ]; then
  echo "[compiler-gate] FAIL: Send bound bypassed on the import path (send_use.vibe compiled)" >&2
  exit 1
fi
if ! grep -qF 'no impl `Send` for `Array[Int]`' "$senddir/send_use.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: import-path Send violation did not produce the expected diagnostic" >&2
  cat "$senddir/send_use.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$senddir"
echo "[compiler-gate] ADR-0068 Send marker ok"

# 49/49. #1085: RC over-drop for a param with a real consume (Array::set)
#        in one branch and a #706 loop-borrow site (while + push) in the
#        sibling branch of an append helper. The #725 epilogue emitted its
#        "one unconditional drop" on every path, over-releasing the store
#        on real-consume executions (use-after-free from the 3rd element,
#        else arm not even executed). Fixed by lc_has_nonloop_consume
#        (codegen/wasi/linked_compile.vibe) suppressing the loop-count
#        drop in the mixed case. Runs under the default RC test lane and
#        checks both the struct shape (silent corruption) and the closure
#        shape (call_indirect trap): want 123123.
echo "[compiler-gate] 49/49 RC branch+loop mixed-consume over-drop (#1085)"
rc1085dir="_build/_gate_rc_branch_loop"
rm -rf "$rc1085dir"; mkdir -p "$rc1085dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_branch_loop_mixed_consume_test.vibe "$rc1085dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1085dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume fixture did not compile" >&2
  cat "$rc1085dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1085_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1085dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume got '$rc1085_out' (want 123123) -- #1085 over-drop regressed" >&2
  echo "$rc1085_out" >&2
  exit 1
fi
rm -rf "$rc1085dir"
echo "[compiler-gate] RC branch+loop mixed-consume over-drop (#1085) ok"

# 50/50. ADR-0076 Phase 3a (#817, docs/effect-evidence-passing.md 追記27):
#        first-class `resume` (suspend handler class) via the depth-0
#        suspend CPS lowering (suspend_cps_pass in codegen/common_base/
#        inline_direct_perform.vibe + the checker's arm-scope `resume`
#        binding). Positive: the scheduler shape -- an arm STORES resume,
#        the handle returns the suspension value, and the stored one-shot
#        continuations drive the remaining body suspend-by-suspend
#        (want 10230); post-processing through the value form
#        (`let k = resume  let r = k(v)  r + 7`, want 1017). Runtime: the
#        second call of the same continuation writes the one-shot message
#        to stderr and traps. Phase 3b (yield bubbling): a suspend body
#        may call concrete-row functions carrying the effect -- CPS
#        clones + per-effect bubble combinator (want 3131365). #1230: a
#        plain `while` + `let mut` spine is eligible too -- the loop
#        becomes a recursive step-returning closure and each `let mut` a
#        1-element cell, so state survives every suspend (want 101020383).
#        Negative: a non-tail DIRECT resume(...) call stays rejected (#942
#        unchanged); a row-variable callee and a loop carrying
#        break/continue/return are HARD compile errors, never a silent
#        replay fallback.
echo "[compiler-gate] 50/50 ADR-0076 Phase 3a first-class resume (suspend CPS)"
scpsdir="_build/_gate_scps"
rm -rf "$scpsdir"; mkdir -p "$scpsdir"
# #1571: fixtures that own their expectation as an `inspect` test block
# compile AS-IS -- no `__DATA__` strip, no temp copy, and no expected value
# in shell. Entry is `__no_entry__`, which synthesizes the test-block
# runner; a mismatch prints inspect's own actual/expected and fails the run.
scps_run_inspect() {
  local fixture="$1" tag="$2"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$fixture" "$scpsdir/$tag.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$scpsdir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture did not compile -- Phase 3a suspend lowering regressed" >&2
    cat "$scpsdir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! scps_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$scpsdir/$tag.wasm" 2>&1)"; then
    echo "[compiler-gate] FAIL: $fixture tests failed -- Phase 3a suspend lowering regressed" >&2
    echo "$scps_out" >&2
    exit 1
  fi
}
scps_run_inspect "effect_resume_store_scheduler.vibe" "sched"
scps_run_inspect "effect_resume_value_postprocess.vibe" "post"
# Phase 3b yield bubbling now lives in
# fixtures/effect_resume_call_bubbling_test.vibe (#1973).
# Trivial row-var wrapper pin now lives in
# fixtures/effect_resume_rowvar_wrapper_normalized_test.vibe (#1973).
# #1230 loop widening: `while` + `let mut` on the spine. 101020383 decodes
# as r0=100/r1=101/r2=102/r3=183 -- the 183 is the pin that both `acc` and
# `i` survived every suspend/resume round trip through their cells.
scps_run_inspect "effect_resume_store_loop.vibe" "loop"
# #1263 Codex P1: a non-suspending loop AHEAD of a suspending one must stay
# iterative. The 200000-iteration prefix would blow the wasm call stack if it
# were converted to the recursive lp() shape (rewrite_self_tail_calls runs
# before suspend_cps_pass, so nothing flattens it back).
scps_run_inspect "effect_resume_store_loop_prefix.vibe" "loopprefix"
# #1263 Codex P2: a nested closure is a control-flow boundary -- its `return`
# targets the closure, not the loop being converted, so it must not reject.
scps_run_inspect "effect_resume_store_loop_nested_return.vibe" "loopnestedret"
# one-shot violation: must NOT produce a value; the failure output carries
# the one-shot stderr diagnostic before the assert trap.
sed '/^_start()$/d' fixtures/effect_resume_one_shot_trap.vibe > "$scpsdir/once.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$scpsdir/once.vibe" "$scpsdir/once.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$scpsdir/once.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_resume_one_shot_trap.vibe did not compile" >&2
  cat "$scpsdir/once.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
scps_once_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$scpsdir/once.wasm" 2>&1 || true)"
if ! printf '%s' "$scps_once_out" | grep -q "one-shot continuation called twice"; then
  echo "[compiler-gate] FAIL: double resume did not trap with the one-shot message; output was:" >&2
  printf '%s\n' "$scps_once_out" >&2
  exit 1
fi
# #1571: the `__DATA__` strip is gone. Every fixture this ran carried an
# `{"error_contains": ...}` tail that was byte-identical to `$needle` right
# here, and the gate read its own copy while stripping the fixture's -- the
# same "one fact, two copies" shape the repository has been removing (six other
# sections already say "no longer carries an unread `__DATA__` error_contains
# copy"). The tails are deleted, so this was the LAST `sed '/^__DATA__$/,$d'`
# in tests/gates/.
#
# `_start()` is still dropped: that is a top-level call line, not an
# expectation, and a rejected fixture must not also fail for having one.
scps_check_reject() {
  local fixture="$1" needle="$2" tag="$3"
  sed '/^_start()$/d' "fixtures/$fixture" > "$scpsdir/$tag.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$scpsdir/$tag.vibe" "$scpsdir/$tag.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$scpsdir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$needle" "$scpsdir/$tag.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $fixture did not produce the expected diagnostic ($needle)" >&2
    cat "$scpsdir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
}
# #1536 (a): a row-free closure param whose every by-name call site
# passes a provably suspend-inert literal is see-through (plain call in
# the clone; want 5), including the delegation shape (pick_any forwards
# its own param into pick's slot; want 5). One site passing a PERFORMING
# literal taints the slot and the rejection stays.
scps_run_inspect "effect_closure_param_inert.vibe" "inertparam"
# Delegation pin now lives in
# fixtures/effect_closure_param_inert_transitive_test.vibe (#1973).
# #1723: a local pure closure shadows a top-level function whose callback
# parameter carries the suspend effect. The prepass must leave the literal on
# the plain convention; Done-wrapping it returns a step pointer instead of 8.
scps_run_inspect "effect_scps_param_shadow_test.vibe" "localparamshadow"
scps_run_inspect "effect_scps_top_level_alias_test.vibe" "toplevelalias"
# #1723 / #1803 P2 follow-up: effect_row_local_shadow_test.vibe's "unshadowed
# effectful call" control sits inside `handle`, where the missing-effect
# diagnostic is suppressed (in_handle), so it cannot pin "still charged when
# NOT shadowed" by itself. This is the un-suppressed half: with no local
# shadow and no handler, the row lands on the caller and a row-free caller is
# refused. The accepted twin is test 1 of effect_row_local_shadow_test.vibe.
scps_check_reject "err_effect_unshadowed_row_charged.vibe" "effect row mismatch for 'caller': missing { Ask }" "unshadowedrow"
# #1536 (a) v3/v4 seq-head pins now live in inspect tests (#1973):
# fixtures/effect_for_await_suspend_test.vibe,
# fixtures/effect_seq_head_block_suspend_test.vibe,
# fixtures/effect_seq_head_reserved_name_collision_test.vibe,
# fixtures/effect_seq_head_if_suspend_test.vibe,
# fixtures/effect_seq_head_match_suspend_test.vibe.
# #1536 direct selection input: a recognized direct perform is first named on
# the CPS spine, evaluates once, then selects a branch/arm whose continuation
# runs once.
scps_run_inspect "effect_seq_head_if_condition_suspend.vibe" "seqheadifcond"
scps_run_inspect "effect_seq_head_match_scrutinee_suspend.vibe" "seqheadmatchscrut"
# Tail selection input pin now lives in
# fixtures/effect_tail_selection_input_suspend_test.vibe (#1973).
# #1536 direct plain-assignment RHS: name the resumed value on the CPS spine,
# then assign and continue once.
scps_run_inspect "effect_assignment_rhs_suspend.vibe" "assignrhs"
# #1536 direct while condition: resume into the existing recursive loop
# closure once per condition check.
scps_run_inspect "effect_while_condition_suspend.vibe" "whilecond"
# #1536 (a) v8: COMPOUND inputs -- an operand, a call argument, a constructor
# payload, a comparison in a condition. The suspension is named on the spine and
# everything the original evaluated before it is named in order ahead of it, so
# these pin evaluation order, not just acceptance (a handler that mutates shared
# state between perform and resume would show up in the numbers). The `while`
# case additionally pins that the chain stayed inside the loop closure.
# New positive regressions own their expectations as inspect snapshots. Run
# them unchanged with the freshly built stage2 that implements this lowering.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_assignment_rhs_compound_suspend.vibe \
  fixtures/effect_seq_head_if_condition_compound_suspend.vibe \
  fixtures/effect_seq_head_match_compound_scrutinee_suspend.vibe \
  fixtures/effect_compound_call_arg_suspend.vibe \
  fixtures/effect_while_condition_compound_suspend.vibe \
  fixtures/effect_assignment_op_rhs_suspend.vibe \
  fixtures/effect_assignment_op_name_collision_test.vibe \
  fixtures/effect_compound_anf_name_collision_test.vibe \
  fixtures/effect_compound_closure_literal_suspend_test.vibe
# #1536 tail-only short-circuit: the whole boolean expression lowers to EIf,
# preserving bypass and selected-RHS suspension. The snapshot pins four paths,
# operation order, handler visits, resumed source-continuation events, and the
# handler regaining control afterward; exact event counts pin exact-once flow.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_tail_shortcircuit_suspend.vibe \
  fixtures/effect_let_shortcircuit_suspend.vibe
# #1536 selection-valued bindings: an `if` / `match` that IS the whole bound
# value distributes the binding and the continuation into its branches. The
# snapshots pin exact-once continuation runs, that the non-suspending branch is
# still selected normally, that a `let mut` cell survives the distribution, and
# that an arm binder cannot capture a name the moved continuation reads.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_let_selection_suspend_test.vibe \
  fixtures/effect_let_selection_match_capture_test.vibe \
  fixtures/effect_letmut_selection_suspend_test.vibe
# #1536 block-valued bindings: `let x = { stmt..; value }` moves the binding
# inward past the statement prefix, so the ordinary spine picks the prefix up.
# The snapshot pins the prefix running once per binding and that a `let` inside
# the block cannot capture the continuation's outer name when it floats.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_let_block_value_suspend_test.vibe
# #1536 assignment mirror: `x = <if/match>` / `x = { stmt..; value }`. A boxed
# target is reshaped before cellification, a target bound outside the spine on
# the continuation spine; the two snapshots pin both arms agreeing.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_assign_selection_suspend_test.vibe \
  fixtures/effect_assign_outer_selection_suspend_test.vibe
# #1536 selection nested in a compound: the linearization names the selection
# WHOLE instead of walking into a branch, so the binding distribution lowers it.
# The snapshot's `order` digits pin that nothing moved across the suspension.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_compound_selection_suspend_test.vibe
# #1536 non-tail short-circuit: named whole too, but only after asking the
# immutable-let lowering whether it will take it (naming a form that lowering
# declines would not converge). The snapshots pin bypass, compound RHS
# terminals (comparison / nested short-circuit / call argument), and order.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_compound_shortcircuit_suspend_test.vibe \
  fixtures/effect_shortcircuit_compound_rhs_test.vibe
# #1536: loop bodies carrying `break` / `continue`. The transfers become calls
# on the CPS spine (exit continuation / loop self-call), dead statements behind
# a transfer drop, and a nested loop keeps its own transfers. `return` in the
# body stays fail-closed.
# New positive regressions use source-owned inspect snapshots and run as-is;
# do not add another __DATA__ + shell-duplicated expectation to this legacy
# helper. VIBE_TEST_CLI_WASM pins the freshly built stage2 that knows this
# lowering while the checked-in seed catches up through normal bootstrap.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_loop_form_suspend_test.vibe \
  fixtures/effect_while_break_continue_suspend_test.vibe \
  fixtures/effect_loop_nested_break_suspend_test.vibe \
  fixtures/effect_resume_store_loop_break_test.vibe \
  fixtures/effect_loop_ctl_name_collision_test.vibe
# #1536 boundary: generic linearization still walks only positions that every
# execution reaching a compound also reaches, so it never names a suspension
# INSIDE a branch or inside a short-circuit RHS. Both are instead named WHOLE
# (the snapshots above pin that, bypass included). A selected RHS that returns
# stays closed -- now via the general rule below, since a `return` anywhere on
# a split body's spine is refused before the split runs.
scps_check_reject "err_effect_let_shortcircuit_return_suspend.vibe" "cannot contain a \`return\`" "letshortcircuitreturn"
# #1536: a `return` on a split body's own spine is hoisted to the tail it
# already denotes (in a needing fn's clone / a closure literal, `return v` IS
# that computation's value). It used to be left in place, compile clean, and
# trap at runtime on the path that took it. The snapshots pin all four shapes
# and the capture-safe match-arm distribution; a `return` this hoist cannot
# reach -- inside a loop -- is still refused (err_effect_loop_return_suspend).
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_in_split_body_test.vibe \
  fixtures/effect_return_match_arm_split_test.vibe \
  fixtures/effect_return_in_loop_test.vibe
# #1536 P0: a transfer with a STATEMENT in front of it, after a resume. The
# transfer test used to see only a BARE break/continue, so `if d { acc = v;
# break }` was not a transfer, the continuation was not dropped, and execution
# fell through the rewritten call and kept looping -- silently answering
# differently than the same loop without a suspension. `scan` is 700 with and
# without effects; it used to be 800 here.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_transfer_after_resume_test.vibe
# `break` leaves only the INNERMOST loop, so each level records-and-breaks and
# is followed by a guard that carries the exit outward one level at a time.
# The snapshot covers two and three levels deep, and a return never taken.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_nested_loop_test.vibe
# #1536: `return` in a HANDLE body means "leave the enclosing function", not
# "the handle's value", so it is captured in a cell declared outside the handle
# and returned after it. The snapshot pins taken / not-taken / from inside a
# suspending loop nested in the handle body.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_in_handle_body_test.vibe
# #1536: `for x in xs` over a PROVED array becomes the indexed while form, which
# the split already handles. The proof is syntactic (a parameter annotated
# Array[..], or a let bound to an array literal) -- codegen decides String-ness
# at run time (#807), so an unproved iterand must not be rewritten. The snapshot
# pins break / continue / index advance / length re-read, not just acceptance.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_array_for_suspend_test.vibe
# The same loop over a PROVED String indexes the string directly, using the
# builtins codegen itself uses to materialize one. An UNPROVED iterand is still
# never rewritten -- that is what keeps a runtime String out of the array form.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_string_for_suspend_test.vibe
# #1536: two more self-proving iterands -- a LITERAL (`for x in [1, 2]` /
# `for c in "ab"`), and a name bound to a call whose callee declares an
# Array[..] / String return. The snapshot pins CHAR CODES for the string forms,
# so it fails if either lowering picks the other kind's indexing.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_for_proved_iterand_suspend_test.vibe
# #1536: and a BUILTIN callee proves it via the registry row, which is where a
# builtin's signature has lived all along. `Array::concat` also joins the
# hand-audited pure-builtin list -- without it the body was refused naming the
# concat, not the loop.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_for_builtin_iterand_suspend_test.vibe
# #1714 P0: the callee-return proof reads the module's TOP-LEVEL statements, so
# a local binding spelling the same name made it answer about the wrong
# function -- lowering a String iterand to the indexed ARRAY form, which
# compiled clean and answered 0 instead of 215. Refused now.
scps_check_reject "err_effect_for_shadowed_callee.vibe" "is not directly on the handle body" "forshadow"
# #1718 P0: the same root in the ELIGIBILITY check. A local `let pick = maker()`
# shadowing a top-level `fn pick() -> Int` (empty row) made scps_fn_row_of admit
# a call to a PERFORMING value -- compiled clean and answered 2285 instead of
# 110. Rename the local and the same program is (correctly) refused as an opaque
# callee; that is now the answer for the shadowed spelling too.
scps_check_reject "err_effect_shadowed_toplevel_callee.vibe" "cannot see through" "shadowtop"
# #1720 follow-up: authorization is lexical, not an additive set. Every newer
# binder masks an older inert/CPS proof, and source-spelled generated prefixes
# remain opaque. Pin the exact culprit so diagnostics and eligibility cannot
# drift apart again. The loop fixture exercises the parser-lowered local form;
# the plain closure-parameter convention also remains pinned by #1707 below.
scps_check_reject "err_effect_inert_local_reshadow.vibe" "here: the call to 'pick'" "inertreshadow"
scps_check_reject "err_effect_cps_local_reshadow.vibe" "here: the call to 'pick'" "cpsreshadow"
scps_check_reject "err_effect_reserved_local_opaque.vibe" "here: the call to '__scps_user'" "reservedopaque"
scps_check_reject "err_effect_enclosing_param_shadow.vibe" "here: the call to 'pick'" "paramshadow"
scps_check_reject "err_effect_clone_param_shadow.vibe" "here: the call to 'pick'" "cloneparamshadow"
scps_check_reject "err_effect_match_binder_reshadow.vibe" "here: the call to 'pick'" "matchreshadow"
scps_check_reject "err_effect_for_binder_reshadow.vibe" "here: the call to 'pick'" "forreshadow"
scps_check_reject "err_effect_loop_binder_reshadow.vibe" "here: the call to 'pick'" "loopreshadow"
# #1721 P0: the third instance, in the REWRITE rather than the check. A local
# shadowing a needing fn had its call retargeted to that fn's CPS clone, so it
# performed instead of returning the local closure's value -- 1511 instead of
# 1507. The fixture's two halves (shadowed / renamed) must agree.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_shadowed_needing_local_test.vibe
# #1536: a `with e` callee is admitted when its declared parameters mention no
# function type anywhere -- there is then no argument able to instantiate the
# row variable, so the call cannot perform the handled effect. A callee that
# does take a function stays refused; that is what keeps this sound.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_rowvar_first_order_call_test.vibe
# #1727 gap 1: the HIGHER-ORDER companion is admitted too when every
# function-typed parameter receives a literal the pass proves inert -- the old
# rule read the callee alone, but whether `e` can become the handled effect is
# a property of what arrives at the call. The refusal still holds one step
# past it: an argument that is a NAME (err_effect_rowvar_hof_call).
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_rowvar_hof_inert_literal_test.vibe
# #1727 gap 2: a `for` iterand called through a LOCAL binding is proved from
# that binding's own declared return type. The #1714 guard was about reading a
# shadowed TOP-LEVEL declaration, not about locals -- so the shadowing shape is
# now ANSWERED (String semantics, 215) rather than refused. An undeclared local
# literal still proves nothing (cli_support_test.vibe pins that refusal).
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_for_local_binding_iterand_suspend_test.vibe
scps_check_reject "err_effect_rowvar_hof_call.vibe" "cannot see through" "rowvarhof"
# #1536 boundary, measured 2026-08-14. Both of these are narrower than the
# residual list implied, so they are pinned rather than described: a closure may
# capture a scalar param, an outer scalar let, or a function param (all compile)
# -- only capturing another LOCAL CLOSURE is refused. And a `for` iterand is
# lowered only when proved; an unannotated callee proves nothing.
# #1536: capturing a PROVABLY INERT local closure literal is admitted (we can
# see what the name holds); capturing a PERFORMING one stays refused, which is
# what keeps that sound -- it is the #1707 shape.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_capture_inert_local_closure_test.vibe
scps_check_reject "err_effect_capture_performing_closure.vibe" "hand the step object back as the value" "captureperforming"
# #1707 P0: a step-split literal may only land in a parameter whose row carries
# the effect. Passed to a plain-convention parameter it used to compile and
# silently return the step object as the value (5 -> 177, 15 -> 301).
scps_check_reject "err_effect_step_literal_plain_param.vibe" "hand the step object back as the value" "stepliteralplainparam"
scps_check_reject "err_effect_for_unproved_iterand.vibe" "let/seq/tail/branch-tail spine" "forunproved"
# A nested handle inside a compound is refused EARLIER, by the pre-existing
# see-through rule -- the linearization neither widens nor narrows it. Gated on
# THAT diagnostic, so the fixture cannot silently start passing for the other
# reason if the boundary ever moves.
scps_check_reject "err_effect_compound_nested_handle_suspend.vibe" "cannot see through" "compoundnestedhandle"
scps_check_reject "err_resume_non_tail.vibe" "must be the last expression of the handler arm" "nontail"
scps_check_reject "err_effect_resume_store_ineligible.vibe" "cannot see through" "inelig"
scps_check_reject "err_effect_closure_param_taint.vibe" "cannot see through" "inerttaint"
# Codex review on #1602: a candidate literal that CAPTURES a performing
# closure and launders it into an eff-free helper must stay rejected --
# only names bound within the literal are trusted by the inert scan.
scps_check_reject "err_effect_closure_param_capture_launder.vibe" "cannot see through" "inertlaunder"
# #1536: the former `break`-in-a-suspending-loop rejection now lives in the
# inspect snapshot suite above. Its arm stores `resume` and never resumes, so
# the first perform escapes with its value; the loop shape is what changed.
# #1261: an unannotated performing closure is row-backfilled by
# dlh_hoist_expr and so gets the evidence dict prepended; handing that value
# to a row-FREE fn-typed slot used to compile clean and trap at runtime with
# a wasm signature mismatch. Reject it, and keep the annotated form working.
scps_check_reject "err_effect_needing_value_escape.vibe" "passed as a VALUE into a slot whose type does not carry that row" "valesc"
# Annotated / eta-wrapped needing-value pins now live in
# fixtures/effect_needing_value_annotated_test.vibe and
# fixtures/effect_needing_value_escape_wrapped_test.vibe (#1973).
# #1380 / #1385 needing-call pins now live in
# fixtures/effect_needing_call_in_row_slot_test.vibe,
# fixtures/effect_needing_call_in_row_slot_capture_test.vibe,
# fixtures/effect_iife_needing_call_test.vibe, and
# fixtures/effect_trivial_wrapper_needing_call_test.vibe (#1973).
rm -rf "$scpsdir"
echo "[compiler-gate] ADR-0076 Phase 3a first-class resume ok"

# 51/51. #1097: a closure literal capturing a MATCH-BOUND payload used to
#        hold it as an unowned env borrow; when the wrapper escaped and
#        the scrutinee died with its lambda frame, a second suspend-shaped
#        site reused the freed block and the stored wrapper trapped.
#        compile_match now backs each capturing literal with one payload
#        dup (md_capturing_fn_count). Runs under the RC lane; want 38013
#        (r's + resumed values + the log digits — silent-corruption pin,
#        not just no-trap).
echo "[compiler-gate] 51/51 RC match-payload closure capture (#1097)"
rc1097dir="_build/_gate_rc_payload_capture"
rm -rf "$rc1097dir"; mkdir -p "$rc1097dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_match_payload_closure_capture_test.vibe "$rc1097dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1097dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture fixture did not compile" >&2
  cat "$rc1097dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1097_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1097dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture got '$rc1097_out' (want 38013) -- #1097 regressed" >&2
  echo "$rc1097_out" >&2
  exit 1
fi
rm -rf "$rc1097dir"
echo "[compiler-gate] RC match-payload closure capture (#1097) ok"

# #1272: a function returning an ELEMENT of a container it owns LOCALLY --
#        `Array::get` hands back an interior reference, so the local must be
#        retained-then-dropped, not dropped outright. Only `.field` used to
#        count as an escaping projection, so both shapes in the fixture
#        returned pointers into freed memory (silent until a later allocation
#        reused the cell: the two shapes summed to 12 and 207, not 45 and 300).
rc1272dir="_build/_gate_rc_local_elem_escape"
rm -rf "$rc1272dir"; mkdir -p "$rc1272dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_local_container_element_escape.vibe "$rc1272dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1272dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_local_container_element_escape fixture did not compile" >&2
  cat "$rc1272dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1272_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1272dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_local_container_element_escape got '$rc1272_out' (want 345) -- #1272 regressed" >&2
  echo "$rc1272_out" >&2
  exit 1
fi
rm -rf "$rc1272dir"
echo "[compiler-gate] RC local-container element escape (#1272) ok"

# #1230: `await` hoisted onto the AST spine (await_poll_pass) so a PENDING
#        future can raise a perform the effect passes still see. The fixture
#        puts awaits in let-value, match-scrutinee and nested-operand
#        positions, more than one of each -- splicing the expansion in place
#        instead of hoisting put an `ELet` in a `let` VALUE, which no source
#        program can write and which sent the compiler itself into unbounded
#        recursion once two appeared in one function.
awmdir="_build/_gate_await_multi"
rm -rf "$awmdir"; mkdir -p "$awmdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/async_await_multi.vibe "$awmdir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$awmdir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: async_await_multi fixture did not compile" >&2
  cat "$awmdir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! awm_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$awmdir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: async_await_multi got '$awm_out' (want 50) -- #1230 await hoist regressed" >&2
  echo "$awm_out" >&2
  exit 1
fi
rm -rf "$awmdir"
echo "[compiler-gate] multi-position await hoist (#1230) ok"

# #1230: the producer half -- Future::pending() / Future::resolve(f, v). Both
#        futures are resolved before they are awaited, so this pins the
#        representation and the two builtins rather than the scheduling (a
#        still-pending await needs a driver parking the continuation).
fpdir="_build/_gate_future_pending"
rm -rf "$fpdir"; mkdir -p "$fpdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/async_future_pending.vibe "$fpdir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$fpdir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_pending fixture did not compile" >&2
  cat "$fpdir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! fp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fpdir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: async_future_pending got '$fp_out' (want 42) -- #1230 pending producer regressed" >&2
  echo "$fp_out" >&2
  exit 1
fi
rm -rf "$fpdir"
echo "[compiler-gate] pending future producer (#1230) ok"

# 52/52. owned-captures ABI (ADR-0076 追記31 Vertical A): a closure env OWNS
#        its heap captures — creation-site dup + class-7 recursive drop.
#        The fixture generalizes #1097 beyond match payloads: a borrowed
#        view (Array::get) captured by an escaping closure survives the
#        owner's scope-end recursive drop. Under the old borrow model the
#        freed element block was reused by churn() and the escaped closure
#        read the reused contents (got 50067, silent corruption).
echo "[compiler-gate] 52/52 RC owned-captures escape (ADR-0076 追記31)"
rcocdir="_build/_gate_rc_owned_capture"
rm -rf "$rcocdir"; mkdir -p "$rcocdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_closure_owned_capture_escape.vibe "$rcocdir/esc.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$rcocdir/esc.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_closure_owned_capture_escape fixture did not compile" >&2
  cat "$rcocdir/esc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rcoc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rcocdir/esc.wasm" 2>/dev/null | tail -1)"
if [ "$rcoc_out" != "4067" ]; then
  echo "[compiler-gate] FAIL: rc_closure_owned_capture_escape got '$rcoc_out' (want 4067) -- owned-captures regressed" >&2
  exit 1
fi
rm -rf "$rcocdir"
echo "[compiler-gate] RC owned-captures escape ok"

# 53/53. closure-CPS ABI (ADR-0076 追記31 Vertical B): a suspending body
#        passed as a plain closure ARGUMENT into a library-side handle.
#        The literal is step-compiled at the call site and the handle body
#        bubbles the steps returned through its closure param (α-seeded
#        cps local). Positive pin 2130 (two-yield resume-value trace) +
#        the v1 convention guard (an untriggered handle for a
#        step-compiled effect is a hard error).
echo "[compiler-gate] 53/53 closure-CPS param suspend (ADR-0076 追記31)"
ccpsdir="_build/_gate_closure_cps"
rm -rf "$ccpsdir"; mkdir -p "$ccpsdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_cps_param.vibe "$ccpsdir/param.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ccpsdir/param.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_param fixture did not compile" >&2
  cat "$ccpsdir/param.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
ccps_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ccpsdir/param.wasm" 2>/dev/null | tail -1)"
if [ "$ccps_out" != "2130" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_param got '$ccps_out' (want 2130) -- closure-CPS regressed" >&2
  exit 1
fi
rm -f "$ccpsdir/mixed.wasm"
cp fixtures/err_effect_closure_cps_mixed_convention.vibe "$ccpsdir/mixed.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ccpsdir/mixed.vibe" "$ccpsdir/mixed.wasm" _start >/dev/null 2>&1 || true
if [ -s "$ccpsdir/mixed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_closure_cps_mixed_convention compiled (must be a hard error)" >&2
  exit 1
fi
if ! grep -qF "mixing the step convention" "$ccpsdir/mixed.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: mixed-convention fixture did not produce the expected diagnostic" >&2
  cat "$ccpsdir/mixed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1324: ordinary arithmetic on a value bound from a GENERIC suspend-lane
# callee must stay eligible. `v`'s syntactically inferable type is the type
# variable `T`, so desugar_trait_dict rewrites `v + 2` to `__generic_add`
# (#973) -- a registered pure builtin that was missing from
# idp_pure_builtin_names, which sank the whole literal to ineligible on the
# synthesized callee name alone. Positive pin 70.
rm -f "$ccpsdir/genop.wasm" "$ccpsdir/genop.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_cps_generic_operand.vibe "$ccpsdir/genop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ccpsdir/genop.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_generic_operand did not compile -- a pure desugar helper (__generic_add / __generic_rel_diff / str_lex_diff) sank a suspend-class closure literal again (#1324)" >&2
  cat "$ccpsdir/genop.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
ccps_genop_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ccpsdir/genop.wasm" 2>/dev/null | tail -1)"
if [ "$ccps_genop_out" != "70" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_generic_operand got '$ccps_genop_out' (want 70)" >&2
  exit 1
fi
rm -rf "$ccpsdir"
echo "[compiler-gate] closure-CPS param suspend ok"

# 54/54. type-directed closure evidence (ADR-0076 追記34 V1): the
#        hof_escaping shape (closure used as direct call AND by-value HOF
#        arg) migrates to evidence — the replay M2 side-effect duplication
#        is gone (hits 4 → 2, pinned via a row-free bump helper). The
#        guard makes an ineligible closure-value program a hard error
#        instead of a silent replay fallback.
echo "[compiler-gate] 54/54 type-directed closure evidence (ADR-0076 追記34)"
tdevdir="_build/_gate_td_evidence"
rm -rf "$tdevdir"; mkdir -p "$tdevdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_m2.vibe "$tdevdir/m2.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/m2.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_m2 fixture did not compile" >&2
  cat "$tdevdir/m2.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
tdev_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/m2.wasm" 2>/dev/null | tail -1)"
if [ "$tdev_out" != "2062" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_m2 got '$tdev_out' (want 2062; 2064 = replay M2 duplication returned)" >&2
  exit 1
fi
rm -f "$tdevdir/inelig.wasm"
cp fixtures/err_closure_value_evidence_ineligible.vibe "$tdevdir/inelig.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdevdir/inelig.vibe" "$tdevdir/inelig.wasm" _start >/dev/null 2>&1 || true
if [ -s "$tdevdir/inelig.wasm" ]; then
  echo "[compiler-gate] FAIL: err_closure_value_evidence_ineligible compiled (must be a hard error)" >&2
  exit 1
fi
if ! grep -qF "type-directed evidence" "$tdevdir/inelig.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: ineligible closure-value fixture did not produce the expected diagnostic" >&2
  cat "$tdevdir/inelig.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$tdevdir/multi.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_multi.vibe "$tdevdir/multi.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/multi.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_multi fixture did not compile" >&2
  cat "$tdevdir/multi.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
multi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/multi.wasm" 2>/dev/null | tail -1)"
if [ "$multi_out" != "33" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_multi got '$multi_out' (want 33; a blanket __ev_ guard drops __ev_B and the raw B perform escapes -- #1116 Codex P1)" >&2
  exit 1
fi
rm -f "$tdevdir/shadow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_shadow.vibe "$tdevdir/shadow.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_shadow fixture did not compile" >&2
  cat "$tdevdir/shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
shadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/shadow.wasm" 2>/dev/null | tail -1)"
if [ "$shadow_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_shadow got '$shadow_out' (want 42; a top-level pure fn sharing a name with a nested row-E closure must not get a stray evidence arg -- #1117 Codex P1)" >&2
  exit 1
fi
rm -rf "$tdevdir"
echo "[compiler-gate] type-directed closure evidence ok"

# 55/55. replay frontier removal (ADR-0076 追記34 V2): the replay engine is
#        gone from codegen. (a) A handle whose effect is never user-performed
#        anywhere (the host-row label-pun shape: the body calls the Env::get
#        BUILTIN directly, so the arms are dead) is erased by the
#        vacuous-handle elimination and the program compiles + runs. (b) A
#        live non-Error handle the evidence migration cannot reach is a HARD
#        error, never a silent fallback. (c) The shadowed-needing class
#        (gate 40ao, 47) now migrates via the seed-scoped α-rename +
#        local-literal call safety instead of parking on replay -- its pin
#        already asserts the value; this section pins the two new behaviors.
echo "[compiler-gate] 55/55 replay frontier removal (ADR-0076 追記34 V2)"
v2dir="_build/_gate_replay_removed"
rm -rf "$v2dir"; mkdir -p "$v2dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_vacuous_handle_erased.vibe "$v2dir/vacuous.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$v2dir/vacuous.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased fixture did not compile" >&2
  cat "$v2dir/vacuous.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! v2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$v2dir/vacuous.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased got '$v2_out' (want 46) -- vacuous-handle elimination regressed" >&2
  echo "$v2_out" >&2
  exit 1
fi
rm -f "$v2dir/reject.wasm"
cp fixtures/err_effect_handle_replay_removed.vibe "$v2dir/reject.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$v2dir/reject.vibe" "$v2dir/reject.wasm" _start >/dev/null 2>&1 || true
if [ -s "$v2dir/reject.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_handle_replay_removed compiled (a live unmigratable non-Error handle must be a hard error)" >&2
  exit 1
fi
# #1511 rewrote this message (actionable sentence first, ADR jargon last).
# Anchor on the identifying phrase rather than the trailing ADR note, which is
# the part most likely to be reworded again.
if ! grep -qF "cannot be compiled here" "$v2dir/reject.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: replay-removed reject fixture did not produce the expected diagnostic" >&2
  cat "$v2dir/reject.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$v2dir"
echo "[compiler-gate] replay frontier removal ok"

# 56/56. #1114: a nested closure calling a bare inlined-builtin name must
#        invoke an ENCLOSING local binding that shadows it, not the builtin.
#        The #773 skip only saw the innermost lambda's own binders + the
#        top-level fn table, so a parameter named `not`/`mul`/... was never
#        captured and the call silently produced the BUILTIN's value.
echo "[compiler-gate] 56/56 closure captures enclosing-scope shadow of an inlined builtin (#1114)"
csibdir="_build/_gate_closure_shadow_builtin"
rm -rf "$csibdir"; mkdir -p "$csibdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/closure_shadowed_inline_builtin.vibe "$csibdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$csibdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin.vibe did not compile" >&2
  cat "$csibdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! csib_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$csibdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin got '$csib_out' (want 28) -- either a shadowed inline builtin fell back to the builtin instead of the captured closure (#1114), or a non-recursive let binder was treated as an enclosing shadow inside its own initializer (#1120 Codex P1)" >&2
  echo "$csib_out" >&2
  exit 1
fi
rm -rf "$csibdir"
echo "[compiler-gate] closure shadowed inline builtin ok (28)"

# 57/57. #1078: an enum CONSTRUCTOR and an effect OPERATION that share a bare
#        name, declared by two UNRELATED packages, must still resolve to the
#        right declaration once BOTH are reachable in one merged program.
#        The reported failure ("argument type mismatch for Request: expected
#        RpcId, got Map[String, Json]") was specific to the merge/flatten
#        whole-program view -- ordinary FS-mode compilation never reproduced
#        it -- so this gate drives the REAL merge lane
#        (VIBE_EMIT_MERGED_SOURCE=1, the same mode generate_bundle.sh uses)
#        and then compiles its output, rather than compiling the sources
#        directly. Note the merge STRIPS the qualification: `Msg::Request(..)`
#        in a pattern comes out as bare `Request(..)`, which is exactly the
#        state the bare-name resolution has to get right.
echo "[compiler-gate] 57/57 merged-program ctor/effect-op name collision across packages (#1078)"
c1078dir="_build/_gate_ctor_effect_collision"
rm -rf "$c1078dir"; mkdir -p "$c1078dir/pkga" "$c1078dir/pkgb"
cat > "$c1078dir/pkga/index.vibe" <<'VEOF'
export enum Msg {
  Request(String, Int, Bool);
  Reply(Int)
}

export fn make_req(m: String, id: Int) -> Msg {
  Msg::Request(m, id, true)
}

export fn req_id(r: Msg) -> Int {
  match r {
    Msg::Request(_m, id, _f) => id,
    Msg::Reply(id) => id
  }
}
VEOF
cat > "$c1078dir/pkgb/index.vibe" <<'VEOF'
export effect Net {
  Request(String, String, String, String) -> Int
}

export fn fetch(url: String) -> Int with Net {
  perform Net::Request("GET", url, "", "")
}
VEOF
cat > "$c1078dir/main.vibe" <<'VEOF'
import ./pkga/index.vibe { Msg, make_req, req_id }
import ./pkgb/index.vibe { Net, fetch }

// BOTH declarations reachable from the exported entry: the enum ctor via
// make_req/req_id, the effect op via the handled fetch call.
export let main = () -> Int {
  let n = req_id(make_req("hello", 40))
  let f = handle {
    fetch("http://127.0.0.1:1/x")
  } with Net {
    Request(_m, _u, _h, _b) => resume(2)
  }
  n + f
}
VEOF
rm -f "$c1078dir/merged.vibe" "$c1078dir/merged.vibe.diag"
VIBE_EMIT_MERGED_SOURCE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1078dir/main.vibe" "$c1078dir/merged.vibe" main >/dev/null 2>&1 || true
if [ ! -s "$c1078dir/merged.vibe" ]; then
  echo "[compiler-gate] FAIL: merge/flatten of the ctor/effect-op collision program failed (#1078)" >&2
  cat "$c1078dir/merged.vibe.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1078dir/merged.vibe" "$c1078dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1078dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: merged ctor/effect-op collision program did not compile -- bare-name resolution picked the wrong declaration (#1078)" >&2
  cat "$c1078dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
c1078_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1078dir/out.wasm" 2>&1 | tail -1)"
if [ "$c1078_out" != "42" ]; then
  echo "[compiler-gate] FAIL: merged ctor/effect-op collision program got '$c1078_out' (want 42) -- #1078 regressed" >&2
  exit 1
fi
rm -rf "$c1078dir"
echo "[compiler-gate] merged ctor/effect-op collision ok (42)"

# 58/58. #906 Phase 2: the worker transport. A worker gets a job directory
# as its entire filesystem sandbox and must be able to check a module WITH
# imports, using dependency environments handed to it as values. Delegated
# because the interesting part is the negative controls -- an unresolved
# import is lenient, so the assertion has to be that the dependency's
# SIGNATURE arrived, not just its name.
echo "[compiler-gate] 58/58 module job dir worker transport (#906 Phase 2)"
if ! bash "$ROOT_DIR/scripts/module_job_dir_test.sh" "$stage2_wasm"; then
  echo "[compiler-gate] FAIL: module job dir worker transport regressed (#906 Phase 2)" >&2
  exit 1
fi

# 59/59. #1081 step 3: ADR-0068 region generativity. `TaskGroup::run`
# mints a fresh, compiler-rigid region skolem (hardcoded to this qualified
# name -- no general rank-2/`Region`-bound mechanism, see docs/
# concurrency.md's dated 実装ノート) and rejects the call if the region
# escapes via the body's return value. Positive: a plain spawn+join inside
# one nursery keeps compiling and running (region_ok_basic.vibe, 42).
# Negative: returning a `TaskHandle` obtained inside the nursery is a
# STATIC error (err_region_escape_return.vibe). Known gap, documented
# rather than silently claimed: an outer-capture check also runs (scans
# every binding visible at the call site after the body is checked), but
# this checker generalizes `let`/`let mut` bindings, so a leak into an
# already-generalized local `let mut` cell is NOT caught by this slice --
# only the return-position escape is a hard guarantee here.
echo "[compiler-gate] 59/59 ADR-0068 region generativity (#1081 step 3)"
regiondir="_build/_gate_region"
rm -rf "$regiondir"; mkdir -p "$regiondir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_basic.vibe "$regiondir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$regiondir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe did not compile -- plain non-escaping nursery use regressed" >&2
  cat "$regiondir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! region_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$regiondir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe got '$region_pos_out' (want 42)" >&2
  echo "$region_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_return.vibe "$regiondir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$regiondir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$regiondir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe did not produce the expected diagnostic" >&2
  cat "$regiondir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$regiondir"
echo "[compiler-gate] ADR-0068 region generativity ok"

echo "[compiler-gate] 60/60 deps missing-for-imports scan (#1145 follow-up 2)"
depsdir="_build/_gate_deps_scan"
rm -rf "$depsdir"; mkdir -p "$depsdir"
VIBE_DEPS_MISSING_SCAN=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ROOT_DIR" "$depsdir/scan.out" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$depsdir/scan.out" ]; then
  echo "[compiler-gate] FAIL: deps-missing scan produced no output" >&2
  cat "$depsdir/scan.out.diag" 2>/dev/null >&2
  exit 1
fi
if ! grep -q "^ok: no missing deps declarations" "$depsdir/scan.out"; then
  echo "[compiler-gate] FAIL: index.vpkg packages with deps missing an import's package (#1128/#1145):" >&2
  cat "$depsdir/scan.out" >&2
  exit 1
fi
rm -rf "$depsdir"
echo "[compiler-gate] deps missing-for-imports scan (#1145 follow-up 2) ok"

# 61/61. #1081 step 3 Phase B: `Spawnable[r]` capture check for
# `TaskGroup::spawn`/`TaskGroup::spawn_suspend`. Like `TaskGroup::run`
# above, hardcoded by literal qualified name (same alias/rename bypass
# caveat, see checker.vibe/docs/concurrency.md). A captured free variable
# must be structurally `Send`, or a `TaskGroup`/`TaskHandle`/`Sender`/
# `Receiver` endpoint tagged with THIS spawn call's own region. Positive: a
# same-region `Sender` capture through `Channel::bounded` keeps compiling
# and running (region_ok_spawnable_capture.vibe, 42) -- the exact "capture
# an endpoint from THIS nursery" case the roadmap calls out as
# inexpressible without regions. Negative: a plain outer `Array` capture
# (err_spawnable_capture_array.vibe), a `Sender` captured from a
# DIFFERENT (outer) nursery (err_spawnable_capture_cross_region.vibe), and
# a captured `let mut` binding regardless of its (Send) type, whether
# declared inside the run body (err_spawnable_capture_letmut.vibe) or in
# the ENCLOSING scope before calling TaskGroup::run
# (err_spawnable_capture_letmut_outer_scope.vibe, Codex review PR #1151
# P1) are all STATIC errors.
echo "[compiler-gate] 61/61 ADR-0068 Spawnable[r] capture check (#1081 step 3 Phase B)"
spawnabledir="_build/_gate_spawnable"
rm -rf "$spawnabledir"; mkdir -p "$spawnabledir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture.vibe "$spawnabledir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe did not compile -- same-region Sender capture regressed" >&2
  cat "$spawnabledir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! spawnable_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe got '$spawnable_pos_out' (want 42)" >&2
  echo "$spawnable_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_array.vibe "$spawnabledir/neg_array.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_array.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable` for `Array[Int]`' "$spawnabledir/neg_array.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_array.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_cross_region.vibe "$spawnabledir/neg_cross.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_cross.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable`' "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut.vibe "$spawnabledir/neg_letmut.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut_outer_scope.vibe "$spawnabledir/neg_letmut_outer.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut_outer.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# Codex review (PR #1152, P1): the whole-program `let mut` capture pass
# used to collect every `let mut` name reachable ANYWHERE in a top-level
# declaration into one flat, scope-blind list and cross-match by name
# alone -- so an unrelated `let mut x` in a sibling closure made a
# lexically-distinct, genuinely-immutable `x` captured elsewhere look
# mutable too. Must compile and run cleanly.
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture_shadowed_letmut.vibe "$spawnabledir/pos_shadow.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe did not compile -- scope-blind let-mut false positive regressed" >&2
  cat "$spawnabledir/pos_shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! spawnable_shadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_shadow.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe got '$spawnable_shadow_out' (want 42)" >&2
  echo "$spawnable_shadow_out" >&2
  exit 1
fi
# Codex review (PR #1152, P2): the whole-program `let mut` capture pass
# also used to lose the `[@off=...]` source-offset marker, degrading
# `vibe diagnostics`/LSP to an unlocated error. The located-diagnostics
# layer decodes `[@off=N:M]` into a `line L:C-C` range before writing the
# .diag file (confirmed empirically -- the raw `[@off=...]` marker itself
# never reaches this file), so check for THAT rendered form instead.
if ! grep -qE 'line [0-9]+:[0-9]+-[0-9]+' "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe diagnostic lost its located line:col-col source range" >&2
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$spawnabledir"
echo "[compiler-gate] ADR-0068 Spawnable[r] capture check ok"

# #1081 step 4 (surface polish): `taskgroup { g => body }` is pure parser
# sugar for `TaskGroup::run((g) -> { body })` -- no dedicated AST node, no
# desugar pass, no checker special-casing (docs/concurrency.md's naming
# note: the actually-implemented library type is `TaskGroup`, not the
# earlier illustrative `Nursery`/`Task`/`Spawn[r]` capability-effect
# design). Positive: the sugar compiles + runs identically to a
# hand-written `TaskGroup::run(...)` call. Negative: the EXISTING region-
# escape check (hardcoded by name on `TaskGroup::run`, unchanged by this
# sugar) still rejects a leaked `TaskHandle`.
echo "[compiler-gate] 62/67 ADR-0068 taskgroup { g => body } syntax sugar (#1081 step 4)"
taskgroupdir="_build/_gate_taskgroup_sugar"
rm -rf "$taskgroupdir"; mkdir -p "$taskgroupdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_taskgroup_sugar.vibe "$taskgroupdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$taskgroupdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe did not compile" >&2
  cat "$taskgroupdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! taskgroup_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$taskgroupdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe got '$taskgroup_pos_out' (want 42)" >&2
  echo "$taskgroup_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_taskgroup_sugar_region_escape.vibe "$taskgroupdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$taskgroupdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$taskgroupdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe did not produce the expected diagnostic" >&2
  cat "$taskgroupdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$taskgroupdir"
echo "[compiler-gate] taskgroup { g => body } syntax sugar ok"

# #906 (compiler self-parallelization prerequisite,
# docs/compiler-parallelism.md "FrozenArray"): FrozenArray[T] is a
# checker-only phantom-type distinction over Array[T]'s exact same runtime
# layout (mirrors ArrayBuilder's new/push/freeze technique, checker.vibe
# #938 -- from_array/to_array are pure identity casts, get/length alias
# Array::get/Array::length's own bodies). Its whole point is the Send
# judgment: checker_trait.vibe's send_ok_rec now has a
# CtNamed("FrozenArray", [elem]) arm recognizing it Send exactly when
# `elem` is, unlike Array[T] (permanently rejected, unaffected). Four
# fixtures: (1) region_ok_frozen_array_basic.vibe -- functional smoke test
# of from_array/get/length/to_array, compiled+run. (2)
# send_bound_frozen_array.vibe -- FrozenArray[Int] satisfies a `[T: Send]`
# bound, compiled+run. (3) err_type_send_frozen_array_of_array_bound.vibe
# -- the judgment truly recurses: FrozenArray[Array[Int]] (non-Send
# element) is still rejected. (4)
# region_ok_frozen_array_taskgroup_capture.vibe -- end-to-end: a
# `TaskGroup::spawn` closure capturing a FrozenArray[Int] built OUTSIDE
# the closure is Spawnable-legal (checker_spawnable.vibe falls back to
# type_send_ok), where the same capture of a plain Array[Int] is rejected
# (fixtures/err_spawnable_capture_array.vibe, gate 61 above, unaffected).
echo "[compiler-gate] 63/67 FrozenArray[T] Send-eligible immutable container (#906)"
frozenarrdir="_build/_gate_frozen_array"
rm -rf "$frozenarrdir"; mkdir -p "$frozenarrdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_frozen_array_basic.vibe "$frozenarrdir/basic.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/basic.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe did not compile" >&2
  cat "$frozenarrdir/basic.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! frozenarr_basic_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/basic.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe got '$frozenarr_basic_out' (want 42)" >&2
  echo "$frozenarr_basic_out" >&2
  exit 1
fi
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/send_bound_frozen_array.vibe "$frozenarrdir/send.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/send.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe did not compile -- FrozenArray[Int] Send acceptance regressed" >&2
  cat "$frozenarrdir/send.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! frozenarr_send_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/send.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe got '$frozenarr_send_out' (want 42)" >&2
  echo "$frozenarr_send_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_type_send_frozen_array_of_array_bound.vibe "$frozenarrdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$frozenarrdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Send` for `FrozenArray[Array[Int]]`' "$frozenarrdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe did not produce the expected diagnostic" >&2
  cat "$frozenarrdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_frozen_array_taskgroup_capture.vibe "$frozenarrdir/capture.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/capture.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe did not compile -- FrozenArray Spawnable capture regressed" >&2
  cat "$frozenarrdir/capture.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! frozenarr_capture_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/capture.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe got '$frozenarr_capture_out' (want 40)" >&2
  echo "$frozenarr_capture_out" >&2
  exit 1
fi
rm -rf "$frozenarrdir"
echo "[compiler-gate] FrozenArray[T] Send-eligible immutable container ok"

# 64/64. #639: effect-row mismatch diagnostic snapshots -- criterion 1 (no
#        'with' clause at all) and criterion 2 (a `handle` locally
#        discharges one effect while another stays genuinely missing; the
#        message must show the handled one folded into "declared" rather
#        than re-flagging it as missing). Pins the exact wording so it
#        can't silently drift; see #639's discussion for why the riskier
#        "over-declared with () is itself a hard error" reading was
#        deliberately NOT implemented.
echo "[compiler-gate] 64/67 effect-row mismatch diagnostic snapshots (#639)"
eff639dir="_build/_gate_eff639"
rm -rf "$eff639dir"; mkdir -p "$eff639dir"
cp fixtures/err_effect_missing_annotation.vibe "$eff639dir/no_with.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff639dir/no_with.vibe" "$eff639dir/no_with.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff639dir/no_with.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_missing_annotation.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Value } (no 'with' clause, requires { Ask::Value })" "$eff639dir/no_with.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_missing_annotation.vibe did not produce the expected diagnostic" >&2
  cat "$eff639dir/no_with.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cp fixtures/err_effect_handle_partial_discharge.vibe "$eff639dir/partial.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff639dir/partial.vibe" "$eff639dir/partial.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff639dir/partial.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_handle_partial_discharge.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Fs } (declared { Ask, Ask::Get }, requires { Ask, Ask::Get, Fs })" "$eff639dir/partial.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_handle_partial_discharge.vibe did not produce the expected diagnostic" >&2
  cat "$eff639dir/partial.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$eff639dir"
echo "[compiler-gate] effect-row mismatch diagnostic snapshots ok"

# 65/65. #1157: a zero-arg `perform Eff::Op` (no parens) previously bypassed
#        the direct effect-row check entirely (silent soundness gap -- see
#        #1157 for the repro). Pin that it is now rejected with the same
#        message as the parenthesized form.
echo "[compiler-gate] 65/67 zero-arg perform (no parens) effect-row check (#1157)"
eff1157dir="_build/_gate_eff1157"
rm -rf "$eff1157dir"; mkdir -p "$eff1157dir"
cp fixtures/err_effect_zero_arg_perform_no_parens.vibe "$eff1157dir/x.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff1157dir/x.vibe" "$eff1157dir/x.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff1157dir/x.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_zero_arg_perform_no_parens.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Get } (no 'with' clause, requires { Ask::Get })" "$eff1157dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_zero_arg_perform_no_parens.vibe did not produce the expected diagnostic" >&2
  cat "$eff1157dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$eff1157dir"
echo "[compiler-gate] zero-arg perform effect-row check ok"

# 66/66. #1161 (Codex review of #1157's fix): a DIRECT-discipline mismatch
#        must report the qualified operation, not the stripped base effect
#        name, when the enclosing function already declares a SIBLING
#        operation of the same effect at operation granularity -- otherwise
#        the generated fix-it would grant the whole effect and over-widen
#        the caller's capability surface (docs/effectset.md's operation-
#        level diagnostic contract).
echo "[compiler-gate] 66/67 operation-level fix-it precision for partial rows (#1161)"
eff1161dir="_build/_gate_eff1161"
rm -rf "$eff1161dir"; mkdir -p "$eff1161dir"
cp fixtures/err_effect_op_level_partial_row_bare_perform.vibe "$eff1161dir/x.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff1161dir/x.vibe" "$eff1161dir/x.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff1161dir/x.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Get } (declared { Ask::Other }, requires { Ask::Get, Ask::Other })" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected diagnostic" >&2
  cat "$eff1161dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -qF "hint: add 'with Ask::Get + Ask::Other' to 'asks'" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected operation-level fix-it hint" >&2
  cat "$eff1161dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$eff1161dir"
echo "[compiler-gate] operation-level fix-it precision ok"

# 67/67. #820 sub-item 3: `vibe context-pack` bundles docs/cheatsheet.md +
#        the verified eval/lang-review/golden corpus for AI-harness context
#        ingestion. Pure shell (scripts/gen_context_pack.sh), no wasm
#        involved -- pin determinism, the expected section markers, and the
#        missing-input error path.
#
#        Codex review (PR #1162): the pack's own text claims every golden
#        example "compiled and ran against the current compiler" -- that
#        claim must actually be re-verified against THIS gate run's stage2
#        (eval/lang-review/run_golden.sh, the existing writability
#        regression check), not just assumed still true. A compiler change
#        that broke a golden example without anyone re-running run_golden.sh
#        separately would otherwise ship a pack that lies about its own
#        examples.
echo "[compiler-gate] 67/67 vibe context-pack generator (#820 sub-item 3)"
if ! LANG_REVIEW_STAGE2="$stage2_wasm" bash eval/lang-review/run_golden.sh; then
  echo "[compiler-gate] FAIL: eval/lang-review/run_golden.sh -- the golden corpus context-pack bundles no longer compiles/runs as claimed" >&2
  exit 1
fi
# r4: the repair corpus is the measurement the `repair_convergence` score rests
# on (rubric dimension 8). It is a TWO-WAY ratchet -- a diagnostic that stops
# firing, whose wording drifts, OR that starts firing on a case recorded as
# silent all fail here, because each of those invalidates the recorded score.
if ! LANG_REVIEW_STAGE2="$stage2_wasm" bash eval/lang-review/run_repair.sh; then
  echo "[compiler-gate] FAIL: eval/lang-review/run_repair.sh -- the diagnostics the repair_convergence score was measured against changed; re-score in eval/lang-review/repair/README.md" >&2
  exit 1
fi
ctxpackdir="_build/_gate_ctxpack"
rm -rf "$ctxpackdir"; mkdir -p "$ctxpackdir"
bash scripts/gen_context_pack.sh "$ROOT_DIR" > "$ctxpackdir/a.md"
bash scripts/gen_context_pack.sh "$ROOT_DIR" > "$ctxpackdir/b.md"
if ! cmp -s "$ctxpackdir/a.md" "$ctxpackdir/b.md"; then
  echo "[compiler-gate] FAIL: gen_context_pack.sh is not deterministic" >&2
  exit 1
fi
if ! grep -qF "## Quick Start" "$ctxpackdir/a.md"; then
  echo "[compiler-gate] FAIL: context pack missing cheatsheet content" >&2
  exit 1
fi
if ! grep -qF "### 01_fizzbuzz" "$ctxpackdir/a.md"; then
  echo "[compiler-gate] FAIL: context pack missing golden example section" >&2
  exit 1
fi
if bash scripts/gen_context_pack.sh "$ctxpackdir" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: gen_context_pack.sh must fail on a dir with no docs/eval tree" >&2
  exit 1
fi
rm -rf "$ctxpackdir"
echo "[compiler-gate] vibe context-pack generator ok"

# 68/68. #1203: a linked (multi-file) program's top-level function can share
#        a bare name with an UNRELATED closure's own parameter declared in an
#        imported file (here, `compose`'s own `f`/`g` params) without the
#        closure silently losing that parameter from its capture list.
#        `collect_free_vars_expr_sc`'s plain EIdent case checked `fn_names`
#        (the whole linked program's top-level names, via a shared
#        capture-name index) BEFORE `encl` (the enclosing scope's own
#        locals) -- so `compose`'s own `f` parameter, referenced inside its
#        returned closure `(z) -> g(f(z))`, was wrongly treated as "already
#        global, no capture needed" whenever the merged program ALSO defined
#        an unrelated top-level `fn f()` anywhere (main.vibe below). The
#        returned closure's captured-environment struct then allocated one
#        field too few and silently dropped the store/load for `f`,
#        corrupting the wasm (invalid at instantiation) or, if it happened
#        to validate, producing a wrong runtime result instead of any
#        diagnostic. Single-file compiles never exercised this: only the
#        LINKED merge pipeline builds one shared name index across every
#        file, so this fixture must use a real cross-file import (matching
#        the smallest repro from the #1203 investigation trail), not the
#        `__DATA__` single-file fixture harness other closure-capture gates
#        above use.
echo "[compiler-gate] 68/68 closure param shadowing a same-named top-level fn in another linked file (#1203)"
c1203dir="_build/_gate_closure_param_shadows_toplevel"
rm -rf "$c1203dir"; mkdir -p "$c1203dir/pkg"
cat > "$c1203dir/pkg/lib.vibe" <<'VEOF'
export fn compose(f: (x: Int) -> Int, g: (y: Int) -> Int) -> (z: Int) -> Int {
  (z) -> g(f(z))
}
export fn addone(x: Int) -> Int { x + 1 }
export fn double(x: Int) -> Int { x * 2 }
VEOF
cat > "$c1203dir/main.vibe" <<'VEOF'
import ./pkg/lib.vibe { compose, addone, double }

// Unrelated top-level fn sharing a bare name with compose's own closure
// parameter (declared in the OTHER, imported file) -- never called, its
// mere presence in the linked program's name table is the trigger.
fn f() -> Int { 1 }

export let main = () -> Int {
  let c = compose(addone, double)
  c(3)
}
VEOF
rm -f "$c1203dir/out.wasm" "$c1203dir/out.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1203dir/main.vibe" "$c1203dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1203dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: closure-param/top-level-name collision program did not compile (#1203)" >&2
  cat "$c1203dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
c1203_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1203dir/out.wasm" 2>&1 | tail -1)"
if [ "$c1203_out" != "8" ]; then
  echo "[compiler-gate] FAIL: closure-param/top-level-name collision program got '$c1203_out' (want 8 = double(addone(3))) -- #1203 regressed (compose's own 'f'/'g' params silently dropped from its returned closure's captures)" >&2
  exit 1
fi
rm -rf "$c1203dir"
echo "[compiler-gate] closure param shadowing a same-named top-level fn ok (8)"

# 69/69. #1212 Codex review (P1): the #1203 fix above only covered `f`/`g`
#        used as a plain identifier / bare call callee. An enclosing `let
#        mut f` reassigned ONLY via `f = ...` / `f += ...` inside a returned
#        closure (never read as a plain EIdent) goes through
#        collect_free_vars_expr_sc's EAssign/EAssignOp cases instead, which
#        had the identical fn_names-before-encl precedence bug, checked
#        separately from the EIdent case -- so it needed its own fix and its
#        own end-to-end regression coverage, not just a unit-level check.
echo "[compiler-gate] 69/69 closure write-only capture of a let-mut shadowing a same-named top-level fn (#1203 follow-up, #1212 review)"
c1203bdir="_build/_gate_closure_assign_target_shadows_toplevel"
rm -rf "$c1203bdir"; mkdir -p "$c1203bdir/pkg"
cat > "$c1203bdir/pkg/lib.vibe" <<'VEOF'
export fn make_ticker() -> () -> Unit {
  let mut f = 0
  () -> {
    f += 1
  }
}
VEOF
cat > "$c1203bdir/main.vibe" <<'VEOF'
import ./pkg/lib.vibe { make_ticker }

// Unrelated top-level fn sharing a bare name with the enclosing `let mut f`
// that the returned closure ONLY writes to (never reads as a plain
// identifier) -- never called, its mere presence in the linked program's
// name table is the trigger.
fn f() -> Int { 1 }

export let main = () -> Int {
  let t = make_ticker()
  t()
  t()
  0
}
VEOF
rm -f "$c1203bdir/out.wasm" "$c1203bdir/out.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1203bdir/main.vibe" "$c1203bdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1203bdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: write-only closure capture / top-level-name collision program did not compile (#1203 follow-up) -- #1212 review regressed" >&2
  cat "$c1203bdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
c1203b_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1203bdir/out.wasm" 2>&1 | tail -1)"
if [ "$c1203b_out" != "0" ]; then
  echo "[compiler-gate] FAIL: write-only closure capture / top-level-name collision program got '$c1203b_out' (want 0) -- #1212 review regressed" >&2
  exit 1
fi
rm -rf "$c1203bdir"
echo "[compiler-gate] closure write-only capture shadowing a same-named top-level fn ok"

# 70/70. inspect() snapshot auto-update tool regression lock (#1061 follow-up,
#        docs/adr.md #0087): scripts/vibe_inspect_update.sh reads a failing
#        `inspect(value, content)` run's "actual/expected" diagnostic and
#        rewrites the stale `content` literal in place. Lock both the
#        multi-call convergence loop (two wrong snapshots in one file, fixed
#        across two compile/run/patch iterations) and that a clean file is
#        left untouched (exits 0, reports "already up to date", no rewrite).
echo "[compiler-gate] 70/70 inspect() snapshot auto-update mode (#1061 follow-up, vibe test --update)"
# VIBE_INSPECT_UPDATE=1 is cli_adapter.vibe::cli_main's low-level mode behind
# `vibe test --update` (runtime/vibe's `test)` case) -- same (input_path,
# output_path) + extra-env-var-for-a-second-path convention as
# VIBE_NORMALIZE/VIBE_TYPE_AT right above it in that file. Exercised here the
# same way those are: directly against the stage2 wasm via
# run_wasm_vibe_host_runner.sh, without needing an installed viberun/vibe-cli
# toolchain layout. Locks both the call-scoped patch (an unrelated earlier
# literal with the same text is left untouched -- #1235 review P1) and that
# an already-correct file's inspect() calls round-trip unchanged (P2's
# trailing-newline handling: a snapshot ending in "\n" survives one patch
# pass byte-identical to the true actual value).
inspupddir="_build/_gate_inspect_update"
rm -rf "$inspupddir"; mkdir -p "$inspupddir"
cat > "$inspupddir/demo.vibe" <<'VEOF'
import ../../lib/@vibe/core { inspect }

let label = "old"

test "demo" {
  inspect(String::concat("line1", "\n"), "old")
  assert(label == "old")
}
VEOF
cat > "$inspupddir/captured.txt" <<'VEOF'
inspect mismatch:
  actual:   line1

  expected: old
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INSPECT_UPDATE=1 VIBE_INSPECT_UPDATE_STDOUT="$inspupddir/captured.txt" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspupddir/demo.vibe" "$inspupddir/patched.vibe" >/dev/null 2>&1 || true
if [ ! -s "$inspupddir/patched.vibe" ]; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE mode produced no output" >&2
  exit 1
fi
if ! grep -q 'inspect(String::concat("line1", "\\n"), "line1\\n")' "$inspupddir/patched.vibe" || ! grep -q 'let label = "old"' "$inspupddir/patched.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE patched to unexpected content (unrelated literal touched, or trailing-newline snapshot mishandled)" >&2
  cat "$inspupddir/patched.vibe" >&2
  exit 1
fi
# A run whose captured output has no recognizable mismatch leaves the source
# byte-identical (echoed back via output_path, not an error).
printf 'unrelated crash output\nRuntimeError: unreachable\n' > "$inspupddir/nomatch.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INSPECT_UPDATE=1 VIBE_INSPECT_UPDATE_STDOUT="$inspupddir/nomatch.txt" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspupddir/demo.vibe" "$inspupddir/unchanged.vibe" >/dev/null 2>&1 || true
if ! cmp -s "$inspupddir/demo.vibe" "$inspupddir/unchanged.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE rewrote a file despite no recognizable mismatch" >&2
  exit 1
fi
rm -rf "$inspupddir"
echo "[compiler-gate] inspect() snapshot auto-update mode ok"

# 71/71. #1239 step 4(A): an import cycle is rejected by the coordinator-side
#        upfront plan -- @vibe/compiler/module_graph's plan_module_order, wired into
#        runtime/typecheck_fs.vibe's ensure_fingerprint_fs_impl -- BEFORE any
#        module is committed, rather than incidentally partway through the
#        walk on whichever module the DFS happened to re-enter first.
#
#        What makes that observable is the persistent cache. The old inline
#        "currently visiting" stack check could only fire after
#        ensure_fingerprint_fs_go had already written each module's dep list
#        on the way down, so a cyclic pair left dep-list entries behind; the
#        upfront pass resolves the whole graph without committing anything,
#        so a cyclic pair now leaves none. Measured on this exact fixture at
#        cb16be5 (before the wiring) vs after: 2 dep-list files -> 0.
#
#        The acyclic control is what gives the 0 its meaning: same file
#        shape, same isolated cache dir, and it DOES write dep lists. Without
#        it, "0 files" would also pass if dep lists simply stopped being
#        written at all.
echo "[compiler-gate] 71/71 import cycle rejected before any module is committed (#1239 step 4A)"
cycdir="_build/_gate_import_cycle"
rm -rf "$cycdir"; mkdir -p "$cycdir/cyclic" "$cycdir/acyclic" "$cycdir/cache_cyclic" "$cycdir/cache_acyclic"
printf 'import ./b.vibe { bee }\nexport let _start = () -> Int { bee() }\n' > "$cycdir/cyclic/a.vibe"
printf 'import ./a.vibe { _start }\nexport let bee = () -> Int { 42 }\n' > "$cycdir/cyclic/b.vibe"
printf 'import ./b.vibe { bee }\nexport let _start = () -> Int { bee() }\n' > "$cycdir/acyclic/a.vibe"
printf 'export let bee = () -> Int { 42 }\n' > "$cycdir/acyclic/b.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$cycdir/cache_cyclic" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cycdir/cyclic/a.vibe" "$cycdir/cyclic/a.wasm" _start >/dev/null 2>&1 && cyc_rc=0 || cyc_rc=$?
if [ "$cyc_rc" = "0" ]; then
  echo "[compiler-gate] FAIL: a cyclic import pair compiled successfully -- the cycle rejection is gone" >&2
  exit 1
fi
cyc_deps="$(find "$cycdir/cache_cyclic" -name 'vibe_selfhost_dep_list_*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$cyc_deps" != "0" ]; then
  echo "[compiler-gate] FAIL: rejecting a cyclic import pair left $cyc_deps dep-list cache entries behind (want 0) -- modules are being committed before the upfront plan rejects the cycle" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$cycdir/cache_acyclic" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cycdir/acyclic/a.vibe" "$cycdir/acyclic/a.wasm" _start >/dev/null 2>&1
acyc_deps="$(find "$cycdir/cache_acyclic" -name 'vibe_selfhost_dep_list_*' 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -s "$cycdir/acyclic/a.wasm" ] || [ "$acyc_deps" = "0" ]; then
  echo "[compiler-gate] FAIL: the acyclic control did not compile (wasm present: $([ -s "$cycdir/acyclic/a.wasm" ] && echo yes || echo no)) or wrote no dep lists ($acyc_deps) -- the cyclic assertion above proves nothing" >&2
  exit 1
fi
rm -rf "$cycdir"
echo "[compiler-gate] import cycle rejected before any commit ok (cyclic 0 dep lists, acyclic $acyc_deps)"

# 72/72. #1239 step 4(D): VIBE_MODULE_PLAN must describe the SAME graph the
#        per-file VIBE_LIST_DEPS loop it replaces described.
#
#        The host-side parallel pre-warm (scripts/parallel_frontend_warm.mjs)
#        used to spawn one compiler per module to discover the import DAG;
#        it now takes the whole graph, already in canonical rank order, from
#        one VIBE_MODULE_PLAN call. That is only safe while the two agree,
#        and disagreement would not fail loudly -- it would silently warm a
#        cache for the wrong graph. So the old per-file mode is kept as the
#        oracle here and diffed against the new one.
#
#        Two checks, split by cost. On the fixture (the leaf/mid/main
#        diamond, where main imports leaf both directly and through mid) the
#        agreement is EXACT: same dep rows in declaration order, duplicates
#        included, and byte-identical ingested source. On this repo's own
#        compiler graph the oracle would need ~200 process spawns, so that
#        one is checked structurally instead, from the plan alone: every
#        dependency must itself be a planned module with a strictly smaller
#        rank. That is the property a wave-at-a-time dispatcher relies on.
echo "[compiler-gate] 72/72 VIBE_MODULE_PLAN agrees with the per-file VIBE_LIST_DEPS graph (#1239 step 4D)"
plandir="_build/_gate_module_plan"
rm -rf "$plandir"; mkdir -p "$plandir/src"
cp scripts/fixtures/parallel_project_sample/leaf.vibe \
   scripts/fixtures/parallel_project_sample/mid.vibe \
   scripts/fixtures/parallel_project_sample/main.vibe "$plandir/src/"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_MODULE_PLAN=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$plandir/src/main.vibe" "$plandir/plan.txt" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$plandir/plan.txt" ]; then
  echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN produced no manifest$([ -s "$plandir/plan.txt.diag" ] && echo ": $(cat "$plandir/plan.txt.diag")")" >&2
  exit 1
fi
plan_mods="$(awk -F'\t' '$1=="module"{print $2"\t"$4}' "$plandir/plan.txt")"
if [ "$(echo "$plan_mods" | grep -c .)" != "3" ]; then
  echo "[compiler-gate] FAIL: expected 3 planned modules for the leaf/mid/main fixture, got:" >&2
  cat "$plandir/plan.txt" >&2
  exit 1
fi
while IFS="$(printf '\t')" read -r idx modpath; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_LIST_DEPS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$modpath" "$plandir/ld$idx.out" __no_entry__ >/dev/null 2>&1
  awk -F'\t' -v i="$idx" '$1=="dep" && $2==i{print $3}' "$plandir/plan.txt" > "$plandir/plan$idx.deps"
  grep -v '^[[:space:]]*$' "$plandir/ld$idx.out" > "$plandir/ld$idx.deps" || true
  if ! cmp -s "$plandir/plan$idx.deps" "$plandir/ld$idx.deps"; then
    echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN and VIBE_LIST_DEPS disagree on $modpath's dependencies" >&2
    diff "$plandir/ld$idx.deps" "$plandir/plan$idx.deps" >&2 || true
    exit 1
  fi
  if ! cmp -s "$plandir/ld$idx.out.src" "$plandir/plan.txt.$idx.src"; then
    echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN and VIBE_LIST_DEPS disagree on $modpath's INGESTED source -- a driver would check different text than the serial walk" >&2
    exit 1
  fi
done <<PLANMODS
$plan_mods
PLANMODS
echo "[compiler-gate] module plan matches per-file discovery on the fixture (3 modules)"
# Structural check on a real graph: one spawn, no oracle needed.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_MODULE_PLAN=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  lib/@vibe/compiler/tests/codegen_lexer_test.vibe "$plandir/big.txt" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$plandir/big.txt" ]; then
  echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN produced no manifest for the compiler's own graph$([ -s "$plandir/big.txt.diag" ] && echo ": $(cat "$plandir/big.txt.diag")")" >&2
  exit 1
fi
plan_check="$(awk -F'\t' '
  $1=="module"{ rank[$4]=$3; idxpath[$2]=$4; n++ }
  $1=="dep"{ dep[++d]=$2 "\t" $3 }
  END{
    bad=0
    for (k=1; k<=d; k++) {
      split(dep[k], parts, "\t")
      importer=idxpath[parts[1]]; target=parts[2]
      if (!(target in rank)) { print "unplanned dependency: " importer " -> " target; bad++ }
      else if (rank[target]+0 >= rank[importer]+0) { print "rank not strictly decreasing: " importer " (" rank[importer] ") -> " target " (" rank[target] ")"; bad++ }
    }
    if (bad==0) print "ok " n
  }' "$plandir/big.txt")"
case "$plan_check" in
  ok\ *) echo "[compiler-gate] module plan rank invariant holds ($(echo "$plan_check" | cut -d' ' -f2) modules)" ;;
  *) echo "[compiler-gate] FAIL: module plan rank invariant violated -- a wave-at-a-time dispatcher would run a module before its dependency:" >&2
     echo "$plan_check" | head -5 >&2
     exit 1 ;;
esac
rm -rf "$plandir"
echo "[compiler-gate] VIBE_MODULE_PLAN agrees with per-file discovery ok"

# 73/73. Bytes::append on the wasm-gc lane, actually RUN.
#
#        Both backends share gen_bytes_append_body (a `Bytes` lives in linear
#        memory on the gc lane too -- gen_bytes_push_body is shared as well),
#        but codegen_bytes_test.vibe's gc cases only assert the module
#        VALIDATES. Nothing executed an append on the gc backend, so a change
#        to that shared generator could pass every gc test while producing a
#        module that computes the wrong bytes.
#
#        The fixture exercises the two paths the small appends elsewhere never
#        reach: crossing the initial capacity of 64 (so the grow branch runs)
#        and appending a buffer to ITSELF (source and destination alias). Its
#        checksum is position-weighted, so a copy landing at the wrong offset
#        or with the wrong length changes it -- a plain sum would not.
echo "[compiler-gate] 73/73 wasm-gc backend runs Bytes::append (grow + self-alias)"
bagdir="_build/_gate_bytes_append_gc"
rm -rf "$bagdir"; mkdir -p "$bagdir"
for bag_be in gc linear; do
  bag_env=""
  [ "$bag_be" = "gc" ] && bag_env="VIBE_BACKEND=gc"
  env $bag_env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_bytes_append_grow.vibe" "$bagdir/$bag_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$bagdir/$bag_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_bytes_append_grow.vibe did not compile on the $bag_be backend" >&2
    cat "$bagdir/$bag_be.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  bag_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$bagdir/$bag_be.wasm" 2>&1 | tail -1)"
  if [ "$bag_out" != "4027170" ]; then
    echo "[compiler-gate] FAIL: Bytes::append on the $bag_be backend got '$bag_out' (want 4027170) -- a grow or an aliased append copied the wrong bytes" >&2
    exit 1
  fi
done
rm -rf "$bagdir"
echo "[compiler-gate] Bytes::append runs correctly on both backends ok (4027170)"

# 74/74. #1259 (#1239 step 5's prerequisite): cross-module diagnostic
#        collection, and its canonical order.
#
#        The fs walk used to throw on the FIRST module diagnostic, so step 5's
#        "sort diagnostics into a canonical order and compare across jobs"
#        had nothing to sort. VIBE_DIAGNOSTICS_ALL=1 collects one diagnostic
#        per failing module instead; off (the default) is unchanged.
#
#        The fixture is two INDEPENDENT bad leaves plus a main that imports
#        both. Independent matters: they land in the same wave, so neither
#        failure removes any input the other needs, and both must be reported.
#        main must NOT be -- it is blocked, and a "no binding a" cascade on
#        top of the real error is exactly the noise a canonical set excludes.
#
#        Order is checked against VIBE_DEP_ORDER_SEED, the #906 Phase 0
#        within-wave permutation. That is the one knob that reproduces what a
#        parallel coordinator varies between runs, so byte-identical output
#        across seeds is the property step 5 actually wants; without the sort,
#        collection order leaks through and the seeds disagree.
echo "[compiler-gate] 74/74 cross-module diagnostics collected in canonical order (#1259)"
dcolldir="_build/_gate_diag_collect"
rm -rf "$dcolldir"; mkdir -p "$dcolldir/src" "$dcolldir/cache"
printf 'export let a: Int = "alpha is not an Int"\n' > "$dcolldir/src/alpha.vibe"
printf 'export let b: Int = "beta is not an Int"\n' > "$dcolldir/src/beta.vibe"
printf 'import ./alpha.vibe { a }\nimport ./beta.vibe { b }\nexport let _start = () -> Int { a + b }\n' > "$dcolldir/src/main.vibe"
# Each run gets a pristine cache dir: a persistent type env published by an
# earlier run would let the next one skip a module and report fewer
# diagnostics, which would make the comparisons below vacuous.
run_diag_collect() {
  # $1 = output tag, $2.. = extra env assignments
  local tag="$1"; shift
  rm -rf "$dcolldir/cache_$tag"; mkdir -p "$dcolldir/cache_$tag"
  env "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$dcolldir/cache_$tag" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dcolldir/src/main.vibe" "$dcolldir/$tag.wasm" _start >/dev/null 2>&1 || true
  grep -c . "$dcolldir/$tag.wasm.diag" 2>/dev/null || echo 0
}
diag_default_lines="$(run_diag_collect default)"
if [ "$diag_default_lines" != "1" ]; then
  echo "[compiler-gate] FAIL: the default walk reported $diag_default_lines diagnostic lines (want 1) -- fail-fast is supposed to be unchanged without VIBE_DIAGNOSTICS_ALL" >&2
  cat "$dcolldir/default.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
diag_all_lines="$(run_diag_collect all VIBE_DIAGNOSTICS_ALL=1)"
if [ "$diag_all_lines" != "2" ]; then
  echo "[compiler-gate] FAIL: VIBE_DIAGNOSTICS_ALL=1 reported $diag_all_lines diagnostic lines (want 2: one per independent bad leaf, none for the blocked importer)" >&2
  cat "$dcolldir/all.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if [ "$(sed -n 1p "$dcolldir/all.wasm.diag" | grep -c 'alpha\.vibe')" != "1" ] || \
   [ "$(sed -n 2p "$dcolldir/all.wasm.diag" | grep -c 'beta\.vibe')" != "1" ]; then
  echo "[compiler-gate] FAIL: collected diagnostics are not in canonical (module path) order -- want alpha.vibe then beta.vibe:" >&2
  cat "$dcolldir/all.wasm.diag" >&2
  exit 1
fi
if grep -q 'main\.vibe' "$dcolldir/all.wasm.diag"; then
  echo "[compiler-gate] FAIL: the blocked importer produced a cascade diagnostic -- only the two real failures belong in the set:" >&2
  cat "$dcolldir/all.wasm.diag" >&2
  exit 1
fi
for diag_seed in 1 7 23; do
  run_diag_collect "seed$diag_seed" VIBE_DIAGNOSTICS_ALL=1 VIBE_DEP_ORDER_SEED="$diag_seed" >/dev/null
  if ! cmp -s "$dcolldir/all.wasm.diag" "$dcolldir/seed$diag_seed.wasm.diag"; then
    echo "[compiler-gate] FAIL: collected diagnostics changed under VIBE_DEP_ORDER_SEED=$diag_seed -- the within-wave visit order is leaking through the canonical sort" >&2
    diff "$dcolldir/all.wasm.diag" "$dcolldir/seed$diag_seed.wasm.diag" >&2 || true
    exit 1
  fi
done
# Vacuity guard for the loop above: prove seed 7 actually REORDERS this wave,
# so "identical across seeds" means the sort held rather than the seed being
# inert. Fail-fast reports whichever module the wave visited first, so at
# seed 7 it must report beta -- the opposite of the unseeded run's alpha.
run_diag_collect ffseed VIBE_DEP_ORDER_SEED=7 >/dev/null
if ! grep -q 'beta\.vibe' "$dcolldir/ffseed.wasm.diag"; then
  echo "[compiler-gate] FAIL: VIBE_DEP_ORDER_SEED=7 did not reorder the two-module wave (fail-fast still reported alpha first) -- the seed-invariance check above proves nothing" >&2
  cat "$dcolldir/ffseed.wasm.diag" >&2
  exit 1
fi
# The control: with collection on and NOTHING wrong, the same shape still
# compiles. Without this, every assertion above would also pass if
# VIBE_DIAGNOSTICS_ALL had simply broken the compiler.
printf 'export let a: Int = 1\n' > "$dcolldir/src/alpha.vibe"
printf 'export let b: Int = 2\n' > "$dcolldir/src/beta.vibe"
rm -rf "$dcolldir/cache_ok"; mkdir -p "$dcolldir/cache_ok"
VIBE_DIAGNOSTICS_ALL=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$dcolldir/cache_ok" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dcolldir/src/main.vibe" "$dcolldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$dcolldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: a clean project failed to compile with VIBE_DIAGNOSTICS_ALL=1" >&2
  cat "$dcolldir/ok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
diag_ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$dcolldir/ok.wasm" 2>&1 | tail -1)"
if [ "$diag_ok_out" != "3" ]; then
  echo "[compiler-gate] FAIL: the clean control got '$diag_ok_out' (want 3) with VIBE_DIAGNOSTICS_ALL=1" >&2
  exit 1
fi
rm -rf "$dcolldir"
echo "[compiler-gate] cross-module diagnostic collection ok (1 fail-fast, 2 collected, seed-invariant)"
# 75/75. ADR-0090 Phase 1 (#1262): `region r { body }` + MutList[T, r]
# vertical slice. The parser lowers the syntax to the reserved
# `__region_run((r) -> { body })`; the checker mints a rigid `#region_N`
# skolem for the binder and scans fully-zonked return/outer-binding types
# for escapes; MutList is a checker-only phantom over the ArrayBuilder
# runtime layout (freeze/to_array are the sanctioned exits). Positive:
# build a MutList inside the region, freeze, read it outside -- compiles
# and returns 42 (region_arena_ok.vibe). Negative: returning the
# region-tainted MutList itself out of the region body is a STATIC error
# (err_region_escape_return_value.vibe). Same known generalize-gap caveat
# as the ADR-0068 section above: the return-position escape is the hard
# guarantee in this slice. #1725 added the closure-capture direction, which
# the result-TYPE scan structurally cannot see (types do not record
# captures) -- both a negative and a false-positive guard, at the end.
echo "[compiler-gate] 75/75 ADR-0090 region + MutList/MutBytes vertical slice (#1262 / #1770)"
r90dir="_build/_gate_region90"
rm -rf "$r90dir"; mkdir -p "$r90dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_ok.vibe "$r90dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_arena_ok.vibe did not compile -- ADR-0090 region/MutList slice regressed" >&2
  cat "$r90dir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_arena_ok.vibe got '$r90_pos_out' (want 42)" >&2
  echo "$r90_pos_out" >&2
  exit 1
fi
cp fixtures/err_region_escape_return_value.vibe "$r90dir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$r90dir/neg.vibe" "$r90dir/neg.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_return_value.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_return_value.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1274 Codex P1: the token is unforgeable -- MutList::empty with a
# non-skolem argument must be rejected.
cp fixtures/err_region_token_forged.vibe "$r90dir/forged.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$r90dir/forged.vibe" "$r90dir/forged.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/forged.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_token_forged.vibe compiled successfully -- the region token must be unforgeable" >&2
  exit 1
fi
if ! grep -qF 'region token' "$r90dir/forged.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_token_forged.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/forged.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1725: the return-position check above scans the region body's RESULT TYPE
# for the skolem, so a region value hidden in a CLOSURE's captured
# environment slips past it -- the result type `() -> Array[Int]` mentions no
# region. These two fixtures pin BOTH directions, which is the whole
# difficulty: capture is legitimate, only escape is not.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_closure_capture.vibe "$r90dir/cap.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/cap.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_closure_capture.vibe compiled successfully -- a region value must not escape inside a closure (#1725)" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/cap.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_closure_capture.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/cap.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The sharper negative: the escaping closure holds the region TOKEN, with no
# outer binding for a spine walk to find.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_token_capture.vibe "$r90dir/tok.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/tok.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_token_capture.vibe compiled successfully -- a closure holding the region token must not escape (#1725)" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/tok.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_token_capture.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/tok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1938: capture provenance is part of the checked function type, not a
# terminal-lambda syntax check. Pin every laundering shape that the old
# stopgap missed (plus a deep alias witness).
for r90_fixture in \
  fixtures/err_region_escape_outer_assignment.vibe \
  fixtures/err_region_escape_container.vibe \
  fixtures/err_region_escape_helper.vibe \
  fixtures/err_region_escape_global_helper.vibe \
  fixtures/err_region_escape_multiple_regions.vibe \
  fixtures/err_region_escape_nested_closure.vibe \
  fixtures/err_region_escape_alias_chain.vibe \
  fixtures/err_region_escape_monomorphic_callback.vibe \
  fixtures/err_region_escape_array_write.vibe \
  fixtures/err_region_escape_field_write.vibe \
  fixtures/err_region_escape_record.vibe \
  fixtures/err_region_escape_generic_defer.vibe \
  fixtures/err_region_escape_named_struct.vibe \
  fixtures/err_region_escape_mutlist_write.vibe \
  fixtures/err_region_escape_array_alias_write.vibe \
  fixtures/err_region_escape_local_callee.vibe \
  fixtures/err_region_escape_callback_defer.vibe \
  fixtures/err_region_escape_named_projection.vibe \
  fixtures/err_region_escape_named_projection_alias.vibe \
  fixtures/err_region_escape_call_alias_write.vibe \
  fixtures/err_region_escape_inline_projection.vibe \
  fixtures/err_region_escape_inline_call_alias_write.vibe \
  fixtures/err_region_escape_aggregate_struct.vibe \
  fixtures/err_region_escape_callback_return.vibe \
  fixtures/err_region_escape_early_return.vibe \
  fixtures/err_region_escape_generalized_local_callee.vibe \
  fixtures/err_region_escape_direct_call_alias_write.vibe \
  fixtures/err_region_escape_alias_result.vibe \
  fixtures/err_region_escape_conditional_alias_result.vibe \
  fixtures/err_region_escape_multi_payload_constructor.vibe \
  fixtures/err_region_escape_enum_alias.vibe \
  fixtures/err_region_escape_enum_container.vibe \
  fixtures/err_region_escape_enum_outer_assignment.vibe \
  fixtures/err_region_escape_enum_payload.vibe \
  fixtures/err_region_escape_struct_alias.vibe \
  fixtures/err_region_escape_struct_container.vibe \
  fixtures/err_region_escape_constructor_helper.vibe \
  fixtures/err_region_escape_bound_struct.vibe \
  fixtures/err_region_escape_mutmap_write.vibe \
  fixtures/err_region_escape_deque_write.vibe \
  fixtures/err_region_escape_option_aggregate.vibe \
  fixtures/err_region_escape_result_aggregate.vibe \
  fixtures/err_region_escape_enum_aggregate.vibe \
  fixtures/err_region_escape_deque_dot_write.vibe \
  fixtures/err_region_escape_param_forwarding.vibe \
  fixtures/err_region_escape_nested_tuple_param.vibe \
  fixtures/err_region_escape_nested_record_param.vibe \
  fixtures/err_region_escape_nested_nominal_param.vibe \
  fixtures/err_region_escape_named_struct_bound.vibe \
  fixtures/err_region_escape_named_struct_field_alias.vibe \
  fixtures/err_region_escape_mutmap_key_write.vibe \
  fixtures/err_region_escape_mutmap_value_write.vibe \
  fixtures/err_region_escape_mutset_write.vibe \
  fixtures/err_region_escape_sortedmap_key_write.vibe \
  fixtures/err_region_escape_sortedmap_value_write.vibe \
  fixtures/err_region_escape_sortedset_write.vibe \
  fixtures/err_region_escape_priority_queue_write.vibe \
  fixtures/err_region_escape_deque_back_write.vibe \
  fixtures/err_region_escape_deque_front_write.vibe \
  fixtures/err_region_escape_hashmap_alias_write.vibe \
  fixtures/err_region_escape_hashset_alias_write.vibe \
  fixtures/err_region_escape_sortedmap_alias_write.vibe \
  fixtures/err_region_escape_sortedset_alias_write.vibe; do
  r90_escape="${r90_fixture#fixtures/err_region_escape_}"
  r90_escape="${r90_escape%.vibe}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$r90_fixture" "$r90dir/${r90_escape}.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$r90dir/${r90_escape}.wasm" ]; then
    echo "[compiler-gate] FAIL: $r90_fixture compiled successfully -- region capture provenance was lost (#1938)" >&2
    exit 1
  fi
  if ! grep -qF 'region escapes its scope' "$r90dir/${r90_escape}.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $r90_fixture did not produce the expected diagnostic (#1938)" >&2
    cat "$r90dir/${r90_escape}.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done

# The false-positive guard: a closure that captures a region value but stays
# inside the region is valid, and the body still exits via freeze. It also
# covers shadowing and an initialiser that merely touches the token while
# evaluating to a scalar -- both shapes an over-eager taint rule rejects.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_closure_local.vibe "$r90dir/caplocal.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/caplocal.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe did not compile -- the #1725 capture check is over-approximating" >&2
  cat "$r90dir/caplocal.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_cap_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/caplocal.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe got '$r90_cap_out' (want 55)" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_capture_provenance.vibe "$r90dir/provenance_ok.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/provenance_ok.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_capture_provenance.vibe did not compile -- capture provenance over-approximated (#1938)" >&2
  cat "$r90dir/provenance_ok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/provenance_ok.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_ok_capture_provenance.vibe snapshots failed (#1938)" >&2
  exit 1
fi
# ADR-0090's sanctioned exits COPY. The rest of the FrozenArray surface is
# identity casts, so this is the one place the distinction is load-bearing:
# an aliasing exit both changes under the caller (the list handle is still in
# scope) and hands out a pointer into the segment the arena slice will
# release by watermark reset. Pushing after the exit must not reach the
# result -- inspect prints actual/expected itself on a regression.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_freeze_copies_out.vibe "$r90dir/copyout.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/copyout.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_freeze_copies_out.vibe did not compile" >&2
  cat "$r90dir/copyout.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_copy_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/copyout.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: MutList::freeze/to_array aliased the list instead of copying out (want 250, aliasing gives 330)" >&2
  echo "$r90_copy_out" >&2
  exit 1
fi
# The arena segment + watermark bulk release. Two fixtures, because the
# release fails in two different ways: reclaiming something still live gives a
# WRONG VALUE (quietly -- reused bump memory reads as plausible data), and
# not releasing at all gives the RIGHT value while leaking. Only the second
# fixture can see the second failure, and only by measuring.
for r90_rc in 1 0; do
  VIBE_RC="$r90_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/region_arena_release_ok.vibe "$r90dir/release.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/release.wasm" ]; then
    echo "[compiler-gate] FAIL: region_arena_release_ok.vibe did not compile (VIBE_RC=$r90_rc)" >&2
    cat "$r90dir/release.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! r90_rel_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/release.wasm" 2>&1)"; then
    echo "[compiler-gate] FAIL: region arena release reclaimed live memory (VIBE_RC=$r90_rc, want 109965)" >&2
    echo "$r90_rel_out" >&2
    exit 1
  fi
  rm -f "$r90dir/release.wasm" "$r90dir/release.wasm.diag"
done
# Boundedness. Bump lane only: that is where the arena is wired (under RC a
# region block would carry an RC header and reach the free list, which the
# bulk release invalidates -- see linked_compile.vibe) and also where it is
# worth anything, since the bump allocator never frees. 200 regions x 500
# elements leaked 1,644,008 B before the arena and cost 6,408 B after; the
# bound below is deliberately loose (it only has to separate "releases" from
# "does not"), because the residual is per-call closure environments and
# grows if that lambda's shape changes.
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_bounded.vibe "$r90dir/bounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe did not compile" >&2
  cat "$r90dir/bounded.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_bounded_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bounded.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe got the wrong value" >&2
  echo "$r90_bounded_out" >&2
  exit 1
fi
r90_heap_delta="$(node scripts/region_arena_heap_delta.mjs "$r90dir/bounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_arena_bounded.wasm" >&2
  exit 1
}
if [ "$r90_heap_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 regions grew the main bump heap by $r90_heap_delta B (want < 100000; ~6408 with the arena, 1644008 without) -- the arena stopped releasing" >&2
  exit 1
fi

# #1937: exception unwind through a region must restore depth. 70 punches
# exceed the 64-slot save table. The value assertion cannot see a skipped
# exit; only the heap delta can. Seed without the wrap leaked 574708 B.
echo "[compiler-gate] ADR-0090 #1937 exception-unwind region restore"
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_throw_unwind_test.vibe "$r90dir/unwind.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/unwind.wasm" ]; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe did not compile" >&2
  cat "$r90dir/unwind.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_unwind_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/unwind.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe got the wrong value" >&2
  echo "$r90_unwind_out" >&2
  exit 1
fi
r90_unwind_delta="$(node --experimental-wasm-exnref scripts/region_arena_heap_delta.mjs "$r90dir/unwind.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_throw_unwind_test.wasm" >&2
  exit 1
}
if [ "$r90_unwind_delta" -gt 150000 ]; then
  echo "[compiler-gate] FAIL: 70 throw-through regions grew the main bump heap by $r90_unwind_delta B (want < 150000; seed without the wrap leaked 574708) -- region exit skipped on unwind (#1937)" >&2
  exit 1
fi
echo "[compiler-gate] region exception-unwind restore ok (70 punches, main heap +${r90_unwind_delta} B)"

# ADR-0090 #1262: a REFERENCE CYCLE inside a region also costs the main heap
# nothing -- the property the ADR calls the complement to RC's permanent
# limitation. The watermark reset reclaims it without inspecting the graph.
#
# Asserted on the MARGINAL cost, not the total: the fixed setup is not zero,
# so a total bound would either be loose enough to miss a leak or tight enough
# to break on unrelated changes. Two iteration counts, and the per-region cost
# has to stay small.
for r90_cyc_n in 200 800; do
  sed -e "s/while k < 200 {/while k < $r90_cyc_n {/" \
      -e "s/inspect(main(), \"1400\")/inspect(main(), \"$((r90_cyc_n * 7))\")/" \
      fixtures/region_arena_cycles.vibe > "$r90dir/cycles_$r90_cyc_n.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RC=0 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$r90dir/cycles_$r90_cyc_n.vibe" "$r90dir/cycles_$r90_cyc_n.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/cycles_$r90_cyc_n.wasm" ]; then
    echo "[compiler-gate] FAIL: region_arena_cycles.vibe ($r90_cyc_n) did not compile" >&2
    cat "$r90dir/cycles_$r90_cyc_n.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/cycles_$r90_cyc_n.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: region_arena_cycles.vibe ($r90_cyc_n) got the wrong value" >&2
    exit 1
  fi
done
r90_cyc_lo="$(node scripts/region_arena_heap_delta.mjs "$r90dir/cycles_200.wasm")" || exit 1
r90_cyc_hi="$(node scripts/region_arena_heap_delta.mjs "$r90dir/cycles_800.wasm")" || exit 1
r90_cyc_per=$(( (r90_cyc_hi - r90_cyc_lo) / 600 ))
if [ "$r90_cyc_per" -gt 64 ]; then
  echo "[compiler-gate] FAIL: a reference cycle inside a region costs $r90_cyc_per B/region on the main heap (want <= 64; ~24 with the arena) -- the cycle is no longer reclaimed by the watermark reset" >&2
  exit 1
fi
echo "[compiler-gate] region arena reclaims reference cycles ok ($r90_cyc_per B/region)"
echo "[compiler-gate] region arena bulk release ok (200 regions, main heap +${r90_heap_delta} B)"

# ADR-0090 MutBytes (#1770 Phase 1): the region-bound byte buffer, same
# vertical slice as MutList above -- positive build/copy-out, unforgeable
# token, closure-capture escape (pins the MutBytes::empty row in
# checker_escape.vibe's taint predicate), copy-out semantics, and the
# boundedness of gen_bytes_push_body's arena regrow (which the MutList
# fixtures never exercise: Array growth and Bytes growth are separate
# builtin bodies).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_ok.vibe "$r90dir/bpos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bpos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_ok.vibe did not compile -- ADR-0090 MutBytes slice regressed" >&2
  cat "$r90dir/bpos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bpos.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_ok.vibe test blocks failed" >&2
  exit 1
fi
for r90b_neg in err_region_bytes_token_forged:'region token' err_region_bytes_escape_return:'region escapes its scope' err_region_bytes_escape_closure_capture:'region escapes its scope'; do
  r90b_fixture="${r90b_neg%%:*}"
  r90b_needle="${r90b_neg#*:}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$r90b_fixture.vibe" "$r90dir/bneg.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$r90dir/bneg.wasm" ]; then
    echo "[compiler-gate] FAIL: $r90b_fixture.vibe compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$r90b_needle" "$r90dir/bneg.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $r90b_fixture.vibe did not produce the expected diagnostic ('$r90b_needle')" >&2
    cat "$r90dir/bneg.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  rm -f "$r90dir/bneg.wasm" "$r90dir/bneg.wasm.diag"
done
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_ok_copy_out.vibe "$r90dir/bcopy.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bcopy.wasm" ] \
  || ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bcopy.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_ok_copy_out.vibe failed -- MutBytes::to_bytes must COPY (an alias sees the post-snapshot push)" >&2
  cat "$r90dir/bcopy.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_arena_bounded.vibe "$r90dir/bbounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bbounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe did not compile" >&2
  cat "$r90dir/bbounded.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bbounded.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe got the wrong value" >&2
  exit 1
fi
r90b_heap_delta="$(node scripts/region_arena_heap_delta.mjs "$r90dir/bbounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_bytes_arena_bounded.wasm" >&2
  exit 1
}
if [ "$r90b_heap_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 MutBytes regions grew the main bump heap by $r90b_heap_delta B (want < 100000; ~8024 with the arena, 194424 without) -- the bytes arena regrow stopped releasing" >&2
  exit 1
fi
echo "[compiler-gate] MutBytes arena bulk release ok (200 regions, main heap +${r90b_heap_delta} B)"
# ADR-0090 / #1770: MutList::get / MutList::length -- the in-region reads
# that make "accumulate AND consume inside the region, escape only the
# reduced value" writable (the shape #1794's rejection identified as the
# only one where the arena is pure profit). Pins a growing worklist read
# back during iteration.
# Both RC modes: RC=1 exercises the borrow-return handling of MutList::get
# on heap-valued (String) elements -- a get treated as fresh-owned would
# over-release there (Codex #1820).
for r90_consume_rc in 1 0; do
  VIBE_RC="$r90_consume_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/region_ok_consume_in_region.vibe "$r90dir/consume.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/consume.wasm" ] \
    || ! VIBE_RC="$r90_consume_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/consume.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: region_ok_consume_in_region.vibe failed under VIBE_RC=$r90_consume_rc -- MutList::get/length in-region reads regressed" >&2
    cat "$r90dir/consume.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  rm -f "$r90dir/consume.wasm"
done
echo "[compiler-gate] MutList in-region reads ok (get/length, RC both modes)"
# Codex #1801 P1: an outer region's buffer regrown inside a NESTED region
# must survive the inner exit (the replacement must not land in the inner
# region's span). Pins the saves[depth-1] guard in gen_arr_push_body /
# gen_bytes_push_body / gen_bytes_append_body for BOTH MutList and MutBytes.
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_nested_regrow_ok.vibe "$r90dir/nested.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/nested.wasm" ] \
  || ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/nested.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_arena_nested_regrow_ok.vibe failed -- an outer buffer regrown inside a nested region was rewound/overwritten" >&2
  cat "$r90dir/nested.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
echo "[compiler-gate] nested-region regrow guard ok (MutList + MutBytes)"
rm -rf "$r90dir"
echo "[compiler-gate] ADR-0090 region + MutList/MutBytes vertical slice ok"

# 76/76. ADR-0091 Phase 1 (#1262): `#zero_alloc` attribute. The attribute
# lexes as a single ident token, parses as a top-level SExpr the checker
# skips (checker_stmt.vibe) and the linear backend drops; enforcement is
# common_analysis.vibe's zero_alloc_check, run at the top of
# compile_wasi_module_linked_impl -- a conservative AST walk (constructors,
# container/closure/string-building literals, float literals, effect
# handlers, and any call not on the safe-builtin list or resolvable to a
# proven-clean top-level fn are rejected; transitive through top-level fn
# calls). Positive: a pure-arithmetic #zero_alloc fn compiles and returns
# 42 (zero_alloc_ok.vibe). Negative: a #zero_alloc fn constructing an enum
# value is a STATIC error naming the site (err_zero_alloc_ctor.vibe).
echo "[compiler-gate] 76/76 ADR-0091 #zero_alloc allocation check (#1262)"
za91dir="_build/_gate_zero_alloc91"
rm -rf "$za91dir"; mkdir -p "$za91dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/zero_alloc_ok.vibe "$za91dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$za91dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: zero_alloc_ok.vibe did not compile -- ADR-0091 #zero_alloc slice regressed" >&2
  cat "$za91dir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! za91_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$za91dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: zero_alloc_ok.vibe got '$za91_pos_out' (want 42)" >&2
  echo "$za91_pos_out" >&2
  exit 1
fi
cp fixtures/err_zero_alloc_ctor.vibe "$za91dir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$za91dir/neg.vibe" "$za91dir/neg.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$za91dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_zero_alloc_ctor.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'zero_alloc' "$za91dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_zero_alloc_ctor.vibe did not produce the expected diagnostic" >&2
  cat "$za91dir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1274 Codex P1: a param shadowing a clean top-level fn is an indirect
# callee and must be rejected.
cp fixtures/err_zero_alloc_shadowed_call.vibe "$za91dir/shadowed.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$za91dir/shadowed.vibe" "$za91dir/shadowed.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$za91dir/shadowed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_zero_alloc_shadowed_call.vibe compiled successfully -- shadowed callees must be treated as indirect" >&2
  exit 1
fi
if ! grep -qF 'zero_alloc' "$za91dir/shadowed.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_zero_alloc_shadowed_call.vibe did not produce the expected diagnostic" >&2
  cat "$za91dir/shadowed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1838: typed operators can allocate even when their operands are variables.
# Pin both allocating overloads: linear Double arithmetic boxes its result,
# and String `+` lowers to concatenation. Int arithmetic remains covered by
# the positive fixture above.
for za_typed in double_operator string_operator shadowed_operator; do
  cp "fixtures/err_zero_alloc_${za_typed}.vibe" "$za91dir/${za_typed}.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$za91dir/${za_typed}.vibe" "$za91dir/${za_typed}.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$za91dir/${za_typed}.wasm" ]; then
    echo "[compiler-gate] FAIL: err_zero_alloc_${za_typed}.vibe compiled successfully -- typed allocating operator must be rejected" >&2
    exit 1
  fi
  if ! grep -qF 'zero_alloc' "$za91dir/${za_typed}.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: err_zero_alloc_${za_typed}.vibe did not produce the expected diagnostic" >&2
    cat "$za91dir/${za_typed}.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done
rm -rf "$za91dir"
# ADR-0091 #1262: the check and the MEASUREMENT pin each other. The two
# fixtures above prove a clean fn compiles and a violating one is rejected;
# neither proves the annotation is TRUE at run time -- a checker that quietly
# stopped looking keeps both green. So state it twice, independently: the
# check says the marked fns allocate nothing, and `__heap_ptr` says the loop
# does not move it.
#
# Asserted on INVARIANCE, not on a total. The setup (`FixedArray::make`) is
# not free, so "total == 0" is unachievable and any fixed bound is arbitrary.
# Two iteration counts with the SAME delta means the per-iteration cost is
# exactly zero.
za91mdir="_build/_gate_zero_alloc91_measured"
rm -rf "$za91mdir"; mkdir -p "$za91mdir"
for za_n in 200 800; do
  sed -e "s/while k < 200 {/while k < $za_n {/" \
      -e "s/inspect(main(), \"22400\")/inspect(main(), \"$((za_n * 112))\")/" \
      fixtures/zero_alloc_measured.vibe > "$za91mdir/measured_$za_n.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RC=0 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$za91mdir/measured_$za_n.vibe" "$za91mdir/measured_$za_n.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$za91mdir/measured_$za_n.wasm" ]; then
    echo "[compiler-gate] FAIL: zero_alloc_measured.vibe ($za_n) did not compile -- the #zero_alloc check rejected a fn the measurement says is clean" >&2
    cat "$za91mdir/measured_$za_n.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$za91mdir/measured_$za_n.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: zero_alloc_measured.vibe ($za_n) got the wrong value" >&2
    exit 1
  fi
done
za_lo="$(node scripts/region_arena_heap_delta.mjs "$za91mdir/measured_200.wasm")" || exit 1
za_hi="$(node scripts/region_arena_heap_delta.mjs "$za91mdir/measured_800.wasm")" || exit 1
if [ "$za_lo" -ne "$za_hi" ]; then
  echo "[compiler-gate] FAIL: #zero_alloc fns allocated $(( (za_hi - za_lo) / 600 )) B per iteration (200 trips: $za_lo B, 800 trips: $za_hi B) -- the check says clean but the heap moved" >&2
  exit 1
fi
rm -rf "$za91mdir"
echo "[compiler-gate] #zero_alloc check and measurement agree ok (0 B/op, $za_lo B fixed setup)"
echo "[compiler-gate] ADR-0091 #zero_alloc allocation check ok"

# 77/77. ADR-0089 Decision 1, increment 1 (#1218): entry-row-Async sleep
# boundary. An entry whose declared row carries `Async` gets (a) a
# synthesized top-level `__slp_perform` that IS `perform
# Async::Suspend(-ms)`, with every unshadowed `sleep(..)` call retargeted
# to it, and (b) a tail-resumptive entry-boundary Async handler settling
# the debt via the row-free `sleep_blocking` (linked_compile.vibe
# lc_inject_async_sleep_boundary). Positive: a wrapper-fn `sleep` chain
# under an Async-row main compiles and returns 42
# (async_sleep_boundary_test.vibe -- behavior parity with the old blocking
# builtin). Negative: adding suspend-class Async handling (TaskGroup
# spawn_suspend) under an Async-row entry mixes conventions and must be
# REJECTED by the ADR-0076 guard, not silently miscompiled
# (err_async_boundary_mixed_convention.vibe).
echo "[compiler-gate] 77/77 ADR-0089 D1 async sleep boundary (#1218)"
asb89dir="_build/_gate_async_sleep89"
rm -rf "$asb89dir"; mkdir -p "$asb89dir"
cp fixtures/async_sleep_boundary_test.vibe "$asb89dir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/pos.vibe" "$asb89dir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe did not compile -- ADR-0089 D1 sleep boundary regressed" >&2
  cat "$asb89dir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe got '$asb89_pos_out' (want 42)" >&2
  exit 1
fi
cp fixtures/err_async_boundary_mixed_convention.vibe "$asb89dir/neg.vibe"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/neg.vibe" "$asb89dir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$asb89dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_convention.vibe compiled successfully -- convention mixing must be rejected" >&2
  exit 1
fi
# Either guard may catch this: the ADR-0076 mixing guard, or #1707's more
# specific one (a step-split literal landing in a plain-convention parameter,
# which is the same root -- a step value meeting a plain call). What this pins
# is that it is REJECTED with an actionable diagnostic, not miscompiled.
if ! grep -qF 'mixing the step convention' "$asb89dir/neg.wasm.diag" 2>/dev/null \
   && ! grep -qF 'hand the step object back as the value' "$asb89dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_convention.vibe did not produce the expected diagnostic" >&2
  cat "$asb89dir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1342: the same guard must be POSITION-INDEPENDENT and must key on the
# boundary that is actually injected.
#   - err_async_boundary_mixed_operand.vibe puts the `spawn_suspend` call in an
#     OPERAND. Its walker was missing EBinOp (and most other arms), so this
#     exact program COMPILED while the let-bound spelling above was rejected.
#   - async_boundary_user_sleep_test.vibe supplies its OWN `sleep`, so no
#     boundary is built and there is nothing to mix -- it must COMPILE and
#     return 42. The guard used to omit that half of the injection's condition.
cp fixtures/err_async_boundary_mixed_operand.vibe "$asb89dir/negop.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/negop.vibe" "$asb89dir/negop.wasm" main >/dev/null 2>&1 || true
if [ -s "$asb89dir/negop.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_operand.vibe compiled -- the mixing guard is position-dependent again (#1342)" >&2
  exit 1
fi
if ! grep -qF 'mixing the step convention' "$asb89dir/negop.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_operand.vibe did not produce the mixing diagnostic" >&2
  cat "$asb89dir/negop.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cp fixtures/async_boundary_user_sleep_test.vibe "$asb89dir/usersleep.vibe"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/usersleep.vibe" "$asb89dir/usersleep.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/usersleep.wasm" ]; then
  echo "[compiler-gate] FAIL: async_boundary_user_sleep_test.vibe was rejected -- the guard fired without an injected boundary (#1342)" >&2
  cat "$asb89dir/usersleep.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_us_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/usersleep.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_us_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_boundary_user_sleep_test.vibe got '$asb89_us_out' (want 42)" >&2
  exit 1
fi
echo "[compiler-gate] async boundary mixing guard: position-independent + injection-keyed ok (#1342)"
# Increment 2 (#1218): a `handle ... with Async` discharges the builtin
# row (the enclosing fn needs no `with Async`) and the handler REALLY
# receives the operations -- sleep(20)+sleep(15) reach the arm as
# Suspend(-20)/Suspend(-15) (debt-payload convention), accumulate to 35,
# and 7 + 35 = 42 (async_sleep_handler_discharge_test.vibe).
cp fixtures/async_sleep_handler_discharge_test.vibe "$asb89dir/dis.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/dis.vibe" "$asb89dir/dis.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/dis.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_handler_discharge_test.vibe did not compile -- handle-with-Async must discharge the builtin row (ADR-0089 D1 increment 2)" >&2
  cat "$asb89dir/dis.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_dis_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/dis.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_dis_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_handler_discharge_test.vibe got '$asb89_dis_out' (want 42 -- the user handler must intercept the sleeps)" >&2
  exit 1
fi
# Increment 4 (#1218): `await` of a PENDING future drives through a user
# Async handler -- the poll loop is a synthesized named `__aw_poll` fn, so
# the tail-resumptive evidence migration sees it (an inline while-wrapped
# perform was invisible). Arm resolves the future and counts one poll:
# 40 + 1 + 1 = 42 (async_await_handler_discharge_test.vibe).
cp fixtures/async_await_handler_discharge_test.vibe "$asb89dir/aw.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/aw.vibe" "$asb89dir/aw.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/aw.wasm" ]; then
  echo "[compiler-gate] FAIL: async_await_handler_discharge_test.vibe did not compile -- a pending-future await under a user Async handler must be evidence-eligible (ADR-0089 D1 increment 4)" >&2
  cat "$asb89dir/aw.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_aw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/aw.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_aw_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_await_handler_discharge_test.vibe got '$asb89_aw_out' (want 42 -- the handler must receive the poll and its resolution must unblock the await)" >&2
  exit 1
fi
# Codex P1 on #1312: scoped retargeting. A handler receives its own
# lexical sleeps while an Async-row top-level fn called from row-free code
# keeps the blocking builtin (no stranded perform). 40 + 1 + 1 = 42.
cp fixtures/async_sleep_mixed_scope_test.vibe "$asb89dir/mx.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/mx.vibe" "$asb89dir/mx.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/mx.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_mixed_scope_test.vibe did not compile -- scoped retargeting must not strand performs (Codex P1 on #1312)" >&2
  cat "$asb89dir/mx.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_mx_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/mx.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_mx_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_mixed_scope_test.vibe got '$asb89_mx_out' (want 42)" >&2
  exit 1
fi
# ADR-0089 Decision 2 (#1218): the Future cell primitives
# (Future::pending/ready/resolve) are inert callees for the evidence
# migration -- a pending future created, resolved, and awaited under an
# Async-row entry (boundary installed by the sleep) must compile and run
# (async_future_boundary_resolved_test.vibe, 1 + 41 = 42). Before the
# allowlist entries the opaque callee names sank the whole boundary-wrapped
# entry body to ineligible.
cp fixtures/async_future_boundary_resolved_test.vibe "$asb89dir/fr.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/fr.vibe" "$asb89dir/fr.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/fr.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_resolved_test.vibe did not compile -- Future cell primitives must be evidence-inert (ADR-0089 D2)" >&2
  cat "$asb89dir/fr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_fr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/fr.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_fr_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_resolved_test.vibe got '$asb89_fr_out' (want 42)" >&2
  exit 1
fi
# ...and awaiting a pending future NOTHING can resolve under the
# tail-resumptive boundary is a deadlock that must trap deterministically
# (the boundary arm asserts req < 1 -> `unreachable`), not livelock:
# compilation succeeds, execution fails fast with the unreachable trap
# (async_future_boundary_deadlock_test.vibe).
cp fixtures/async_future_boundary_deadlock_test.vibe "$asb89dir/fd.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/fd.vibe" "$asb89dir/fd.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/fd.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe did not compile (ADR-0089 D2 -- the deadlock case must compile and trap at runtime)" >&2
  cat "$asb89dir/fd.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_fd_out="$(timeout 30 bash -c "VIBE_PREOPEN_DIR='$ROOT_DIR' bash scripts/run_wasm_vibe_host_runner.sh --invoke main '$asb89dir/fd.wasm' 2>&1" || true)"
if [ "$(printf '%s\n' "$asb89_fd_out" | tail -1)" = "42" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe returned 42 -- an unresolvable await under the boundary must trap, not complete" >&2
  exit 1
fi
if ! printf '%s\n' "$asb89_fd_out" | grep -q "unreachable"; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe did not trap with 'unreachable' (livelock or wrong failure mode?)" >&2
  printf '%s\n' "$asb89_fd_out" | tail -5 >&2
  exit 1
fi
rm -rf "$asb89dir"
echo "[compiler-gate] ADR-0089 D1 async sleep boundary ok"

# 78/78. ADR-0089 (c) (#1218/#1337): the named-host-future NAME COLLECTOR must
# be total over expression containers and shadow-aware.
#
# compile_call lowers `host_future_named("price")` to `vibe_hf_get_raw$price`
# wherever it appears, so a container linked_compile's collector fails to walk
# reserves no import and no func-table entry -- the program then fails to
# compile with `undefined variable (local): vibe_hf_get_raw$price` (measured on
# the record-literal form before the fix). The mirror hazard is the same walk
# being shadow-BLIND: a local named `host_future_named` is an ordinary closure
# call compile_call leaves alone, so collecting its argument would demand a
# component import the program never uses.
#
# These are compile-level properties, so they belong here rather than only in
# the viberun-driven test_named_hostfutures_component_gate.sh (which also
# covers them, at runtime).
echo "[compiler-gate] 78/78 named host future collector: total + shadow-aware (#1337)"
nhf37dir="_build/_gate_1337"
rm -rf "$nhf37dir"; mkdir -p "$nhf37dir"
# The record literal lives in a row-free NAMED fn, not in the handled body:
# ADR-0076's evidence-migration eligibility independently rejects a container
# literal on the handled spine, and that rejection (a clear diagnostic) is not
# what this section is about. What it IS about is that the collector must walk
# INTO the record at all -- pre-fix this exact file failed with
# `undefined variable (local): vibe_hf_get_raw$price`.
cat > "$nhf37dir/nested.vibe" <<'EOF'
fn make_cell() -> Future[Int] {
  let r = record {
    p: host_future_named("price")
  }
  r.p
}

let run: () -> Int with Async = () -> {
  await(make_cell())
}
EOF
rm -f "$nhf37dir/nested.wasm" "$nhf37dir/nested.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$nhf37dir/nested.vibe" "$nhf37dir/nested.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$nhf37dir/nested.wasm" ]; then
  echo "[compiler-gate] FAIL: host_future_named nested in a record literal did not compile (#1337)" >&2
  cat "$nhf37dir/nested.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -q "price" "$nhf37dir/nested.wasm"; then
  echo "[compiler-gate] FAIL: record-nested host_future_named compiled without a 'price' import (#1337)" >&2
  exit 1
fi
# A SHADOWED builtin must reserve nothing.
cat > "$nhf37dir/shadowed.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let host_future_named = (s: String) -> Int {
    41
  }
  host_future_named("price") + 1
}
EOF
rm -f "$nhf37dir/shadowed.wasm" "$nhf37dir/shadowed.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$nhf37dir/shadowed.vibe" "$nhf37dir/shadowed.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$nhf37dir/shadowed.wasm" ]; then
  echo "[compiler-gate] FAIL: a shadowed host_future_named did not compile (#1337)" >&2
  cat "$nhf37dir/shadowed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if grep -q 'host_future_get\$price' "$nhf37dir/shadowed.wasm"; then
  echo "[compiler-gate] FAIL: a SHADOWED host_future_named still reserved the 'price' host import (#1337)" >&2
  exit 1
fi
nhf37_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nhf37dir/shadowed.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$nhf37_out" != "42" ]; then
  echo "[compiler-gate] FAIL: shadowed host_future_named output '$nhf37_out' (want 42, #1337)" >&2
  exit 1
fi
rm -rf "$nhf37dir"
echo "[compiler-gate] named host future collector ok"

# 79/79. ADR-0071 generic-effect instantiation (#1340): generic effect
# declarations now REGISTER their operation signatures (checker_stmt.vibe's
# SEffectDef arm keeps the type params; perform/handle sites instantiate
# them with fresh inference vars — one shared instantiation per handle),
# and `with State[Int]` row items parse (collect_row_item_targs,
# parser_base.vibe) with base-name-aware containment. Positive: the
# instantiated-row fixture compiles and runs to 42. Negatives: the #1218
# hole (a 3-argument perform against a 0-arity generic op used to pass
# silently) is rejected with an arity diagnostic, and a bracketed row item
# naming a NON-generic effect is rejected by geff_validate_row_targs.
echo "[compiler-gate] 79/79 generic effect instantiation registration + rows (ADR-0071/#1340)"
g1340dir="_build/_gate_1340"
rm -rf "$g1340dir"; mkdir -p "$g1340dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_generic_row_instantiation.vibe "$g1340dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$g1340dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_generic_row_instantiation.vibe did not compile (with State[Int] row grammar or generic registration regressed)" >&2
  cat "$g1340dir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! g1340_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g1340dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_generic_row_instantiation got '$g1340_out' (want 42)" >&2
  echo "$g1340_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_generic_effect_perform_arity.vibe "$g1340dir/arity.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1340dir/arity.wasm" ]; then
  echo "[compiler-gate] FAIL: err_generic_effect_perform_arity.vibe compiled -- the #1218 generic-effect arity hole is back" >&2
  exit 1
fi
if ! grep -q "perform State::Get expects 0 argument(s), got 3" "$g1340dir/arity.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_generic_effect_perform_arity.vibe did not produce the arity diagnostic" >&2
  cat "$g1340dir/arity.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_generic_effect_row_targ.vibe "$g1340dir/rowtarg.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1340dir/rowtarg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_generic_effect_row_targ.vibe compiled -- a bracketed row item on a non-generic effect must be rejected" >&2
  exit 1
fi
if ! grep -q "effect Log declares no type parameters" "$g1340dir/rowtarg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_generic_effect_row_targ.vibe did not produce the row-instantiation diagnostic" >&2
  cat "$g1340dir/rowtarg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$g1340dir"
echo "[compiler-gate] generic effect instantiation ok"

# 80/80. ADR-0071 operation-level rows, BUILTIN slice (#1343): host capabilities
# can be granted one operation at a time. Before this the builtin call path
# compared only the bare effect label (builtin_call_effect -> decl_authorizes_
# effect), so `with Fs::read_file` was rejected with `missing { Fs }` and the
# only expressible grant for a host capability was the whole effect -- which is
# what forced coarse rows like `with Http` (serve + outbound request in one
# grant). The row is the CONSUMER axis (minimal permission); the effect name
# stays the PROVIDER axis (which host provider implements it), so this needs no
# splitting of provider labels.
#
# Three directions, all required: the operation grant ADMITS its own operation,
# RESTRICTS a sibling operation (naming the missing OPERATION, not the effect),
# and the bare effect keeps granting everything (every existing row).
echo "[compiler-gate] 80/80 operation-level rows authorize builtin calls (ADR-0071/#1343)"
opb="_build/_gate_1343_op_rows"
rm -rf "$opb"; mkdir -p "$opb"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_builtin_operation_row.vibe "$opb/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$opb/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: with Fs::read_file no longer authorizes the Fs::read_file builtin (#1343)" >&2
  cat "$opb/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! op_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$opb/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_builtin_operation_row got '$op_out' (want 42)" >&2
  echo "$op_out" >&2
  exit 1
fi
cat > "$opb/neg.vibe" <<'EOF'
fn only_read(p: String) -> Unit with Fs::read_file {
  Fs::write_file(p, "x")
}

let main = () -> Int {
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$opb/neg.vibe" "$opb/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$opb/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: with Fs::read_file authorized Fs::write_file -- operation grants are not minimal (#1343)" >&2
  exit 1
fi
if ! grep -q "missing { Fs::write_file }" "$opb/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the missing OPERATION, not the whole effect (ADR-0071/#1343)" >&2
  cat "$opb/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$opb/bare.vibe" <<'EOF'
fn both(p: String) -> Unit with Fs {
  Fs::write_file(p, Fs::read_file(p))
}

let main = () -> Int {
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$opb/bare.vibe" "$opb/bare.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$opb/bare.wasm" ]; then
  echo "[compiler-gate] FAIL: the bare effect row stopped granting all of its operations (#1343 must be a pure widening)" >&2
  cat "$opb/bare.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$opb"
echo "[compiler-gate] operation-level builtin rows ok"

# 81/81. #1358: a `for` over an ASYNC iterator requires `Async`. The loop's
# `await(..)` is injected AFTER the checker (desugar_trait_dict's
# build_await_iter_for), so nothing in the program text is an async primitive
# and the Async pass used to find nothing to require -- the loop could suspend
# from a context that neither declares nor handles Async. The requirement is now
# read from the ITERAND's type (type_name_has_async_iterator_impl), which is the
# same bit the desugar switches on. Both directions are required: the declared
# row still compiles AND runs (the await lowering is unchanged), and the
# undeclared one is rejected naming `<T>::next`.
echo "[compiler-gate] 81/81 async for-loop requires the Async row (#1358)"
afdir="_build/_gate_1358"
rm -rf "$afdir"; mkdir -p "$afdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_async_for_row.vibe "$afdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$afdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_async_for_row.vibe did not compile -- a declared `with Async` row must still accept the async for loop (#1358)" >&2
  cat "$afdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! af_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$afdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_async_for_row got '$af_out' (want 42) -- the await lowering of the async for loop regressed" >&2
  echo "$af_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_async_for_undeclared.vibe "$afdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_for_undeclared.vibe compiled -- a for loop over a Future-returning iterator must require { Async } (#1358)" >&2
  exit 1
fi
if ! grep -q "Countdown::next" "$afdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the async-for diagnostic must name the iterator's next method (#1358)" >&2
  cat "$afdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# Codex review on PR #1364 (P1 x2): two iterand shapes reached the await
# lowering but slipped past the row requirement -- a GENERIC impl (recorded as
# EnvTraitImplGen, skipped by the scan) and an ENUM iterand (CtEnum, dropped by
# the head-name helper). Both were verified against repros that actually RAN
# the await loop (a sync EForIn over the value would have trapped), so each was
# a real hole. Locked here because neither is reachable through the struct-
# literal fixture above.
cat > "$afdir/generic.vibe" <<'EOF'
trait AIter[T] {
  next(Self) -> Future[Option[(T, Self)]]
}

struct Iter[T] {
  n: Int
}

impl [T] AIter for Iter[T] {
  next(self) -> Future[Option[(Int, Iter[T])]] {
    Future::ready(if self.n > 0 {
      Some((self.n, Iter::{
        n: self.n - 1
      }))
    } else {
      None
    })
  }
}

let main = () -> Int {
  let mut acc = 0
  for x in Iter::{
    n: 3
  } {
    acc = acc + x
  }
  acc
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$afdir/generic.vibe" "$afdir/generic.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/generic.wasm" ]; then
  echo "[compiler-gate] FAIL: a GENERICALLY implemented async iterator escaped the Async requirement -- EnvTraitImplGen must be matched like EnvTraitImpl (#1358, Codex P1 on #1364)" >&2
  exit 1
fi
cat > "$afdir/enum.vibe" <<'EOF'
trait AIter[T] {
  next(Self) -> Future[Option[(T, Self)]]
}

enum Chan {
  Chan(Int)
}

impl AIter for Chan {
  next(self) -> Future[Option[(Int, Chan)]] {
    Future::ready(match self {
      Chan(n) => if n > 0 {
        Some((n, Chan(n - 1)))
      } else {
        None
      }
    })
  }
}

let main = () -> Int {
  let mut acc = 0
  for x in Chan(3) {
    acc = acc + x
  }
  acc
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$afdir/enum.vibe" "$afdir/enum.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/enum.wasm" ]; then
  echo "[compiler-gate] FAIL: an ENUM async iterand escaped the Async requirement -- CtEnum must keep its head name (#1358, Codex P1 on #1364)" >&2
  exit 1
fi
rm -rf "$afdir"
echo "[compiler-gate] async for-loop Async requirement ok"

# 82/82. #1361: a LOCAL closure's declared row leaks at its CALL site. Before
# this the closure was checked against its OWN row (so it always satisfied
# itself) and the call site consulted only the top-level call-graph map, in
# which a local name never appears -- so the row escaped the enclosing
# declaration silently, and file_entry_cacheable / file_tests_cacheable (which
# reuse this walk) judged such an entry deterministic. Registering the binding
# in the #885 callback overlay closes both. Measured on the corpus at the time
# of the fix: 499/499 test files and 27/27 doctest ```vibe run blocks keep their
# cache judgment, so nothing was de-cached to buy this.
echo "[compiler-gate] 82/82 local closure rows leak at the call site (#1361)"
lcdir="_build/_gate_1361"
rm -rf "$lcdir"; mkdir -p "$lcdir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_local_closure_effect_leak.vibe "$lcdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$lcdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_local_closure_effect_leak.vibe compiled -- a local closure's declared row must leak into its caller (#1361)" >&2
  exit 1
fi
if ! grep -q "missing { Env }" "$lcdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the local-closure leak must be reported as the caller's missing row label (#1361)" >&2
  cat "$lcdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$lcdir/pos.vibe" <<'EOF'
let main = () -> Unit with Stdout + Env {
  let read_home = () -> String with Env {
    Env::get("HOME")
  }
  println(read_home())
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pos.vibe" "$lcdir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lcdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: declaring the local closure's row must satisfy the leak check (#1361)" >&2
  cat "$lcdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$lcdir/pure.vibe" <<'EOF'
let main = () -> Unit with Stdout {
  let twice = (n: Int) -> Int {
    n * 2
  }
  println(__to_string(twice(21)))
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pure.vibe" "$lcdir/pure.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lcdir/pure.wasm" ]; then
  echo "[compiler-gate] FAIL: a PURE local closure must stay free of any row requirement (#1361 must not over-require)" >&2
  cat "$lcdir/pure.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$lcdir"
echo "[compiler-gate] local closure row leak ok"

# 83/83. #1347 (ADR-0089 Part A): a `handle ... with E` that can never fire. A
# continuation captured by handler H carries H with it (the suspend lowering
# bakes H's driver into the closure handed to the arm), so re-driving a stored
# continuation under a NEW handle switches nothing -- the new arms are dead.
# Measured before the fix on this exact program: the wrapping handler's arm
# never ran and the second yield still went to the ORIGINAL arm, silently. The
# suspend lowering already rejected the same shape when the WRAPPING arm was
# itself suspend-class; this restores the symmetry for the tail-resumptive one.
#
# Three shapes are locked: the dead handle is REJECTED, a handle whose body
# performs the effect directly still compiles, and -- the false-positive
# direction that actually bit during implementation -- a body whose only callee
# is a row-carrying PARAMETER or annotated local still compiles.
echo "[compiler-gate] 83/83 a handle that can never fire is rejected (#1347)"
hsdir="_build/_gate_1347_switch"
rm -rf "$hsdir"; mkdir -p "$hsdir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_handler_switch_dead_handle.vibe "$hsdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$hsdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_handler_switch_dead_handle.vibe compiled -- the handler-switch no-op is silent again (#1347)" >&2
  exit 1
fi
if ! grep -q "can never fire" "$hsdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the dead-handle diagnostic is missing (#1347)" >&2
  cat "$hsdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$hsdir/live.vibe" <<'EOF'
effect Yield {
  Yield(Int) -> Unit
}

fn gen() -> Unit with Yield {
  perform Yield::Yield(1)
}

let main = () -> Int {
  handle {
    gen()
    41
  } with Yield {
    Yield(x) => resume(())
  } + 1
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/live.vibe" "$hsdir/live.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$hsdir/live.wasm" ]; then
  echo "[compiler-gate] FAIL: a handle whose body DOES reach the effect must still compile (#1347 must not over-reject)" >&2
  cat "$hsdir/live.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$hsdir/param.vibe" <<'EOF'
effect Yield {
  Yield(Int) -> Unit
}

fn gen() -> Unit with Yield {
  perform Yield::Yield(1)
}

fn run(f: () -> Int with Yield) -> Int {
  handle {
    f()
  } with Yield {
    Yield(x) => resume(())
  }
}

let main = () -> Int {
  let body: () -> Int with Yield = () -> {
    gen()
    42
  }
  run(body)
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/param.vibe" "$hsdir/param.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$hsdir/param.wasm" ]; then
  echo "[compiler-gate] FAIL: a handled body whose only callee is a row-carrying PARAMETER (or annotated local) must compile -- #1347 must consult the #885/#1361 overlay, not just top-level bindings" >&2
  cat "$hsdir/param.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$hsdir"
echo "[compiler-gate] dead-handle rejection ok"

# 84/84. #1347: the higher-order-effect message. An operation parameterised by
# an EFFECTFUL block was already rejected, but the generic migration error
# blamed the handle and told the reader to restructure ITS body -- unactionable,
# since the gap is in the operation's signature one level away. The diagnostic
# now names the operation. The PURE-block form must keep working (that is the
# supported half, pinned by fixtures/effect_talk_tracing_span_test.vibe).
echo "[compiler-gate] 84/84 higher-order effectful block names the operation (#1347)"
hodir="_build/_gate_1347_ho"
rm -rf "$hodir"; mkdir -p "$hodir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_higher_order_effectful_block.vibe "$hodir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$hodir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: an operation taking an EFFECTFUL block must still be rejected (#1347)" >&2
  exit 1
fi
if ! grep -q "Higher-order effects" "$hodir/neg.wasm.diag" 2>/dev/null || ! grep -q "Tracing::Span" "$hodir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the higher-order OPERATION and the limitation (#1347)" >&2
  cat "$hodir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$hodir"
echo "[compiler-gate] higher-order effect diagnostic ok"

# 85/85. ADR-0085 typed exceptions (#1344): `throw(v)` requires
# `Exception[typeof(v)]` in the enclosing row, `Exception[E1]` neither
# authorizes nor discharges `Exception[E2]`, and the ERASED spellings
# (`Error` / `Exception`) stay compatible with every kind -- which is what
# makes the feature additive for the codebase's ~970 un-annotated throw sites.
# Positive: the typed-row fixture compiles and runs to 42 (so every spelling
# still lowers to the one abortive Wasm tag). Negatives: a kind mismatch is
# rejected and NAMES the missing kind with a spelling that actually parses in a
# row, and a kinded `handle` does not catch a foreign kind.
echo "[compiler-gate] 85/85 typed Exception[E] rows (ADR-0085/#1344)"
excdir="_build/_gate_1344"
rm -rf "$excdir"; mkdir -p "$excdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/exception_typed_row.vibe "$excdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$excdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: exception_typed_row.vibe did not compile (Exception[E] rows / kinded handle / erased alias regressed)" >&2
  cat "$excdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! exc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$excdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: exception_typed_row got '$exc_out' (want 42) -- kinded exceptions must share one Wasm tag" >&2
  echo "$exc_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_exception_kind_mismatch.vibe "$excdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: with Exception[ParseError] authorized an IoError throw -- exact-kind rows are not enforced (#1344)" >&2
  exit 1
fi
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the missing KIND (#1344)" >&2
  cat "$excdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1344 follow-up: the same rejection when the payload is a LOCAL binder rather
# than an inline constructor application. Until the payload-kind scope was
# threaded through the perform walk this compiled -- a local's type was
# invisible to that (untyped) pass, so the throw fell back to the erased
# `Error::Throw`, which every exception row authorizes. That exempted exactly
# the shape #1324's migration produces.
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_exception_local_binder_kind.vibe "$excdir/neglocal.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/neglocal.wasm" ]; then
  echo "[compiler-gate] FAIL: a LOCAL binder's throw payload was not kind-checked (#1344 follow-up)" >&2
  exit 1
fi
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/neglocal.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the local-binder diagnostic must name the missing KIND (#1344 follow-up)" >&2
  cat "$excdir/neglocal.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The fix-it must be pasteable: the row grammar takes `Eff::Op` and `Eff[T]`
# but NOT `Eff[T]::Op`, so a `Exception[IoError]::Throw` hint would name a
# label that does not parse. Feed the hint's row back through the compiler.
cat > "$excdir/fixit.vibe" <<'EOF'
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

let boom = () -> Int with Exception[IoError] + Exception[ParseError] {
  throw(NotFound("cfg"))
}

let main = () -> Int {
  handle {
    boom()
  } with Exception {
    Throw(_e) => 42
  }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$excdir/fixit.vibe" "$excdir/fixit.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$excdir/fixit.wasm" ]; then
  echo "[compiler-gate] FAIL: the row the kind-mismatch hint suggests does not itself compile (#1344)" >&2
  cat "$excdir/fixit.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$excdir/handle.vibe" <<'EOF'
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

let boom = () -> Int {
  handle {
    throw(NotFound("cfg"))
  } with Exception[ParseError] {
    Throw(_e) => 42
  }
}

let main = () -> Int {
  boom()
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$excdir/handle.vibe" "$excdir/handle.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/handle.wasm" ]; then
  echo "[compiler-gate] FAIL: handle with Exception[ParseError] discharged an IoError throw (#1344)" >&2
  exit 1
fi
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/handle.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a kinded handle must leave the foreign kind in the row (#1344)" >&2
  cat "$excdir/handle.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$excdir"
echo "[compiler-gate] typed Exception[E] rows ok"

echo "[compiler-gate] 86/86 string interpolation renders derive(Show) structurally (#1392)"
# `"\{v}"` lowers in the parser to `__to_string(v)`, before any type is
# known, so every aggregate used to render as the ADR-0058 heuristic's raw
# pointer decimal -- `derive(Show)` or not. desugar_trait_dict now retargets
# the call to the generated `T::to_string` (slice 1) and expands the wrapper
# shapes (slice 2) whenever it can resolve the argument. The fixture returns
# one DIGIT per case, 1 = ok, so a partial regression names itself by which
# digit went to zero -- see the fixture header for the mapping. This exact
# program returned 1 before #1392 and 11111 with slice 1 alone. The top two
# digits are the spelled-out `to_string(v)`: prelude defines it as an
# unconditional `__to_string(x)`, so it kept printing the pointer decimal after
# interpolation was already fixed. They live in this fixture so a change that
# fixes one spelling and breaks the other cannot pass.
showdir="_build/_gate_interp_show"
rm -rf "$showdir"; mkdir -p "$showdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/interp_show_derive.vibe "$showdir/show.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$showdir/show.wasm" ]; then
  echo "[compiler-gate] FAIL: interp_show_derive.vibe did not compile (#1392)" >&2
  cat "$showdir/show.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! show_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$showdir/show.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: interpolation rendering got '$show_out' (want 1111111111111111111) (#1392)" >&2
  echo "$show_out" >&2
  exit 1
fi
rm -rf "$showdir"
echo "[compiler-gate] interpolation Show rendering ok"

# #1766: Array/tuple type arguments used to be discarded from fn_returns, so
# interpolation of a structural function result passed check and printed its
# raw pointer. The positive fixture covers direct and let-bound results,
# nesting under Option, plus nominal controls. The negative fixture locks the
# fail-closed diagnostic for a nominal result without a renderer.
retshowdir="_build/_gate_interp_function_return"
rm -rf "$retshowdir"; mkdir -p "$retshowdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$stage2_wasm" fixtures/interp_function_return_test.vibe "$retshowdir/show.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$retshowdir/show.wasm" ]; then
  echo "[compiler-gate] FAIL: structural function-return interpolation fixture did not compile (#1766)" >&2
  exit 1
fi
if ! retshow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$retshowdir/show.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: structural function-return interpolation rendered incorrectly (#1766)" >&2
  printf '%s\n' "$retshow_out" >&2
  exit 1
fi
set +e
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$stage2_wasm" fixtures/interp_function_return_missing_show_error.vibe "$retshowdir/missing.wasm" main >/dev/null 2>&1
retshow_status=$?
set -e
if [ "$retshow_status" -eq 0 ] || [ -s "$retshowdir/missing.wasm" ] || ! grep -q 'cannot interpolate a value of type `Hidden`' "$retshowdir/missing.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: missing renderer function result was not rejected actionably (#1766)" >&2
  cat "$retshowdir/missing.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$retshowdir"
echo "[compiler-gate] structural function-return interpolation ok"

echo "[compiler-gate] 87/87 uncaught throw reports the payload VALUE (#1374 / #1392 slice 3)"
# ADR-0085's runtime carries one abortive tag with no kind, so the entry
# boundary's erased `with Error` arm binds the payload at CtUnknown and can
# resolve neither a `T::to_string` nor a `[T: Show]` witness. #1374 gave it the
# payload's TYPE; slice 3 gives it the payload RENDERED at the throw site,
# where the type is still known. Three cases, because the interesting part is
# that the third did NOT regress: a type with no structural renderer must keep
# printing `<Kind>` rather than the pointer decimal a naive "trust any non-empty
# render" reader would emit.
exnmsgdir="_build/_gate_exn_msg"
rm -rf "$exnmsgdir"; mkdir -p "$exnmsgdir"
cat > "$exnmsgdir/shown.vibe" <<'VIBEEOF'
enum AppError {
  Failed(String);
  Cancelled
} derive (Show)

let _start = () -> Int with Exception {
  throw(Failed("io"))
}
VIBEEOF
cat > "$exnmsgdir/plain.vibe" <<'VIBEEOF'
let _start = () -> Int with Exception {
  throw("plain message")
}
VIBEEOF
cat > "$exnmsgdir/noshow.vibe" <<'VIBEEOF'
enum NoShow {
  Bang(Int)
}

let _start = () -> Int with Exception {
  throw(Bang(5))
}
VIBEEOF
exn_msg_expect() {
  local name="$1" want="$2"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$exnmsgdir/$name.vibe" "$exnmsgdir/$name.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$exnmsgdir/$name.wasm" ]; then
    echo "[compiler-gate] FAIL: $name.vibe did not compile (#1392 slice 3)" >&2
    cat "$exnmsgdir/$name.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  local got
  if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$exnmsgdir/$name.wasm" >"$exnmsgdir/$name.stdout" 2>"$exnmsgdir/$name.stderr"; then
    echo "[compiler-gate] FAIL: $name uncaught exception exited 0 (#1945)" >&2
    exit 1
  fi
  got="$(grep "uncaught error" "$exnmsgdir/$name.stderr" | head -1)"
  if [ "$got" != "vibe: uncaught error: $want" ]; then
    echo "[compiler-gate] FAIL: $name got '$got' (want 'vibe: uncaught error: $want') (#1392 slice 3)" >&2
    exit 1
  fi
}
# derive(Show) enum: the VALUE, not `<AppError>` (which is what #1374 printed).
exn_msg_expect shown "Failed(io)"
# String payload: `__to_string` is the identity, output unchanged.
exn_msg_expect plain "plain message"
# No structural renderer: the kind, NOT the pointer decimal.
exn_msg_expect noshow "<NoShow>"
# #1398 review (Codex P1): the render is SYNTHESIZED, runs on every throw even
# when no handler reads it, and its effects are absent from the throwing
# function's checked row -- so it must only ever call a renderer this pass
# GENERATED. A hand-written `T::to_string` is called for an interpolation the
# user wrote and for nothing else. Before the fix this program printed
# "FORMATTER RAN" twice; a formatter that threw would have replaced the
# original exception outright.
cat > "$exnmsgdir/handwritten.vibe" <<'VIBEEOF'
enum Boom {
  Bang(Int)
}

fn Boom::to_string(self: Boom) -> String with Stdout {
  println("FORMATTER RAN")
  "boom"
}

let _start = () -> Int with Stdout {
  println("interp=\{Bang(1)}")
  handle {
    throw(Bang(1))
  } with Exception {
    Throw(_m) => 7
  }
}
VIBEEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$exnmsgdir/handwritten.vibe" "$exnmsgdir/handwritten.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$exnmsgdir/handwritten.wasm" ]; then
  echo "[compiler-gate] FAIL: handwritten.vibe did not compile (#1398 review P1)" >&2
  cat "$exnmsgdir/handwritten.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
hw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$exnmsgdir/handwritten.wasm" 2>&1)"
hw_runs="$(printf '%s\n' "$hw_out" | grep -c "FORMATTER RAN" || true)"
if [ "$hw_runs" != "1" ]; then
  echo "[compiler-gate] FAIL: hand-written formatter ran $hw_runs time(s), want 1 (#1398 review P1)" >&2
  printf '%s\n' "$hw_out" >&2
  exit 1
fi
if ! printf '%s\n' "$hw_out" | grep -q "^interp=boom$"; then
  echo "[compiler-gate] FAIL: an EXPLICIT interpolation must still use the hand-written formatter (#1398 review P1)" >&2
  printf '%s\n' "$hw_out" >&2
  exit 1
fi
rm -rf "$exnmsgdir"
echo "[compiler-gate] uncaught throw payload rendering ok"

echo "[compiler-gate] 88/88 a closure-captured let mut is always a HEADERED RC cell (ADR-0092/#1262)"
# The ref-cell contract used to be half-conditional: the name went into
# ctx.ref_cell_names unconditionally, but the RC-managed (headered) cell was
# only built when expr_is_intish(value) held. expr_is_intish accepts no unary
# op but `!`, so `let mut i = -1` alone took the raw 8-byte HEADERLESS box --
# while compile_lambda still treated the capture as RC-owned (odd tagging +
# emit_rc_word_inc_saturating at box-4 + the class-7 recursive __rt_rc_drop).
# That incremented whatever preceded the box and pushed a headerless pointer
# onto the RC free list; the allocator's walk later followed a wild link and
# trapped far away -- the long-standing "all-RC bootstrap" OOB.
#
# The program's OUTPUT does not witness this (the corrupted neighbour is
# usually dead), so the lock asserts the ALLOCATOR INVARIANT instead:
# rc_patch_freelist_assert.py splices "trap if alloc_size == 0" into
# __rt_rc_drop (a post-hoc binary patch -- wasm code is outside linear memory,
# so it cannot move the guest heap), and a headerless box reaching a drop
# turns into `unreachable`. Verified to fire on the pre-fix codegen.
refcelldir="_build/_gate_rc_ref_cell"
rm -rf "$refcelldir"; mkdir -p "$refcelldir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_RC=1 VIBE_WASM_NAMES=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_captured_let_mut.vibe "$refcelldir/cell.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$refcelldir/cell.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_captured_let_mut.vibe did not compile under VIBE_RC=1 (#1262)" >&2
  cat "$refcelldir/cell.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_RC_ASSERT_SIZE0_ONLY=1 python3 scripts/rc_patch_freelist_assert.py \
  "$refcelldir/cell.wasm" "$refcelldir/cell_sz0.wasm" __rt_rc_drop >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: could not splice the alloc_size==0 assert into __rt_rc_drop (#1262)" >&2
  exit 1
fi
refcell_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$refcelldir/cell_sz0.wasm" 2>&1 | tail -1)"
if [ "$refcell_out" != "1" ]; then
  echo "[compiler-gate] FAIL: a headerless ref-cell box reached __rt_rc_drop (#1262)" >&2
  echo "  got '$refcell_out' (want 1); an 'unreachable' trap here means a captured" >&2
  echo "  let mut took the raw-bump path while the closure treated it as RC-owned" >&2
  exit 1
fi
rm -rf "$refcelldir"
echo "[compiler-gate] RC ref cell header ok"

# 89. #1262 / ADR-0055 Blocker-2: no codegen site may push a FULL f64 bit
#     pattern through an `Int`.
#
# `Double::to_i64_bits(Double) -> Int` cannot honour its own signature: a normal
# f64 pattern (`2.0` = 0x4000000000000000 = 2^62) exceeds Int::max_value
# (2^61-1). Under RC the value comes back HALVED, so `emit_f64_const_bits` --
# which slices the pattern with `>>8/16/.../56` -- writes `true_byte >> 1` for
# every one of the 8 bytes. The correct form splits the pattern into two 32-bit
# halves (each <= 2^32-1, both fit) via Double::to_i64_bits_lo/_hi +
# emit_f64_const_lohi.
#
# uniform-value-repr.md has recorded Blocker-2 as "FIXED" since #505, but the
# fix only ever landed in the LINEAR backend; codegen/gc/backend_expr.vibe kept
# the broken form and silently miscompiled every gc-lane float literal whenever
# the COMPILER ITSELF was RC-built (gate 40h read 91527 instead of 101557 --
# Double::to_int saturating to 0 and float interpolation stringifying to one
# char). A bump-built compiler hides it completely, which is why 40h never
# caught it: the DEFAULT self-build is VIBE_RC=0.
#
# So this lock is STATIC. A runtime lock would have to build an RC stage2 first
# (minutes), and the default gate has no RC-built compiler to ask.
badf64="$(grep -rn 'emit_f64_const_bits(\|Double::to_i64_bits(' lib/@vibe/compiler --include=*.vibe \
  | grep -v 'compiler_sources_bundle\|cli_adapter_bundle\|selfbuild_runtime_entry_bundle\|_cli_adapter_module_source' \
  | grep -v 'export fn emit_f64_const_bits(' \
  | grep -v 'declare Double::to_i64_bits(' || true)"
if [ -n "$badf64" ]; then
  echo "[compiler-gate] FAIL: full-f64-pattern-through-Int in codegen (#1262, ADR-0055 Blocker-2)" >&2
  echo "$badf64" >&2
  echo "  A full f64 bit pattern does not fit the 62-bit Int; under RC it arrives halved" >&2
  echo "  and every emitted f64.const byte becomes (true_byte >> 1)." >&2
  echo "  Use: emit_f64_const_lohi(buf, Double::to_i64_bits_lo(v), Double::to_i64_bits_hi(v))" >&2
  exit 1
fi
echo "[compiler-gate] f64 literal lo/hi split ok"

echo "[compiler-gate] 90/90 the @vibe/wit_runtime Result reaches the WIT projection (#1324)"
# #1324 removed `Result` from the language, but the WASM component boundary
# still needs one: WIT has `result<T, E>` and an `Exception[E]` row has no
# projection onto it (the signature is built from the return type alone, and
# exception labels are filtered out of the world imports the same way `Error`
# is), so a row-carrying export would render as plain `T`. @vibe/wit_runtime is the
# canonical `Result` for that boundary.
#
# TWO steps, because the WIT emission alone cannot see the import.
#
# VIBE_EMIT_WIT parses the ENTRY FILE ONLY and hands its raw annotations to
# wit_from_program -- it never resolves imports and never type-checks. Measured:
# swapping the import for a nonexistent package, or deleting it outright, still
# emits a byte-identical world (only the world NAME, derived from the filename,
# changes). So a golden diff by itself would pass with the package missing, and
# would NOT establish what this gate is for.
#
# Step 1 therefore FS-compiles the fixture (module resolution + checking), which
# does discriminate -- measured rc=1 with "no require pin for @vibe/..." on a
# broken import and "unknown name: Ok" with the import deleted. Step 2 then
# diffs the emitted WIT against the golden.
#
# Together they lock what the package is for: the IMPORTED type reaches the
# projection. wit_gen matches on the TypeExpr HEAD NAME, so a contract import
# only works as long as the annotation still reads `Result[..]` where wit_gen
# sees it. fixtures/wit_gen_result.vibe imports @vibe/wit_runtime rather than
# declaring a local copy, and also pins the boundary idiom itself (row inside,
# ONE `handle` in the export body producing Ok/Err).
witresdir="_build/_gate_wit_result"
rm -rf "$witresdir"; mkdir -p "$witresdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_result.vibe" "$witresdir/fixture.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$witresdir/fixture.wasm" ]; then
  echo "[compiler-gate] FAIL: fixtures/wit_gen_result.vibe did not FS-compile -- the @vibe/wit_runtime import does not resolve or does not type-check (#1324)" >&2
  cat "$witresdir/fixture.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_result.vibe" "$witresdir/out.wit" main >/dev/null 2>&1 || true
if [ ! -s "$witresdir/out.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_EMIT_WIT produced no output for the @vibe/wit_runtime fixture (#1324)" >&2
  cat "$witresdir/out.wit.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_result.golden.wit" "$witresdir/out.wit" >&2; then
  echo "[compiler-gate] FAIL: WIT output differs from fixtures/wit_gen_result.golden.wit. If the boundary contract changed intentionally, update the golden AND docs/effect-wit-mapping.md together." >&2
  exit 1
fi
rm -rf "$witresdir"
echo "[compiler-gate] @vibe/wit_runtime Result projection ok"

echo "[compiler-gate] 91/91 resource declarations enforce logical identity (ADR-0075 / #1343)"
# ADR-0075 Phase 2: `resource Posts : S3::Bucket` declares a LOGICAL resource
# identity the executable requires a binding for. The rules that matter are
# about identity, so the gate checks that two spellings which would give one
# thing two names are both rejected, and that an ordinary declaration compiles.
#
# `Process::Root` is the singleton kind (ADR-0094's default for every host
# capability): its one inhabitant is itself, so a program declaring another
# resource of that kind would be aliasing the process under a second name --
# ADR-0075's alias check exists to catch exactly that, and rejecting it at the
# declaration is cheaper than detecting the alias at bind time.
resdir="_build/_gate_resource_decl"
rm -rf "$resdir"; mkdir -p "$resdir"
res_case() {
  # res_case <name> <expect: ok|err> <source> [substring the .diag must contain]
  local rname="$1" expect="$2" rsrc="$3" rneedle="${4:-}"
  printf '%s' "$rsrc" > "$resdir/$rname.vibe"
  rm -f "$resdir/$rname.wasm" "$resdir/$rname.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$resdir/$rname.vibe" "$resdir/$rname.wasm" main >/dev/null 2>&1 || true
  if [ "$expect" = "ok" ]; then
    if [ ! -s "$resdir/$rname.wasm" ]; then
      echo "[compiler-gate] FAIL: resource case '$rname' should compile but did not (ADR-0075/#1343)" >&2
      cat "$resdir/$rname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$resdir/$rname.wasm" ]; then
      echo "[compiler-gate] FAIL: resource case '$rname' should be rejected but compiled (ADR-0075/#1343)" >&2
      exit 1
    fi
    if [ -n "$rneedle" ] && ! grep -q -- "$rneedle" "$resdir/$rname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: resource case '$rname' rejected without naming '$rneedle' (ADR-0075/#1343):" >&2
      cat "$resdir/$rname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  fi
}
res_case basic ok 'resource Posts : S3::Bucket

fn main with Stdout {
  println("ok")
}
'
res_case unqualified err 'resource Posts : Bucket

fn main with Stdout {
  println("ok")
}
' 'must be qualified'
res_case duplicate err 'resource Posts : S3::Bucket
resource Posts : S3::Table

fn main with Stdout {
  println("ok")
}
' 'already declared'
res_case singleton err 'resource Home : Process::Root

fn main with Stdout {
  println("ok")
}
' 'singleton'
res_case exported err 'export resource Posts : S3::Bucket

fn main with Stdout {
  println("ok")
}
' 'cannot be exported'
# `resource` stays an ordinary identifier: the declaration form needs an
# identifier right after the word, which no expression can have at statement
# position, so nothing that used the name breaks.
res_case as_name ok 'let resource = 1

fn main with Stdout {
  println("ok")
}
'
rm -rf "$resdir"
echo "[compiler-gate] resource declaration identity rules ok"

# Section banner. `92/92` is this section's stable registry id (see
# tests/gates/registry.tsv), not a fixture count. It read "verdicts match"
# before anything had been checked, so a failing run announced a pass and then
# printed FAIL; "vs" states the subject without the verdict.
echo "[compiler-gate] 92/92 fixtures/typecheck verdicts vs expected.tsv, both lanes (#138, #2142, #2144)"
# The corpus and both of its lanes live in scripts/check_typecheck_fixtures.sh:
# every row is compiled with `__no_entry__` AND with the entry name a user
# passes, `main`, and a difference between the two verdicts has to be recorded
# in the row or the gate fails. It used to be compiled the first way only, and
# a `handle` rejected at the entry boundary was recorded as `ok` (#2142/#2144).
#
# It is a script rather than a loop here so that its row-checker can be driven
# with synthetic verdicts by its own self-test -- Red first, then green. The
# stage2 this lane resolved is passed explicitly: a gate that picks its own
# compiler picks the newest generation on disk, which is not the one under
# test (AGENTS.md, "Which compiler answered?").
TYPECHECK_FIXTURES_STAGE2="$stage2_wasm" bash scripts/check_typecheck_fixtures.sh

# --- #819: per-block `__test_*` exports + isolated invocation -----------------
# A `__no_entry__` test build exports one `__test_<name>` per `test {}` block
# (alongside the `__bench_<name>` exports that already existed), and the runner
# does NOT pre-run `_start` for those names -- `_start` IS the loop over every
# block, so pre-running it would make one failing block fail every per-block
# invoke. This is what gives merged builds (#819) per-block failure attribution
# and a per-block timeout; scripts/unit_test_runner.sh uses it to name the
# trapping block instead of reporting a bare file-level trap.
pbdir="_build/_gate_per_block_test"
rm -rf "$pbdir"; mkdir -p "$pbdir"
cat > "$pbdir/pb_test.vibe" <<'PBEOF'
test "alpha_ok" {
  let x = 1 + 1
  if x != 2 { throw("bad alpha") }
  println("from alpha")
}

test "beta_fails" {
  throw("boom beta")
}

test "gamma_ok" {
  let y = 3
  if y != 3 { throw("bad gamma") }
  println("from gamma")
}
PBEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pbdir/pb_test.vibe" "$pbdir/pb.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$pbdir/pb.wasm" ]; then
  echo "[compiler-gate] FAIL: per-block test fixture did not compile (#819)" >&2
  cat "$pbdir/pb.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
pbexports="$(node -e '
  const m = new WebAssembly.Module(require("fs").readFileSync(process.argv[1]));
  for (const e of WebAssembly.Module.exports(m)) {
    if (e.kind === "function" && e.name.startsWith("__test_")) console.log(e.name);
  }
' "$pbdir/pb.wasm" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "$pbexports" != "__test_alpha_ok __test_beta_fails __test_gamma_ok " ]; then
  echo "[compiler-gate] FAIL: expected one __test_<name> export per test block, got: '$pbexports' (#819)" >&2
  exit 1
fi
# Isolation: the passing blocks must pass even though a sibling block traps.
# Before #819 this failed, because the runner ran `_start` (every block) first.
for pbname in __test_alpha_ok __test_gamma_ok; do
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
       --invoke "$pbname" "$pbdir/pb.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $pbname trapped -- a per-block invoke is running its siblings (#819)" >&2
    exit 1
  fi
done
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
     --invoke __test_beta_fails "$pbdir/pb.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: __test_beta_fails did not trap -- per-block invoke is not running the body (#819)" >&2
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
     --invoke _start "$pbdir/pb.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: _start did not trap on a file with a failing block (#819)" >&2
  exit 1
fi

# --- #141: batched per-block invokes -----------------------------------------
# `--invoke-batch-dir` runs every `--invoke` target in ONE process and keeps
# their outputs apart: target i's stdout/stderr/status land in
# `<dir>/<i>.{out,err,rc}`, 1-based in flag order. That separation is the whole
# point -- both callers (scripts/vibe_md.vibex's doctest blocks,
# unit_test_runner.sh's failure attribution) need EACH target's own output, so
# a plain repeated `--invoke` (which concatenates everything into one stream)
# cannot serve them.
pbbatch="$pbdir/batch"
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke-batch-dir "$pbbatch" \
  --invoke __test_alpha_ok --invoke __test_beta_fails --invoke __test_gamma_ok \
  "$pbdir/pb.wasm" >/dev/null 2>&1 && pbbatch_rc=0 || pbbatch_rc=$?
if [ "$pbbatch_rc" -eq 0 ]; then
  echo "[compiler-gate] FAIL: --invoke-batch-dir exited 0 with a failing target (#141)" >&2
  exit 1
fi
for pbslot in 1 2 3; do
  if [ ! -f "$pbbatch/$pbslot.rc" ]; then
    echo "[compiler-gate] FAIL: --invoke-batch-dir wrote no $pbslot.rc -- a failing target aborted the batch (#141)" >&2
    exit 1
  fi
done
pbrcs="$(cat "$pbbatch/1.rc" "$pbbatch/2.rc" "$pbbatch/3.rc" | tr '\n' ' ')"
if [ "$pbrcs" != "0 1 0 " ]; then
  echo "[compiler-gate] FAIL: expected batch statuses '0 1 0 ', got '$pbrcs' (#141)" >&2
  exit 1
fi
# Each target's stdout is its OWN, not the concatenation -- this is what the
# doctest harness compares against a block's ```output.
if [ "$(cat "$pbbatch/1.out")" != "from alpha" ] || [ -s "$pbbatch/2.out" ] \
   || [ "$(cat "$pbbatch/3.out")" != "from gamma" ]; then
  echo "[compiler-gate] FAIL: batch stdout is not split per target (#141):" >&2
  for pbslot in 1 2 3; do echo "  $pbslot.out: $(cat "$pbbatch/$pbslot.out")" >&2; done
  exit 1
fi
# stderr is split the same way: the trap diagnostics belong to the target that
# trapped, and do not leak into a passing sibling's report. (What that
# diagnostic SAYS is a separate, pre-existing limit -- a thrown string reaches
# the host as an opaque `WebAssembly.Exception` on the single-invoke path too,
# so this asserts attribution, not message quality.)
if [ ! -s "$pbbatch/2.err" ] || [ -s "$pbbatch/1.err" ] || [ -s "$pbbatch/3.err" ]; then
  echo "[compiler-gate] FAIL: batch stderr is not split per target (#141)" >&2
  for pbslot in 1 2 3; do echo "  $pbslot.err: $(cat "$pbbatch/$pbslot.err")" >&2; done
  exit 1
fi
rm -rf "$pbdir"
echo "[compiler-gate] per-block __test_* exports + isolated invoke + batch ok"

echo "[compiler-gate] 93/93 an imported enum's variants reach the importing module (#1455)"
# #1455: the checker's cross-module transport is the flat TypeEnv, so an
# importing module used to see an imported enum's CONSTRUCTORS but nothing
# that said which enum owned them. That one missing edge produced three
# separate wrong behaviours, and this section locks all three plus the two
# collision cases the fix had to leave alone.
#
# Each case is a two-file program: `dep.vibe` declares the enums, `<name>.vibe`
# imports them. One file would not exercise anything -- a same-file
# declaration always registered its TDEnum.
endir="_build/_gate_enum_import"
rm -rf "$endir"; mkdir -p "$endir"
cat > "$endir/dep.vibe" <<'ENUMDEP'
export enum Box {
  Mk(Int);
  Nil
}

export enum Attempt[T] {
  Got(T);
  Missed
}

export enum Paint {
  Red;
  Blue
}
ENUMDEP
en_case() {
  # en_case <name> <expect: ok|err> <source> [substring the .diag must contain]
  local ename="$1" expect="$2" esrc="$3" eneedle="${4:-}"
  printf '%s' "$esrc" > "$endir/$ename.vibe"
  rm -f "$endir/$ename.wasm" "$endir/$ename.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$endir/$ename.vibe" "$endir/$ename.wasm" main >/dev/null 2>&1 || true
  if [ "$expect" = "ok" ]; then
    if [ ! -s "$endir/$ename.wasm" ]; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' should compile but did not (#1455)" >&2
      cat "$endir/$ename.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$endir/$ename.wasm" ]; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' should be rejected but compiled (#1455)" >&2
      exit 1
    fi
    if [ -n "$eneedle" ] && ! grep -q -- "$eneedle" "$endir/$ename.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' rejected without naming '$eneedle' (#1455):" >&2
      cat "$endir/$ename.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  fi
}
# 1. `Box::Mk` resolves. This used to be `unknown name: Box::Mk`, which made
#    #1455's "require the qualified spelling" plan unimplementable: there was
#    no way to WRITE a qualified reference to an imported constructor.
en_case qualified ok 'import ./dep.vibe { Box, Mk, Nil }

fn main with Stdout {
  let b = Box::Mk(7)
  let r = match b {
    Mk(n) => n,
    Nil => 0
  }
  println(__to_string(r))
}
'
# 2. The payload is TYPE-CHECKED. Without the TDEnum, find_ctor_in_defs fell
#    through to bind_unknown and bound every sub-pattern CtUnknown, so this
#    compiled with an Int `n` handed to a String parameter. That is the silent
#    one: a hole in checking, not a message-quality complaint.
en_case payload_checked err 'import ./dep.vibe { Box, Mk, Nil }

fn main with Stdout {
  let b = Mk(7)
  match b {
    Mk(n) => println(String::concat(n, "!")),
    Nil => println("")
  }
}
' 'String::concat'
# 3. Exhaustiveness can NAME the missing variant. Before, the enum definition
#    was unknown here, so the check was skipped entirely and an unhandled
#    variant trapped at runtime instead.
en_case exhaustive err 'import ./dep.vibe { Box, Mk }

fn main with Stdout {
  let b = Mk(7)
  let r = match b {
    Mk(n) => n
  }
  println(__to_string(r))
}
' 'variant `Nil` of enum Box'
# 4. A PARAMETERIZED enum crosses the boundary too (#1455 follow-up). The
#    carrier stores the enum'"'"'s formals plus NAME-parameterized payloads
#    (`CtNamed("T", [])`), not the declaring compilation'"'"'s CtVar ids, so the
#    importer can rebind `T` to ids of its own. Before that, `Attempt::Got`
#    was `unknown name` -- resolve_qualified_ctor_ident fell back to a flat
#    env_lookup that could not see the imported scheme.
en_case parameterized ok 'import ./dep.vibe { Attempt, Got, Missed }

fn main with Stdout {
  let a = Got(3)
  let r = match a {
    Got(v) => v,
    Missed => 0
  }
  println(__to_string(r))
}
'
en_case parameterized_qualified ok 'import ./dep.vibe { Attempt, Got, Missed }

fn main with Stdout {
  let a = Attempt::Got(3)
  let r = match a {
    Attempt::Got(v) => v,
    Attempt::Missed => 0
  }
  println(__to_string(r))
}
'
# 4b. The rebuilt scheme has to stay GENERIC. If the formal were bound to a
#     shared, non-quantified var, the second instantiation in one module would
#     unify against the first and the String use would be a type error.
en_case parameterized_two_instances ok 'import ./dep.vibe { Attempt, Got, Missed }

fn first() -> Int {
  match Attempt::Got(3) {
    Got(v) => v,
    Missed => 0
  }
}

fn second() -> String {
  match Attempt::Got("s") {
    Got(v) => v,
    Missed => ""
  }
}

fn main with Stdout {
  println(String::concat(__to_string(first()), second()))
}
'
# 4c. #1455 step 3: the qualifier is CHECKED. `parse_pattern` lowers
#     `Attempt::Missed` to the same PCtor("Missed") the bare spelling produces,
#     so a swapped qualifier used to be accepted silently -- the parser now
#     records the pair on a side channel and the checker validates it against
#     the enum table (checker_pattern.vibe::check_qualified_pattern_refs).
#     `Box` is a real enum here, just not the one that owns `Missed`.
en_case pattern_qualifier_wrong_enum err 'import ./dep.vibe { Attempt, Box, Got, Missed }

fn main with Stdout {
  let a = Got(3)
  let r = match a {
    Got(v) => v,
    Box::Missed => 0
  }
  println(__to_string(r))
}
' 'enum `Box` has no variant `Missed`'
# 4d. ...and a qualifier that is not an enum stays silent, which is what keeps
#     handle-arm operation patterns (`Log::Emit(m)`) working: they reach the
#     same side channel through the same parser branch.
en_case pattern_qualifier_effect_arm ok 'effect Log {
  Emit(String) -> Unit
}

fn shout(s: String) -> String with Log {
  perform Log::Emit(s)
  s
}

fn main with Stdout {
  let r = handle {
    shout("hi")
  } with Log {
    Log::Emit(m) => resume(m)
  }
  println(r)
}
'
# 5. A local enum that reuses an imported constructor NAME still compiles.
#    This is the case that forced the variant-collision guard in
#    seed_imported_enum_defs: `find_ctor_in_defs` is first-match-wins over one
#    flat `defs`, so registering Paint would have made the `Red` arm resolve
#    to Paint and retyped the whole match. Shadowing an imported constructor
#    is ordinary code -- the local binding wins -- so the seeded enum has to
#    step aside rather than take it over.
en_case shadow_import ok 'import ./dep.vibe { Paint, Red, Blue }

enum Color {
  Red;
  Green
}

fn main with Stdout {
  let c = Red
  match c {
    Red => println("red"),
    Green => println("green")
  }
}
'
# 6. ...but the collision #1078 is actually about -- two enums in ONE unit,
#    where the flat last-registered-wins env silently points a bare `Mk` at
#    the wrong signature -- is still rejected.
en_case collide_local err 'enum A {
  Mk(Int)
}

enum B {
  Mk(String)
}

fn main with Stdout {
  println("unreachable")
}
' 'constructor name collision'
rm -rf "$endir"
echo "[compiler-gate] imported enum variant lists ok"

echo "[compiler-gate] 94/94 importing a name the dependency does not export is a CHECK error (#1521)"
# #1521: `bind_import_names_from_cache` bound CtUnknown for an imported name
# the dependency does not export. CtUnknown unifies with anything, so every
# USE of that name typechecked -- `vibe check` said ok -- and the program
# died in codegen with `undefined variable (ident): X`, naming no file and
# no line. Worse than having no diagnostic: the import SUPPRESSED the
# `unknown name` the same code gets without it.
#
# The negatives are the point of this section, not padding. Two earlier
# attempts at this check passed their positives while silently breaking
# valid code (or while wired into a lane `vibe check` never runs), so every
# shape that must stay clean is pinned right next to the shapes that must
# fail.
uidir="_build/_gate_unresolved_import"
rm -rf "$uidir"; mkdir -p "$uidir"
cat > "$uidir/dep.vibe" <<'UIDEP'
export enum Hue {
  Crimson;
  Cerulean
}

export fn hue_rank(h: Hue) -> Int {
  match h {
    Crimson => 0
    Cerulean => 1
  }
}
UIDEP
ui_case() {
  # ui_case <name> <expect: ok|err> <source>
  #   ok  -- compiles
  #   err -- rejected BY THE #1521 CHECK (diag names the unexported import)
  # (A third expectation, `gap`, used to pin the #1533 shape: a private
  # import that failed in CODEGEN instead of the check. #1533 is fixed --
  # published dependency environments are restricted to the export surface,
  # see runtime/typecheck_fs.vibe restrict_env_to_export_surface -- so that
  # shape is an ordinary `err` now and the expectation is gone.)
  local uname="$1" uexpect="$2" usrc="$3"
  printf '%s' "$usrc" > "$uidir/$uname.vibe"
  rm -f "$uidir/$uname.wasm" "$uidir/$uname.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$uidir/$uname.vibe" "$uidir/$uname.wasm" _start >/dev/null 2>&1 || true
  if [ "$uexpect" = "ok" ]; then
    if [ ! -s "$uidir/$uname.wasm" ]; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' should compile but did not (#1521)" >&2
      cat "$uidir/$uname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$uidir/$uname.wasm" ]; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' compiled; the bogus import was not caught (#1521)" >&2
      exit 1
    fi
    if ! grep -q "is not exported by" "$uidir/$uname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' was rejected by something OTHER than the #1521 check" >&2
      cat "$uidir/$uname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  fi
}
# 1. The reported shape: a value import that does not exist, and is used.
ui_case bogus_used err 'import ./dep.vibe { no_such_fn }

export let _start = () -> Int { no_such_fn(1) }
'
# 2. Reported even when UNUSED. The pre-existing "never used" warning fires
#    here too, but "unused" is not "no such name" -- the import is still wrong.
ui_case bogus_unused err 'import ./dep.vibe { no_such_fn }

export let _start = () -> Int { 1 }
'
# 3. An alias does not launder it: the ORIGINAL name is what must exist.
ui_case bogus_aliased err 'import ./dep.vibe { no_such_fn as f }

export let _start = () -> Int { f(1) }
'
# 4-6. Every valid shape stays clean: plain value + type + constructor,
#      the same through aliases, and constructors imported on their own.
ui_case good_plain ok 'import ./dep.vibe { hue_rank, Hue, Crimson }

export let _start = () -> Int { hue_rank(Crimson) }
'
ui_case good_aliased ok 'import ./dep.vibe { hue_rank as r, Hue as T, Crimson }

fn pick() -> T { T::Crimson }

export let _start = () -> Int { r(pick()) }
'
ui_case good_ctors ok 'import ./dep.vibe { Hue, Crimson, Cerulean }

export let _start = () -> Int {
  match Cerulean {
    Crimson => 0
    Cerulean => 1
  }
}
'
# 7. Declaration authority now travels with the dependency environment, so an
#    unknown uppercase selection is rejected by the same import-surface check.
#    (This case kept the name `bogus_uppercase_not_reported` long after it
#    stopped being a gap; the same stale claim outlived it in CLAUDE.md, which
#    still told readers uppercase names went undetected. Measured
#    2026-08-19: all four shapes below are caught.)
ui_case bogus_uppercase err 'import ./dep.vibe { Hue, NoSuchType }

export let _start = () -> Int { 1 }
'
# 7b-7d. The three uppercase shapes CLAUDE.md named as still-undetected. A
#    struct and a type alias are DECLARED in the dependency but not exported,
#    which is a different path from case 7's name-that-never-existed: the
#    dependency's own environment has them, and only the export-surface
#    restriction keeps them off the published one.
cat > "$uidir/upper.vibe" <<'UIUPPER'
export struct Shown {
  x: Int
}

struct Hidden {
  y: Int
}

export type ShownAlias = Int

type HiddenAlias = Int
UIUPPER
ui_case private_struct_reported err 'import ./upper.vibe { Hidden }

export let _start = () -> Int {
  let h = Hidden::{ y: 1 }
  h.y
}
'
ui_case private_type_alias_reported err 'import ./upper.vibe { HiddenAlias }

fn take(x: HiddenAlias) -> Int { x }

export let _start = () -> Int { take(1) }
'
# ...and the exported pair from that same module stays clean, so the two
# cases above are not passing because `upper.vibe` is broken.
ui_case public_upper_ok ok 'import ./upper.vibe { Shown, ShownAlias }

fn take(x: ShownAlias) -> Int { x }

export let _start = () -> Int {
  let s = Shown::{ x: 1 }
  take(s.x)
}
'
# 8. A dependency that binds NO values is still a checked dependency. Deriving
#    "known" from the binding count switched the check off for exactly these
#    (Codex review, PR #1532) -- a trait-only module is cached as an empty
#    value environment, and a bogus import from it went back to dying in
#    codegen. `dep_known` now comes from the cache lookup itself.
cat > "$uidir/traitonly.vibe" <<'UITRAIT'
export trait Pingable {
  ping(Self) -> Int
}
UITRAIT
ui_case bogus_from_traitonly err 'import ./traitonly.vibe { no_such_fn }

export let _start = () -> Int { no_such_fn(1) }
'
# 9. #1533, fixed (was pinned here as a `gap` case): a PRIVATE name is not in
#    the environment the dependency publishes -- check_module restricts it to
#    the export surface -- so the membership check reports it exactly like a
#    name that never existed. From the importer's side those are the same
#    fact: the dependency does not export it.
cat > "$uidir/privates.vibe" <<'UIPRIV'
fn private_fn(x: Int) -> Int {
  x + 1
}

export fn public_fn(x: Int) -> Int {
  private_fn(x)
}
UIPRIV
ui_case private_import_reported err 'import ./privates.vibe { private_fn }

export let _start = () -> Int { private_fn(1) }
'
# 10. ...and the public name from that same module still imports cleanly, so
#     case 9 is not passing because the module is broken.
ui_case public_from_mixed_module ok 'import ./privates.vibe { public_fn }

export let _start = () -> Int { public_fn(1) }
'
# 11-12. The same rule for PASS-THROUGH names (#1533's other face): a name the
#     dependency merely imported sits in its checked environment (the import
#     env is the base of the chain) but is NOT part of its export surface --
#     importing it from the middleman is an error unless the middleman
#     re-exports it, which puts the name on the surface for real.
cat > "$uidir/middleman.vibe" <<'UIMID'
import ./dep.vibe { hue_rank, Hue, Crimson }

export fn middleman_rank() -> Int {
  hue_rank(Crimson)
}
UIMID
ui_case passthrough_import_reported err 'import ./middleman.vibe { hue_rank }

export let _start = () -> Int { hue_rank(1) }
'
cat > "$uidir/reexporter.vibe" <<'UIREX'
export ./dep.vibe { hue_rank, Hue, Crimson }
UIREX
ui_case reexported_name_ok ok 'import ./reexporter.vibe { hue_rank, Hue, Crimson }

export let _start = () -> Int { hue_rank(Crimson) }
'
rm -rf "$uidir"
echo "[compiler-gate] unresolved import names ok"

echo "[compiler-gate] 95/95 a name reaching codegen unresolved says it is a COMPILER bug (#1521/#1491/#1529)"
# The shared exit of a whole family of defects. #1502, #1510, #1491, #1521,
# #1529 and #1533 are unrelated in cause -- an alias qualifier, a first-match
# lookup, a CtUnknown fallback, a struct shape collision -- and every one of
# them surfaced the same way: the checker accepted the program, and codegen
# died on a name it could not resolve, with a message naming no file, no line,
# and `locals=[__env,,__fn_val]` (pass state).
#
# The three codegen sites that can raise it now say whose bug it is, in one
# shared wording so they cannot drift. This section pins that wording, so the
# next defect in this family arrives as "internal compiler error, report it"
# rather than as something a user might read as their own mistake.
#
# It does NOT try to prove no program reaches those sites -- reaching them IS
# the open-issue set. What it pins is that arriving there is legible.
for cg_site in \
  "lib/@vibe/compiler/codegen/common_base/common_base.vibe" \
  "lib/@vibe/compiler/codegen/expr/compile_expr.vibe" \
  "lib/@vibe/compiler/codegen/gc/backend_expr.vibe"
do
  # The load-bearing half: the OLD spelling must be gone. Asserting the new
  # helper "appears in the file" does not do it -- common_base DEFINES the
  # helper, so it matches whether or not `resolve_local` still calls it, and a
  # revert there would sail through. (Codex review on PR #1562; the check was
  # asking a different question from the one it meant, which is the very shape
  # ARCH011 was added for.)
  if grep -q '"undefined variable' "$ROOT_DIR/$cg_site"; then
    echo "[compiler-gate] FAIL: $cg_site raises a bare \"undefined variable\" again" >&2
    echo "[compiler-gate]       That message names no file, no line, and reads as the user's mistake." >&2
    grep -n '"undefined variable' "$ROOT_DIR/$cg_site" >&2
    exit 1
  fi
  if ! grep -q "codegen_unresolved_name_prefix()" "$ROOT_DIR/$cg_site"; then
    echo "[compiler-gate] FAIL: $cg_site no longer routes its unresolved-name error through the shared wording" >&2
    exit 1
  fi
done
# ...and specifically INSIDE resolve_local, not merely somewhere in the file
# that declares the helper.
if ! awk '/^export fn resolve_local\(/,/^}/' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base.vibe" \
  | grep -q "codegen_unresolved_name_prefix()"; then
  echo "[compiler-gate] FAIL: resolve_local's own error no longer uses the shared wording" >&2
  exit 1
fi
if ! grep -q 'internal compiler error' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base.vibe"; then
  echo "[compiler-gate] FAIL: the unresolved-name error no longer identifies itself as a compiler bug" >&2
  exit 1
fi
# And a normal program must NOT produce it -- the wording lock above is
# worthless if the message fires on correct code.
cgdir="_build/_gate_codegen_unresolved"
rm -rf "$cgdir"; mkdir -p "$cgdir"
printf 'enum Color {\n  Red;\n  Green\n}\n\nexport let _start = () -> Int {\n  match Color::Red {\n    Red => 1\n    Green => 2\n  }\n}\n' > "$cgdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cgdir/ok.vibe" "$cgdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cgdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: a correct program hit the unresolved-name path" >&2
  cat "$cgdir/ok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$cgdir"
echo "[compiler-gate] codegen unresolved-name error is legible ok"

echo "[compiler-gate] 96/96 host-side tracing spans nest, propagate and record failures (docs/tracing-design.md step 0)"
bash scripts/test_trace_spans.sh
echo "[compiler-gate] tracing spans ok"

echo "[compiler-gate] 97/97 desugar-emitted builtins resolve in BOTH compile lanes (#1590)"
# The three builtins desugar_trait_dict synthesizes -- str_lex_diff for String
# `<`, __generic_rel_diff / __generic_add for an erased type parameter -- were
# checker_visible=false, which is fine only while the checker runs BEFORE
# desugar. It does not in the lane that omits VIBE_FS_COMPILE=1 (the one
# generate_bundle.sh's bootstrap_merge_flatten_tool pass 3 uses), so each one
# died there with `unknown name: <builtin>` while compiling fine with
# VIBE_FS_COMPILE=1. Compiling every shape in the NON-FS lane specifically:
# the FS lane never had the bug and would pass either way.
dvdir="_build/_gate_desugar_builtins"
rm -rf "$dvdir"; mkdir -p "$dvdir"
printf 'export fn lt(a: String, b: String) -> Bool { a < b }\nexport fn main() -> Int { if lt("a","b") { 0 } else { 1 } }\n' > "$dvdir/str_lex_diff.vibe"
printf 'fn g[T](a: T, b: T) -> Bool { a < b }\nexport fn main() -> Int { if g(1,2) { 0 } else { 1 } }\n' > "$dvdir/generic_rel_diff.vibe"
printf 'fn ga[T](a: T, b: T) -> T { a + b }\nexport fn main() -> Int { ga(1,2) }\n' > "$dvdir/generic_add.vibe"
for dvsrc in "$dvdir"/*.vibe; do
  dvname="$(basename "$dvsrc" .vibe)"
  VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dvsrc" "$dvdir/$dvname.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$dvdir/$dvname.wasm" ]; then
    echo "[compiler-gate] FAIL: $dvname did not compile in the non-FS lane (#1590)" >&2
    cat "$dvdir/$dvname.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done
rm -rf "$dvdir"
echo "[compiler-gate] desugar-emitted builtins resolve in both lanes ok"

echo "[compiler-gate] 98/104 \`vibe grep\`'s typed filters resolve imports like \`vibe check\` (#1572)"
bash "$ROOT_DIR/scripts/test_vibe_grep_help.sh"
bash "$ROOT_DIR/scripts/test_vibe_rc_help.sh"
# grep_test.vibe covers the pattern language and the filters through
# grep_scan_source (no Fs). What only the REAL adapter mode exercises is the
# filesystem tier: sweeping a directory, and resolving a capture's type through
# the same FS import walk `vibe check` uses. That resolution is the whole point
# of the feature and it is the part that silently degrades -- seeding the module
# sources wrong makes every import type as `CtUnknown`, at which point the
# filters keep answering, just wrongly.
gvdir="_build/_gate_vibe_grep"
rm -rf "$gvdir"; mkdir -p "$gvdir"
cat > "$gvdir/dep.vibe" <<'VEOF'
export fn helper(v: Int) -> Int {
  v + 1
}
VEOF
cat > "$gvdir/main.vibe" <<'VEOF'
import ./dep.vibe {
  helper as h
}

fn readit(p: String) -> String with Fs {
  Fs::read_file(p)
}

fn plain(p: String) -> String {
  p
}

fn run(q: String) -> String with Fs {
  let a = readit(q)
  let b = h(1)
  String::concat(plain(a), __to_string(b))
}
VEOF
gv_run() {
  # $1 = output basename, $2.. = extra env assignments (name=value)
  local gv_out="$gvdir/$1"; shift
  rm -f "$gv_out" "$gv_out.diag" "$gv_out.warn"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_GREP=1 "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$gvdir" "$gv_out" >/dev/null 2>&1 || true
}
# Parse-only tier: every call in the directory, whatever its arity.
gv_run all.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))'
for gv_want in 'readit(q)' 'h(1)' 'plain(a)' 'Fs::read_file(p)'; do
  if ! grep -qF "$gv_want" "$gvdir/all.txt"; then
    echo "[compiler-gate] FAIL: vibe grep did not find $gv_want" >&2
    cat "$gvdir/all.txt" "$gvdir/all.txt.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done
if ! grep -q '^.*main\.vibe:[0-9][0-9]*:[0-9][0-9]*: ' "$gvdir/all.txt"; then
  echo "[compiler-gate] FAIL: vibe grep output is not path:line:col-prefixed" >&2
  cat "$gvdir/all.txt" >&2
  exit 1
fi
# Typed tier: the effect row of the CALLEE, which only exists if the import
# walk actually resolved the module graph.
gv_run row.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))' VIBE_GREP_WHERE_ROW='$f with Fs'
if ! grep -qF 'readit(q)' "$gvdir/row.txt" || grep -qF 'plain(a)' "$gvdir/row.txt"; then
  echo "[compiler-gate] FAIL: --where-row '\$f with Fs' kept the wrong sites" >&2
  cat "$gvdir/row.txt" "$gvdir/row.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
# Resolved-name filter: `h` is an ALIAS for dep.vibe's `helper`, so a text grep
# for `helper(` finds nothing here and this must still find it.
gv_run alias.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))' VIBE_GREP_WHERE='$f = helper'
if ! grep -qF 'h(1)' "$gvdir/alias.txt"; then
  echo "[compiler-gate] FAIL: --where '\$f = helper' did not resolve the import alias" >&2
  cat "$gvdir/alias.txt" "$gvdir/alias.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
# A bad pattern is an ERROR on the .diag sidecar, never a plausible-but-wrong
# match list on output_path (the VIBE_SYMBOLS convention).
gv_run bad.txt VIBE_GREP_PATTERN='f($(x:expr))'
if [ -s "$gvdir/bad.txt" ] || ! grep -q 'unknown metavariable kind' "$gvdir/bad.txt.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a bad grep pattern did not land on the .diag sidecar" >&2
  cat "$gvdir/bad.txt" "$gvdir/bad.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi

# A typing failure belongs to ONE file, not to the whole repository sweep.
# Keep the trustworthy hits on either side, drop the broken file, and report
# that skip once on the warning sidecar. This preserves fail-closed filtering
# without turning a work-in-progress file into a repo-wide abort (#1834).
cat > "$gvdir/a_sweep_good.vibe" <<'VEOF'
fn good_before() -> Int {
  let xs = [1]
  Array::length(xs)
}
VEOF
cat > "$gvdir/b_sweep_bad.vibe" <<'VEOF'
fn broken_between() -> Int {
  let wrong: String = 1
  let xs = [2]
  Array::length(xs)
}
VEOF
cat > "$gvdir/c_sweep_good.vibe" <<'VEOF'
fn good_after() -> Int {
  let xs = [3]
  Array::length(xs)
}
VEOF
gv_run sweep.txt VIBE_GREP_PATTERN='Array::length($(x:exp))' VIBE_GREP_WHERE='$x : Array[Int]'
if ! grep -qF 'a_sweep_good.vibe' "$gvdir/sweep.txt" || ! grep -qF 'c_sweep_good.vibe' "$gvdir/sweep.txt"; then
  echo "[compiler-gate] FAIL: a broken file aborted the typed grep repo sweep" >&2
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
  exit 1
fi
if grep -qF 'b_sweep_bad.vibe' "$gvdir/sweep.txt" || [ -s "$gvdir/sweep.txt.diag" ]; then
  echo "[compiler-gate] FAIL: typed grep did not fail closed per broken file" >&2
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
  exit 1
fi
if [ "$(grep -cF 'b_sweep_bad.vibe' "$gvdir/sweep.txt.warn" 2>/dev/null || true)" -ne 1 ]; then
  echo "[compiler-gate] FAIL: typed grep did not report the skipped file exactly once" >&2
  cat "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$gvdir"
echo "[compiler-gate] vibe grep typed filters ok"

# 99. #1571: `inspect` is a REWRITE, not a function, so the two ways it can be
#     wrong are both silent -- it can capture a name the user already bound, and
#     it can hijack a call the user meant for their own `inspect`. Both were
#     found by review rather than by a gate (the second twice: expression
#     binders in #1622, PATTERN binders after that), which is what this step is
#     for. Each case below fails DIFFERENTLY if the guard regresses.
echo "[compiler-gate] 99/104 the inspect rewrite neither captures nor hijacks (#1571)"
inspdir="_build/_gate_inspect_guard"
rm -rf "$inspdir"; mkdir -p "$inspdir"

# (a) Hygiene: the temporaries the expansion introduces must not capture a name
# the arguments already reference. With a fixed temp name this compared the
# literal against ITSELF and passed; the assertion has to see "wrong".
cat > "$inspdir/hygiene.vibe" <<'INSPH'
fn main() -> Int with Stdout {
  let __vibe_inspect_actual = "wrong"
  inspect(1, __vibe_inspect_actual)
  0
}
INSPH
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/hygiene.vibe" "$inspdir/hygiene.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/hygiene.wasm" ]; then
  echo "[compiler-gate] FAIL: the inspect hygiene sample did not compile" >&2
  cat "$inspdir/hygiene.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if insp_hyg="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/hygiene.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: inspect(1, __vibe_inspect_actual) PASSED -- the expansion's temporary captured the argument, so it compared a value against itself (#1571 hygiene)" >&2
  echo "$insp_hyg" >&2
  exit 1
fi

# The same freshness boundary when the candidate appears ONLY as a compound-
# assignment target inside the value expression. A target-blind scan reuses the
# name, so the generated let captures the mutation and the snapshot observes 1.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/inspect_assignop_target_freshness.vibe "$inspdir/assignop.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$inspdir/assignop.wasm" ]; then
  echo "[compiler-gate] FAIL: inspect EAssignOp target-only freshness fixture did not compile" >&2
  cat "$inspdir/assignop.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$inspdir/assignop.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: inspect temporary captured a target-only __vibe_inspect_actual" >&2
  exit 1
fi

# (b) Shadow, expression binder: a user function named `inspect` must keep its
# own body. 2 + 5 = 7; the rewrite would return Unit and not type.
cat > "$inspdir/shadow_fn.vibe" <<'INSPF'
fn inspect(v: Int, c: String) -> Int {
  v + 5
}

fn main() -> Int {
  inspect(2, "ignored")
}
INSPF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/shadow_fn.vibe" "$inspdir/shadow_fn.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/shadow_fn.wasm" ]; then
  echo "[compiler-gate] FAIL: a user-declared \`inspect\` did not compile -- the rewrite hijacked the call (#1571 shadow)" >&2
  cat "$inspdir/shadow_fn.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
insp_fn_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/shadow_fn.wasm" 2>/dev/null | tail -1)"
if [ "$insp_fn_out" != "7" ]; then
  echo "[compiler-gate] FAIL: a user-declared \`inspect\` got '$insp_fn_out' (want 7) -- its body did not run (#1571 shadow)" >&2
  exit 1
fi

# (c) Shadow, PATTERN binder (Codex review on #1622): the same hijack via a
# match arm, which the expression-only guard could not see. The side effect is
# the observable: the rewrite runs a snapshot assertion instead and traps.
cat > "$inspdir/shadow_pat.vibe" <<'INSPP'
enum Box {
  B((Int, String) -> Unit with Stdout)
}

fn shout(v: Int, c: String) -> Unit with Stdout {
  println(c)
}

fn main() -> Int with Stdout {
  match B(shout) {
    B(inspect) => {
      inspect(1, "SIDE EFFECT RAN")
      7
    }
  }
}
INSPP
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/shadow_pat.vibe" "$inspdir/shadow_pat.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/shadow_pat.wasm" ]; then
  echo "[compiler-gate] FAIL: a pattern-bound \`inspect\` did not compile (#1571 shadow, pattern binders)" >&2
  cat "$inspdir/shadow_pat.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
insp_pat_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/shadow_pat.wasm" 2>&1)"
case "$insp_pat_out" in
  *"SIDE EFFECT RAN"*) ;;
  *)
    echo "[compiler-gate] FAIL: a match-arm-bound \`inspect\` was rewritten -- the user's function never ran (#1571 shadow; see dinsp_pat_binds in normalize/desugar_trait_dict.vibe)" >&2
    echo "$insp_pat_out" >&2
    exit 1
    ;;
esac
rm -rf "$inspdir"
echo "[compiler-gate] inspect rewrite hygiene + shadow guard ok"

# 100. #1567 slice 1: `vibe check` and `vibe diagnostics` must agree on the
#      COUNT of top-level parse errors, not just on their wording. The
#      recovering parser has already collected every one by the time
#      check_linked_file looks, so reporting `parse_diags[0]` and dropping the
#      rest made `check` a strictly worse answer to the same question -- three
#      broken statements cost three edit-and-rerun cycles. This pins the two
#      surfaces together so they cannot drift apart again.
echo "[compiler-gate] 100/104 check and diagnostics report the SAME parse errors (#1567)"
chkdir="_build/_gate_check_diag_parity"
rm -rf "$chkdir"; mkdir -p "$chkdir"
# Three top-level statements, two independently broken, one good between them.
# The good statement in the middle is what forces real resynchronization.
printf 'export let a = = 1\nexport let ok = 1\nexport let b = = 2\n' > "$chkdir/multi.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/multi.vibe" "$chkdir/check.out" main >/dev/null 2>&1 || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/multi.vibe" "$chkdir/diag.out" main >/dev/null 2>&1 || true
# check reports through the .diag sidecar, diagnostics through the output file.
# That is a COMPILER-side transport difference; the launcher normalizes both to
# stdout (#1567 slice 2, pinned in tests/integration/install/install_test.sh, which is
# the layer that owns the user-facing contract). This step stays at the
# compiler layer and only pins the counts.
chk_n="$(grep -c '^line ' "$chkdir/check.out.diag" 2>/dev/null || true)"
diag_n="$(grep -c '^line ' "$chkdir/diag.out" 2>/dev/null || true)"
[ -n "$chk_n" ] || chk_n=0
[ -n "$diag_n" ] || diag_n=0
if [ "$chk_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe check reported $chk_n parse errors, want 2 -- check_linked_file is dropping diagnostics the recovering parser already collected (#1567)" >&2
  cat "$chkdir/check.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
if [ "$diag_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe diagnostics reported $diag_n parse errors, want 2 (#1567)" >&2
  cat "$chkdir/diag.out" 2>/dev/null >&2 || true
  exit 1
fi
# Same errors, not merely the same count: both must name line 1 and line 3.
for want in 'line 1:' 'line 3:'; do
  if ! grep -qF "$want" "$chkdir/check.out.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe check's report is missing '$want' (#1567)" >&2
    cat "$chkdir/check.out.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! grep -qF "$want" "$chkdir/diag.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe diagnostics' report is missing '$want' (#1567)" >&2
    cat "$chkdir/diag.out" 2>/dev/null >&2 || true
    exit 1
  fi
done
# A clean file must stay clean on both, with check still exiting 0.
printf 'export let a = 1\n' > "$chkdir/clean.vibe"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/clean.vibe" "$chkdir/clean.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: vibe check rejected a clean file (#1567)" >&2
  cat "$chkdir/clean.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$chkdir"
echo "[compiler-gate] check/diagnostics parse-error parity ok (#1567)"

# #1551: compiler-owned ingestion-pipeline observations are published only by
# successful checks and distinguish cold, warm, and list-to-group recovery.
node scripts/ingestion_pipeline_telemetry_integration.mjs "$ROOT_DIR" "$stage2_wasm"

# --- #988: `vibe deps` -- the resolved import closure ------------------------
#
# This verb exists to be MACHINE-consumed (scripts/affected_tests.mjs selects
# which tests to run from it), so the failure that matters is a list that is
# quietly incomplete: a caller then skips tests and reports green. Every check
# below is aimed at that, not at pretty output.
depdir="_build/_gate_vibe_deps"
rm -rf "$depdir"; mkdir -p "$depdir"
dep_run() {
  # $1 = output basename, $2 = input path, $3.. = extra env assignments
  local dep_out="$depdir/$1"; local dep_in="$2"; shift 2
  rm -f "$dep_out" "$dep_out.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dep_in" "$dep_out" __no_entry__ >/dev/null 2>&1 || true
}

# (a) --direct resolves an `@scope/pkg` import to the package CONTRACT. The
# import line says `@vibe/ast`; only real resolution turns that into a path,
# which is precisely what a text scan of import lines cannot do.
dep_run direct.txt lib/@vibe/parser/parser_smoke_test.vibe VIBE_DEPS_DIRECT=1
if ! grep -qx 'lib/@vibe/ast/index.vpkg' "$depdir/direct.txt"; then
  echo "[compiler-gate] FAIL: vibe deps --direct did not resolve '@vibe/ast' to its index.vpkg (#988)" >&2
  cat "$depdir/direct.txt" "$depdir/direct.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi

# (b) The closure reaches a contract's SIBLING IMPLEMENTATION. No import line
# anywhere names lib/@vibe/ast/ast.vibe -- it enters the build only because the
# loader pulls a .vpkg's impls in. A selection built on anything less would
# miss every change to that file.
dep_run closure.txt lib/@vibe/parser/parser_smoke_test.vibe
if ! grep -qx 'lib/@vibe/ast/ast.vibe' "$depdir/closure.txt"; then
  echo "[compiler-gate] FAIL: vibe deps closure missed the .vpkg sibling impl lib/@vibe/ast/ast.vibe (#988)" >&2
  cat "$depdir/closure.txt" "$depdir/closure.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The closure must cover the direct deps; a closure smaller than one hop means
# the walk terminated early and every caller under-selects.
while IFS= read -r dep_line; do
  [ -n "$dep_line" ] || continue
  if ! grep -qxF "$dep_line" "$depdir/closure.txt"; then
    echo "[compiler-gate] FAIL: vibe deps closure is missing direct dep '$dep_line' (#988)" >&2
    exit 1
  fi
done < "$depdir/direct.txt"
# The entry never lists itself (callers treat the output as "other files").
if grep -qx 'lib/@vibe/parser/parser_smoke_test.vibe' "$depdir/closure.txt"; then
  echo "[compiler-gate] FAIL: vibe deps listed the entry itself (#988)" >&2
  exit 1
fi

# (c) An unresolvable import is an ERROR on the .diag sidecar with EMPTY output
# -- never a truncated list. A partial dep list is not a degraded answer, it is
# a wrong one, and it is the shape that makes a caller silently skip tests.
printf 'import ./does_not_exist.vibe {\n  nope\n}\n\nexport let a = 1\n' > "$depdir/broken.vibe"
dep_run broken.txt "$depdir/broken.vibe" VIBE_DEPS_DIRECT=1
if [ -s "$depdir/broken.txt" ] || [ ! -s "$depdir/broken.txt.diag" ]; then
  echo "[compiler-gate] FAIL: an unresolvable import did not land on the .diag sidecar with empty output (#988)" >&2
  cat "$depdir/broken.txt" "$depdir/broken.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$depdir"
echo "[compiler-gate] vibe deps import-closure ok (#988)"

# 101. #1262 / ADR-0100 (1): vibe answers "does this `let mut` escape?" with
#      TWO predicates on purpose -- lowering (`vibe escapes`, codegen's
#      `is_mut_captured_in`: box when unsure, since over-boxing only costs
#      speed) and enforcement (`vibe escapes --strict`, the checker's, whose
#      answer `TypeEnv` now carries via `env_bind_mut`: stay silent when
#      unsure, since a false positive is a wrong diagnostic). Two predicates
#      that are SUPPOSED to disagree are exactly the shape that rots into two
#      predicates that disagree by accident, so this pins WHERE they differ:
#      only on binder shadowing, and only in the one direction (strict's
#      output is a subset of the default's).
# 104/104. ADR-0091 (#1262): `vibe allocs` -- every heap-allocating site, as
#      `FN KIND OFFSET`. The direction is what matters and what this pins:
#      over-report, never under-report. A site this query misses lets
#      `#zero_alloc` certify something untrue, silently; a site it reports in
#      error costs the reader one line and argues back through a diagnostic.
#      So both halves are checked -- a function that allocates nothing really
#      produces EMPTY output (otherwise "clean" is worthless), and the sites
#      the source does not spell out (a closure's environment, a captured
#      `let mut` becoming a heap ref cell) really appear.
echo "[compiler-gate] 104/104 vibe allocs reports heap sites, and nothing else (ADR-0091 / #1262)"
bash "$ROOT_DIR/scripts/test_vibe_allocs_launcher.sh"
alcdir="_build/_gate_allocs"
rm -rf "$alcdir"; mkdir -p "$alcdir"
cat > "$alcdir/in.vibe" <<'ALCA'
fn pure_sum(a: Array[Int], n: Int) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < n {
    acc = acc + Array::get(a, i)
    i = i + 1
  }
  acc
}

fn counter() -> () -> Int {
  let mut c = 0
  () -> Int {
    c = c + 1
    c
  }
}
ALCA
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ALLOCS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$alcdir/in.vibe" "$alcdir/out.txt" >/dev/null 2>&1 || true
if [ -s "$alcdir/out.txt.diag" ]; then
  echo "[compiler-gate] FAIL: vibe allocs failed on a valid file (ADR-0091 / #1262)" >&2
  cat "$alcdir/out.txt.diag" >&2 || true
  exit 1
fi
# The reads-only function must contribute NOTHING: "empty means zero-alloc" is
# the whole contract.
if grep -q '^pure_sum ' "$alcdir/out.txt" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe allocs reported a site in an allocation-free function (ADR-0091 / #1262)" >&2
  cat "$alcdir/out.txt" >&2 || true
  exit 1
fi
# The two implicit sites -- neither is visible in the source text.
for want in "counter mut-cell" "counter closure"; do
  if ! grep -q "^$want " "$alcdir/out.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe allocs missed '$want' -- an implicit allocation ADR-0091 exists to surface (#1262)" >&2
    cat "$alcdir/out.txt" >&2 || true
    exit 1
  fi
done
# Exercise the advertised PUBLIC verb too. The adapter-only environment lane
# above cannot catch a missing `runtime/vibe` case (the original #1792 review
# regression): that would leave `vibe allocs` documented but unusable.
VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  VIBE_CLI_WASM="$stage2_wasm" \
  bash "$ROOT_DIR/runtime/vibe" allocs "$alcdir/in.vibe" > "$alcdir/public.txt"
for want in "counter mut-cell" "counter closure"; do
  if ! grep -q "^$want " "$alcdir/public.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: public 'vibe allocs' missed '$want' (#1262)" >&2
    cat "$alcdir/public.txt" >&2 || true
    exit 1
  fi
done
# A file with no functions at all is empty output, not an error.
printf 'enum Empty {\n  E0\n}\n' > "$alcdir/none.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ALLOCS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$alcdir/none.vibe" "$alcdir/none.txt" >/dev/null 2>&1 || true
if [ -s "$alcdir/none.txt" ] || [ -s "$alcdir/none.txt.diag" ]; then
  echo "[compiler-gate] FAIL: vibe allocs on a function-free file should be empty and clean (#1262)" >&2
  cat "$alcdir/none.txt" "$alcdir/none.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$alcdir"
echo "[compiler-gate] vibe allocs ok (ADR-0091 / #1262)"

echo "[compiler-gate] 101/104 the two escape predicates differ only on shadowing (#1262)"
escdir="_build/_gate_escapes"
rm -rf "$escdir"; mkdir -p "$escdir"

esc_run() { # esc_run <out> <src> <strict>
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ESCAPES=1 VIBE_ESCAPES_STRICT="$3" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$2" "$escdir/$1" >/dev/null 2>&1 || true
}

# (a) A genuine capture: BOTH lanes must report it. If only one does, one of
# the two is broken -- they are meant to agree everywhere except shadowing.
cat > "$escdir/real.vibe" <<'ESCA'
fn main() -> Int {
  let mut acc = 0
  let bump = () -> Unit { acc = acc + 1 }
  bump()
  acc
}
ESCA
esc_run real_loose.txt "$escdir/real.vibe" 0
esc_run real_strict.txt "$escdir/real.vibe" 1
for lane in loose strict; do
  if ! grep -q '^acc ' "$escdir/real_$lane.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe escapes ($lane lane) missed a genuine closure capture (#1262)" >&2
    cat "$escdir/real_$lane.txt" "$escdir/real_$lane.txt.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done

# (b) A `for-in` binder that merely REUSES the outer `let mut`'s name. The
# closure captures the LOOP variable, so no authority crosses the binding --
# but codegen still boxes the outer cell on the name match. Loose must report
# it (that box is real, and a cost query must say so); strict must not.
cat > "$escdir/shadow.vibe" <<'ESCB'
fn main(xs: Array[Int]) -> Int {
  let mut n = 0
  for n in xs {
    let c = () -> Int { n }
    let _ = c()
  }
  n
}
ESCB
esc_run shadow_loose.txt "$escdir/shadow.vibe" 0
esc_run shadow_strict.txt "$escdir/shadow.vibe" 1
if ! grep -q '^n ' "$escdir/shadow_loose.txt" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the LOWERING escape lane stopped reporting a shadowed name -- it must stay conservative, because codegen really does box that cell (#1262)" >&2
  cat "$escdir/shadow_loose.txt" "$escdir/shadow_loose.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
if [ -s "$escdir/shadow_strict.txt" ]; then
  echo "[compiler-gate] FAIL: \`vibe escapes --strict\` reported a binding a binder SHADOWS -- the enforcement predicate must subtract shadowing, or every check built on it (Spawnable today, region/Mut[c] next) inherits a false positive (#1262 / ADR-0100 (1))" >&2
  cat "$escdir/shadow_strict.txt" >&2
  exit 1
fi

# (c) A lex/parse failure goes to the .diag sidecar with EMPTY output, in both
# lanes -- "the query broke" must stay distinguishable from "nothing escapes",
# since empty output is this surface's clean signal.
printf 'fn main() -> Int {\n  let mut = =\n}\n' > "$escdir/broken.vibe"
esc_run broken_loose.txt "$escdir/broken.vibe" 0
esc_run broken_strict.txt "$escdir/broken.vibe" 1
for lane in loose strict; do
  if [ -s "$escdir/broken_$lane.txt" ] || [ ! -s "$escdir/broken_$lane.txt.diag" ]; then
    echo "[compiler-gate] FAIL: a broken source did not land on the .diag sidecar with empty output in the $lane escape lane (#1262)" >&2
    cat "$escdir/broken_$lane.txt" "$escdir/broken_$lane.txt.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done
rm -rf "$escdir"
echo "[compiler-gate] escape predicate two-lane split ok (#1262)"

# 102. ADR-0101 (3) / #1262: the Builder family's terminal verb is `build`, so
#      the type name and the verb correspond lexically. `freeze` is reserved
#      for the verb producing a Frozen- (persistent + Send) value, which a
#      Builder terminal is not -- the worst case of the old spelling was
#      `ArrayBuilder::freeze -> Array`, where the result of "freeze" is
#      mutable. The new spelling rides `canonical_builtin_name`, so it must
#      reach the SAME registry row and the SAME codegen dispatch as the legacy
#      one in BOTH backends: a source-level alias that only the checker knows
#      about would typecheck and then miscompile.
echo "[compiler-gate] 102/104 StringBuilder::build reaches the same lowering as ::freeze (ADR-0101 (3) / #1262)"
sbdir="_build/_gate_sb_build"
rm -rf "$sbdir"; mkdir -p "$sbdir"
cat > "$sbdir/build.vibe" <<'SBB'
fn joined() -> String {
  let b = StringBuilder::new()
  StringBuilder::push(b, "hello ")
  StringBuilder::push(b, "world")
  StringBuilder::build(b)
}

fn main() -> Int {
  String::length(joined())
}
SBB
sed 's/StringBuilder::build(b)/StringBuilder::freeze(b)/' "$sbdir/build.vibe" > "$sbdir/freeze.vibe"
for spelling in build freeze; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$sbdir/$spelling.vibe" "$sbdir/$spelling.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$sbdir/$spelling.wasm" ]; then
    echo "[compiler-gate] FAIL: StringBuilder::$spelling did not compile (ADR-0101 (3) / #1262)" >&2
    cat "$sbdir/$spelling.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  sb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$sbdir/$spelling.wasm" 2>&1 | tail -1)"
  if [ "$sb_out" != "11" ]; then
    echo "[compiler-gate] FAIL: StringBuilder::$spelling produced '$sb_out' (want 11 = len(\"hello world\")) -- the two spellings must lower identically (#1262)" >&2
    exit 1
  fi
done
# Byte-identical output is the strong form of "same lowering": the alias is
# resolved before anything downstream can branch on the spelling, so the two
# programs are the same program.
if ! cmp -s "$sbdir/build.wasm" "$sbdir/freeze.wasm"; then
  echo "[compiler-gate] FAIL: StringBuilder::build and ::freeze produced DIFFERENT wasm -- the alias is being resolved somewhere downstream of a branch on the name (ADR-0101 (3) / #1262)" >&2
  exit 1
fi
rm -rf "$sbdir"
echo "[compiler-gate] StringBuilder::build terminal-verb alias ok (#1262)"

# 103. #1262 follow-up: `vibe check` must answer for a file that imports a
#      `@scope/pkg` package. It could not -- `check_linked_file` ran a SECOND
#      import resolution (`resolve_import_path`, a plain path join) alongside
#      the loader's real one, so `import @vibe/core { ... }` was read as the
#      filename `@vibe/core.vibe` and the check ABORTED. The same file
#      compiles, which is the exact shape CLAUDE.md calls a diagnostic hole:
#      the verb that is supposed to answer "does this compile?" could not.
#      The second consequence was quieter and worse -- `check_deprecated_warnings`
#      used that same resolver, so a `#deprecated` alias published by a PACKAGE
#      (every alias the ADR-0100 (3) collection rename shipped) was invisible
#      and the migration warning the rename PROMISED never appeared.
echo "[compiler-gate] 103/104 vibe check resolves @scope/pkg imports, and package deprecations warn (#1262)"
chkpkgdir="_build/_gate_check_scoped_pkg"
rm -rf "$chkpkgdir"; mkdir -p "$chkpkgdir"
cat > "$chkpkgdir/entry.vibe" <<'CHKPKG'
import @vibe/core {
  MutMap, MutMap::size, HashMap::new_string
}

fn main() -> Int {
  let m: MutMap[String, Int] = HashMap::new_string()
  MutMap::size(m)
}
CHKPKG
# Read the status rather than calling bare: the FAIL branch below exists to
# keep this surface from producing "a diagnostic-free failure", and under
# errexit a bare call made that branch unreachable -- the exact thing it
# guards against.
gate_status chk_rc env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkpkgdir/entry.vibe" "$chkpkgdir/check.out" main
# (a) it must SUCCEED. A crash here used to produce exit 1 with an empty
# output AND an empty .diag -- indistinguishable from a diagnostic-free
# failure, which is the one thing this surface must never be.
if [ "$chk_rc" != "0" ]; then
  echo "[compiler-gate] FAIL: vibe check exited $chk_rc on a file importing @vibe/core -- the second import resolver is back (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -q '^ok$' "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe check on a @scope/pkg importer did not report clean (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
# (b) the deprecated alias must NAME its replacement. This is the half that
# was silently false: the scanner worked, but the package's marker never
# reached it, so the rename's documented migration path did not exist.
if ! grep -qF "'HashMap::new_string' is deprecated: use MutMap::new_string" "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a #deprecated alias published by a PACKAGE did not warn -- ADR-0100 (3)'s staged migration depends on this (#1262)" >&2
  cat "$chkpkgdir/check.out" >&2
  exit 1
fi
# (c) warnings are NON-FATAL. The migration must not break builds, so the
# exit code above (0) and this line together are the contract.
if ! grep -q '^warning: ' "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the deprecation line is not spelled as a warning (#1262)" >&2
  exit 1
fi
# (d) the control: the NEW spelling is silent. Without this, a check that
# warned unconditionally would pass every assertion above.
sed 's/, HashMap::new_string//; s/HashMap::new_string()/MutMap::new_string()/' \
  "$chkpkgdir/entry.vibe" > "$chkpkgdir/clean.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkpkgdir/clean.vibe" "$chkpkgdir/clean.out" main >/dev/null 2>&1 || true
if grep -q '^warning: ' "$chkpkgdir/clean.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the Mut- spelling warned -- the deprecation scan is not name-selective (#1262)" >&2
  cat "$chkpkgdir/clean.out" >&2
  exit 1
fi
rm -rf "$chkpkgdir"
echo "[compiler-gate] scoped-package check + package deprecation warnings ok (#1262)"

# 104. #1700: a generic transparent alias published by index.vpkg must keep
#      its formal parameters and target through the importer TypeEnv
#      projection. The committed seed predates that transport and diagnoses
#      `Box[Int]` vs `Cell[Int]`; the fresh stage2 must accept it. The opaque
#      control proves this is alias transparency, not a weakening that makes
#      every applied package type interchangeable.
echo "[compiler-gate] 104/104 generic aliases cross index.vpkg transparently (#1700)"
if ! VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/generic_alias_vpkg_test.vibe \
  fixtures/immutmap_alias_test.vibe \
  lib/@vibe/core/collection_alias_test.vibe >/dev/null; then
  echo "[compiler-gate] FAIL: a generic transparent alias did not cross an index.vpkg boundary (#1700)" >&2
  exit 1
fi
aliasdir="_build/_gate_generic_alias_vpkg"
rm -rf "$aliasdir"; mkdir -p "$aliasdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/generic_opaque_vpkg_mismatch.vibe "$aliasdir/opaque.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ -s "$aliasdir/opaque.wasm" ] \
  || ! grep -qF "expected Token[Int], got Seal[Int]" "$aliasdir/opaque.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: distinct opaque generic contract types stopped being nominal (#1700 control)" >&2
  cat "$aliasdir/opaque.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$aliasdir"
echo "[compiler-gate] generic transparent alias + opaque control ok (#1700)"

# 105. #2158: the checker's per-call-site Double type reaching the LINEAR
#      backend's floatish classifiers (CompileCtx.float_call_offsets).
#
#      Compiled through the SINGLE-SOURCE lane on purpose -- no
#      VIBE_FS_COMPILE, so `compile_source_wasi_only` runs, which is the linear
#      entry that supplies the offsets. `scripts/vibe_test.sh` and
#      `scripts/unit_test_runner.sh` both set VIBE_FS_COMPILE=1 and would take
#      the FS merge lane, where the channel is not wired; running the fixture
#      there would assert the wrong thing (and fail). The fixture is named
#      without a `_test` suffix so the unit runner's glob does not pick it up.
echo "[compiler-gate] 105/105 checker Double call-result offsets on the linear source lane (#2158)"
fcodir="_build/_gate_float_call_offsets"
rm -rf "$fcodir"; mkdir -p "$fcodir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/float_call_offset_source_lane.vibe "$fcodir/fco.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ ! -s "$fcodir/fco.wasm" ]; then
  echo "[compiler-gate] FAIL: float call-offset fixture did not compile (#2158)" >&2
  cat "$fcodir/fco.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fcodir/fco.wasm" >"$fcodir/run.log" 2>&1; then
  echo "[compiler-gate] FAIL: a Double reaching __to_string through a call still renders as raw bits (#2158)" >&2
  cat "$fcodir/run.log" >&2 || true
  exit 1
fi
rm -rf "$fcodir"
echo "[compiler-gate] linear source-lane Double call-result offsets ok (#2158)"

# ...and the offset that channel uses must not be one another node already
# owns. #2231's first fix gave a call-rooted dot-call the DOT FIELD NAME's
# offset, which `type_at.vibe` uses to identify that token; the type table is
# last-wins, so the call's result type would have overwritten it (#2248
# review). The `(` of the argument list belongs to no other node, and this
# pins that: an identifier in a call-rooted dot-call keeps its own type.
tadir="_build/_gate_typeat_callsite"
rm -rf "$tadir"; mkdir -p "$tadir"
cat > "$tadir/ta.vibe" <<'TAEOF'
struct Box { get: () -> Double }
fn mk_box() -> Box { Box::{ get: () -> { 2.5 } } }
fn main() -> Int {
  let v = mk_box().get()
  0
}
TAEOF
ta_out="$(VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" type-at "$tadir/ta.vibe" 4 11 2>/dev/null | head -1)"
if [ "$ta_out" != "() -> Box" ]; then
  echo "[compiler-gate] FAIL: type-at on \`mk_box\` in a call-rooted dot-call reports '$ta_out', not '() -> Box' -- the call-site offset is stealing an identifier token (#2231/#2248)" >&2
  exit 1
fi

# #2261: the same collision for an IDENT-rooted dot-call. `b.get()` gave the
# outer call the offset of the identifier `b`, and type-at's table is
# last-wins, so hovering `b` answered `Double` -- the CALL's result -- instead
# of `Box`. #1941 solved this for a NAMED callee via `CalleeHit`, but that
# escape resolves through the top-level env and cannot answer for a local
# receiver. Three positions, because a fix that answered "" everywhere would
# also stop reporting Double.
cat > "$tadir/ta2.vibe" <<'TAEOF2'
struct Box { get: () -> Double }
fn mk_box() -> Box { Box::{ get: () -> { 2.5 } } }
fn main() -> Int {
  let b = mk_box()
  let w = b.get()
  let z = b
  0
}
TAEOF2
ta_q() { VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" type-at "$tadir/ta2.vibe" "$1" "$2" 2>/dev/null | head -1; }
ta_recv="$(ta_q 5 11)"
ta_plain="$(ta_q 6 11)"
ta_fn="$(ta_q 4 11)"
if [ "$ta_recv" != "Box" ] || [ "$ta_plain" != "Box" ] || [ "$ta_fn" != "() -> Box" ]; then
  echo "[compiler-gate] FAIL: type-at on a dot-call receiver (#2261): recv='$ta_recv' plain='$ta_plain' fn='$ta_fn'; wanted Box / Box / () -> Box" >&2
  exit 1
fi
rm -rf "$tadir"
echo "[compiler-gate] call-site offset does not steal an identifier token ok (#2231)"

# 106/106. `vibe fmt` (#2149). The formatter has always been real and
#      CI-enforced, but reachable only through lib/@vibe/cli/fmt_entry.vibe --
#      a separate wasm scripts/vibe_fmt.sh FS-compiles on demand, whose paths
#      must live under the repo checkout. So an INSTALLED user could not
#      format at all, while 21 documents told them to run `vibe fmt`.
#
#      Two halves, and the second is the one that can rot silently. The
#      launcher arm's own decisions (mode dispatch, refusal, adapter-mode env
#      clearing) are pinned by a fake runner, so they are checked even when no
#      compiler is built. Then the real thing: the stage2 under test formats a
#      messy file through VIBE_FMT and must produce the canonical layout --
#      the guest branch, not the shell around it.
echo "[compiler-gate] 106/106 vibe fmt reaches an installed user (#2149)"
bash "$ROOT_DIR/scripts/test_vibe_fmt_launcher.sh"
# cli_adapter dispatches on selectors in SOURCE ORDER, so a leaked one hijacks
# every verb whose selector is evaluated later. Keeping the launcher's `env -u`
# lists right by hand demonstrably does not work -- this PR shipped an arm
# missing six selectors, then fixed one arm at a time and still missed three.
# So the requirement is DERIVED from cli_adapter rather than restated.
bash "$ROOT_DIR/scripts/check_selector_precedence.sh"
# ...and prove that check can FAIL. It reported ok on a hijackable tree five
# separate times; each defect was caught by a reviewer, and each red test that
# proved the fix lived only in a commit message, so the guarantee did not
# survive the next edit. Every one of those five is now a case.
bash "$ROOT_DIR/scripts/check_selector_precedence_test.sh"
# The same rule, for every gate: a new one ships with a self-test that mutates
# a real input and asserts the gate fails (ratcheted -- 18 predate the rule).
bash "$ROOT_DIR/scripts/check_gate_self_tests.sh"
bash "$ROOT_DIR/scripts/check_gate_self_tests_test.sh"
# ...and the two ways a self-test stops meaning anything without ever going
# red: it depends on a tool CI does not have (ripgrep -- five of them did, and
# were exempted rather than fixed), or its pattern quietly means something
# other than it reads (`grep -E` does not interpret `\t`, so `'x\t'` matches
# `xt` and the check answers "no match" forever). #2252.
bash "$ROOT_DIR/scripts/check_gate_portability.sh"
bash "$ROOT_DIR/scripts/check_gate_portability_test.sh"
# check_book_console.sh landed (#2253) with no self-test and CI caught it the
# same day -- the ratchet working as intended. Its cases hand the gate a STUB
# compiler so the transcripts fail identically for all of them, and assert the
# message each mutation adds on top: block count, ja/en parity, and whether the
# chapter's documented 42 -> 43 edit still applies. ~1s, no generation needed.
bash "$ROOT_DIR/scripts/check_book_console_test.sh"

# 107/107. The host runner's `[crash debug]` dump is OFF by default (#2199).
#      It is compiler-developer diagnostics -- heap bytes, the RC freelist, raw
#      memory windows -- and it printed on EVERY trap, so the first thing a
#      reader saw when `Array::get(xs, 10)` went out of range was a page of hex
#      ahead of the message naming the index and the length. Both directions
#      are asserted: silence alone would also pass if the program stopped
#      trapping, and the dump alone would pass if it were unconditional again.
echo "[compiler-gate] 107/107 the host runner's crash dump is opt-in (#2199)"
cdbg="_build/_gate_crash_debug"
rm -rf "$cdbg"; mkdir -p "$cdbg"
cat > "$cdbg/oob.vibe" <<'CDBGEOF'
fn main() -> Int with Console {
  let xs = [1, 2, 3]
  println("get = \{Array::get(xs, 10)}")
  0
}
CDBGEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$cdbg/oob.vibe" "$cdbg/oob.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$cdbg/oob.wasm" ]; then
  echo "[compiler-gate] FAIL: crash-debug fixture did not compile (#2199)" >&2
  cat "$cdbg/oob.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh   --invoke _start "$cdbg/oob.wasm" >"$cdbg/quiet.log" 2>&1 || true
VIBE_CRASH_DEBUG=1 VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh   --invoke _start "$cdbg/oob.wasm" >"$cdbg/loud.log" 2>&1 || true
if grep -qF '[crash debug]' "$cdbg/quiet.log"; then
  echo "[compiler-gate] FAIL: the crash dump printed without VIBE_CRASH_DEBUG (#2199)" >&2
  cat "$cdbg/quiet.log" >&2
  exit 1
fi
if ! grep -qF 'Array::get: index 10 out of bounds for length 3' "$cdbg/quiet.log"; then
  echo "[compiler-gate] FAIL: the bounds message the reader needs is gone too (#2199)" >&2
  cat "$cdbg/quiet.log" >&2
  exit 1
fi
if ! grep -qF '[crash debug]' "$cdbg/loud.log"; then
  echo "[compiler-gate] FAIL: VIBE_CRASH_DEBUG=1 produced no dump -- the gate above proves nothing (#2199)" >&2
  cat "$cdbg/loud.log" >&2
  exit 1
fi
rm -rf "$cdbg"
echo "[compiler-gate] crash dump opt-in ok (#2199)"

# 108/108. The ADR-0068 concurrency surface is opt-in (#2248).
#      docs/spec/stable-surface.md said the unstable surface "is reached only
#      through `@build.unstable`, an explicit flag, or an ADR still marked
#      `proposed`" -- and `@build.unstable` appeared nowhere else in the tree,
#      there was no such flag, and `TaskGroup::run` checked clean with no
#      marker of any kind.
#
#      BOTH verbs, because a build that accepts what the check rejects is the
#      "two verbs, two answers" defect #1567 fixed for check/diagnostics, and
#      it is worse here: the accepting verb is the one that ships. And three
#      directions each, since any one alone is satisfiable by the wrong thing
#      -- silence would also pass if the gate were deleted, rejection would
#      also pass if the opt-in did nothing, and both would pass if it rejected
#      every file.
echo "[compiler-gate] 108/108 the ADR-0068 concurrency surface is opt-in, in check AND build (#2248)"
uwdir="_build/_gate_unstable_warn"
rm -rf "$uwdir"; mkdir -p "$uwdir"
cat > "$uwdir/uses.vibe" <<'UWEOF'
import @vibe/concurrent { TaskGroup }

fn main() -> Int with Exception {
  TaskGroup::run((n) -> {
    let _t = TaskGroup::spawn(n, () -> { 7 })
    0
  })
}
UWEOF
cat > "$uwdir/plain.vibe" <<'UWEOF'
fn main() -> Int { 1 + 1 }
UWEOF
# `env -u VIBE_UNSTABLE`: the no-opt-in cases must not inherit the opt-in.
# Measured -- with VIBE_UNSTABLE=1 in the ambient environment this section
# reported "did not reject" and would have passed vacuously had the assertion
# been the other way round. Same defect #2252 found in five self-tests: a
# check that measures the machine, not the property.
uw_check() { env -u VIBE_UNSTABLE VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" check "$1" 2>&1; }
uw_build() { # <src> <out> [extra env assignments...]
  local src="$1" out="$2"; shift 2
  rm -f "$out" "$out.diag"
  env -u VIBE_UNSTABLE "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$src" "$out" main >/dev/null 2>&1 || true
}

# check: rejected, opt-in accepted, unrelated file untouched.
#
# Captured into a variable, not piped: this gate runs under `set -o pipefail`,
# and `uw_check` exits 1 on the rejection it is asserting, so `uw_check | grep`
# fails even when grep MATCHES. Measured -- the first version reported "vibe
# check accepted @vibe/concurrent" while the rejection it was looking for was
# printed one line above it in the same log.
uw_uses_out="$(uw_check "$uwdir/uses.vibe" || true)"
if ! printf '%s\n' "$uw_uses_out" | grep -qF 'VIBE_UNSTABLE=1'; then
  echo "[compiler-gate] FAIL: vibe check accepted @vibe/concurrent with no opt-in (#2248)" >&2
  printf '%s\n' "$uw_uses_out" >&2
  exit 1
fi
if ! VIBE_UNSTABLE=1 VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" check "$uwdir/uses.vibe" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let vibe check through (#2248)" >&2
  exit 1
fi
uw_plain_out="$(uw_check "$uwdir/plain.vibe" || true)"
if printf '%s\n' "$uw_plain_out" | grep -qF 'VIBE_UNSTABLE=1'; then
  echo "[compiler-gate] FAIL: a file not importing @vibe/concurrent was rejected anyway (#2248)" >&2
  printf '%s\n' "$uw_plain_out" >&2
  exit 1
fi

# build: the same three, through the FS-compile lane.
uw_build "$uwdir/uses.vibe" "$uwdir/uses.wasm"
if [ -s "$uwdir/uses.wasm" ]; then
  echo "[compiler-gate] FAIL: vibe build accepted @vibe/concurrent with no opt-in -- the build accepts what the check rejects (#2248)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/uses.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the build rejection did not name the opt-in (#2248)" >&2
  cat "$uwdir/uses.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
uw_build "$uwdir/uses.vibe" "$uwdir/uses_optin.wasm" VIBE_UNSTABLE=1
if [ ! -s "$uwdir/uses_optin.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let the build through (#2248)" >&2
  cat "$uwdir/uses_optin.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
uw_build "$uwdir/plain.vibe" "$uwdir/plain.wasm"
if [ ! -s "$uwdir/plain.wasm" ]; then
  echo "[compiler-gate] FAIL: a file not importing @vibe/concurrent failed to build (#2248)" >&2
  cat "$uwdir/plain.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi

# Whitespace must not cross the boundary (#2277 review). The first version of
# the scan matched `String::starts_with(line, "import ")` and sliced a fixed 7
# bytes, so a tab skipped the check outright and two spaces yielded an empty
# package name. Both spellings are valid source the lexer accepts, so both were
# a silent bypass; the gate now reads the PARSED import instead. Written with
# printf rather than a heredoc so the tab survives being read back.
printf 'import\t@vibe/concurrent { TaskGroup }\n\nfn main() -> Int with Exception {\n  TaskGroup::run((n) -> { 0 })\n}\n' > "$uwdir/tab.vibe"
printf 'import  @vibe/concurrent { TaskGroup }\n\nfn main() -> Int with Exception {\n  TaskGroup::run((n) -> { 0 })\n}\n' > "$uwdir/spaces.vibe"
for uw_odd in tab spaces; do
  uw_odd_out="$(uw_check "$uwdir/$uw_odd.vibe" || true)"
  if ! printf '%s\n' "$uw_odd_out" | grep -qF 'VIBE_UNSTABLE=1'; then
    echo "[compiler-gate] FAIL: '$uw_odd' whitespace spelling of the import bypassed the check gate (#2277)" >&2
    printf '%s\n' "$uw_odd_out" >&2
    exit 1
  fi
  uw_build "$uwdir/$uw_odd.vibe" "$uwdir/$uw_odd.wasm"
  if [ -s "$uwdir/$uw_odd.wasm" ]; then
    echo "[compiler-gate] FAIL: '$uw_odd' whitespace spelling of the import bypassed the build gate (#2277)" >&2
    exit 1
  fi
done

# The reported line must be the OFFENDING import, not the first line that
# mentions the package. `import @vibe/core { .. } // @vibe/concurrent` is a
# stable import carrying the name in a comment; naming it told the reader to
# delete a line that was not the problem, which is worse than no line at all
# (#2277 review). The offending import is on line 3 here.
cat > "$uwdir/comment.vibe" <<'UWEOF'
import @vibe/core { array_empty } // @vibe/concurrent

import @vibe/concurrent { TaskGroup }

fn main() -> Int with Exception {
  TaskGroup::run((n) -> { 0 })
}
UWEOF
uw_build "$uwdir/comment.vibe" "$uwdir/comment.wasm"
if ! grep -qF 'line 3:' "$uwdir/comment.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the opt-in diagnostic named the wrong import line (#2277)" >&2
  cat "$uwdir/comment.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$uwdir"
echo "[compiler-gate] ADR-0068 opt-in gate: check + build + whitespace + comment-line ok (#2248, #2277)"
fmtdir="_build/_gate_vibe_fmt"
rm -rf "$fmtdir"; mkdir -p "$fmtdir"
printf 'let   add=(a:Int,b:Int)->Int{a+b}\n' > "$fmtdir/messy.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fmtdir/messy.vibe" "$fmtdir/out.vibe" >"$fmtdir/run.log" 2>&1 || true
if [ ! -s "$fmtdir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: VIBE_FMT produced no output -- vibe fmt is not wired into the compiler (#2149)" >&2
  cat "$fmtdir/run.log" >&2 || true
  exit 1
fi
cat > "$fmtdir/expected.vibe" <<'FMTEXP'
let add = (a: Int, b: Int) -> Int {
  a + b
}
FMTEXP
if ! cmp -s "$fmtdir/expected.vibe" "$fmtdir/out.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_FMT did not produce the canonical layout (#2149)" >&2
  diff -u "$fmtdir/expected.vibe" "$fmtdir/out.vibe" >&2 || true
  exit 1
fi
rm -rf "$fmtdir"
echo "[compiler-gate] vibe fmt ok (#2149)"

# 109/109. A multiline closure literal in a NON-FINAL argument slot formats to
# a fixpoint (#2271). Reported as permanently unformattable -- apply changed
# nothing, --check kept reporting a diff. The construct was never the problem:
# the formatter ENTRY had failed to compile (a fresh checkout has none of the
# untracked generated artifacts), and `vibe fmt` spelled "I could not build
# myself" with the same exit 1 it uses for "this file is not formatted", so a
# caller looped forever. Fixed in scripts/ensure_entry_wasm.sh (the failure is
# loud) and scripts/vibe_fmt.sh (it exits 2), pinned there by
# scripts/ensure_entry_wasm_test.sh. This section pins the other half of the
# report -- that the SHAPE formats, on the stage2 lane -- so the issue's claim
# is a regression test in both directions.
echo "[compiler-gate] 109/109 a multiline closure in a non-final argument slot formats to a fixpoint (#2271)"
nfdir="_build/_gate_nonfinal_closure"
rm -rf "$nfdir"; mkdir -p "$nfdir"
cat > "$nfdir/in.vibe" <<'NFIN'
fn collect_by(is_formal: (String) -> Bool, out: Array[String]) -> Unit {
  ()
}
fn caller(shadow: Array[String], out: Array[String]) -> Unit {
  collect_by((head) -> {
      let mut found = false
      if Array::length(shadow) > 0 {
    found = true
      } else {
        ()
      }
      found
  }, out)
}
NFIN
cat > "$nfdir/expected.vibe" <<'NFEXP'
fn collect_by(is_formal: (String) -> Bool, out: Array[String]) -> Unit {
  ()
}
fn caller(shadow: Array[String], out: Array[String]) -> Unit {
  collect_by((head) -> {
    let mut found = false
    if Array::length(shadow) > 0 {
      found = true
    } else {
      ()
    }
    found
  }, out)
}
NFEXP
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nfdir/in.vibe" "$nfdir/out.vibe" >"$nfdir/run.log" 2>&1 || true
if [ ! -s "$nfdir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: the formatter produced nothing for a non-final closure argument (#2271)" >&2
  cat "$nfdir/run.log" >&2 || true
  exit 1
fi
if ! cmp -s "$nfdir/expected.vibe" "$nfdir/out.vibe"; then
  echo "[compiler-gate] FAIL: non-final closure argument not formatted as expected (#2271)" >&2
  diff -u "$nfdir/expected.vibe" "$nfdir/out.vibe" >&2 || true
  exit 1
fi
# The fixpoint is the half the issue said was unreachable: formatting the
# formatted form again must change nothing, or `pkf run fmt` and CI's
# vibe-fmt-check disagree about the file forever.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nfdir/expected.vibe" "$nfdir/again.vibe" >"$nfdir/again.log" 2>&1 || true
if ! cmp -s "$nfdir/expected.vibe" "$nfdir/again.vibe"; then
  echo "[compiler-gate] FAIL: the formatted non-final closure is not a fixpoint (#2271)" >&2
  diff -u "$nfdir/expected.vibe" "$nfdir/again.vibe" >&2 || true
  exit 1
fi
rm -rf "$nfdir"
echo "[compiler-gate] non-final closure argument fixpoint ok (#2271)"

# 110/110. An `assert_eq` failure names the line it fired on (#2202).
# The report gave the test name and both sides but no location, so a test with
# several asserts sharing an expected value could not say which one failed --
# and the book's chapter 12 reproduces that output shape verbatim, documenting
# the gap without naming it.
#
# Two directions, because either alone is satisfiable by the wrong thing: the
# SECOND assert's line must appear (not merely "a line"), and the first
# assert's line must NOT, or the stamp is attached to the test rather than to
# the call. `vibe test` compiles through VIBE_FS_COMPILE, which is the lane
# that merges modules and therefore the lane where offsets are per-module.
echo "[compiler-gate] 110/110 an assert_eq failure names its own line (#2202)"
aldir="_build/_gate_assert_line"
rm -rf "$aldir"; mkdir -p "$aldir"
cat > "$aldir/two_asserts_test.vibe" <<'ALEOF'
fn double(n: Int) -> Int {
  n * 2
}

test "which assert fired" {
  assert_eq(double(21), 42)
  assert_eq(double(2), 5)
}
ALEOF
VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$aldir/two_asserts_test.vibe" >"$aldir/out.log" 2>&1 || true
# The failing assert is on line 7; the passing one is on line 6.
if ! grep -qF 'two_asserts_test.vibe:7' "$aldir/out.log"; then
  echo "[compiler-gate] FAIL: the assert_eq failure did not name the line it fired on (#2202)" >&2
  cat "$aldir/out.log" >&2
  exit 1
fi
if grep -qF 'two_asserts_test.vibe:6' "$aldir/out.log"; then
  echo "[compiler-gate] FAIL: the report named the PASSING assert's line -- the stamp is not per call (#2202)" >&2
  cat "$aldir/out.log" >&2
  exit 1
fi
# The values still have to be there: a location that replaced the diagnostic
# would pass the two checks above and be a regression.
if ! grep -qF 'expected: 5' "$aldir/out.log" || ! grep -qF 'actual:   4' "$aldir/out.log"; then
  echo "[compiler-gate] FAIL: the assert_eq report lost its operands (#2202)" >&2
  cat "$aldir/out.log" >&2
  exit 1
fi

# A USER-written three-argument `assert_eq` must still be an arity error, in
# BOTH lanes. The first version of the stamp reused `assert_eq` at arity 3 and
# recognized it by "third operand is a literal string", which made
# `assert_eq(1, 2, "user")` indistinguishable from a stamped call -- and the
# single-source lane lowers BEFORE it checks, so that call compiled and
# reported `assert_eq failed at user` instead of an arity error (#2277 review).
# The stamp is a separate internal callee now. Both lanes are checked because
# the FS lane happened to reject it anyway, by typechecking the unstamped
# module -- so testing only that lane proves nothing about this.
cat > "$aldir/user_three_arg.vibe" <<'ALEOF'
test "user three arg" {
  assert_eq(1, 2, "user")
}
ALEOF
al_fs_out="$(VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1   bash scripts/vibe_test.sh "$aldir/user_three_arg.vibe" 2>&1 || true)"
if ! printf '%s\n' "$al_fs_out" | grep -qF 'arity mismatch for assert_eq'; then
  echo "[compiler-gate] FAIL: a user-written 3-arg assert_eq was accepted by the FS lane (#2202)" >&2
  printf '%s\n' "$al_fs_out" >&2
  exit 1
fi
rm -f "$aldir/user.wasm" "$aldir/user.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$aldir/user_three_arg.vibe" "$aldir/user.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$aldir/user.wasm" ]; then
  echo "[compiler-gate] FAIL: a user-written 3-arg assert_eq COMPILED on the single-source lane -- it was lowered as a stamped call (#2202)" >&2
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$aldir/user.wasm" >&2 2>&1 || true
  exit 1
fi
if ! grep -qF 'arity mismatch for assert_eq' "$aldir/user.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the single-source lane rejected the 3-arg assert_eq for the wrong reason (#2202)" >&2
  cat "$aldir/user.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi

# The stamped callee must be UNSPELLABLE, not merely obscure. Two earlier
# spellings were reachable from source, and in the single-source lane the
# lowering runs before `check_program`, so anything it recognizes bypasses name
# and arity checking: `assert_eq` at arity 3 with a string, then the ordinary
# identifier `__assert_eq_at`. Both compiled and ran as asserts; the second
# would also have let a user DECLARING that name have their calls rewritten out
# from under them. `#` is not an identifier character, so the marker cannot be
# constructed from any input (#2277 review).
printf 'test "hijack" {\n  __assert_eq_at(1, 2, "user")\n}\n' > "$aldir/hijack.vibe"
rm -f "$aldir/hijack.wasm" "$aldir/hijack.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$aldir/hijack.vibe" "$aldir/hijack.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$aldir/hijack.wasm" ]; then
  echo "[compiler-gate] FAIL: user source spelling the stamped callee was lowered as an assert (#2202)" >&2
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$aldir/hijack.wasm" >&2 2>&1 || true
  exit 1
fi
# The `#` spelling is not an identifier at all -- the lexer refuses it, which is
# what makes the marker unspellable rather than merely unlikely.
printf 'test "hash" {\n  #assert_eq_at(1, 2, "user")\n}\n' > "$aldir/hash.vibe"
rm -f "$aldir/hash.wasm" "$aldir/hash.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$aldir/hash.vibe" "$aldir/hash.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$aldir/hash.wasm" ]; then
  echo "[compiler-gate] FAIL: a '#'-prefixed callee was accepted from source -- the marker is spellable (#2202)" >&2
  exit 1
fi
rm -rf "$aldir"
echo "[compiler-gate] assert_eq location + 3-arg + unspellable-marker rejection ok (#2202)"
