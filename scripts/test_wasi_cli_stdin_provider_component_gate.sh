#!/usr/bin/env bash
# #1539: generated, production-unused stdin provider shadow component gate.
# Structural checks always cover the exact nominal import prefix, synchronous
# memory-bearing read-via-stream lower, private adapter/scenario surface, and
# component WIT. Wasmtime 47.0.2 additionally runs drain/early-close and the
# expected-trap controls when its ratified stdin provider is available. The
# forced completion tag and byte-mismatch controls exercise cleanup/fail-closed
# code; they do not measure provider-generated errors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
# Keep this fixed because the generated Vibe harness writes the same path.
# There is intentionally no OUT_DIR override with a divergent guest target.
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_cli_stdin_provider_shadow"
mkdir -p "$OUT_DIR"

require_or_skip_runtime() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "wasi cli stdin provider shadow FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "[wasi-cli-stdin-provider-shadow] runtime SKIP: $what"
  echo "wasi cli stdin provider shadow structural gate OK"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || {
  echo "wasi cli stdin provider shadow FAILED: wasm-tools is required for generated structural validation" >&2
  exit 1
}

COMPILER="${VIBE_STDIN_PROVIDER_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  shopt -s nullglob
  for candidate in "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm; do
    if [ -z "$COMPILER" ] || [ "$candidate" -nt "$COMPILER" ]; then
      COMPILER="$candidate"
    fi
  done
  shopt -u nullglob
  # The CI job that runs this gate (wasi-p3-gate) builds nothing itself: it
  # downloads compiler-gate's stage2 into _build/ci-artifacts/ and never runs
  # ensure_seed.sh, so it has NEITHER a generations tree nor a seed. Without
  # this candidate the search fell through to the seed path, and a path that
  # does not exist reached the runner as an argument -- surfacing as an ENOENT
  # stack trace plus a spurious `usage:` line (the runner prints usage for any
  # pre-instantiation failure), which reads as a broken invocation rather than
  # a missing compiler.
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/_build/ci-artifacts/stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
if [ ! -f "$COMPILER" ]; then
  echo "wasi cli stdin provider shadow FAILED: no compiler to generate the shadow component with." >&2
  echo "  looked for: _build/selfhost/generations/*/stage2.wasm, _build/ci-artifacts/stage2.wasm, bootstrap/seed/compiler.wasm" >&2
  echo "  set VIBE_STDIN_PROVIDER_GATE_COMPILER=<stage2.wasm> to point at one." >&2
  exit 1
fi
HARNESS="$OUT_DIR/dump.vibex"
HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
PRINTED="$OUT_DIR/generated.wat"
WIT="$OUT_DIR/generated.wit"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_stdin_provider_shadow
}

fn main() -> Unit with Exception + Fs {
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_shadow/generated.component.wasm", comp_emit_component_wasm_stdin_provider_shadow())
}
EOF
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"
# The CLI writes compile diagnostics to a `<output>.diag` SIDECAR, not to
# stdout/stderr (#1567), so a failed compile here exits non-zero having printed
# nothing at all -- under `set -e` that surfaced as a bare
# "Process completed with exit code 1" with no cause anywhere in the CI log.
# Echo the sidecar before giving up.
if ! VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null; then
  echo "wasi cli stdin provider shadow FAILED: could not compile the generator harness with $COMPILER" >&2
  if [ -s "$HARNESS_WASM.diag" ]; then
    # The sidecar has no trailing newline, so give it one rather than letting
    # it run into whatever the log prints next.
    cat "$HARNESS_WASM.diag" >&2
    echo >&2
  else
    echo "  (no .diag sidecar was written)" >&2
  fi
  exit 1
fi
VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null

wasm-tools validate --features all "$COMPONENT"
wasm-tools print "$COMPONENT" >"$PRINTED"
wasm-tools component wit "$COMPONENT" >"$WIT"

# #1620's independently-derived 208-byte golden, now a shared exact prefix.
PREFIX_SHA="$(dd if="$COMPONENT" bs=1 count=208 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[ "$PREFIX_SHA" = "9e0ecf27d3a3e5515f503f3fc0867e0ae5e02164adc32f279f9e6b1efd921c5e" ] || {
  echo "wasi cli stdin provider shadow FAILED: exact nominal import prefix drifted ($PREFIX_SHA)" >&2
  exit 1
}
grep -Fq 'import wasi:cli/types@0.3.0;' "$WIT"
grep -Fq 'import wasi:cli/stdin@0.3.0;' "$WIT"
grep -Fq 'read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;' "$WIT"
grep -Fq '(core func (;0;) (canon lower (func 0) (memory 0)))' "$PRINTED"
grep -Fq 'canon stream.read 3 async (memory 0)' "$PRINTED"
grep -Fq 'canon future.read 5 async (memory 0)' "$PRINTED"
grep -Fq 'stdin-provider-shadow-acquire' "$PRINTED"
grep -Fq 'stdin-provider-shadow-settle' "$PRINTED"
grep -Fq 'forced-completion-tag-control' "$PRINTED"
grep -Fq 'foreign-provider-control' "$PRINTED"
grep -Fq 'wrong-byte-cleanup-control' "$PRINTED"
grep -Fq 'extra-byte-cleanup-control' "$PRINTED"
# The dollar sign is part of the literal canonical import name.
# shellcheck disable=SC2016
if grep -Fq 'host_stream_get$stdin' "$PRINTED" || grep -Fq 'host_stream_close' "$PRINTED"; then
  echo "wasi cli stdin provider shadow FAILED: generic HostStream machinery leaked into shadow" >&2
  exit 1
fi
# Both BLOCKED branches encode join(handle,set), wait, join(handle,0), set.drop.
[ "$(grep -c 'call 6' "$PRINTED")" -ge 4 ]
[ "$(grep -c 'call 8' "$PRINTED")" -eq 2 ]
# Scenario mismatch traps must be immediately preceded by close(id) and its
# result local.set. These fixed indices are part of this byte-level shadow gate.
check_cleanup_before_traps() {
  local func_idx="$1" expected_traps="$2"
  local body="$OUT_DIR/func-$func_idx.wat"
  sed -n "/    (func (;$func_idx;) (type 6)/,/^    )/p" "$PRINTED" >"$body"
  awk -v expected="$expected_traps" '
    /^        call 20$/ { close_line = NR }
    /^        unreachable$/ {
      traps += 1
      if (close_line != NR - 2) bad = 1
    }
    END { exit !(traps == expected && bad != 1) }
  ' "$body"
}
check_cleanup_before_traps 21 5 # drain wrong-byte + extra-byte diagnostics
check_cleanup_before_traps 22 1 # post-close scenario diagnostic
check_cleanup_before_traps 25 1 # wrong-byte cleanup control
check_cleanup_before_traps 26 3 # extra-byte cleanup control and prefix guards
echo "[wasi-cli-stdin-provider-shadow] generated component validate/WIT/prefix/structure OK"

WASMTIME_BIN="${WASMTIME_BIN:-$(command -v wasmtime || true)}"
[ -n "$WASMTIME_BIN" ] || require_or_skip_runtime "wasmtime not installed"
WASMTIME_VERSION="$("$WASMTIME_BIN" --version 2>/dev/null || true)"
case "$WASMTIME_VERSION" in
  "wasmtime 47.0.2"\ *) ;;
  *) require_or_skip_runtime "requires wasmtime 47.0.2, got ${WASMTIME_VERSION:-unavailable}" ;;
esac

INPUT="$OUT_DIR/stdin-10-15-17.bin"
printf '\012\017\021' >"$INPUT"
FLAGS=(-Sp3 -W component-model-async=y -W component-model-async-stackful=y -W component-model-more-async-builtins=y)
run_success() {
  local lane="$1" expected="$2"
  local log="$OUT_DIR/run.$lane.log"
  if ! timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke "$lane()" "$COMPONENT" <"$INPUT" >"$log" 2>&1; then
    if grep -Eq 'component imports instance .wasi:cli/stdin@0\.3\.0., but a matching implementation was not found in (the )?linker' "$log"; then
      require_or_skip_runtime "wasmtime has no matching wasi:cli/stdin@0.3.0 implementation"
    fi
    cat "$log" >&2
    echo "wasi cli stdin provider shadow FAILED: $lane did not exit 0" >&2
    exit 1
  fi
  [ "$(cat "$log")" = "$expected" ] || {
    echo "wasi cli stdin provider shadow FAILED: $lane expected $expected, got $(cat "$log")" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-shadow] $lane: $expected"
}
run_trap() {
  local lane="$1"
  local log="$OUT_DIR/run.$lane.log"
  if timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke "$lane()" "$COMPONENT" <"$INPUT" >"$log" 2>&1; then
    echo "wasi cli stdin provider shadow FAILED: $lane unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Eqi 'unreachable|wasm trap' "$log" || {
    echo "wasi cli stdin provider shadow FAILED: $lane failed without the expected trap" >&2
    cat "$log" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-shadow] $lane: expected trap"
}

run_success drain 42
run_success early-close 43
run_trap forced-completion-tag-control
run_trap foreign-provider-control
run_trap wrong-byte-cleanup-control
run_trap extra-byte-cleanup-control

echo "wasi cli stdin provider shadow component gate OK (wasmtime 47.0.2)"
