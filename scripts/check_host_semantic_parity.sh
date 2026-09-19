#!/usr/bin/env bash
# #1346: the two host runners must agree about what a capability call MEANS,
# not merely that both provide a function by that name.
#
# `check_host_runtime_contract.py` compares NAMES and, since the viberun
# signature check, TYPES. Neither says anything about behaviour: two providers
# can share a name and a signature and still disagree about what happens when
# the file is missing, or how many bytes a multibyte string is. That class of
# bug is what `check_host_remove_parity.sh` caught for `Fs::remove`, where one
# runner deleted a tree and the other refused. This gate is the same shape for
# the rows #1346 lists as "semantic conformance fixtures".
#
# Three programs, each compiled ONCE and run under BOTH runners:
#
#   missing   Fs::read_file on a path that does not exist -> FAILS under both
#   empty     Fs::read_file on an empty file              -> length 0 under both
#   multibyte Fs::read_file on `日本語ですよ`              -> length 18 under both
#
# The third is the one worth having. 6 codepoints, 18 bytes: ADR-0098 makes a
# String a BYTE string, and this asserts that both hosts agree about it rather
# than only the compiler. A provider that returned a codepoint count would pass
# every name and signature check in the tree.
#
# The observation is the pair (exit-ok, last stdout line), NOT a per-runner
# verdict, so the runners are compared on what they SAW rather than on whether
# each independently liked it.
#
# PIPEFAIL IS LOAD-BEARING. `out="$(runner | tail -1)"` reports TAIL's status,
# so without it the failing probe reads as a success and this gate passes
# vacuously -- measured while writing it: all three probes reported rc=0,
# including the one whose whole point is to fail.
#
# WHICH COMPILER: passed in, never guessed (AGENTS.md "Which compiler answered?").
# WHICH RUNNERS: both required. The subject is the two disagreeing, so a missing
# runner is UNCHECKED rather than "safe" -- it fails and says how to fix it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# resolve_stage2.sh defines a FUNCTION; it is sourced, not executed.
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 host-semantic-parity "${HOST_SEMANTIC_PARITY_STAGE2:-${VIBE_STAGE2_WASM:-}}")"
if [ ! -f "$STAGE2" ]; then
  echo "host-semantic-parity: FAIL: no stage2. Pass HOST_SEMANTIC_PARITY_STAGE2=<stage2.wasm>." >&2
  exit 1
fi

if [ -z "${HOST_SEMANTIC_PARITY_VIBERUN:-}" ]; then
  if ! bash "$ROOT_DIR/scripts/ensure_viberun.sh" >&2; then
    echo "host-semantic-parity: FAIL: could not build runtime/viberun." >&2
    echo "host-semantic-parity: this gate compares the TWO host runners, so one runner cannot answer it." >&2
    exit 1
  fi
fi
VIBERUN="${HOST_SEMANTIC_PARITY_VIBERUN:-runtime/viberun/target/release/viberun}"
if [ ! -x "$VIBERUN" ]; then
  echo "host-semantic-parity: FAIL: the Rust runner is missing at '$VIBERUN'." >&2
  echo "host-semantic-parity: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
  exit 1
fi

WORK="${HOST_SEMANTIC_PARITY_WORK:-_build/_gate_host_semantic_parity}"
rm -rf "$WORK"; mkdir -p "$WORK"

printf '' > "$WORK/empty.txt"
printf '日本語ですよ' > "$WORK/multi.txt"

emit_probe() { # <name> <body-expr>
  cat > "$WORK/$1.vibe" <<VIBE
export let main = () -> Int with Fs {
$2
}
VIBE
}

emit_probe missing   '  String::length(Fs::read_file("'"$WORK"'/does_not_exist.txt"))'
emit_probe empty     '  String::length(Fs::read_file("'"$WORK"'/empty.txt"))'
emit_probe multibyte '  String::length(Fs::read_file("'"$WORK"'/multi.txt"))'

PROBES="missing empty multibyte"

for probe in $PROBES; do
  env -u VIBE_FS_COMPILE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/$probe.vibe" "$WORK/$probe.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$WORK/$probe.wasm" ]; then
    echo "host-semantic-parity: FAIL: '$probe' did not compile with $STAGE2." >&2
    cat "$WORK/$probe.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# <runner-label> <probe> -> "<ok|failed>:<stdout-tail>"
observe() {
  local label="$1" probe="$2" rc=0 out=""
  case "$label" in
    js)
      if [ -n "${HOST_SEMANTIC_PARITY_JS_RUNNER:-}" ]; then
        # Self-test hook only: run a MUTATED copy of the JS runner, so the red
        # test can prove this gate detects a real divergence.
        out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" node --experimental-wasm-exnref --stack-size=131072 \
          "$HOST_SEMANTIC_PARITY_JS_RUNNER" "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$?
      else
        out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$?
      fi
      ;;
    rust) out="$("$VIBERUN" "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$? ;;
  esac
  local ok="ok"; [ "$rc" -eq 0 ] || ok="failed"
  printf '%s:%s' "$ok" "$out"
}

fail=0
for probe in $PROBES; do
  js="$(observe js "$probe")"
  rust="$(observe rust "$probe")"
  if [ "$js" != "$rust" ]; then
    echo "host-semantic-parity: FAIL: '$probe' -- node saw [$js], viberun saw [$rust]" >&2
    fail=1
  else
    echo "host-semantic-parity: ok: $probe -> both runners saw [$js]"
  fi
done

# The VALUE, not only agreement. Agreement alone passes when BOTH runners break
# the same way -- the point fixtures/gc_host_builtins.vibe makes for the
# linear-vs-gc pair, and it applies just as much here.
multi="$(observe rust multibyte)"
if [ "$multi" != "ok:18" ]; then
  echo "host-semantic-parity: FAIL: 日本語ですよ must be 18 BYTES (ADR-0098), got [$multi]" >&2
  fail=1
else
  echo "host-semantic-parity: ok: the multibyte read is 18 bytes, not 6 codepoints (ADR-0098)"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
rm -rf "$WORK"
echo "host-semantic-parity: ok (3 probes agree across both runners; byte-length pinned)"
