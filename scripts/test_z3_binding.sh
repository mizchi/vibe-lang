#!/usr/bin/env bash
# @vibex/z3 against the real z3.wasm: the typed core-wasm import of a 38 MB
# third-party module.
#
#   bash scripts/test_z3_binding.sh <stage2.wasm>
#
# Asserted:
#   1. lib/@vibex/z3 and fixtures/z3/smtlib_main.vibex type-check against the
#      pinned binary (scripts/fetch_z3_wasm.sh);
#   2. the built program imports exactly the Z3 functions it calls (not all
#      853 the binding offers), each with the signature z3.wasm declares
#      (Z3_eval_smtlib2_string: (i32, i32) -> i32, ...);
#   3. running it is REFUSED, naming what z3.wasm needs. This is the npm
#      build of z3: an emscripten module that imports its JS runtime
#      (env.* -- pthreads, JS-side C++ exceptions, EM_ASM) and its memory, and
#      no vibe runner provides those to a foreign module. When one does, this
#      assertion is the one to turn into `prints "sat"`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_z3_binding.sh <stage2.wasm>" >&2; exit 2; }

WORK="$ROOT_DIR/_build/test_z3_binding"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[z3-binding] FAIL $*" >&2; exit 1; }

bash "$ROOT_DIR/scripts/fetch_z3_wasm.sh" >/dev/null || fail "could not fetch z3.wasm"
VIBERUN="${VIBE_Z3_BINDING_VIBERUN:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
if [ "$VIBERUN" = "$ROOT_DIR/runtime/viberun/target/release/viberun" ]; then
  bash "$ROOT_DIR/scripts/ensure_viberun.sh" >/dev/null 2>&1 || fail "could not build runtime/viberun"
fi

vibe() {
  VIBE_RUNNER="$VIBERUN" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_BUILD_DIR="$WORK/build" "$ROOT_DIR/runtime/vibe" "$@"
}

# 1.
for f in lib/@vibex/z3/z3.vibe fixtures/z3/smtlib_main.vibex; do
  out="$(vibe check "$f" 2>&1)" || { printf '%s\n' "$out" >&2; fail "vibe check $f"; }
  [ -z "$out" ] || { printf '%s\n' "$out" >&2; fail "vibe check $f printed diagnostics"; }
done

# 2. and 3. `vibe run` builds the artifact first, then runs it.
status=0
vibe run fixtures/z3/smtlib_main.vibex >"$WORK/out" 2>"$WORK/err" || status=$?
art="$WORK/build/run/smtlib_main.wasm"
[ -s "$art" ] || { cat "$WORK/err" >&2; fail "no artifact at $art"; }
node - "$art" <<'JS' || fail "import signatures"
const fs = require("node:fs");
const bytes = fs.readFileSync(process.argv[2]);
// Read the import section's function types directly: the JS API names
// imports but not their types.
let p = 8;
const u = () => { let r = 0, s = 0, b; do { b = bytes[p++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; };
const name = () => { const n = u(); const s = bytes.subarray(p, p + n).toString(); p += n; return s; };
const vt = { 0x7f: "i32", 0x7e: "i64", 0x7d: "f32", 0x7c: "f64" };
let types = [], imports = [];
while (p < bytes.length) {
  const id = bytes[p++]; const size = u(); const end = p + size;
  if (id === 1) {
    const n = u();
    for (let i = 0; i < n; i++) { p++; const np = u(); const ps = []; for (let k = 0; k < np; k++) ps.push(vt[bytes[p++]]); const nr = u(); const rs = []; for (let k = 0; k < nr; k++) rs.push(vt[bytes[p++]]); types.push(`(${ps.join(", ")}) -> (${rs.join(", ")})`); }
  } else if (id === 2) {
    const n = u();
    for (let i = 0; i < n; i++) { const m = name(); const f = name(); const kind = bytes[p++]; if (kind !== 0) throw new Error("non-function import " + m + "." + f); imports.push([m, f, u()]); }
  }
  p = end;
}
const want = {
  Z3_mk_config: "() -> (i32)",
  Z3_mk_context: "(i32) -> (i32)",
  Z3_del_context: "(i32) -> ()",
  Z3_eval_smtlib2_string: "(i32, i32) -> (i32)",
  Z3_get_full_version: "() -> (i32)",
  malloc: "(i32) -> (i32)",
  free: "(i32) -> ()",
  "vibe:memory.load8_u": "(i32) -> (i32)",
  "vibe:memory.store8": "(i32, i32) -> ()",
};
const mod = "vibe:wasm:lib/@vibex/z3/z3.wasm";
// Tree-shaken: exactly what the program calls (plus the memory accessor
// pair), not the 853 functions the binding offers.
const got = imports.filter(([m]) => m === mod).map(([, f]) => f).sort();
const wantNames = [...Object.keys(want), "Z3_del_config"].sort();
if (JSON.stringify(got) !== JSON.stringify(wantNames)) throw new Error(`imports ${got.length} z3 functions (${got.slice(0, 12).join(" ")}${got.length > 12 ? " ..." : ""}); want the ${wantNames.length} it calls: ${wantNames.join(" ")}`);
for (const [f, sig] of Object.entries(want)) {
  const hit = imports.find(([m, ff]) => m === mod && ff === f);
  if (!hit) throw new Error(`no import ${mod}.${f}`);
  if (types[hit[2]] !== sig) throw new Error(`${f}: ${types[hit[2]]}, want ${sig}`);
}
JS
[ "$status" != 0 ] || fail "the run succeeded; update this gate to assert z3's answer (see header)"
grep -q "cannot link 'vibe:wasm:lib/@vibex/z3/z3.wasm': it imports 121 item(s)" "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "the run failed for another reason than z3's own imports"; }

echo "[z3-binding] ok (checks against z3.wasm; imports typed from its exports; linking refused: z3.wasm needs the emscripten runtime)"
