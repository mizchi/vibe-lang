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
bash scripts/install.sh --cli-wasm "$cli" >/dev/null 2>&1
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

# 6. #1508: direct client `Http::*` calls in bench blocks use the compiled
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
