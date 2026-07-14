#!/usr/bin/env bash
# Regression test for the wasm name section (debugger P0 / ADR-0035 /
# docs/release-roadmap.md テーマ3): a compiled program must carry a "name"
# custom section that names its user functions, so wasm backtraces and tooling
# show `main` instead of `<wasm function N>`. Builds a fresh CLI compiler and
# checks a compiled sample.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/moonrun_wasmtime/target/release/vibewt"
[ -x "$RT" ] || cargo build --release --manifest-path runtime/moonrun_wasmtime/Cargo.toml >/dev/null

cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "FAIL: no CLI wasm built" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/prog.vibe" <<'EOF'
export let helper = (x: Int) -> Int { x * 2 }
export let main = () -> Int { helper(21) }
EOF

VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  "$RT" "$cli" "$work/prog.vibe" "$work/prog.wasm" main >/dev/null 2>&1
[ -s "$work/prog.wasm" ] || { echo "FAIL: compile produced no wasm" >&2; exit 1; }

# 1. the program still runs correctly
res="$("$RT" "$work/prog.wasm" 2>/dev/null | tr -dc '0-9')"
[ "$res" = "42" ] || { echo "FAIL: program returned '$res' (expected 42)" >&2; exit 1; }
echo "ok: compiled program runs (42)"

# 2. the wasm is valid and carries a well-formed name section naming the funcs
node - "$work/prog.wasm" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const b = fs.readFileSync(path);
// validity
try { new WebAssembly.Module(b); } catch (e) { console.error("FAIL: invalid wasm: " + e.message); process.exit(1); }
// find the "name" custom section and decode the function-names subsection
let p = 8, names = [];
function u() { let x = 0, s = 0; for (;;) { const c = b[p++]; x |= (c & 0x7f) << s; if (!(c & 0x80)) break; s += 7; } return x >>> 0; }
while (p < b.length) {
  const id = b[p++], sz = u(), end = p + sz;
  if (id === 0) {
    const nl = u();
    const nm = b.slice(p, p + nl).toString();
    p += nl;
    if (nm === "name") {
      while (p < end) {
        const sub = b[p++], ssz = u(), sEnd = p + ssz;
        if (sub === 1) { // function names
          const count = u();
          for (let i = 0; i < count; i++) { const idx = u(); const ln = u(); names.push(b.slice(p, p + ln).toString()); p += ln; }
        }
        p = sEnd;
      }
    }
  }
  p = end;
}
const ok = names.includes("main") && names.includes("helper");
if (!ok) { console.error("FAIL: name section missing main/helper; got: " + JSON.stringify(names.slice(0, 10))); process.exit(1); }
console.log("ok: name section names user functions (main, helper)");
NODE

echo "[name-section-test] passed"
