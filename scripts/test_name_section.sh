#!/usr/bin/env bash
# Regression test for the wasm name section (debugger P0 / ADR-0035),
# updated for ADR-0077 (#1107): release
# executables are STRIPPED by default — the name section must be absent from
# a plain FS compile — while `VIBE_WASM_NAMES=1` (what `vibe run`/`vibe shell`
# pass, so trap backtraces keep naming user functions) must still produce a
# well-formed name section naming them. Builds a fresh CLI compiler and
# checks a compiled sample both ways.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
[ -x "$RT" ] || cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null

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

VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_WASM_NAMES=1 \
  "$RT" "$cli" "$work/prog.vibe" "$work/prog.named.wasm" main >/dev/null 2>&1
[ -s "$work/prog.named.wasm" ] || { echo "FAIL: VIBE_WASM_NAMES=1 compile produced no wasm" >&2; exit 1; }

# 1. both builds still run correctly
res="$("$RT" "$work/prog.wasm" 2>/dev/null | tr -dc '0-9')"
[ "$res" = "42" ] || { echo "FAIL: stripped program returned '$res' (expected 42)" >&2; exit 1; }
echo "ok: compiled program runs (42)"
res_n="$("$RT" "$work/prog.named.wasm" 2>/dev/null | tr -dc '0-9')"
[ "$res_n" = "42" ] || { echo "FAIL: named program returned '$res_n' (expected 42)" >&2; exit 1; }
echo "ok: VIBE_WASM_NAMES=1 program runs (42)"

# 2. name-section contract, both directions: extract function names from a
#    module; the default (release) build must have NONE, the VIBE_WASM_NAMES=1
#    build must be valid and name the user functions.
check_names() { # $1 = wasm path; prints function names one per line
  node - "$1" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const b = fs.readFileSync(path);
try { new WebAssembly.Module(b); } catch (e) { console.error("INVALID: " + e.message); process.exit(2); }
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
for (const n of names) console.log(n);
NODE
}

stripped_names="$(check_names "$work/prog.wasm")" || { echo "FAIL: stripped wasm invalid" >&2; exit 1; }
if [ -n "$stripped_names" ]; then
  echo "FAIL: default (release) build still carries a name section (ADR-0077 expects it stripped); got: $(echo "$stripped_names" | head -3 | tr '\n' ' ')" >&2
  exit 1
fi
echo "ok: default build strips the name section (ADR-0077)"

named_names="$(check_names "$work/prog.named.wasm")" || { echo "FAIL: named wasm invalid" >&2; exit 1; }
if ! echo "$named_names" | grep -qx "main" || ! echo "$named_names" | grep -qx "helper"; then
  echo "FAIL: VIBE_WASM_NAMES=1 name section missing main/helper; got: $(echo "$named_names" | head -10 | tr '\n' ' ')" >&2
  exit 1
fi
echo "ok: VIBE_WASM_NAMES=1 names user functions (main, helper)"

echo "[name-section-test] passed"
