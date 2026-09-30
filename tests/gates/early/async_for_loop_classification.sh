#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# 27d. async for-loop classification (#827 / #1350): the pull-closure lowering
#      must fire only on a POSITIVELY function-shaped source. It used to be
#      reachable by a silent fallback, which compiled fine and then trapped at
#      runtime (call_indirect on the stream's array pointer). #1350 removed the
#      `for await` syntax and made the UNCLASSIFIED fallback the plain array
#      loop. #1954 later replaced the structural `Stream[Int]` spelling with
#      nominal `ByteStream`, while retaining its byte-iteration lowering, so
#      the hazard is now structural rather than
#      diagnostic: BOTH the annotated and the unannotated param must compile
#      and run to 42.
echo "[compiler-gate] 27d/27 async for-loop classification (#827/#1350)"
fadir="_build/_gate_forawait"
rm -rf "$fadir"; mkdir -p "$fadir"
cat > "$fadir/ok_annot.vibe" <<'EOF'
let consume: (ByteStream) -> Int = (s) -> {
  let mut sum = 0
  for x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(String::to_bytes("*")) }
EOF
cat > "$fadir/ok_unannot.vibe" <<'EOF'
let consume = (s) -> Int {
  let mut sum = 0
  for x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(String::to_bytes("*")) }
EOF
# #1350 (Codex P1): the pull-closure loop must fire only when the source
# POSITIVELY returns a function. A call to a function whose return annotation
# was merely OMITTED records the same empty head as a closure-returning one
# did before the fix, and its array was then called as a closure
# (call_indirect trap). Reproduced on the pre-fix stage2; 42 = 40 + 2.
cat > "$fadir/ok_unannot_factory.vibe" <<'EOF'
let values = () -> {
  [40, 2]
}
export let _start: () -> Int = () -> {
  let mut sum = 0
  for x in values() {
    sum = sum + x
  }
  sum
}
EOF
# #1350 (Codex P1, second round): the same ambiguity in the OTHER direction --
# an unannotated factory that really DOES return a pull closure must keep its
# pull loop. Tightening the annotated case alone moved the trap here (the
# closure was iterated as an array). The head is inferred from the body's tail
# expression, so both unannotated shapes classify correctly. 42 = 14 * 3.
cat > "$fadir/ok_unannot_closure_factory.vibe" <<'EOF'
let make_pull = () -> {
  let mut n = 0
  () -> {
    if n >= 3 {
      None
    } else {
      n = n + 1
      Some(14)
    }
  }
}
export let _start: () -> Int = () -> {
  let mut sum = 0
  for x in make_pull() {
    sum = sum + x
  }
  sum
}
EOF
for fa_case in ok_annot ok_unannot ok_unannot_factory ok_unannot_closure_factory; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fadir/$fa_case.vibe" "$fadir/$fa_case.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$fadir/$fa_case.wasm" ]; then
    echo "[compiler-gate] FAIL: $fa_case byte-stream for-loop did not compile" >&2; exit 1
  fi
  fa_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fadir/$fa_case.wasm" 2>/dev/null | tail -n 1)"
  if [ "$fa_out" != "42" ]; then
    echo "[compiler-gate] FAIL: $fa_case returned '$fa_out' (expected 42 -- ByteStream uses byte iteration; a pull-closure fallback would trap)" >&2; exit 1
  fi
done
rm -rf "$fadir"
echo "[compiler-gate] async for-loop classification ok"

# 27e. Error-as-perform equivalence (#640 Stage 1): `perform Error::Throw(x)`
#      must be indistinguishable from `throw(x)` — both emit the EThrow wasm
#      exception (tag 2), so the same `with Error` handler catches both.
#      Previously the perform spelling was lowered with the out-of-range
#      fallback effect tag (Error is never in effect_names) and ESCAPED the
#      handler as an uncaught exception. Also pins #640's checker rule:
#      Error is non-resumable, so resume(...) inside a with-Error arm is a
#      compile error (the arm's value IS the handle result).
echo "[compiler-gate] 27e/27 Error-as-perform equivalence + non-resumability (#640)"
edir="_build/_gate_error_perform"
rm -rf "$edir"; mkdir -p "$edir"
cat > "$edir/via_perform.vibe" <<'EOF'
let safe = () -> Int with Exception {
  perform Error::Throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Exception { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/via_throw.vibe" <<'EOF'
let safe = () -> Int with Exception {
  throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Exception { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/bad_resume_arm.vibe" <<'EOF'
let risky = () -> Int with Exception {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Exception { Throw(_m) => resume(0) }
}
EOF
# Codex P2 on #933: the rejection walk's catch-all used to end at EBreak /
# ELoop (and EMap/ESpread/ELabeledArg/EContinue/ERecord), so a resume tucked
# into `loop { break resume(0) }` reached codegen's meaningless tag-1 path.
cat > "$edir/bad_resume_loop.vibe" <<'EOF'
let risky = () -> Int with Exception {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Exception { Throw(_m) => loop { break resume(0) } }
}
EOF
for v in via_perform via_throw; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$edir/$v.vibe" "$edir/$v.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$edir/$v.wasm" ]; then
    echo "[compiler-gate] FAIL: $v did not compile (#640)" >&2; exit 1
  fi
done
perf_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/via_perform.wasm" 2>/dev/null | tail -n 1 || true)"
throw_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/via_throw.wasm" 2>/dev/null | tail -n 1 || true)"
if [ "$throw_out" != "4" ]; then
  echo "[compiler-gate] FAIL: throw spelling returned '$throw_out' (expected 4)" >&2; exit 1
fi
if [ "$perf_out" != "$throw_out" ]; then
  echo "[compiler-gate] FAIL: perform Error::Throw diverged from throw ('$perf_out' vs '$throw_out'; #640 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/bad_resume_arm.vibe" "$edir/bad_resume_arm.wasm" _start >/dev/null 2>&1 || true
if [ -s "$edir/bad_resume_arm.wasm" ]; then
  echo "[compiler-gate] FAIL: resume(...) in a with-Error arm compiled (#640 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/bad_resume_loop.vibe" "$edir/bad_resume_loop.wasm" _start >/dev/null 2>&1 || true
if [ -s "$edir/bad_resume_loop.wasm" ]; then
  echo "[compiler-gate] FAIL: resume(...) nested in loop/break inside a with-Error arm compiled (walk gap; Codex P2 on #933)" >&2; exit 1
fi
# 27e2 (#640 Stage 2): `throw(x)` desugars at PARSE time to the exact
# `perform Error::Throw(x)` AST (single internal form), so the two spellings
# must produce BYTE-IDENTICAL wasm — a much stronger pin than the equal-output
# check above. If this ever diverges, the single-form invariant regressed
# (e.g. one spelling grew its own lowering again).
if ! cmp -s "$edir/via_perform.wasm" "$edir/via_throw.wasm"; then
  echo "[compiler-gate] FAIL: throw vs perform Error::Throw wasm bytes differ (#640 Stage 2 single-form regressed)" >&2; exit 1
fi
rm -rf "$edir"
echo "[compiler-gate] Error-as-perform equivalence ok (4, byte-identical)"

# 27f. print primitives on the bare FS lane (#929/#930): the println/print
#      checker builtins had no linear-lane lowering (any program not importing
#      @vibe/io died with "undefined variable (local): println @call"), and the
#      Stdout::write_char / Stderr::write_char / Stdin::read_stream host
#      imports were called with guest-TAGGED ints (write_char(65) wrote byte
#      130 — "42" printed as "hd"). println/print must compile standalone and
#      print exact text; write_char must print the untagged byte; a source-
#      provided println (shadow) must still win over the builtin lowering.
echo "[compiler-gate] 27f/27 print primitives on the FS lane (#929/#930)"
ppdir="_build/_gate_print_prims"
rm -rf "$ppdir"; mkdir -p "$ppdir"
cat > "$ppdir/prints.vibe" <<'EOF'
fn main() -> Unit allows Console {
  println("hello gate")
  print("forty")
  print("two")
  println("")
  println("\{40 + 2}")
  Stdout::write_char(String::char_code_at("A", 0))
  Stdout::write_char(10)
}
EOF
# The lowering must hold on BOTH linear lanes: the RC-canonical lane (raw
# host ABI, #930 untag shims) and the non-RC lane this gate's global
# VIBE_RC=0 pin compiles under (its generic call path untags import args
# itself). Compile and run the same program once per lane.
for pp_rc in 0 1; do
  rm -f "$ppdir/prints.wasm" "$ppdir/prints.wasm.diag"
  VIBE_RC="$pp_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ppdir/prints.vibe" "$ppdir/prints.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$ppdir/prints.wasm" ]; then
    echo "[compiler-gate] FAIL: println/print program did not compile on the FS lane under VIBE_RC=$pp_rc (#929 regressed)" >&2
    cat "$ppdir/prints.wasm.diag" >&2 2>/dev/null; exit 1
  fi
  pp_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ppdir/prints.wasm" 2>/dev/null | head -n 4 | tr '\n' '|')"
  if [ "$pp_out" != "hello gate|fortytwo|42|A|" ]; then
    echo "[compiler-gate] FAIL: print primitives output '$pp_out' under VIBE_RC=$pp_rc (expected 'hello gate|fortytwo|42|A|'; #929/#930 regressed)" >&2; exit 1
  fi
done
# #2107: both rows are declared because both functions really do print --
# `print` carries `Console` now that the checker holds the print builtins to
# the row discipline. What this fixture pins is unchanged: the SOURCE
# definition of `println` wins over the builtin lowering, so the program
# prints "S" rather than "ignored".
cat > "$ppdir/shadow.vibe" <<'EOF'
fn println(s: String) -> Unit with Console {
  print("S\n")
}

fn main() -> Unit allows Console {
  println("ignored")
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ppdir/shadow.vibe" "$ppdir/shadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$ppdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: source-shadowed println did not compile (#929 shadow guard broke shadowing)" >&2; exit 1
fi
pp_shadow="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ppdir/shadow.wasm" 2>/dev/null | head -n 1)"
if [ "$pp_shadow" != "S" ]; then
  echo "[compiler-gate] FAIL: source-shadowed println printed '$pp_shadow' (expected 'S'; builtin lowering must yield to source defs)" >&2; exit 1
fi
rm -rf "$ppdir"
echo "[compiler-gate] print primitives ok"

# 28. argument type checking: the checker used to SWALLOW argument unification
#     failures (`unify_call_args` did `None => out`), so an ill-typed call like
#     `f("x")` for `f: (Int) -> Int` was silently accepted. It now reports a
#     STRUCTURAL argument mismatch (effect-only differences and the polymorphic
#     `__to_string` interpolation stringifier are still tolerated, since effect
#     inference on function values is imprecise). The mismatch must be REJECTED;
#     a correct call must still compile.
# 27g. the raw-ABI shim's OTHER sleep spelling (#2903). `cc_raw_abi_shim_applies`
#      listed `sleep` but not `sleep_blocking`, and both observed paths reach
#      the host through the latter: a direct call, and the Async entry
#      boundary, whose settle calls `sleep_blocking` to pay the suspend debt.
#      So `sleep(1000)` handed the host 2000 and slept twice as long --
#      runtime/viberun and the node runner both obey the module's OWN
#      `vibe.abi: host_import_abi=raw` declaration, so the EMITTER was the one
#      violating it.
#
#      Asserted on the VALUE, not on wall-clock. A duration has no output to
#      diff and a timing band flakes on a shared runner; the contract here is
#      exact -- the declaration says raw, so the i64 handed to `vibe.sleep`
#      must BE the millisecond count. The observer decodes nothing, so it
#      cannot paper over a tag the way the runner's own heuristic did.
#
#      Both lanes, like 27f: under VIBE_RC=0 there is no tag to remove and the
#      generic path already passed 1000, so the RC=0 row is the control that
#      proves the expectation is not simply "whatever the compiler emits".
echo "[compiler-gate] 27g/27 raw-ABI shim covers sleep_blocking (#2903)"
sbdir="_build/_gate_sleep_raw_abi"
rm -rf "$sbdir"; mkdir -p "$sbdir"
cat > "$sbdir/sleepb.vibe" <<'EOF'
fn main() -> Int {
  sleep_blocking(1000)
  7
}
EOF
# #2903's own repro: the user-visible spelling. `sleep` was already in the
# shim list, so this row is NOT redundant with the one above -- it fails for
# a different reason. Under `allows Async` the call becomes a suspend request
# and the injected `__entry_settle` pays the debt by calling `sleep_blocking`
# (linked_compile.vibe:4222/:4255), which resolves to the SAME `vibe.sleep`
# import (:10996). So a fix that covered only the direct spelling would leave
# every `sleep(ms)` in async code doubled, and this row is what notices.
cat > "$sbdir/sleepa.vibe" <<'EOF'
fn main() -> Int allows Async {
  sleep(1000)
  7
}
EOF
cat > "$sbdir/observe.mjs" <<'EOF'
// Print the raw i64 the guest hands vibe.sleep. No decoding on purpose.
import { readFileSync } from "node:fs";
const mod = await WebAssembly.compile(readFileSync(process.argv[2]));
let seen = null;
const imports = {
  vibe: new Proxy({}, { get: (_t, name) => (v) => { if (name === "sleep") seen = v; return 0n; } }),
  wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }),
};
const inst = await WebAssembly.instantiate(mod, imports);
try { inst.exports.main(0n); } catch { try { inst.exports.main(); } catch {} }
console.log(seen === null ? "NOCALL" : String(BigInt(seen)));
EOF
for sb_src in sleepb sleepa; do
  for sb_rc in 0 1; do
    rm -f "$sbdir/$sb_src.wasm" "$sbdir/$sb_src.wasm.diag"
    VIBE_RC="$sb_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$sbdir/$sb_src.vibe" "$sbdir/$sb_src.wasm" main >/dev/null 2>&1 || true
    if [ ! -s "$sbdir/$sb_src.wasm" ]; then
      echo "[compiler-gate] FAIL: $sb_src.vibe did not compile under VIBE_RC=$sb_rc (#2903)" >&2
      cat "$sbdir/$sb_src.wasm.diag" >&2 2>/dev/null; exit 1
    fi
    sb_val="$(node "$sbdir/observe.mjs" "$sbdir/$sb_src.wasm" 2>/dev/null)"
    if [ "$sb_val" != "1000" ]; then
      echo "[compiler-gate] FAIL: $sb_src.vibe under VIBE_RC=$sb_rc handed vibe.sleep '$sb_val', want 1000." >&2
      echo "  The module declares host_import_abi=raw, so the argument must be the" >&2
      echo "  millisecond count. 2000 means the raw-ABI shim stopped covering" >&2
      echo "  sleep_blocking (compile_call.vibe cc_raw_abi_shim_applies, and the" >&2
      echo "  sorted ladder-membership list it is reached through). NOCALL means" >&2
      echo "  main trapped before reaching the import, which is also a failure." >&2
      exit 1
    fi
  done
done
rm -rf "$sbdir"
echo "[compiler-gate] raw-ABI shim covers sleep_blocking ok (1000 on both lanes, direct and via Async)"

# 27h. the RETURN side of the same shim (#2905). `Console::read_char` aliases
#      the `vibe.stdin_read_char` import that `Stdin::read_char` uses
#      (linked_compile.vibe maps both to `stdin_read_char_idx`), so the raw
#      byte the host returns needs the same RC tag. It had neither half:
#      #2911 gave it the import RESERVATION -- before that the module BUILT
#      CLEAN and failed to validate -- and the result tag was still missing,
#      so it loaded and answered `host >> 1`. 'A' (65) came back as 32.
#
#      A loud failure became a silent wrong answer, which this repo's triage
#      ranks WORSE than the crash it replaced, and no gate saw either.
#
#      Asserted as a VALUE against a host stub that returns a fixed byte and
#      decodes nothing, with TWO controls that make a passing row mean
#      something: `Stdin::read_char` (the sibling that was always right) must
#      agree, and VIBE_RC=0 (no tag to add) must already agree -- so the
#      expectation is not "whatever the compiler emits".
echo "[compiler-gate] 27h/27 Console::read_char returns the host byte (#2905)"
crdir="_build/_gate_console_read_char"
rm -rf "$crdir"; mkdir -p "$crdir"
cat > "$crdir/console.vibe" <<'EOF'
fn main() -> Int allows Console {
  Console::read_char()
}
EOF
cat > "$crdir/stdin.vibe" <<'EOF'
fn main() -> Int allows Stdin {
  Stdin::read_char()
}
EOF
cat > "$crdir/stub.mjs" <<'EOF'
// Return a fixed raw byte from every vibe import and print what main gives
// back. Decodes nothing, so it cannot paper over a missing tag.
import { readFileSync } from "node:fs";
const val = BigInt(process.argv[3]);
const mod = await WebAssembly.compile(readFileSync(process.argv[2]));
const imports = {
  vibe: new Proxy({}, { get: () => () => val }),
  wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }),
};
const inst = await WebAssembly.instantiate(mod, imports);
let r;
try { r = inst.exports.main(0n); } catch { try { r = inst.exports.main(); } catch { console.log("TRAP"); process.exit(0); } }
console.log(String(BigInt(r)));
EOF
for cr_rc in 0 1; do
  for cr_src in console stdin; do
    rm -f "$crdir/$cr_src.wasm" "$crdir/$cr_src.wasm.diag"
    VIBE_RC="$cr_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$crdir/$cr_src.vibe" "$crdir/$cr_src.wasm" main >/dev/null 2>&1 || true
    if [ ! -s "$crdir/$cr_src.wasm" ]; then
      echo "[compiler-gate] FAIL: $cr_src.vibe did not compile under VIBE_RC=$cr_rc (#2905)" >&2
      cat "$crdir/$cr_src.wasm.diag" >&2 2>/dev/null; exit 1
    fi
    # A module that builds but does not validate is the shape #2905 opened on,
    # so check that separately from the value -- otherwise it reads as "TRAP".
    if ! node -e "new WebAssembly.Module(require('fs').readFileSync('$crdir/$cr_src.wasm'))" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $cr_src.vibe under VIBE_RC=$cr_rc built a module that does not validate (#2905)" >&2
      exit 1
    fi
    for cr_byte in 65 200 1; do
      cr_got="$(node "$crdir/stub.mjs" "$crdir/$cr_src.wasm" "$cr_byte" 2>/dev/null)"
      if [ "$cr_got" != "$cr_byte" ]; then
        echo "[compiler-gate] FAIL: $cr_src.vibe under VIBE_RC=$cr_rc returned '$cr_got' for host byte $cr_byte (#2905)." >&2
        echo "  The import speaks UNTAGGED integers, so the RC lane must tag the" >&2
        echo "  result. Half the byte means the tag is missing: add the name to" >&2
        echo "  the RC result-shim arm in compile_call.vibe AND to cc_ladder_names," >&2
        echo "  which gates whether that arm is reached at all." >&2
        exit 1
      fi
    done
  done
done
rm -rf "$crdir"
echo "[compiler-gate] Console::read_char ok (host byte returned intact on both lanes, matching Stdin::read_char)"


echo "[compiler-gate] 28/28 argument type checking"
adir="_build/_gate_argcheck"
rm -rf "$adir"; mkdir -p "$adir"
cat > "$adir/wrong.vibe" <<'EOF'
let f: (Int) -> Int = (x) -> { x + 1 }
export let _start: () -> Int = () -> { f("hello") }
EOF
cat > "$adir/right.vibe" <<'EOF'
let f: (Int) -> Int = (x) -> { x + 1 }
export let _start: () -> Int = () -> { f(41) + 1 }
EOF
# Field-stored-function call `b.f(args)`: when no method `T::f` exists but the
# struct field `f` holds a function, the args must be checked against the
# field's parameter types (this `b.f("s")` was previously unchecked).
cat > "$adir/ffwrong.vibe" <<'EOF'
struct B { f: (Int) -> Int }
export let _start: () -> Int = () -> { let b = B::{ f: (x) -> { x + 1 } }; (b.f)("s") }
EOF
cat > "$adir/ffright.vibe" <<'EOF'
struct B { f: (Int) -> Int }
export let _start: () -> Int = () -> { let b = B::{ f: (x) -> { x + 1 } }; (b.f)(3) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/right.vibe" "$adir/right.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/right.wasm" ]; then
  echo "[compiler-gate] FAIL: a correctly-typed call did not compile (arg-check over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffright.vibe" "$adir/ffright.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/ffright.wasm" ]; then
  echo "[compiler-gate] FAIL: a correct field-stored-function call did not compile (over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/wrong.vibe" "$adir/wrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/wrong.wasm" ]; then
  echo "[compiler-gate] FAIL: an ill-typed argument (Int <- String) compiled (arg-check regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffwrong.vibe" "$adir/ffwrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/ffwrong.wasm" ]; then
  echo "[compiler-gate] FAIL: ill-typed field-stored-function call (Int <- String) compiled" >&2; exit 1
fi
rm -rf "$adir"
echo "[compiler-gate] argument type checking ok"

# 29. assignment / typed-binding / if-branch type checking: more positions the
#     checker used to leave unchecked. A typed `let x: Int = "s"`, an assignment
#     `y = "s"` (for `let mut y = 1`), and `if c { 1 } else { "x" }` must all be
#     REJECTED; their well-typed counterparts must compile. (Iterative
#     check_expr spine — check_seq_spine — gives the stack headroom for these
#     extra checks during self-compile.)
echo "[compiler-gate] 29/29 assignment / binding / if-branch / struct-field / local-let type checking"
tdir="_build/_gate_typecheck"
rm -rf "$tdir"; mkdir -p "$tdir"
cat > "$tdir/ok.vibe" <<'EOF'
export let x: Int = 5
export let _start: () -> Int = () -> {
  let mut y = 1
  y = 7
  y + (if true { 1 } else { 2 }) + x
}
EOF
cat > "$tdir/bad_let.vibe" <<'EOF'
export let x: Int = "hello"
export let _start: () -> Int = () -> { x }
EOF
cat > "$tdir/bad_assign.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut y = 1
  y = "str"
  y
}
EOF
cat > "$tdir/bad_if.vibe" <<'EOF'
export let _start: () -> Int = () -> { if true { 1 } else { "x" } }
EOF
cat > "$tdir/bad_ifnoelse.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x: Int = if true { 1 }; x }
EOF
cat > "$tdir/bad_struct.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> {
  let p = P::{ x: "oops" }
  0
}
EOF
cat > "$tdir/bad_locallet.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x: Int = "hello"
  0
}
EOF
cat > "$tdir/bad_missingfield.vibe" <<'EOF'
struct Pt { x: Int; y: Int }
export let _start: () -> Int = () -> {
  let p = Pt::{ x: 1 }
  p.x
}
EOF
cat > "$tdir/bad_fnannot.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let g: (Int) -> String = (n) -> { n }
  0
}
EOF
cat > "$tdir/bad_return.vibe" <<'EOF'
export let f: () -> Int = () -> { return "x" }
export let _start: () -> Int = () -> { f() }
EOF
cat > "$tdir/bad_retviaannot.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let g: (Int) -> String = (n) -> { return n }
  0
}
EOF
cat > "$tdir/bad_genhead.vibe" <<'EOF'
let f = [T](a: Array[T]) -> Int { 0 }
export let _start: () -> Int = () -> { f(5) }
EOF
cat > "$tdir/bad_builtinarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::length(5) }
EOF
cat > "$tdir/bad_dupfield.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> { let p = P::{ x: 1, x: 2 }; p.x }
EOF
cat > "$tdir/bad_some2.vibe" <<'EOF'
export let _start: () -> Int = () -> { match Some(1, 2) { Some(a) => a, None => 0 } }
EOF
cat > "$tdir/bad_optfield.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> { let o: Option[P] = None; o.x }
EOF
cat > "$tdir/bad_concatarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::concat("a", 1); 0 }
EOF
cat > "$tdir/bad_concatarg0.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::concat(1, "a"); 0 }
EOF
cat > "$tdir/bad_substrarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::substring("abc", "x", 2); 0 }
EOF
cat > "$tdir/bad_unknownfield.vibe" <<'EOF'
struct P { x: Int; y: Int }
export let _start: () -> Int = () -> { let p = P::{ x: 1, z: 2 }; p.y }
EOF
cat > "$tdir/bad_guardonly.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  match 0 {
    v if v > 0 => 1,
    v if v < 0 => -1
  }
}
EOF
cat > "$tdir/bad_arity_get.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3]) }
EOF
cat > "$tdir/bad_mutann.vibe" <<'EOF'
export let _start: () -> Int = () -> { let mut x: Bool = 5; 0 }
EOF
cat > "$tdir/bad_agrecv.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get("str", 0) }
EOF
cat > "$tdir/bad_agidx.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], "x") }
EOF
cat > "$tdir/bad_asrecv.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::set("str", 0, 1); 0 }
EOF
cat > "$tdir/bad_arity_bytesnew.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Bytes::new(1, 2); Bytes::length(b) }
EOF
# #827: Stream[T] is CtNamed (head 0 = tolerated), so the eager Array-backed
# representation leaked through the Array builtins — these compiled AND ran.
cat > "$tdir/bad_streamlen.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::length(String::to_bytes("*")) }
EOF
cat > "$tdir/bad_streamget.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get(String::to_bytes("*"), 0) }
EOF
cat > "$tdir/bad_streamset.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::set(String::to_bytes("*"), 0, 1); 0 }
EOF
# #805 (0.3.0 redundant-syntax removal): the `\(expr)` string-interpolation
# spelling was removed — only `\{expr}` remains. A source using the old form
# must be a (located) compile error. The ok side is covered by the existing
# tests' pervasive `\{...}` usage.
cat > "$tdir/bad_interp_paren.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x = 41
  let s = "\(x)"
  String::length(s)
}
EOF
# 0.3.0 redundant-syntax removal (2nd batch): ',' as the separator inside type
# declaration bodies (enum variants / struct fields) was removed — only ';'
# separates members. Sources using the old comma form must be (located) parse
# errors. The ok side is covered by the compiler tree's pervasive ';' decls
# (and $tdir/ok.vibe compiles above).
cat > "$tdir/bad_declcomma.vibe" <<'EOF'
enum Color { Red, Green, Blue }
export let _start: () -> Int = () -> { match Red { Red => 42, _ => 0 } }
EOF
cat > "$tdir/bad_structcomma.vibe" <<'EOF'
struct Pt { x: Int, y: Int }
export let _start: () -> Int = () -> { let p = Pt::{ x: 40, y: 2 }; p.x + p.y }
EOF
# #829 (lang-review r2 M7): a GENERIC struct literal must instantiate its type
# params from the field values, so a field read consumed at the wrong concrete
# type is a compile error (it used to compile and return silent garbage).
cat > "$tdir/bad_genfield.vibe" <<'EOF'
struct Box[T] { v: T }
export let _start: () -> Int = () -> {
  let b = Box::{ v: 1 }
  String::length(b.v)
}
EOF
# The well-typed counterpart: the instantiated field read consumed at its own
# concrete type must still compile (no over-reject).
cat > "$tdir/ok_genfield.vibe" <<'EOF'
struct Box[T] { v: T }
fn unbox[T](b: Box[T]) -> T { b.v }
export let _start: () -> Int = () -> {
  let b = Box::{ v: 41 }
  let s = Box::{ v: "x" }
  b.v + String::length(s.v) + unbox(b)
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed binding/assign/if did not compile (over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok_genfield.vibe" "$tdir/ok_genfield.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok_genfield.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed generic-struct field reads did not compile (over-rejects, #829)" >&2; exit 1
fi
for bad in bad_let bad_assign bad_if bad_ifnoelse bad_struct bad_locallet bad_missingfield bad_fnannot bad_return bad_retviaannot bad_genhead bad_builtinarg bad_dupfield bad_some2 bad_optfield bad_concatarg bad_concatarg0 bad_substrarg bad_unknownfield bad_guardonly bad_arity_get bad_arity_bytesnew bad_mutann bad_agrecv bad_agidx bad_asrecv bad_streamlen bad_streamget bad_streamset bad_interp_paren bad_declcomma bad_structcomma bad_genfield; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$tdir/$bad.vibe" "$tdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$tdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (type-check regressed)" >&2; exit 1
  fi
done
rm -rf "$tdir"
echo "[compiler-gate] assignment / binding / if-branch / struct-field / local-let type checking ok"

# 30. `mut`-field write escape analysis (#418): assigning `obj.field = x` (which
#     desugars to `__set_field(obj, "field", x)`) is only legal when `field` was
#     declared `mut` in its struct. A write to a non-`mut` field must be
#     REJECTED; a write to a `mut` field (and a same-typed value) must compile.
echo "[compiler-gate] 30/30 mut-field write escape analysis"
mdir="_build/_gate_mutfield"
rm -rf "$mdir"; mkdir -p "$mdir"
cat > "$mdir/ok_mut.vibe" <<'EOF'
struct Cell { mut n: Int }
export let _start: () -> Int = () -> {
  let c = Cell::{ n: 0 }
  c.n = 5
  c.n
}
EOF
cat > "$mdir/bad_nonmut.vibe" <<'EOF'
struct Frozen { x: Int }
export let _start: () -> Int = () -> {
  let p = Frozen::{ x: 1 }
  p.x = 9
  p.x
}
EOF
cat > "$mdir/bad_valty.vibe" <<'EOF'
struct Cell2 { mut n: Int }
export let _start: () -> Int = () -> {
  let c = Cell2::{ n: 0 }
  c.n = "str"
  c.n
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mdir/ok_mut.vibe" "$mdir/ok_mut.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mdir/ok_mut.wasm" ]; then
  echo "[compiler-gate] FAIL: mut-field write did not compile (over-rejects)" >&2
  cat "$mdir/ok_mut.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_nonmut bad_valty; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$mdir/$bad.vibe" "$mdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$mdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: $bad field write compiled (mut/value-type check regressed)" >&2; exit 1
  fi
done
rm -rf "$mdir"
echo "[compiler-gate] mut-field write escape analysis ok"

# 31. value-soundness probes (each was previously accepted silently): value-
#     yielding `match` arms must agree; array literal elements must share a type;
#     calling a non-function value, `!` on a non-Bool, and `for x in <scalar>`
#     must all be rejected. A `CtUnit` arm (statement-position match) and the
#     well-typed positives must still compile.
echo "[compiler-gate] 31/31 match-arm / array / non-fn-call / unary-not / for-iterable type checking"
cdir="_build/_gate_consistency"
rm -rf "$cdir"; mkdir -p "$cdir"
cat > "$cdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [1, 2, 3]
  let m = match a[0] { 0 => 10, _ => 20 }
  Array::length(a) + m
}
EOF
cat > "$cdir/bad_match.vibe" <<'EOF'
export let _start: () -> Int = () -> { match 1 { 0 => 1, _ => "x" } }
EOF
cat > "$cdir/bad_array.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, "x", 3]; 0 }
EOF
cat > "$cdir/bad_arraynest.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [[1], ["x"]]; 0 }
EOF
cat > "$cdir/bad_call.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = 5; x(3) }
EOF
cat > "$cdir/bad_calloption.vibe" <<'EOF'
export let _start: () -> Int = () -> { let o = Some(1); o(2) }
EOF
cat > "$cdir/bad_not.vibe" <<'EOF'
export let _start: () -> Bool = () -> { !5 }
EOF
cat > "$cdir/bad_forint.vibe" <<'EOF'
export let _start: () -> Int = () -> { for x in 5 { let _ = x; () }; 0 }
EOF
cat > "$cdir/bad_tuparity.vibe" <<'EOF'
export let _start: () -> Int = () -> { let t = (1, 2); let (a, b, c) = t; a }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed match/array did not compile (over-rejects)" >&2
  cat "$cdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_match bad_array bad_arraynest bad_call bad_calloption bad_not bad_forint bad_tuparity; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$cdir/$bad.vibe" "$cdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$cdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (consistency check regressed)" >&2; exit 1
  fi
done
rm -rf "$cdir"
echo "[compiler-gate] match-arm / array / non-fn-call / unary-not / for-iterable type checking ok"

# 32. mutability discipline: reassigning a plain (immutable) `let` is rejected;
#     a `let mut` binding, an accumulator updated in a loop, and a closure-local
#     `let mut` must still compile.
echo "[compiler-gate] 32/32 mutability discipline (immutable let reassignment)"
mudir="_build/_gate_mutability"
rm -rf "$mudir"; mkdir -p "$mudir"
cat > "$mudir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut x = 1
  x = 2
  let mut s = 0
  for i in [1, 2, 3] { s = s + i }
  x + s
}
EOF
cat > "$mudir/bad.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = 1; x = 2; x }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/ok.vibe" "$mudir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mudir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed mut/accumulator did not compile (over-rejects)" >&2
  cat "$mudir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/bad.vibe" "$mudir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mudir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: immutable-let reassignment compiled (mutability check regressed)" >&2; exit 1
fi
rm -rf "$mudir"
echo "[compiler-gate] mutability discipline ok"

# 32b. mutability discipline completeness (#629 step 3-2): an illegal reassignment
#      of an immutable `let` must be flagged even when it sits inside a Map::from_pairs value
#      (and likewise labeled arg / spread / break / continue — check_mutability_expr
#      previously dropped these Expr forms to `_ => errors`, missing the violation).
#      A `let mut` reassignment inside the same form must still compile (no over-reject).
echo "[compiler-gate] 32b/32 mutability discipline completeness (nested forms)"
mu2dir="_build/_gate_mutability_nested"
rm -rf "$mu2dir"; mkdir -p "$mu2dir"
cat > "$mu2dir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut x = 1
  let m = Map::from_pairs([("a", { x = 2; x })])
  m["a"]
}
EOF
cat > "$mu2dir/bad.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x = 1
  let m = Map::from_pairs([("a", { x = 2; x })])
  m["a"]
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/ok.vibe" "$mu2dir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mu2dir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: legal mut reassignment inside Map::from_pairs value did not compile (over-rejects)" >&2
  cat "$mu2dir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/bad.vibe" "$mu2dir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mu2dir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: immutable-let reassignment inside map literal compiled (completeness regressed)" >&2; exit 1
fi
rm -rf "$mu2dir"
echo "[compiler-gate] mutability discipline completeness ok"

# 33. pattern-soundness: a constructor pattern must bind its variant's exact
#     payload arity, and cannot match a scalar scrutinee. Binding the right
#     arity, a nullary variant, and the builtin Option ctors must still compile.
echo "[compiler-gate] 33/33 constructor-pattern arity / scrutinee type checking"
pdir="_build/_gate_patsound"
rm -rf "$pdir"; mkdir -p "$pdir"
cat > "$pdir/ok.vibe" <<'EOF'
enum E { Pair(Int, Int) }
export let _start: () -> Int = () -> {
  let m = match Pair(1, 2) { Pair(a, b) => a + b }
  let o = match Some(5) { Some(v) => v, None => 0 }
  m + o
}
EOF
cat > "$pdir/bad_arity.vibe" <<'EOF'
enum E { Pair(Int, Int) }
export let _start: () -> Int = () -> { match Pair(1, 2) { Pair(a) => a, _ => 0 } }
EOF
cat > "$pdir/bad_scalar.vibe" <<'EOF'
enum Color { Red; Green }
export let _start: () -> Int = () -> { match 5 { Red => 1, _ => 0 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/ok.vibe" "$pdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed ctor patterns did not compile (over-rejects)" >&2
  cat "$pdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_arity bad_scalar; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$pdir/$bad.vibe" "$pdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$pdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed pattern $bad compiled (pattern check regressed)" >&2; exit 1
  fi
done
rm -rf "$pdir"
echo "[compiler-gate] constructor-pattern arity / scrutinee type checking ok"

# 34. indexing / tuple-projection soundness: `obj[i]` on a non-indexable scalar
#     and `t.N` past a tuple's arity must be rejected; indexing an Array/String
#     and an in-range tuple projection must still compile.
echo "[compiler-gate] 34/34 indexing / tuple-projection type checking"
idir="_build/_gate_index"
rm -rf "$idir"; mkdir -p "$idir"
cat > "$idir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [10, 20, 30]
  let t = (1, 2)
  a[1] + t.0 + t.1
}
EOF
cat > "$idir/bad_index.vibe" <<'EOF'
export let _start: () -> Int = () -> { let n = 5; n[0] }
EOF
cat > "$idir/bad_tuple.vibe" <<'EOF'
export let _start: () -> Int = () -> { let t = (1, 2); t.5 }
EOF
cat > "$idir/bad_idxtype.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; a["x"] }
EOF
cat > "$idir/bad_idxelem.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = a[0]; 0 }
EOF
cat > "$idir/bad_stridx.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s: String = "abc"[0]; 0 }
EOF
cat > "$idir/bad_arrget.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = Array::get(a, 0); 0 }
EOF
cat > "$idir/bad_arrpush.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::push(a, "x"); 0 }
EOF
cat > "$idir/bad_arrset.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::set(a, 0, "x"); 0 }
EOF
cat > "$idir/bad_arrmap.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let b = Array::map(a, (x) -> { x + 1 }); let s: String = Array::get(b, 0); 0 }
EOF
cat > "$idir/bad_arrfold.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = Array::fold(a, 0, (acc, x) -> { acc + x }); 0 }
EOF
cat > "$idir/bad_mapparam.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Array::map([1, 2], (s: String) -> { s }); 0 }
EOF
cat > "$idir/bad_foldparam.vibe" <<'EOF'
export let _start: () -> Int = () -> { let r = Array::fold([1, 2], 0, (acc: String, x) -> { acc }); 0 }
EOF
cat > "$idir/bad_arrslice.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2, 3]; let b = Array::slice(a, 0, 2); let s: String = Array::get(b, 0); 0 }
EOF
cat > "$idir/bad_arrconcat.vibe" <<'EOF'
export let _start: () -> Int = () -> { let c = Array::concat([1, 2], [3, 4]); let s: String = Array::get(c, 0); 0 }
EOF
cat > "$idir/bad_arrconcatmix.vibe" <<'EOF'
export let _start: () -> Int = () -> { let c = Array::concat([1, 2], ["x"]); 0 }
EOF
cat > "$idir/bad_arrpushallmix.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::push_all(a, ["x"]); 0 }
EOF
cat > "$idir/bad_arrrev.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Array::reverse([1, 2]); let s: String = Array::get(b, 0); 0 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/ok.vibe" "$idir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$idir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed index/tuple did not compile (over-rejects)" >&2
  cat "$idir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_index bad_tuple bad_idxtype bad_idxelem bad_stridx bad_arrget bad_arrpush bad_arrset bad_arrmap bad_arrfold bad_mapparam bad_foldparam bad_arrslice bad_arrconcat bad_arrconcatmix bad_arrpushallmix bad_arrrev; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$idir/$bad.vibe" "$idir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$idir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (index/tuple check regressed)" >&2; exit 1
  fi
done
rm -rf "$idir"
echo "[compiler-gate] indexing / tuple-projection type checking ok"

# 34b. match-arm guards (#666): `pat if cond => body` must DISPATCH on the guard.
#     Guards were previously parsed and silently DISCARDED — the arm was taken
#     unconditionally (`match 5 { n if n > 100 => 999, _ => 0 }` wrongly => 999).
#     Now desugared at parse time into nested EIf/EMatch over a bound scrutinee,
#     so a failed guard falls through to later arms, and pattern bindings (with
#     re-binding in the fall-through arm) stay in scope for the guard. Verify
#     the runtime answer, not just that it compiles.
echo "[compiler-gate] 34b/35 match-arm guard dispatch (#666)"
gdir="_build/_gate_guard"
rm -rf "$gdir"; mkdir -p "$gdir"
cat > "$gdir/guard.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let miss = match 5 { n if n > 100 => 999, _ => 7 }
  let hit = match 5 { n if n > 3 => 11, _ => 0 }
  let fall = match 5 { n if n > 100 => 1, n if n > 4 => 2, _ => 3 }
  let o = Some(2)
  let bind = match o { Some(x) if x > 5 => x, Some(y) => y + 100, _ => 0 }
  miss + hit + fall + bind
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gdir/guard.vibe" "$gdir/guard.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gdir/guard.wasm" ]; then
  echo "[compiler-gate] FAIL: guarded match did not compile" >&2
  cat "$gdir/guard.wasm.diag" >&2 2>/dev/null; exit 1
fi
gres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gdir/guard.wasm" 2>/dev/null | tr -dc '0-9-')"
rm -rf "$gdir"
# 7 (guard misses -> wildcard) + 11 (guard hits) + 2 (second guard) + 102 (bind fall-through) = 122
if [ "$gres" != "122" ]; then
  echo "[compiler-gate] FAIL: guarded match returned '$gres' (expected 122 — guard dispatch wrong)" >&2; exit 1
fi
echo "[compiler-gate] match-arm guard dispatch ok (122)"

# 35. match exhaustiveness: a match on a concrete user enum must cover every
#     variant or carry a catch-all; a non-exhaustive match must be rejected.
#     Wildcard, full-coverage, and or-pattern coverage must still compile.
echo "[compiler-gate] 35/35 match exhaustiveness (enum variant coverage)"
xdir="_build/_gate_exhaust"
rm -rf "$xdir"; mkdir -p "$xdir"
cat > "$xdir/ok.vibe" <<'EOF'
enum Color { Red; Green; Blue }
export let _start: () -> Int = () -> {
  let a = match Red { Red => 1, Green => 2, Blue => 3 }
  let b = match Green { Red => 1, _ => 0 }
  let c = match Blue { Red | Green => 1, Blue => 3 }
  a + b + c
}
EOF
cat > "$xdir/bad.vibe" <<'EOF'
enum Color { Red; Green; Blue }
export let _start: () -> Int = () -> { match Red { Red => 1 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ok.vibe" "$xdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: exhaustive matches did not compile (over-rejects)" >&2
  cat "$xdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/bad.vibe" "$xdir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$xdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: non-exhaustive match compiled (exhaustiveness check regressed)" >&2; exit 1
fi
rm -rf "$xdir"
echo "[compiler-gate] match exhaustiveness ok"

# 36. literal-pattern type checking: an integer/string/boolean literal pattern
#     can only match a scrutinee of its own type — `match 5 { "x" => .. }` and a
#     nested `Some(true)` over `Option[Int]` must be rejected; matching literals
#     of the right type (incl. nested) must compile.
echo "[compiler-gate] 36/36 literal-pattern type checking"
ldir="_build/_gate_litpat"
rm -rf "$ldir"; mkdir -p "$ldir"
cat > "$ldir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = match 5 { 0 => 1, 5 => 2, _ => 0 }
  let o: Option[Int] = Some(1)
  let b = match o { Some(3) => 1, Some(_) => 9, None => 0 }
  a + b
}
EOF
cat > "$ldir/bad_lit.vibe" <<'EOF'
export let _start: () -> Int = () -> { match 5 { "x" => 1, _ => 0 } }
EOF
cat > "$ldir/bad_nested.vibe" <<'EOF'
export let _start: () -> Int = () -> { let o: Option[Int] = Some(1); match o { Some(true) => 1, _ => 0 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed literal patterns did not compile (over-rejects)" >&2
  cat "$ldir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_lit bad_nested; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ldir/$bad.vibe" "$ldir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$ldir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed literal pattern $bad compiled (check regressed)" >&2; exit 1
  fi
done
rm -rf "$ldir"
echo "[compiler-gate] literal-pattern type checking ok"

# 37. unary `-` on a non-number and `break`/`continue` outside a loop must be
#     rejected; numeric negation and in-loop break/continue must compile.
echo "[compiler-gate] 37/37 unary-minus / break-outside-loop checking"
bdir="_build/_gate_breakneg"
rm -rf "$bdir"; mkdir -p "$bdir"
cat > "$bdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut i = 0
  let mut s = 0
  while i < 10 { if i == 5 { break }; i = i + 1 }
  for x in [1, 2, 3] { if x == 2 { continue }; s = s + x }
  let neg = -i
  neg + s
}
EOF
cat > "$bdir/bad_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = -"hi"; 0 }
EOF
cat > "$bdir/bad_break.vibe" <<'EOF'
export let _start: () -> Int = () -> { break; 0 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/ok.vibe" "$bdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$bdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed negation/break/continue did not compile (over-rejects)" >&2
  cat "$bdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
for bad in bad_neg bad_break; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$bad.vibe" "$bdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$bdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-formed $bad compiled (unary-minus/break check regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[compiler-gate] unary-minus / break-outside-loop checking ok"

# 38. tuple-pattern destructuring soundness: `let (a, b) = v` may only
#     destructure a tuple value; binding a tuple pattern over a concrete
#     non-tuple (`let (a, b) = 5`) must be rejected, while a genuine tuple
#     destructure must still compile.
echo "[compiler-gate] 38/38 tuple-pattern destructuring type checking"
tdir="_build/_gate_tupledestr"
rm -rf "$tdir"; mkdir -p "$tdir"
cat > "$tdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = (1, 2); a + b }
EOF
cat > "$tdir/bad_nontuple.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = 5; a + b }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed tuple destructure did not compile (over-rejects)" >&2
  cat "$tdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/bad_nontuple.vibe" "$tdir/bad_nontuple.wasm" _start >/dev/null 2>&1 || true
if [ -s "$tdir/bad_nontuple.wasm" ]; then
  echo "[compiler-gate] FAIL: ill-typed tuple destructure compiled (tuple-pattern check regressed)" >&2; exit 1
fi
rm -rf "$tdir"
echo "[compiler-gate] tuple-pattern destructuring type checking ok"

# 39. multi-feature end-to-end smoke: real programs that combine several language
#     features must compile through the fresh stage2 AND run to a known value —
#     a codegen/runtime regression net broader than the single-feature checks
#     above. `eff` deliberately exercises this session's work together: multi-
#     operation effect dispatch (#665), a match guard inside a handler arm
#     (#666), and the effect-call discipline (#626) in one program.
echo "[compiler-gate] 39/39 multi-feature end-to-end smoke"
sdir="_build/_gate_smoke"
rm -rf "$sdir"; mkdir -p "$sdir"
cat > "$sdir/clos.vibe" <<'EOF'
let rec fold: (Array[Int], Int, (Int, Int) -> Int) -> Int = (a, acc, f) -> {
  if Array::length(a) == 0 { acc }
  else { let h = Array::get(a, 0); fold(Array::slice(a, 1, Array::length(a)), f(acc, h), f) }
}
export let _start: () -> Int = () -> { let add = (x: Int, y: Int) -> { x + y }; fold([1, 2, 3, 4], 0, add) }
EOF
cat > "$sdir/eff.vibe" <<'EOF'
effect Calc { Add(Int) -> Int; Mul(Int) -> Int }
export let _start: () -> Int = () -> {
  handle {
    let a = perform Calc::Add(5)
    let b = perform Calc::Mul(3)
    a + b
  } with Calc {
    Add(n) => resume(match n { x if x > 3 => x * 10, _ => n });
    Mul(n) => resume(n + 100)
  }
}
EOF
cat > "$sdir/gen.vibe" <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) }
let rec sum: (Tree) -> Int = (t) -> { match t { Leaf(n) => n, Node(l, r) => sum(l) + sum(r) } }
export let _start: () -> Int = () -> { sum(Node(Node(Leaf(1), Leaf(2)), Leaf(3))) }
EOF
cat > "$sdir/teq.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let e1 = (1, "b") == (1, "b")
  let e2 = (1, 2, 3) == (1, 2, 3)
  let n1 = (1, "b") != (1, "c")
  let bad = (1, 2) == (1, 9)
  let v = if e1 { 1 } else { 0 }
  let v2 = if e2 { 10 } else { 0 }
  let v3 = if n1 { 100 } else { 0 }
  let v4 = if bad { 1000 } else { 0 }
  v + v2 + v3 + v4
}
EOF
cat > "$sdir/eeq.vibe" <<'EOF'
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let c = Circle(5)
  let v1 = if c == Circle(5) { 1 } else { 0 }
  let v2 = if Circle(5) != Circle(9) { 10 } else { 0 }
  let v3 = if Rect(3, 4) == Rect(3, 4) { 100 } else { 0 }
  let v4 = if Pt == Pt { 1000 } else { 0 }
  let v5 = if Circle(5) != Pt { 10000 } else { 0 }
  v1 + v2 + v3 + v4 + v5
}
EOF
cat > "$sdir/seq.vibe" <<'EOF'
struct V { x: Int; y: Int } derive(Eq)
struct N { name: String; value: Int } derive(Eq)
export let _start: () -> Int = () -> {
  let a = V::{ x: 1, y: 2 }
  let b = V::{ x: 1, y: 2 }
  let c = V::{ x: 3, y: 4 }
  let na = N::{ name: "foo", value: 1 }
  let nb = N::{ name: "foo", value: 1 }
  let v1 = if a == b { 1 } else { 0 }
  let v2 = if a != c { 20 } else { 0 }
  let v3 = if na == nb { 300 } else { 0 }
  let v4 = if a == c { 5000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
cat > "$sdir/eveq.vibe" <<'EOF'
enum Color { Red; Green; Blue }
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let a = Green
  let b = Green
  let c = Red
  let s1 = Circle(5)
  let s2 = Circle(5)
  let v1 = if a == b { 1 } else { 0 }
  let v2 = if a != c { 20 } else { 0 }
  let v3 = if s1 == s2 { 3000 } else { 0 }
  let v4 = if s1 == Circle(9) { 40000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# qctor: qualified constructor references `Enum::Variant` (`Color::Green`,
# `Sh::Circle(5)`) resolve at check time and dispatch `==` structurally, both as
# direct literals and through qualified-ctor-bound variables. (#672 qualified
# ctors: checker resolve_qualified_ctor_ident + desugar unqualify + infer.)
cat > "$sdir/qctor.vibe" <<'EOF'
enum Color { Red; Green; Blue }
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let a = Color::Green
  let b: Color = Green
  let v1 = if a == b { 1 } else { 0 }
  let c = Sh::Circle(5)
  let d: Sh = Circle(5)
  let v2 = if c == d { 10 } else { 0 }
  let v3 = if Color::Red == Color::Red { 100 } else { 0 }
  let v4 = if Sh::Circle(5) == Sh::Circle(5) { 1000 } else { 0 }
  let v5 = if Sh::Circle(5) != Sh::Rect(1, 2) { 10000 } else { 0 }
  v1 + v2 + v3 + v4 + v5
}
EOF
# rec: recursive enum (`Tree`) and nested struct (`Outer { Inner }`) compare
# structurally — the generated comparators emit DIRECT `T::equals` calls for
# aggregate field/variant-arg types, so recursion closes without relying on
# operand type inference. (#672 recursion close: eq_for_typed.)
cat > "$sdir/rec.vibe" <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) } derive(Eq)
struct Inner { v: Int } derive(Eq)
struct Outer { a: Inner; b: Int } derive(Eq)
export let _start: () -> Int = () -> {
  let t1 = Node(Leaf(1), Leaf(2))
  let t2 = Node(Leaf(1), Leaf(2))
  let t3 = Node(Leaf(1), Leaf(3))
  let x = Outer::{ a: Inner::{ v: 1 }, b: 2 }
  let y = Outer::{ a: Inner::{ v: 1 }, b: 2 }
  let z = Outer::{ a: Inner::{ v: 9 }, b: 2 }
  let v1 = if t1 == t2 { 1 } else { 0 }
  let v2 = if t1 != t3 { 20 } else { 0 }
  let v3 = if x == y { 300 } else { 0 }
  let v4 = if x != z { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# beq: builtin Option/Result and tuples with AGGREGATE payloads compare
# structurally (#825). Before the fix the bare-`==` dispatch only recovered the
# head name ("Option"/"Result") and word-compared payloads, so `Some([1,2]) ==
# Some([1,2])` was silently false (heap pointers differ); tuples containing
# arrays likewise. The dispatch now infers the full static shape from literal
# syntax and routes through eq_for_typed. v7 guards the #815 follow-up: the
# lowered match interpolates as true/false, not raw 1/0 (the boolish
# classifier sees through the lift_match_scrutinees `let __m_scrut_N` wrap).
cat > "$sdir/beq.vibe" <<'EOF'
enum Res[T, E] {
  Ok(T);
  Err(E)
}
export let _start: () -> Int = () -> {
  let v1 = if Some([1, 2]) == Some([1, 2]) { 1 } else { 0 }
  let v2 = if Some((1, 2)) == Some((1, 2)) { 20 } else { 0 }
  let v3 = if Some(Some(1)) == Some(Some(1)) { 300 } else { 0 }
  let v4 = if Ok([1, 2]) == Ok([1, 2]) { 4000 } else { 0 }
  let v5 = if ([1, 2], 0) == ([1, 2], 0) { 50000 } else { 0 }
  let v6 = if Some([1, 2]) != Some([1, 3]) { 600000 } else { 0 }
  let v7 = if "\{Some(1) == Some(1)}" == "true" { 7000000 } else { 0 }
  v1 + v2 + v3 + v4 + v5 + v6 + v7
}
EOF
# tann: function-type annotation arity. A parenthesized tuple parameter
# `((A, B)) -> R` is ONE tuple param, distinct from `(A, B) -> R`'s two params —
# previously both flattened to a two-param list and the tuple-param form failed
# to typecheck (`expected (Bool,Int)->Int, got (?t0)->Int`). Covers 0/1/2-param,
# a function-typed param (HOF), the tuple param, and tuple-param-plus-scalar.
# (parser_base.vibe parse_type_impl arity-preserving paren group.)
# tostr: `__to_string` of large integers (via interpolation) stringifies the
# DECIMAL value instead of misreading the i64 as a string handle. #664 root
# cause: a value whose high 32 bits fall below memory_size was treated as a
# string pointer, so its low 32 bits became a bogus length — a multi-gigabyte
# one crashed the persistent-sources-cache `String::concat` ("memory access out
# of bounds"), a `0` low word produced an empty string. The `64 <= ptr` and
# `ptr + len <= memory_size` bounds keep genuine strings on the identity path
# while routing large integers to decimal stringify.
# (compile_call.vibe __to_string heuristic.)
cat > "$sdir/tostr.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let v1 = if "\{4294967296}" == "4294967296" { 1 } else { 0 }
  let v2 = if "\{8294967296}" == "8294967296" { 20 } else { 0 }
  let v3 = if "\{1000000000000000000}" == "1000000000000000000" { 300 } else { 0 }
  let v4 = if "\{42}" == "42" { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# ieq: integer `==` is sound for values >= 2^32 and large integer literals
# compile without truncation/trap. Root cause: the generic `eq` fell back to
# `str_eq` for bit-different operands, which reads an Int as a string fat-pointer
# `(ptr<<32)|len` — two unequal ints with a zero low word compared EQUAL, and a
# large low word made `str_eq`'s byte loop read OOB. The latter also surfaced as
# a compile trap for literals >= 2^39 (leb128's loop terminates on `v == 0`).
# Guards the `str_eq` fallback on both operands looking like real strings.
# (bodies_core_a1a1_eq.vibe emit_looks_like_string.)
#
# #678: v1/v2 use BARE integer VARIABLES (`let a = 1<<40; a == b`) — the residual
# the shape-only path could not classify. A bare ident now takes the direct
# i64.eq when its slot is int-tracked (compile_expr_tail expr_is_intish +
# int_local_slots, pruned at branch/arm boundaries). v5 is the regression guard:
# a bare String variable must still compare by CONTENT (a heap-built "abc" at a
# different offset than the interned literal), proving the int-tracking never
# misclassifies a string slot as int.
cat > "$sdir/ieq.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = 1 << 40
  let b = 1 << 41
  let v1 = if a == b { 0 } else { 1 }
  let c = 1 << 50
  let v2 = if c == c { 20 } else { 0 }
  let v3 = if "\{1 << 40}" == "1099511627776" { 300 } else { 0 }
  let v4 = if 2305843009213693951 > 1000000000 { 4000 } else { 0 }
  let s = String::concat("ab", "c")
  let v5 = if s == "abc" { 0 } else { 9000 }
  v1 + v2 + v3 + v4 + v5
}
EOF
# pstruct: struct field patterns in `match` (`S::{ x, y }`) bind fields by NAME
# (offset from the struct field-name table, so pattern field order is
# independent of declaration order) — previously fields were never bound
# (`undefined variable: x`). Covers full / reordered / partial field binds.
# (compile_match.vibe bind_struct_pat + is_catchall_pat PStruct.)
cat > "$sdir/pstruct.vibe" <<'EOF'
struct P { x: Int; y: Int }
struct N { a: Int; b: Int; c: Int }
export let _start: () -> Int = () -> {
  let p = P::{ x: 3, y: 5 }
  let n = N::{ a: 2, b: 4, c: 6 }
  let v1 = match p { P::{ x, y } => x * 10 + y }
  let v2 = match p { P::{ y, x } => x * 10 + y }
  let v3 = match n { N::{ a, c } => a + c }
  v1 + v2 + v3
}
EOF
# pneg: negative integer literal patterns `-5` (bare, in a constructor arg, and
# in a tuple element) — previously `unexpected in pattern: -`.
# (parser_base.vibe parse_pattern TMinus arm.)
cat > "$sdir/pneg.vibe" <<'EOF'
enum E { N(Int) }
export let _start: () -> Int = () -> {
  let v1 = match (0 - 5) { -5 => 1, _ => 0 }
  let v2 = match 5 { -5 => 0, _ => 20 }
  let v3 = match N(0 - 3) { N(-3) => 300, N(_) => 0 }
  let v4 = match (0 - 1, 2) { (-1, 2) => 4000, _ => 0 }
  v1 + v2 + v3 + v4
}
EOF
# interp: string interpolation `\{expr}` parses an arbitrary EXPRESSION
# (arithmetic, call, field access, multiple holes), not just a bare
# identifier — previously the embedded source was treated as an identifier name
# (`undefined variable: 1+1`). (parser_expr_primary.vibe build_interp_expr.)
# The `\(expr)` spelling was removed in 0.3.0 (#805; see bad_interp_paren in
# section 29 for the reject side).
cat > "$sdir/interp.vibe" <<'EOF'
struct P { x: Int }
let inc: (Int) -> Int = (n) -> { n + 1 }
export let _start: () -> Int = () -> {
  let a = 2
  let p = P::{ x: 7 }
  let v1 = if "\{a + 3}" == "5" { 1 } else { 0 }
  let v2 = if "\{inc(a)}" == "3" { 20 } else { 0 }
  let v3 = if "\{p.x}" == "7" { 300 } else { 0 }
  let v4 = if "\{a}-\{p.x}" == "2-7" { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
cat > "$sdir/tann.vibe" <<'EOF'
let two: (Int, Int) -> Int = (a, b) -> { a + b }
let one: (Int) -> Int = (x) -> { x + 1 }
let zero: () -> Int = () -> { 5 }
let hof: ((Int) -> Int, Int) -> Int = (f, x) -> { f(x) }
let tup1: ((Int, Int)) -> Int = (p) -> { let (a, b) = p; a + b }
let mix: ((Int, Int), Int) -> Int = (p, c) -> { let (a, b) = p; a + b + c }
export let _start: () -> Int = () -> {
  two(3, 4) + one(9) + zero() + hof((n) -> { n * 2 }, 10) + tup1((1, 2)) + mix((1, 2), 100)
}
EOF
smoke_check() {
  local nm="$1" want="$2"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$sdir/$nm.vibe" "$sdir/$nm.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$sdir/$nm.wasm" ]; then
    echo "[compiler-gate] FAIL: smoke '$nm' did not compile (codegen regression)" >&2
    cat "$sdir/$nm.wasm.diag" >&2 2>/dev/null; exit 1
  fi
  local got
  got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sdir/$nm.wasm" 2>/dev/null | tr -dc '0-9-')"
  if [ "$got" != "$want" ]; then
    echo "[compiler-gate] FAIL: smoke '$nm' ran to '$got' (expected $want)" >&2; exit 1
  fi
}
smoke_check clos 10
smoke_check eff 153
smoke_check gen 6
smoke_check teq 111
smoke_check eeq 11111
smoke_check seq 321
smoke_check eveq 3021
smoke_check qctor 11111
smoke_check rec 4321
smoke_check beq 7654321
smoke_check tann 148
smoke_check interp 4321
smoke_check pneg 4321
smoke_check pstruct 78
smoke_check tostr 4321
smoke_check ieq 4321
rm -rf "$sdir"
echo "[compiler-gate] multi-feature end-to-end smoke ok (10/153/6/111/11111/321/3021/11111/4321/7654321/148/4321/4321/78/4321/4321)"

echo "[compiler-gate] GC guest future refusal (#3188)"
VIBE_STAGE2_WASM="$stage2_wasm" bash scripts/test_gc_future_refusal.sh
echo "[compiler-gate] capability DCE reachability (#3193)"
VIBE_STAGE2_WASM="$stage2_wasm" bash scripts/test_capability_dce_reachability.sh

# Function extraction validates edits before publication.
echo "[compiler-gate] function extraction"
VIBE_TEST_CLI_WASM="$stage2_wasm" bash "$ROOT_DIR/scripts/test_extract_function.sh"
