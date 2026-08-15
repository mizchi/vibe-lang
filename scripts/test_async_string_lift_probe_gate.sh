#!/usr/bin/env bash
set -euo pipefail

# #1540 follow-up probe gate: the canonical-option set for an ASYNC lift whose
# params and result are STRINGS.
#
# tools/wasip3_component_probe/async_string_lift/component.wat carries the full
# rationale and the measured byte encodings. This gate is what keeps them true:
# it is the byte-level pin the README of the http_body_stream probe asks for
# before `emit_canon_lift_async_section` / `emit_canon_task_return` are
# generalized.
#
# Asserts, in order:
#   1. the component parses and validates;
#   2. `task.return` carries exactly Memory + UTF8 -- and NOT realloc, which
#      wasmtime rejects outright;
#   3. the async lift carries Async + Memory + Realloc + UTF8;
#   4. the RAW BYTES of both match what the probe documents;
#   5. it RUNS: `greet("bob")` returns "hi", so the string really round-trips
#      through task.return rather than merely type-checking.
#
# 4 is not redundant with 2-3, and is the assertion this gate exists for. The
# decoded options come from `wasm-tools dump`'s AST: they pin the SEMANTICS, not
# the ENCODING. A wasm-tools change to an opcode or index encoding -- or an edit
# to the probe that moves a core-func/type index -- would leave 2, 3 and 5 green
# while the byte sequences the emitter is supposed to be built against went
# stale. Keeping both means a failure says which layer moved: 2-3 name the
# option that changed, 4 catches a re-encoding of options that did not.
#
# Skips cleanly when wasm-tools / wasmtime are unavailable, and fails instead
# under VIBE_P3_GATE_REQUIRE_TOOLS=1, matching the other P3 probes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROBE="$PROJECT_ROOT/tools/wasip3_component_probe/async_string_lift/component.wat"
OUT_DIR="$PROJECT_ROOT/_build/bench/async_string_lift_probe/run-$$"

if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[async-string-lift] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[async-string-lift] SKIP: $1 not found"; exit 0
}
command -v wasm-tools >/dev/null 2>&1 || missing_tool "wasm-tools"
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  missing_tool "wasmtime"
fi

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
trap 'rm -rf "$OUT_DIR"' EXIT
WASM="$OUT_DIR/component.wasm"

wasm-tools parse "$PROBE" -o "$WASM"
wasm-tools validate --features all "$WASM"
echo "[async-string-lift] parses and validates"

DUMP="$(wasm-tools dump "$WASM" 2>/dev/null)"

# 2. task.return's option set. `realloc` here is a hard wasmtime error, so its
#    ABSENCE is as load-bearing as the two that are present.
if ! printf '%s' "$DUMP" | grep -qF 'TaskReturn { result: Some(Primitive(String)), options: [Memory(0), UTF8] }'; then
  echo "[async-string-lift] FAILED: task.return's option set changed (want [Memory(0), UTF8], and never Realloc)" >&2
  printf '%s\n' "$DUMP" | grep -i "taskreturn" >&2 || true
  exit 1
fi
echo "[async-string-lift] task.return: [Memory(0), UTF8], no realloc"

# 3. the async lift's option set -- all four, which is what the emitter must
#    learn to produce.
if ! printf '%s' "$DUMP" | grep -qF 'options: [Async, Memory(0), Realloc(0), UTF8]'; then
  echo "[async-string-lift] FAILED: the async lift's option set changed (want [Async, Memory(0), Realloc(0), UTF8])" >&2
  printf '%s\n' "$DUMP" | grep -i "lift" >&2 || true
  exit 1
fi
echo "[async-string-lift] async lift: [Async, Memory(0), Realloc(0), UTF8]"

# 4. the raw bytes. Byte-aligned by construction (od emits one hex pair per
#    byte), and asserted to occur EXACTLY once so a coincidental match
#    elsewhere in the module cannot satisfy it.
BYTES="$(od -An -tx1 -v "$WASM" | tr -s ' \n' ' ')"
expect_bytes() {
  local what="$1" seq="$2" n
  # `|| true`: grep exits 1 on no match, and under `set -euo pipefail` that
  # would kill the script AT THE ASSIGNMENT -- a non-zero exit with no
  # diagnostic, which is the one failure mode this gate must never have.
  n="$(printf '%s' "$BYTES" | grep -o " $seq " | wc -l | tr -d ' ' || true)"
  [ -n "$n" ] || n=0
  if [ "$n" != "1" ]; then
    echo "[async-string-lift] FAILED: $what byte sequence occurs $n times, want exactly 1" >&2
    echo "[async-string-lift]   expected: $seq" >&2
    echo "[async-string-lift]   the probe's documented encoding is stale, or the module moved an index" >&2
    exit 1
  fi
}
expect_bytes "task.return"       "09 00 73 02 03 00 00"
expect_bytes "async lift"        "00 00 02 04 06 03 00 04 00 00 00"
echo "[async-string-lift] raw bytes match the documented encoding"

# 5. and it actually runs -- validation is not execution, and a string that
#    never leaves guest memory would still validate.
OUT="$("$WASMTIME_BIN" run "${WASM_FLAGS[@]}" --invoke 'greet("bob")' "$WASM" 2>&1 || true)"
if ! printf '%s' "$OUT" | grep -qF '"hi"'; then
  echo "[async-string-lift] FAILED: greet(\"bob\") returned '$OUT' (want \"hi\")" >&2
  exit 1
fi
echo "[async-string-lift] greet(\"bob\") -> \"hi\" (the string round-trips through task.return)"
echo "[async-string-lift] PASS: async lift + string task.return option set pinned (#1540)"
