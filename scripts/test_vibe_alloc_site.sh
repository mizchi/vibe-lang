#!/usr/bin/env bash
# Integration test for `vibe run --alloc-site` (memory profiling tier 4): the
# runner attributes bump-heap growth to the function that allocated it. It reuses
# the break-mode `vibe::dbg_break` hook (fired at every user-function entry), so
# no new codegen instrumentation is needed and a plain run is byte-identical.
# Reports `vibe::allocsite fn=<name> line=<decl> bytes=<n>` per function to stderr,
# top-N by bytes; stdout stays the program's own output.
#
# Installs a FRESH toolchain into a throwaway VIBE_HOME/VIBE_BIN_DIR (mirrors
# scripts/test_vibe_mem.sh) so it never touches a real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
if [ ! -x "$RT" ] || [ -n "$(find runtime/viberun/src -name "*.rs" -newer "$RT" 2>/dev/null | head -1)" ]; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "FAIL: no CLI wasm built" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

echo "[test] installing fresh CLI into $VIBE_HOME"
bash scripts/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }
bytes_of() { printf '%s\n' "$1" | grep -oE "fn=$2 line=[0-9?]+ bytes=[0-9]+" | grep -oE 'bytes=[0-9]+' | head -1 | cut -d= -f2; }

proj="$WORK/proj"; mkdir -p "$proj"
# `heavy` does ~4x the per-iteration allocation of `light`, and main calls both;
# leaf attribution must credit each function its own growth.
cat > "$proj/sites.vibex" <<'EOF'
let heavy = (n: Int) -> String {
  let mut s = ""
  let mut i = 0
  while i < n { s = String::concat(s, "xxxx"); i = i + 1 }
  s
}
let light = (n: Int) -> String {
  let mut t = ""
  let mut j = 0
  while j < n { t = String::concat(t, "y"); j = j + 1 }
  t
}
fn main with { Stdout } {
  let a = heavy(300)
  let b = light(50)
  Stdout::write_stream("\{String::length(a) + String::length(b)}\n")
}
EOF

# 1. plain run emits NO alloc-site report.
plain="$("$VIBE" run "$proj/sites.vibex" 2>&1 >/dev/null)"
if printf '%s' "$plain" | grep -q "allocsite"; then bad "plain run leaked an alloc-site report"; else ok "plain run emits no alloc-site report"; fi

# 2. --alloc-site keeps stdout clean (just the program's 1250).
site_out="$("$VIBE" run --alloc-site "$proj/sites.vibex" 2>/dev/null)"
[ "$(printf '%s' "$site_out" | grep -o '1250' | head -1)" = "1250" ] && ok "--alloc-site: stdout contains the program output (1250)" || bad "--alloc-site: stdout missing program output (got: $site_out)"

# 3. machine-readable lines + human summary on stderr.
site_err="$("$VIBE" run --alloc-site "$proj/sites.vibex" 2>&1 >/dev/null)"
printf '%s\n' "$site_err" | grep -qE "vibe::allocsite fn=[A-Za-z_][A-Za-z0-9_]* line=[0-9?]+ bytes=[0-9]+" \
  && ok "--alloc-site: machine-readable lines present" || bad "--alloc-site: missing machine line (got: $site_err)"
printf '%s\n' "$site_err" | grep -qE "vibe: alloc sites — [0-9]+ function\(s\), .* attributed total" \
  && ok "--alloc-site: human summary present" || bad "--alloc-site: missing human summary (got: $site_err)"

# 4. both functions are attributed, and heavy >> light (it allocates 4x per iter
#    over 6x the iterations).
hb="$(bytes_of "$site_err" heavy)"; lb="$(bytes_of "$site_err" light)"
[ -n "$hb" ] && [ "$hb" -gt 10000 ] && ok "heavy attributed a substantial figure (bytes=$hb)" || bad "heavy bytes=$hb (expected >10000)"
[ -n "$lb" ] && [ "$lb" -gt 0 ] && ok "light attributed a non-zero figure (bytes=$lb)" || bad "light bytes=$lb (expected >0)"
if [ -n "$hb" ] && [ -n "$lb" ] && [ "$hb" -gt "$lb" ]; then
  ok "heavy attributed more than light ($hb > $lb)"
else
  bad "expected heavy > light (heavy=$hb light=$lb)"
fi

# 5. a function's declaration line is resolved (not `?`) via the funcmap.
printf '%s\n' "$site_err" | grep -qE "vibe::allocsite fn=heavy line=[0-9]+ " \
  && ok "declaration line resolved for heavy" || bad "heavy line unresolved (got: $(printf '%s\n' "$site_err" | grep 'fn=heavy'))"

# 6. coverage: allocation in a pure mut-loop (no user-function call) is still
#    attributed — to the enclosing function. dbg_line-based attribution missed
#    this; dbg_break (per function entry) catches it.
cat > "$proj/inline.vibex" <<'EOF'
fn main with { } {
  let mut s = ""
  let mut i = 0
  while i < 200 { s = String::concat(s, "zzzz"); i = i + 1 }
  let _ = String::length(s)
  ()
}
EOF
inline_err="$("$VIBE" run --alloc-site "$proj/inline.vibex" 2>&1 >/dev/null)"
ib="$(bytes_of "$inline_err" main)"
if [ -n "$ib" ] && [ "$ib" -gt 10000 ]; then
  ok "pure mut-loop attributed to main (bytes=$ib)"
else
  bad "pure mut-loop main bytes=$ib (expected >10000)"
fi

# 7. top-N cap: --alloc-site=1 reports only the top function (still summarizes all).
top1="$("$VIBE" run --alloc-site=1 "$proj/sites.vibex" 2>&1 >/dev/null)"
nlines="$(printf '%s\n' "$top1" | grep -cE '^vibe::allocsite ' || true)"
[ "${nlines:-0}" -eq 1 ] && ok "--alloc-site=1 caps the report to 1 function" || bad "--alloc-site=1 emitted $nlines lines (expected 1)"
printf '%s\n' "$top1" | grep -qE "top 1 shown" && ok "top-N summary reflects the cap" || bad "missing 'top 1 shown' (got: $top1)"

echo "[test_vibe_alloc_site] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
