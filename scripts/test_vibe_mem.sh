#!/usr/bin/env bash
# Integration test for `vibe run --mem` (memory profiling tier 1): the runner
# reads the `__heap_ptr` bump-allocator pointer before/after `_start` and reports
# peak / total allocated to stderr. A pure program allocates ~nothing; an
# allocation-heavy program reports a real, larger figure. stdout stays clean.
#
# Installs a FRESH toolchain into a throwaway VIBE_HOME/VIBE_BIN_DIR (mirrors
# scripts/test_vibe_step.sh) so it never touches a real install.
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
bash install/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

proj="$WORK/proj"; mkdir -p "$proj"
cat > "$proj/pure.vibex" <<'EOF'
let add = (a: Int, b: Int) -> Int { a + b }
fn main with () { let _ = add(2, 3); () }
EOF
cat > "$proj/output.vibex" <<'EOF'
fn main with Stdout { Stdout::write_stream("5\n") }
EOF
# Allocation-heavy: O(n^2) string build allocates a fresh string each iteration.
cat > "$proj/alloc.vibex" <<'EOF'
let build = (n: Int) -> String {
  let mut s = ""
  let mut i = 0
  while i < n {
    s = String::concat(s, "x")
    i = i + 1
  }
  s
}
fn main with () { let _ = String::length(build(500)); () }
EOF

# 1. plain run emits NO memory report.
plain_err="$("$VIBE" run "$proj/output.vibex" 2>&1 >/dev/null)"
if printf '%s' "$plain_err" | grep -q "vibe::mem"; then bad "plain run leaked a memory report"; else ok "plain run emits no memory report"; fi

# 2. --mem emits the machine-readable line + keeps stdout clean.
output_out="$("$VIBE" run --mem "$proj/output.vibex" 2>/dev/null)"
output_err="$("$VIBE" run --mem "$proj/output.vibex" 2>&1 >/dev/null)"
[ "$(printf '%s' "$output_out" | grep -o '5' | head -1)" = "5" ] && ok "--mem: stdout contains the program output (5)" || bad "--mem: stdout missing program output (got: $output_out)"
printf '%s\n' "$output_err" | grep -qE "vibe::mem heap_base=[0-9]+ heap_peak=[0-9]+ allocated=[0-9]+ committed=[0-9]+" \
  && ok "--mem: machine-readable line present" || bad "--mem: missing machine-readable line (got: $output_err)"

# 3. pure program allocates ~0 bytes.
pure_err="$("$VIBE" run --mem "$proj/pure.vibex" 2>&1 >/dev/null)"
pure_alloc="$(printf '%s\n' "$pure_err" | grep -oE 'allocated=[0-9]+' | head -1 | cut -d= -f2)"
[ "${pure_alloc:-x}" = "0" ] && ok "pure program allocates 0 bytes" || bad "pure program allocated=$pure_alloc (expected 0)"

# 4. allocation-heavy program reports a substantial figure (> 10 KiB).
alloc_err="$("$VIBE" run --mem "$proj/alloc.vibex" 2>&1 >/dev/null)"
alloc_bytes="$(printf '%s\n' "$alloc_err" | grep -oE 'allocated=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "$alloc_bytes" ] && [ "$alloc_bytes" -gt 10240 ]; then
  ok "alloc-heavy program reports >10 KiB (allocated=$alloc_bytes)"
else
  bad "alloc-heavy program allocated=$alloc_bytes (expected >10240)"
fi

# 5. the human line is present too.
printf '%s\n' "$alloc_err" | grep -qE "vibe: memory — allocated .* peak heap .* committed " \
  && ok "--mem: human-readable summary present" || bad "--mem: missing human summary (got: $alloc_err)"

# 6. growth timeline (tier 2): small program stays within the 4 MiB initial
#    memory -> 0 grow events; a >4 MiB allocator -> grow events + memgrow lines.
printf '%s\n' "$alloc_err" | grep -qE "grow_events=0\b" \
  && ok "small program: 0 growth events (stays within initial memory)" \
  || bad "small program: expected grow_events=0 (got: $(printf '%s' "$alloc_err" | grep -oE 'grow_events=[0-9]+'))"

cat > "$proj/grow.vibex" <<'EOF'
let build = (n: Int) -> Int {
  let mut s = ""
  let mut i = 0
  while i < n { s = String::concat(s, "x"); i = i + 1 }
  String::length(s)
}
fn main with () { let _ = build(3500); () }
EOF
grow_err="$("$VIBE" run --mem "$proj/grow.vibex" 2>&1 >/dev/null)"
gcount="$(printf '%s\n' "$grow_err" | grep -oE 'grow_events=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "$gcount" ] && [ "$gcount" -gt 0 ]; then
  ok ">4 MiB program records growth events (grow_events=$gcount)"
else
  bad ">4 MiB program expected grow_events>0 (got: $gcount)"
fi
printf '%s\n' "$grow_err" | grep -qE "vibe::memgrow t_us=[0-9]+ from=[0-9]+ to=[0-9]+ pages=\+[0-9]+" \
  && ok "growth timeline emits machine-readable memgrow lines" \
  || bad "missing memgrow line (got: $(printf '%s\n' "$grow_err" | grep memgrow | head -1))"

# 7. heap sampling (tier 3): --mem-sample produces a heap-over-time curve. Sample
#    capture is timing-based (epoch-driven), so use a long compute loop that spans
#    many 1 ms intervals on any machine, retry a few times to absorb scheduler
#    jitter, and guard `grep -c` (it exits non-zero on 0 matches, which would trip
#    `set -e`).
cat > "$proj/long.vibex" <<'EOF'
fn main with () {
  let mut acc = 0
  let mut i = 0
  while i < 60000000 { acc = acc + (i & 7); i = i + 1 }
  let _ = acc
  ()
}
EOF
sample_err=""; scount=0
for _attempt in 1 2 3; do
  sample_err="$("$VIBE" run --mem-sample "$proj/long.vibex" 2>&1 >/dev/null)"
  scount="$(printf '%s\n' "$sample_err" | grep -cE 'vibe::memsample t_us=[0-9]+ heap=[0-9]+' || true)"
  [ "${scount:-0}" -ge 1 ] && break
done
printf '%s\n' "$sample_err" | grep -qE "vibe: heap samples — " \
  && ok "--mem-sample emits a heap-sampling summary" \
  || bad "--mem-sample missing summary (got: $(printf '%s\n' "$sample_err" | tail -1))"
if [ "${scount:-0}" -ge 1 ]; then
  ok "--mem-sample records >=1 heap sample over time ($scount samples)"
else
  bad "--mem-sample recorded 0 samples across retries (expected >=1 for a long run)"
fi
# plain run must not emit samples.
if "$VIBE" run "$proj/long.vibex" 2>&1 | grep -q "vibe::memsample"; then
  bad "plain run leaked heap samples"
else
  ok "plain run emits no heap samples"
fi

echo "[test_vibe_mem] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
