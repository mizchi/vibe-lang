#!/usr/bin/env bash
# Integration test for `vibe bench`: compile a file's `bench {}` blocks and run
# the warm instance N times, reporting ns/op (min/p50/p95/mean), ops/sec, and
# bytes/op (bump-heap delta / iters — reuses the --mem tier-1 foundation). A pure
# bench allocates 0 B/op; an allocation-heavy bench reports a real figure.
#
# Fresh throwaway install (mirrors scripts/test_vibe_mem.sh).
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
HTTP_ECHO_PID=""
cleanup() {
  if [ -n "$HTTP_ECHO_PID" ] && kill -0 "$HTTP_ECHO_PID" 2>/dev/null; then
    kill "$HTTP_ECHO_PID" 2>/dev/null || true
    wait "$HTTP_ECHO_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
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
field() { printf '%s\n' "$1" | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2; }

proj="$WORK/proj"; mkdir -p "$proj"
cat > "$proj/pure_bench.vibe" <<'EOF'
let add = (a: Int, b: Int) -> Int { a + b }
bench "pure_add" { let _ = add(2, 3) }
EOF
cat > "$proj/alloc_bench.vibe" <<'EOF'
let build = (n: Int) -> String {
  let mut s = ""
  let mut i = 0
  while i < n { s = String::concat(s, "x"); i = i + 1 }
  s
}
bench "build" { let _ = String::length(build(50)) }
EOF

# 1. pure bench: machine-readable line, bytes_per_op = 0, ops_per_sec present.
pure_out="$("$VIBE" bench "$proj/pure_bench.vibe" --iters 200 --warmup 10 2>&1)"
printf '%s\n' "$pure_out" | grep -qE "vibe::bench label=.* iters=200 .* ops_per_sec=[0-9]+ bytes_per_op=[0-9]+" \
  && ok "pure: machine-readable bench line present" || bad "pure: missing/garbled bench line (got: $pure_out)"
[ "$(field "$pure_out" iters)" = "200" ] && ok "--iters respected (200)" || bad "--iters not respected (got: $(field "$pure_out" iters))"
[ "$(field "$pure_out" bytes_per_op)" = "0" ] && ok "pure bench: 0 bytes/op" || bad "pure bench bytes_per_op=$(field "$pure_out" bytes_per_op) (expected 0)"
pops="$(field "$pure_out" ops_per_sec)"
[ -n "$pops" ] && [ "$pops" -gt 0 ] && ok "ops_per_sec reported (> 0)" || bad "ops_per_sec not > 0 (got: $pops)"

# 2. alloc bench: bytes_per_op > 0.
alloc_out="$("$VIBE" bench "$proj/alloc_bench.vibe" --iters 200 2>&1)"
abytes="$(field "$alloc_out" bytes_per_op)"
if [ -n "$abytes" ] && [ "$abytes" -gt 0 ]; then
  ok "alloc bench reports bytes/op > 0 (bytes_per_op=$abytes)"
else
  bad "alloc bench bytes_per_op=$abytes (expected > 0)"
fi

# 3. percentile fields present + ordered (min <= p50 <= p95 not required strictly,
#    but all three must be present and numeric).
for f in ns_min ns_p50 ns_p95 ns_mean; do
  v="$(field "$alloc_out" "$f")"
  [ -n "$v" ] && ok "$f present ($v)" || bad "$f missing"
done

# 4. human summary line present.
printf '%s\n' "$alloc_out" | grep -qE "bench .*: 200 iters — .*/op .*ops/s" \
  && ok "human summary line present" || bad "missing human summary (got: $alloc_out)"

# 5. per-block granularity: a file with multiple `bench {}` blocks reports a row
#    per block, each labelled `<file>::<block>` (codegen exports `__bench_<name>`,
#    the runner times each in isolation). `light` does ~half the work of `heavy`.
cat > "$proj/multi_bench.vibe" <<'EOF'
let work = (n: Int) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < n { acc = acc + (i & 3); i = i + 1 }
  acc
}
bench "light" { let _ = work(500) }
bench "heavy" { let _ = work(1000) }
EOF
multi_out="$("$VIBE" bench "$proj/multi_bench.vibe" --iters 200 --warmup 20 2>&1)"
printf '%s\n' "$multi_out" | grep -qE "vibe::bench label=multi_bench\.vibe::light " \
  && ok "per-block: 'light' block reported separately" || bad "per-block: missing 'light' row (got: $multi_out)"
printf '%s\n' "$multi_out" | grep -qE "vibe::bench label=multi_bench\.vibe::heavy " \
  && ok "per-block: 'heavy' block reported separately" || bad "per-block: missing 'heavy' row (got: $multi_out)"
mlines="$(printf '%s\n' "$multi_out" | grep -cE '^vibe::bench ' || true)"
[ "${mlines:-0}" -eq 2 ] && ok "per-block: exactly 2 machine-readable rows for 2 blocks" \
  || bad "per-block: expected 2 vibe::bench rows, got $mlines (out: $multi_out)"

# 6. Guest CPU profiles are isolated per block and written in Firefox's
# processed-profile JSON format. Warmup happens before the profiler is armed.
profile_dir="$WORK/bench-profiles"
profile_out="$($VIBE bench "$proj/multi_bench.vibe" --iters 200 --warmup 20 \
  --guest-profile "$profile_dir" --interval-us 100 2>&1)"
profile_count="$(find "$profile_dir" -name '*.json' -type f | wc -l | tr -d ' ')"
[ "$profile_count" -eq 2 ] && ok "guest profile: one JSON file per bench block" \
  || bad "guest profile: expected 2 JSON files, got $profile_count ($profile_out)"
if find "$profile_dir" -name '*.json' -type f -exec grep -l '"threads"' {} \; | grep -q .; then
  ok "guest profile: Firefox processed-profile JSON written"
else
  bad "guest profile: no processed-profile JSON found"
fi

# Sanitized labels are not unique (`a/b` and `a?b` both become `a_b`), so the
# runner must append a stable discriminator instead of overwriting one profile.
cat > "$proj/colliding_profile_names.vibe" <<'EOF'
bench "a/b" { let _ = 1 + 1 }
bench "a?b" { let _ = 2 + 2 }
EOF
collision_dir="$WORK/colliding-profiles"
collision_out="$($VIBE bench "$proj/colliding_profile_names.vibe" --iters 2 --warmup 0 \
  --guest-profile "$collision_dir" --interval-us 100 2>&1)"
collision_count="$(find "$collision_dir" -name '*.json' -type f | wc -l | tr -d ' ')"
[ "$collision_count" -eq 2 ] && ok "guest profile: sanitized labels cannot overwrite each other" \
  || bad "guest profile: colliding labels produced $collision_count files ($collision_out)"

# A failure after warmup must still stop the sampler and flush its diagnostic
# profile. The shared Array is incremented once by warmup, then the first
# measured iteration traps.
cat > "$proj/trapping_profile_bench.vibe" <<'EOF'
let calls = [0]
bench "trap_measurement" with Exception {
  let next = calls[0] + 1
  Array::set(calls, 0, next)
  if next > 1 { throw("measurement boom") }
}
EOF
trap_bench_dir="$WORK/trapping-bench-profiles"
set +e
trap_bench_out="$($VIBE bench "$proj/trapping_profile_bench.vibe" --iters 1 --warmup 1 \
  --guest-profile "$trap_bench_dir" --interval-us 100 2>&1)"
trap_bench_status=$?
set -e
trap_bench_profile="$(find "$trap_bench_dir" -name '*.json' -type f | head -1)"
[ "$trap_bench_status" -ne 0 ] && [ -s "$trap_bench_profile" ] && grep -q '"threads"' "$trap_bench_profile" \
  && ok "guest profile: measured bench trap still flushes profile JSON" \
  || bad "guest profile: measured trap lost profile (status=$trap_bench_status, out=$trap_bench_out)"

# 7. The normal `vibe profile` surface produces a named guest profile.
cat > "$proj/profile.vibex" <<'EOF'
fn spin(n: Int) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < n { acc = acc + (i & 7); i = i + 1 }
  acc
}
fn main with () { let _ = spin(20000000) }
EOF
run_profile="$WORK/run-profile.json"
profile_run_out="$($VIBE profile "$proj/profile.vibex" --out "$run_profile" --interval-us 100 2>&1)"
[ -s "$run_profile" ] && grep -q '"threads"' "$run_profile" \
  && ok "vibe profile: normal run writes processed-profile JSON" \
  || bad "vibe profile: missing JSON ($profile_run_out)"
grep -q 'spin' "$run_profile" \
  && ok "vibe profile: Wasm name section resolves guest function" \
  || bad "vibe profile: named spin frame missing"

spaced_profile="$WORK/cpu profiles/run profile.json"
mkdir -p "$(dirname "$spaced_profile")"
spaced_profile_out="$($VIBE profile "$proj/profile.vibex" --out "$spaced_profile" --interval-us 100 2>&1)"
[ -s "$spaced_profile" ] && grep -q '"threads"' "$spaced_profile" \
  && ok "vibe profile: output paths containing whitespace stay one argument" \
  || bad "vibe profile: whitespace output path failed ($spaced_profile_out)"

# A guest failure must not discard the samples collected before the trap.
cat > "$proj/trap.vibex" <<'EOF'
fn work(n: Int) -> Int {
  let mut i = 0
  while i < n { i = i + 1 }
  i
}
fn main() -> Unit with Exception {
  let _ = work(20000000)
  throw("profiled boom")
}
EOF
trap_profile="$WORK/trap-profile.json"
set +e
trap_profile_out="$($VIBE profile "$proj/trap.vibex" --out "$trap_profile" --interval-us 100 2>&1)"
trap_profile_status=$?
set -e
[ "$trap_profile_status" -ne 0 ] && [ -s "$trap_profile" ] && grep -q '"threads"' "$trap_profile" \
  && ok "vibe profile: guest trap still flushes profile JSON" \
  || bad "vibe profile: trap did not flush JSON (status=$trap_profile_status, out=$trap_profile_out)"

# A normal precompiled image has no epoch checkpoints and must fail closed.
cwasm="$WORK/plain.cwasm"
"$RT" --precompile lib/@vibe/optimizer/__fixtures/empty.wasm -o "$cwasm"
set +e
cwasm_out="$(VIBE_GUEST_PROFILE="$WORK/invalid.json" "$RT" "$cwasm" 2>&1)"
cwasm_status=$?
set -e
[ "$cwasm_status" -ne 0 ] && printf '%s\n' "$cwasm_out" | grep -q 'fresh .wasm' \
  && ok "guest profile: ordinary .cwasm is rejected with guidance" \
  || bad "guest profile: .cwasm rejection missing (status=$cwasm_status, out=$cwasm_out)"

# 8. #1508: direct client `Http::*` calls in bench blocks use the compiled
# host-import path. The local echo server gives this an actual request/response
# round trip rather than merely proving that the source type-checks.
requested_http_echo_port="${VIBE_HTTP_ECHO_PORT:-0}"
http_echo_log="$WORK/http_echo.log"
python3 "$ROOT_DIR/tests/http_echo_server.py" "$requested_http_echo_port" >"$http_echo_log" 2>&1 &
HTTP_ECHO_PID=$!
http_echo_port=""
for _ in $(seq 1 50); do
  if ! kill -0 "$HTTP_ECHO_PID" 2>/dev/null; then
    break
  fi
  http_echo_port="$(sed -n 's/^HTTP echo server listening on 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$http_echo_log" | head -1)"
  [ -n "$http_echo_port" ] && break
  sleep 0.1
done
if [ -z "$http_echo_port" ] || ! kill -0 "$HTTP_ECHO_PID" 2>/dev/null; then
  bad "HTTP echo server failed to start (requested port $requested_http_echo_port)"
  cat "$http_echo_log" >&2 || true
else
  export VIBE_HTTP_ECHO_PORT="$http_echo_port"
  http_out="$("$VIBE" bench "$ROOT_DIR/bench/http_bench.vibe" --iters 5 --warmup 1 2>&1)"
  for label in http_get_hello http_post_echo_small http_post_echo_1kb http_get_headers; do
    printf '%s\n' "$http_out" | grep -qE "vibe::bench label=http_bench\\.vibe::$label iters=5 " \
      && ok "HTTP bench: $label completed through local echo server" \
      || bad "HTTP bench: missing $label result (got: $http_out)"
  done
  hlines="$(printf '%s\n' "$http_out" | grep -cE '^vibe::bench ' || true)"
  [ "${hlines:-0}" -eq 4 ] && ok "HTTP bench: exactly 4 client benchmark rows" \
    || bad "HTTP bench: expected 4 vibe::bench rows, got $hlines (out: $http_out)"
fi

echo "[test_vibe_bench] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
