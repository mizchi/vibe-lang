#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.

# ADR-0068 (#2248): `@vibe/concurrent/experimental` needs `VIBE_UNSTABLE=1` to compile at
# all, and a dozen fixtures in this lane exercise that surface deliberately
# (region generativity, spawnable capture, the async boundary, the TaskGroup
# sugar). Granted lane-wide rather than per call site: the boundary exists for
# a USER's build, these are the repository's own fixtures, and the boundary
# itself is pinned by section 108 -- which clears the variable with
# `env -u VIBE_UNSTABLE` on every no-opt-in case precisely so it stays honest
# under an ambient grant.
export VIBE_UNSTABLE=1


# 41. ADR-0069 Phase 1: `fn main {}` sugar + entry/top-level hardening.
#     (a) ok_fnmain: the paren-less/annotation-less `fn main allows Stdout { .. }`
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
fn main allows Stdout {
  Stdout::write_stream("42\n")
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/ok_fnmain.vibe" "$a69dir/ok_fnmain.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$a69dir/ok_fnmain.wasm" ]; then
  echo "[compiler-gate] FAIL: fn main {} sugar did not compile" >&2
  cat "$a69dir/ok_fnmain.wasm.diag" >&2 2>/dev/null || true
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
  cat "$a69dir/int_main.wasm.diag" >&2 2>/dev/null || true
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
  cat "$a69dir/typo.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g830dir/toplevel_record_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g830dir/fnbody_record_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g844dir/toplevel_narrow.wasm.diag" >&2 2>/dev/null; exit 1
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
  cat "$g844dir/local_narrow.wasm.diag" >&2 2>/dev/null; exit 1
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
  cat "$g844dir/ok_bare_roundtrip.wasm.diag" >&2 2>/dev/null; exit 1
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
  cat "$g844dir/ok_matching.wasm.diag" >&2 2>/dev/null; exit 1
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
  cat "$g1078dir/ctor_collision.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/toplevel_tuple_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/toplevel_struct_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/toplevel_record_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/toplevel_destr_once.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/toplevel_refutable_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g859dir/fnbody_tuple_destr.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g944dir/leak_off.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g944dir/leak_on.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -f "$g944dir/discharged.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/discharged.vibe" "$g944dir/discharged.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944dir/discharged.wasm" ]; then
  echo "[compiler-gate] FAIL: checked-Error mode rejected a handle-with-Error discharge (over-strict, #944)" >&2
  cat "$g944dir/discharged.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g944cdir/out.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g944cdir/typed.wasm.diag" >&2 2>/dev/null || true
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
  cat "$g944cdir/strp.wasm.diag" >&2 2>/dev/null || true
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
# #3109: the node host runner ends every run -- a guest `process_exit`, a
# trap, a runner error -- through Node's normal exit path. `process.exit()`
# can hang on Node 24 against a concurrent Sparkplug job.
if ! node --test scripts/wasm_vibe_host_runner_exit.test.cjs >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: host runner exit paths (#3109)" >&2
  node --test scripts/wasm_vibe_host_runner_exit.test.cjs >&2 || true
  exit 1
fi
echo "[compiler-gate] host runner exit paths ok (#3109)"

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
  cat "$g1087dir/out.wasm.diag" >&2 2>/dev/null || true
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
  cat "$vpkgdir/scan.out.diag" >&2 2>/dev/null
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
  cat "$c1062dir/c1062.wasm.diag" >&2 2>/dev/null || true
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
  cat "$lspgatedir/stderr.log" >&2 2>/dev/null || true
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

# 48/48. ADR-0068 `Send` marker (docs/internal/design/concurrency.md "`Send` and capture
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
  cat "$senddir/pos.wasm.diag" >&2 2>/dev/null || true
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
    cat "$senddir/$tag.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
}
send_check_reject "err_type_send_array_bound.vibe" 'no impl `Send` for `Array[Int]`' "arr"
# #3156 review: a bound that EXTENDS `Send` (`trait Work: Send`) is Send in
# its body, so an instantiation that is not Send is refused at the call even
# when the program declares `impl Work for Array[Int]`.
send_check_reject "err_type_send_supertrait_bound.vibe" 'no impl `Send` for `Array[Int]`: `Work` extends `Send`' "super"
send_check_reject "err_type_send_mut_struct_bound.vibe" 'no impl `Send` for `Counter`' "mut"
send_check_reject "err_type_send_closure_bound.vibe" 'no impl `Send` for `' "clos"
send_check_reject "err_type_send_user_impl.vibe" '`Send` is a compiler-judged structural marker' "impl"
# #1090 review: the coinductive guard keys on constructor + ARGS — a
# recursive occurrence with different arguments must still be checked.
send_check_reject "err_type_send_nonregular_recursion.vibe" 'no impl `Send` for `LoopT[Int]`' "nonreg"
# #2523: the same shape for the COMPARISON markers. `Eq` / `Ord` are declared
# with no methods, so a `[T: Eq]` / `[T: Ord]` bound lowers to the builtin
# `==` / `<` -- correct for the five scalars the markers register impls for,
# REFERENCE identity for anything else. A user `impl Eq for Pt` used to make
# the bound satisfiable and the answer wrong (two EQUAL, distinct `Pt` gave
# `false`; one `Pt` against itself gave `true`). The bound is refused at the
# instantiation, not the impl, so the message matters as much as the refusal:
# the plain "no impl" half is misleading when an impl IS declared three lines
# above, and the hint is what names the edit.
send_check_reject "err_type_eq_marker_bound_struct.vibe" 'no impl `Eq` for `Pt`' "eqmarker"
send_check_reject "err_type_eq_marker_bound_struct.vibe" 'is a marker trait (declared with no methods)' "eqmarker2"
# #3327: the edit names `equals(Self, Self) -> Bool`, not "at least one method":
# a program `Eq` given some other method stops being a marker, stands the guard
# down, and still compares by reference.
send_check_reject "err_type_eq_marker_bound_struct.vibe" 'Give `Eq` an `equals(Self, Self) -> Bool` method' "eqmarker3"
send_check_reject "err_type_ord_marker_bound_struct.vibe" 'no impl `Ord` for `Token`' "ordmarker"
# #3327: a bound that EXTENDS a comparison marker is judged as that marker, the
# way `trait Work: Send` is judged as `Send` above. `trait Key: Eq {}` over the
# program's own marker `Eq` checked clean and answered `false` for two equal
# `Pt`; a subtrait of the prelude's `Ord` did the same for two equal `Token`.
send_check_reject "err_type_eq_marker_subtrait_bound_struct.vibe" 'no impl `Eq` for `Pt` (`Key` extends `Eq`)' "eqsub"
send_check_reject "err_type_eq_marker_subtrait_bound_struct.vibe" 'is a marker trait (declared with no methods)' "eqsub2"
send_check_reject "err_type_eq_marker_subtrait_bound_struct.vibe" 'Give `Eq` an `equals(Self, Self) -> Bool` method' "eqsub3"
# With no `impl Eq for Pt` written, the message must not say one is declared:
# `Pt` satisfies `Eq` only through `impl Key for Pt`.
send_check_reject "err_type_eq_marker_subtrait_no_parent_impl.vibe" 'no impl `Eq` for `Pt` (`Key` extends `Eq`): `Pt` implements `Eq`, but `Eq` is a marker trait' "eqsubnoimpl"
# Codex on #3349: the exemption for a subtrait that carries `equals(Self, Self)`
# follows the flattened dictionary's FIRST `equals`. `Key: Bad + Good + Eq`
# keeps `Bad`'s `equals(Int, Int)`, so it is refused; `Good + Bad + Eq` is
# accepted and answers in fixtures/eq_marker_subtrait_bound_accepted_test.vibe.
send_check_reject "err_type_eq_marker_subtrait_wrong_first_equals.vibe" 'no impl `Eq` for `Pt` (`Key` extends `Eq`)' "eqsubfirst"
send_check_reject "err_type_ord_subtrait_bound_struct.vibe" 'no impl `Ord` for `Token` (`Ordered` extends `Ord`)' "ordsub"
send_check_reject "err_type_ord_subtrait_bound_struct.vibe" 'giving `Ord` a method would not help' "ordsub2"
# #2895: `Double` is the instantiation the guard used to wave through, and it
# was the silent wrong answer the guard exists to prevent -- `lt[T: Ord](2.5,
# 1.5)` answered TRUE and `gt[T: Ord](2.5, 1.5)` answered FALSE, i.e. reading
# allocation order. `Eq` is no longer part of it: ADR-0097 gave it a method
# (#2523), so `[T: Eq]` at `Double` dispatches through a real witness and is
# pinned as an ANSWER in fixtures/eq_bound_derive_test.vibe. `Ord` is still a
# marker, so this fixture uses the PRELUDE's `Ord`.
send_check_reject "err_type_ord_marker_bound_double.vibe" 'no impl `Ord` for `Double`' "orddouble"
send_check_reject "err_type_ord_marker_bound_double.vibe" 'is a marker trait (declared with no methods)' "orddouble2"
# The edit, which differs from the struct case: nobody can add a method to the
# prelude's `Ord` from their own program, so "give it a method" is not advice a
# reader can act on here.
send_check_reject "err_type_ord_marker_bound_double.vibe" 'Compare at the concrete type' "orddouble3"
# #3158 review: `Add` is a marker too, and `[T: Add]`'s `+` lowers to
# `__generic_add` -- string join or a raw integer add. At `Double` that answered
# `add=0` for `1.5 + 2.25` on the linear lane; at a user struct it would add two
# pointers. Refused at both, with the edit named.
send_check_reject "err_type_add_marker_bound_double.vibe" 'no impl `Add` for `Double`' "adddouble"
send_check_reject "err_type_add_marker_bound_double.vibe" 'adds the raw representation, not the value' "adddouble2"
send_check_reject "err_type_add_marker_bound_double.vibe" 'Add at the concrete type' "adddouble3"
send_check_reject "err_type_add_marker_bound_struct.vibe" 'no impl `Add` for `Pt`' "addmarker"
send_check_reject "err_type_add_marker_bound_struct.vibe" 'adds the raw representation, not the value' "addmarker2"
# #2640: `@vibe/core` declares its collections BODYLESS in its contract
# (`type MutMap[K, V]`, `type MutSet[T]`), so a consumer sees them as
# `CtNamed` -- indistinguishable, in the type representation, from a rigid
# type parameter -- and they sat in `head_kind`'s tolerated `0` bucket. An
# `Array[String]` passed where a `MutSet[String]` is declared checked CLEAN
# and then trapped in `find_index`, reading the array header as a hash table.
#
# BOTH directions, because `head_kind` is consulted symmetrically
# (`eh != 0 && ah != 0 && eh != ah`): a fix that gave only one side a certain
# head would leave the other open and this row would not notice.
send_check_reject "err_type_mutset_from_array.vibe" 'expected MutSet[String], got Array[String]' "cgenhead"
send_check_reject "err_type_array_from_mutset.vibe" 'expected Array[String], got MutSet[String]' "cgenhead2"
# And against EACH OTHER: the two heads get separate kinds, so this pair is
# caught by `head_differ` rather than falling through to
# `nominal_head_conflict`. A shared kind would pass every other row here.
send_check_reject "err_type_mutmap_from_mutset.vibe" 'expected MutMap[String, Int], got MutSet[String]' "cgenhead3"
# #2378: a dependency's `fn` at a QUALIFIED builtin name replaces that builtin
# for every program that links the file, with nothing said. It is refused at
# the IMPORTER -- the module that never asked for the override and gets it
# anyway -- naming the dependency and leading with the edit; the entry file's
# own shadow stays legal (fixtures/to_string_shadowed_builtin_test.vibe). The
# controls -- a bare name, a non-builtin qualified name, a trait-owned name and
# the `let` alias shape -- are lib/@vibe/compiler/tests/builtin_fn_shadowing_test.vibe.
send_check_reject "err_builtin_fn_shadowing.vibe" 'rename `String::index_of` in ' "bfs"
send_check_reject "err_builtin_fn_shadowing.vibe" 'builtin_fn_shadowing_dep.vibe: it is a builtin, and a `fn` defined at a builtin' "bfs2"
send_check_reject "err_builtin_fn_shadowing.vibe" 'replaces that builtin for EVERY program that links that file' "bfs3"
# PR #2708 review: the `__vibe_` prefix is reserved for the definitions the
# compiler generates and finds again by spelling; a program's own
# `fn __vibe_double_to_string` used to pass for the Double runtime prelude.
send_check_reject "err_reserved_vibe_prefix.vibe" 'rename `__vibe_double_to_string`: the `__vibe_` prefix is reserved' "rvp"
# #3189 review: the `__hs_` prefix is reserved the same way. The host-stream
# reader the linked lowering injects (`__hs_next`, its finisher `__hs_fin`) is
# called and pruned by name, so a program's own top-level `__hs_fin` shared a
# name with the generated one.
send_check_reject "err_reserved_hs_prefix.vibe" 'rename `__hs_fin`: the `__hs_` prefix is reserved' "rvphs"
# The control, and the reason the two rows above cannot pass by rejecting the
# type outright: the same heads used correctly -- including a function
# polymorphic over the element, which is what the `0` bucket exists for --
# must still compile AND run. (The compiler's own self-build is the same
# claim at scale; `lib/@vibe` uses these two everywhere.)
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/contract_generic_head_ok.vibe "$senddir/cgenok.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$senddir/cgenok.wasm" ]; then
  echo "[compiler-gate] FAIL: contract_generic_head_ok.vibe did not compile -- the #2640 head check over-rejects" >&2
  cat "$senddir/cgenok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cgenok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$senddir/cgenok.wasm" 2>&1)" || cgenok_out="<run failed> $cgenok_out"
# The VALUE, not just the exit status: the fixture's arithmetic reads both
# heads through four call sites, so 42 is what says they were all typed --
# a run that merely exits 0 would pass while returning anything.
if [ "$(printf '%s' "$cgenok_out" | tail -1)" != "42" ]; then
  echo "[compiler-gate] FAIL: contract_generic_head_ok got '$cgenok_out' (want 42)" >&2
  exit 1
fi
# The SHADOWING pin (Codex review): a type formal may be NAMED `MutSet` --
# shadowing is legal, these names are not reserved, and a bare shadowed formal
# resolves to `CtNamed("MutSet", [])`, the same representation the contract
# head has. The head check keys on ARITY so the string is never asked to carry
# that distinction alone.
#
# This row is a PIN, not a discriminating test, and the difference is worth
# stating: measured, it compiles and runs to 42 against a stage2 built WITHOUT
# the arity guard as well. Seven shapes were tried to find a program where the
# unguarded classification changes the answer -- a bare formal field, an
# un-instantiated struct literal, an anonymous record against a uniquely
# matched struct, a bare-struct annotation -- and none diverged from the same
# declaration spelled `T`. So the guard is a narrowing that costs nothing and
# closes a mechanism that is real in `resolve_type_expr_core_shadowed`, and
# this row holds the behaviour still rather than proving it.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/contract_generic_head_shadowed_formal.vibe "$senddir/cgenshadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$senddir/cgenshadow.wasm" ]; then
  echo "[compiler-gate] FAIL: a type formal named MutSet no longer compiles -- the #2640 head check classifies shadowed formals" >&2
  cat "$senddir/cgenshadow.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cgenshadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$senddir/cgenshadow.wasm" 2>&1)" || cgenshadow_out="<run failed> $cgenshadow_out"
if [ "$(printf '%s' "$cgenshadow_out" | tail -1)" != "42" ]; then
  echo "[compiler-gate] FAIL: contract_generic_head_shadowed_formal got '$cgenshadow_out' (want 42)" >&2
  exit 1
fi
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
  cat "$senddir/send_use.wasm.diag" >&2 2>/dev/null || true
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
  cat "$rc1085dir/src.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! rc1085_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1085dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume got '$rc1085_out' (want 123123) -- #1085 over-drop regressed" >&2
  echo "$rc1085_out" >&2
  exit 1
fi
rm -rf "$rc1085dir"
echo "[compiler-gate] RC branch+loop mixed-consume over-drop (#1085) ok"

# 50/50. ADR-0076 Phase 3a (#817, docs/internal/design/effect-evidence-passing.md 追記27):
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
    cat "$scpsdir/$tag.wasm.diag" >&2 2>/dev/null || true
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
  cat "$scpsdir/once.wasm.diag" >&2 2>/dev/null || true
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
    cat "$scpsdir/$tag.wasm.diag" >&2 2>/dev/null || true
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
# #2345: the same allowlist, the same failure mode, a new name.
# `Bytes::index_of_bytes` is the Bytes-prologue half of the windowed substring
# search `String::index_of` already reaches, and scps_named_call_ok consults
# the list by exact name with no registry fallback -- so without the entry a
# handle body calling it is refused naming the call. LINEAR only: a
# suspend-class arm captures `resume` as a value and the gc backend does not
# lower that, so a gc run of this shape proves nothing here. The fixture
# carries `String::index_of` as its own control.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_suspend_bytes_index_of_bytes_test.vibe
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
# #2065 wall 2: the same laundering with the performing closure written as a
# LITERAL argument. The discharge rule exempts a value argument only where the
# callee's parameter type carries the effect, which `apply1`'s does not.
scps_check_reject "err_effect_closure_literal_launder.vibe" "cannot see through" "litlaunder"
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
  cat "$rc1097dir/src.wasm.diag" >&2 2>/dev/null || true
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
  cat "$rc1272dir/src.wasm.diag" >&2 2>/dev/null || true
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
  cat "$awmdir/src.wasm.diag" >&2 2>/dev/null || true
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
  cat "$fpdir/src.wasm.diag" >&2 2>/dev/null || true
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
  cat "$rcocdir/esc.wasm.diag" >&2 2>/dev/null || true
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
  cat "$ccpsdir/param.wasm.diag" >&2 2>/dev/null || true
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
  cat "$ccpsdir/mixed.wasm.diag" >&2 2>/dev/null || true
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
  cat "$ccpsdir/genop.wasm.diag" >&2 2>/dev/null || true
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
  cat "$tdevdir/m2.wasm.diag" >&2 2>/dev/null || true
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
  cat "$tdevdir/inelig.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -f "$tdevdir/multi.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_multi.vibe "$tdevdir/multi.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/multi.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_multi fixture did not compile" >&2
  cat "$tdevdir/multi.wasm.diag" >&2 2>/dev/null || true
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
  cat "$tdevdir/shadow.wasm.diag" >&2 2>/dev/null || true
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
  cat "$v2dir/vacuous.wasm.diag" >&2 2>/dev/null || true
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
  cat "$v2dir/reject.wasm.diag" >&2 2>/dev/null || true
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
  cat "$csibdir/out.wasm.diag" >&2 2>/dev/null || true
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
#        and then compiles its output through the trusted single-source lane
#        used by generate_bundle.sh. The flat artifact carries compiler-only
#        source-boundary metadata, so feeding it back through ordinary FS
#        ingestion would correctly reject that reserved syntax as a user
#        forgery. Note the merge STRIPS the qualification: `Msg::Request(..)`
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
  cat "$c1078dir/merged.vibe.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1078dir/merged.vibe" "$c1078dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1078dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: merged ctor/effect-op collision program did not compile -- bare-name resolution picked the wrong declaration (#1078)" >&2
  cat "$c1078dir/out.wasm.diag" >&2 2>/dev/null || true
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
# name -- no general rank-2/`Region`-bound mechanism, see docs/internal/
# design/concurrency.md "Regions and escape") and rejects the call if the region
# escapes via the body's return value. Positive: a plain spawn+join inside
# one nursery keeps compiling and running (region_ok_basic.vibe, 42).
# Negative: returning a `TaskHandle` obtained inside the nursery is a
# STATIC error (err_region_escape_return.vibe). Known gap, documented
# rather than silently claimed: an outer-capture check also runs (scans
# every binding visible at the call site after the body is checked) and
# refuses a leak into an outer binding whose type is still open, but a
# binding the checker generalized (a generic struct value) or annotated with
# a concrete type is not seen (concurrency.md "Known gaps") -- only the
# return-position escape is a hard guarantee here.
echo "[compiler-gate] 59/59 ADR-0068 region generativity (#1081 step 3)"
regiondir="_build/_gate_region"
rm -rf "$regiondir"; mkdir -p "$regiondir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_basic.vibe "$regiondir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$regiondir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe did not compile -- plain non-escaping nursery use regressed" >&2
  cat "$regiondir/pos.wasm.diag" >&2 2>/dev/null || true
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_return.vibe "$regiondir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$regiondir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$regiondir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe did not produce the expected diagnostic" >&2
  cat "$regiondir/neg.wasm.diag" >&2 2>/dev/null || true
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
  cat "$depsdir/scan.out.diag" >&2 2>/dev/null
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
# `TaskGroup::spawn`/`TaskGroup::spawn_suspend`, and (#3125) any callee with
# their type -- a `let` alias, a renamed import, a same-signature wrapper;
# the alias rows live in fixtures/typecheck (spawn_*). A captured free variable
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture.vibe "$spawnabledir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe did not compile -- same-region Sender capture regressed" >&2
  cat "$spawnabledir/pos.wasm.diag" >&2 2>/dev/null || true
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_array.vibe "$spawnabledir/neg_array.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_array.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable` for `Array[Int]`' "$spawnabledir/neg_array.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_array.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #3125: the same capture through an ALIAS of TaskGroup::spawn. The check
# used to key on the spelling, so this compiled and ran; it now follows the
# callee's type and gives the direct call's diagnostic. Its positive twin
# captures only a Send value and still compiles.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_alias.vibe "$spawnabledir/neg_alias.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_alias.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_alias.vibe compiled successfully -- an alias of TaskGroup::spawn skipped the capture check" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable` for `Array[Int]`' "$spawnabledir/neg_alias.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_alias.vibe did not produce the direct call's diagnostic" >&2
  cat "$spawnabledir/neg_alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/spawnable_alias_send_ok.vibe "$spawnabledir/pos_alias.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_alias.wasm" ]; then
  echo "[compiler-gate] FAIL: spawnable_alias_send_ok.vibe did not compile -- an alias capturing only Send values must pass" >&2
  cat "$spawnabledir/pos_alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_cross_region.vibe "$spawnabledir/neg_cross.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_cross.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable`' "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_cross.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut.vibe "$spawnabledir/neg_letmut.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut_outer_scope.vibe "$spawnabledir/neg_letmut_outer.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut_outer.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" >&2 2>/dev/null || true
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture_shadowed_letmut.vibe "$spawnabledir/pos_shadow.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe did not compile -- scope-blind let-mut false positive regressed" >&2
  cat "$spawnabledir/pos_shadow.wasm.diag" >&2 2>/dev/null || true
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
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #3125: the check follows the callee's TYPE, not its spelling. A local alias
# and a renamed import of `TaskGroup::spawn` get the same diagnostic as the
# literal call (err_spawnable_capture_array.vibe above), and the function
# handed on as a value is refused with the edit that fixes it.
# #3152: a closure passed by NAME is checked too -- a local `let` closure by
# its recorded captures, a local closure called inside the body as a capture,
# `Parallel::map`'s closure at its call site, and a closure parameter whose
# captures cannot be seen is refused. #3153: `TaskGroup::run`'s escape check
# follows the callee's type the same way. Each of these compiled and ran
# before its fix.
for spawn_route in \
  "err_spawnable_alias_capture:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_spawnable_annotated_alias_capture:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_spawnable_rename_import_capture:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_spawnable_value_passed:\`TaskGroup::spawn\` cannot be used as a value here" \
  "err_spawnable_let_closure:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_spawnable_called_closure:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_spawnable_opaque_param:no impl \`Spawnable\` for closure \`work\`: its captures cannot be seen here" \
  "err_spawnable_parallel_map_capture:no impl \`Spawnable\` for \`Array[Int]\`" \
  "err_region_escape_run_rename:region escapes its nursery scope" \
  "err_region_escape_run_local_alias:region escapes its nursery scope" \
  "err_region_escape_run_value:\`TaskGroup::run\` cannot be used as a value here"; do
  spawn_fx="${spawn_route%%:*}"
  spawn_needle="${spawn_route#*:}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$spawn_fx.vibe" "$spawnabledir/$spawn_fx.wasm" main >/dev/null 2>&1 || true
  if [ -s "$spawnabledir/$spawn_fx.wasm" ]; then
    echo "[compiler-gate] FAIL: $spawn_fx.vibe compiled successfully -- must be rejected (#3125)" >&2
    exit 1
  fi
  if ! grep -qF "$spawn_needle" "$spawnabledir/$spawn_fx.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $spawn_fx.vibe did not produce the expected diagnostic (#3125)" >&2
    cat "$spawnabledir/$spawn_fx.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
# #3125 positive side: an alias whose closures capture only `Send` values
# keeps compiling and running (82 = 41 + 1 + 40, pinned by the fixture's
# `inspect` block).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_alias.vibe "$spawnabledir/pos_alias.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_alias.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_alias.vibe did not compile -- a Send-only spawn alias must stay legal (#3125)" >&2
  cat "$spawnabledir/pos_alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_alias_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_alias.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_alias.vibe got '$spawnable_alias_out' (want 82)" >&2
  exit 1
fi
# #3156 review: an ANNOTATED alias is the same alias -- its ascription wraps
# the bare name, and it used to be refused as a value; its calls stay
# Send-checked (err_spawnable_annotated_alias_capture above). 43 = 41 + 2,
# pinned by the fixture's `inspect` block.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_annotated_alias.vibe "$spawnabledir/pos_annotated_alias.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_annotated_alias.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_annotated_alias.vibe did not compile -- an annotated Send-only spawn alias must stay legal (#3125)" >&2
  cat "$spawnabledir/pos_annotated_alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_annotated_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_annotated_alias.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_annotated_alias.vibe got '$spawnable_annotated_out' (want 43)" >&2
  exit 1
fi
# #3152 positive side: the closure values the check can see -- a local `let`
# closure, a local closure called in the body, a top-level function by name,
# a spawn-shaped wrapper, and `Parallel::map` -- keep compiling and running
# (249, pinned by the fixture's `inspect` block).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_closure_values.vibe "$spawnabledir/pos_values.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_values.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_closure_values.vibe did not compile -- a Send-only closure value must stay legal (#3152)" >&2
  cat "$spawnabledir/pos_values.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_values_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_values.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_closure_values.vibe got '$spawnable_values_out' (want 249)" >&2
  exit 1
fi
# #3152 review: a labeled / optional parameter of a closure passed by name
# shadows an outer non-Send binding of the same bare name, in the closure and
# in a lambda nested inside it; it is not a capture (21, pinned by the
# fixture's `inspect` block).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_labeled_param.vibe "$spawnabledir/pos_labeled.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_labeled.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_labeled_param.vibe did not compile -- a labeled parameter was counted as a capture (#3152)" >&2
  cat "$spawnabledir/pos_labeled.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_labeled_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_labeled.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_labeled_param.vibe got '$spawnable_labeled_out' (want 21)" >&2
  exit 1
fi
# #3156 review: a formal bound by a trait that EXTENDS `Send` is Send inside
# its body, like `[T: Send]` (42, pinned by the fixture's `inspect` block).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_supertrait_send.vibe "$spawnabledir/pos_supertrait.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_supertrait.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_supertrait_send.vibe did not compile -- a bound extending Send must count as Send (#3152)" >&2
  cat "$spawnabledir/pos_supertrait.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_supertrait_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_supertrait.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_supertrait_send.vibe got '$spawnable_supertrait_out' (want 42)" >&2
  exit 1
fi
# #3152 review: an annotated local closure (`let f: () -> Int = () -> ..`)
# records its captures through the parser's ascription wrapper (41).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_annotated_closure.vibe "$spawnabledir/pos_ann_closure.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_ann_closure.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_annotated_closure.vibe did not compile -- an annotated let closure lost its capture facts (#3152)" >&2
  cat "$spawnabledir/pos_ann_closure.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_ann_closure_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_ann_closure.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_annotated_closure.vibe got '$spawnable_ann_closure_out' (want 41)" >&2
  exit 1
fi
# #3153 review: a function is a nursery runner only when its scheme binds the
# `TaskGroup` region and returns its callback's result; a String-returning
# lookalike and a monomorphic helper over an enclosing region are ordinary
# values (15).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_not_a_runner.vibe "$spawnabledir/pos_not_runner.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_not_runner.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_not_a_runner.vibe did not compile -- a non-runner was classified as TaskGroup::run (#3153)" >&2
  cat "$spawnabledir/pos_not_runner.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_not_runner_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_not_runner.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_not_a_runner.vibe got '$spawnable_not_runner_out' (want 15)" >&2
  exit 1
fi
# #3155: a local `let` alias of `TaskGroup::run` (and of a row-polymorphic
# function) is callable -- it used to be refused with "unresolved effect row
# { e }" -- while its escape check stays (err_region_escape_run_local_alias
# above). 48, pinned by the fixture's `inspect` block.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_run_local_alias.vibe "$spawnabledir/pos_run_alias.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_run_alias.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_run_local_alias.vibe did not compile -- a local alias of TaskGroup::run must be callable (#3155)" >&2
  cat "$spawnabledir/pos_run_alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! spawnable_run_alias_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_run_alias.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_run_local_alias.vibe got '$spawnable_run_alias_out' (want 48)" >&2
  exit 1
fi
rm -rf "$spawnabledir"
echo "[compiler-gate] ADR-0068 Spawnable[r] capture check ok"
