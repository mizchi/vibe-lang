#!/usr/bin/env bash
# #1696: the exported entry's observable result must not depend on VIBE_RC.
#
# Under RC an Int is `value << 1`, and the entry function's result is untagged
# so the host sees the real number. That untag was emitted AFTER the body, which
# `return` branches straight past -- so `return 777` handed the host 1554 while
# the same value in tail position was correct. Silently wrong, and no gate saw
# it: compiler_gate.sh pins `VIBE_RC=0` (a deliberate cutover pin), so the RC
# lane only runs when something asks for it explicitly. This is that something.
#
# The property asserted is deliberately not "777 comes back" but "RC=0 and RC=1
# agree". That is what makes it a parity gate rather than a table of constants
# to update whenever the fixtures change.
#
#   bash scripts/test_rc_entry_result_parity.sh [stage2.wasm]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI_WASM="${1:-${VIBE_RC_ENTRY_PARITY_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$CLI_WASM" ] && [ -s "$CLI_WASM" ] || {
  echo "[rc-entry-parity] FAIL: pass a stage2.wasm or build a selfhost generation" >&2
  exit 1
}

WORK="$(mktemp -d "$ROOT_DIR/_build/rc_entry_parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

entry_result() {
  local rc="$1" src="$2" out="$WORK/case_rc$1.wasm"
  local out_rel="${out#"$ROOT_DIR"/}"
  rm -f "$out"
  VIBE_RC="$rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$src" "$out_rel" _start >/dev/null 2>&1
  [ -s "$out" ] || { echo "COMPILE-FAIL"; return; }
  VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$out" 2>/dev/null | tail -1
}

assert_rc_parity() {
  local label="$1" program="$2"
  local src="$WORK/case.vibe"
  printf '%s' "$program" > "$src"
  local off on
  off="$(entry_result 0 "$src")"
  on="$(entry_result 1 "$src")"
  if [ "$off" = "COMPILE-FAIL" ] || [ "$on" = "COMPILE-FAIL" ]; then
    echo "[rc-entry-parity] FAIL: $label did not compile (RC=0:$off RC=1:$on)" >&2
    exit 1
  fi
  if [ "$off" != "$on" ]; then
    echo "[rc-entry-parity] FAIL: $label -- RC=0 gave '$off' but RC=1 gave '$on'" >&2
    exit 1
  fi
  echo "[rc-entry-parity] ok: $label (both lanes: $off)"
}

# The baseline: tail position was always correct, so a mismatch here means the
# untag itself broke rather than the `return` path.
assert_rc_parity "entry tail value" 'let _start = () -> Int {
  777
}
'

assert_rc_parity "entry return" 'let _start = () -> Int {
  return 777
}
'

assert_rc_parity "entry early return in statement position" 'let _start = () -> Int {
  let x = 1
  if true {
    return 777
  } else {
    ()
  }
  x
}
'

# An inner function is not the entry, so its `return` must NOT be untagged --
# its result is an ordinary tagged value the caller keeps computing with. This
# is the case that fails if the untag is applied too widely.
assert_rc_parity "inner fn return feeding entry arithmetic" 'fn inner(n: Int) -> Int {
  if n > 0 {
    return 7
  } else {
    ()
  }
  0
}

let _start = () -> Int {
  inner(1) + 100
}
'

# Same trap, one level further in: a lambda compiles to its own wasm function
# with its own context, so it must not inherit the entry untag either.
assert_rc_parity "lambda return feeding entry arithmetic" 'let _start = () -> Int {
  let f = (n) -> {
    if n > 0 {
      return 5
    } else {
      ()
    }
    0
  }
  f(1) + 700
}
'

echo "[rc-entry-parity] ok: the entry result does not depend on VIBE_RC"
