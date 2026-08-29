#!/usr/bin/env bash
# Smoke test for selfhost `vibe run` (scripts/vibe_run.sh): compile + execute a
# single-file and a multi-file program via the seed, asserting their results.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_run_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK" "$ROOT_DIR/_build/vibe_run"' EXIT

# single-file executable root
printf 'fn main with Stdout {\n  let xs = [1, 2, 3, 4]\n  let total = Array::fold(xs, 0, _ + _)\n  Stdout::write_stream("\\{total}\\n")\n}\n' > "$WORK/prog.vibex"
out="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/prog.vibex" | tr -dc '0-9\n' | grep -E '.' | head -1)"
if [ "$out" != "10" ]; then
  echo "[vibe-run-smoke] FAIL single-file: expected 10, got '$out'" >&2; exit 1
fi

# multi-file (FS import resolution)
printf 'export let dbl = (x: Int) -> Int { x * 2 }\n' > "$WORK/lib.vibe"
printf 'import ./lib.vibe { dbl }\nfn main with Stdout { Stdout::write_stream("\\{dbl(21)}\\n") }\n' > "$WORK/m2.vibex"
out2="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/m2.vibex" | tr -dc '0-9\n' | grep -E '.' | head -1)"
if [ "$out2" != "42" ]; then
  echo "[vibe-run-smoke] FAIL multi-file: expected 42, got '$out2'" >&2; exit 1
fi

# A library/module source is never accepted by the executable launcher.
printf 'let main = () -> Int { 0 }\n' > "$WORK/legacy.vibe"
legacy_err="$WORK/legacy.err"
if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/legacy.vibe" > /dev/null 2> "$legacy_err"; then
  echo "[vibe-run-smoke] FAIL: .vibe executable was accepted" >&2; exit 1
fi
grep -q "vibe run requires a .vibex executable root" "$legacy_err" || {
  echo "[vibe-run-smoke] FAIL: missing .vibe rejection diagnostic" >&2; exit 1
}

# The user-visible entry is fixed; arbitrary positional entries are not ABI.
entry_err="$WORK/entry.err"
if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/prog.vibex" alternate > /dev/null 2> "$entry_err"; then
  echo "[vibe-run-smoke] FAIL: custom .vibex entry was accepted" >&2; exit 1
fi
grep -q ".vibex entry is always main" "$entry_err" || {
  echo "[vibe-run-smoke] FAIL: missing custom-entry rejection diagnostic" >&2; exit 1
}

# #2361: a program that does not compile must say WHY on stderr. The compile
# step's reason lives in the `<output>.diag` sidecar, and the wrapper used to
# send its stdout to /dev/null and exit 1 having printed nothing -- "the file is
# broken", "the wrapper does not support this" and "the toolchain is not built"
# were indistinguishable from the output.
#
# Two shapes, because they are produced by different parts of the compiler and
# a wrapper can lose one while relaying the other.
check_explains() { # <label> <source text> <expected substring>
  local label="$1" src="$2" needle="$3" err="$WORK/$1.err"
  printf '%s' "$src" > "$WORK/$label.vibex"
  if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/$label.vibex" > /dev/null 2> "$err"; then
    echo "[vibe-run-smoke] FAIL $label: a program that does not compile exited 0" >&2; exit 1
  fi
  grep -q "$needle" "$err" || {
    echo "[vibe-run-smoke] FAIL $label: the failure was not explained on stderr (#2361)" >&2
    echo "    expected substring: $needle" >&2
    echo "    stderr was:" >&2
    sed 's/^/      /' "$err" >&2
    exit 1
  }
}

# A checker diagnostic.
check_explains missing_effect_row \
  'fn main() -> Unit {
  println("hi")
}
' \
  "requires an explicit effect row"

# A parse error, which is reported by an earlier phase.
check_explains parse_error \
  'fn main() -> Unit with () {
  let x = (
}
' \
  "unexpected token"

# A diagnostic with a `hint:` continuation is ONE diagnostic. `runtime/vibe` and
# `format_check_report` both frame it that way so `grep -c '^error: '` is an
# exact count; prefixing every relayed line would make this program look like
# two errors.
printf 'fn helper() -> Unit with () {\n  println("hi")\n}\nfn main() -> Unit with Stdout {\n  helper()\n}\n' > "$WORK/hint_shape.vibex"
hint_err="$WORK/hint_shape.err"
if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/hint_shape.vibex" > /dev/null 2> "$hint_err"; then
  echo "[vibe-run-smoke] FAIL hint_shape: a program that does not compile exited 0" >&2; exit 1
fi
starts="$(grep -c '^error: ' "$hint_err" || true)"
hints="$(grep -c '^  hint: ' "$hint_err" || true)"
if [ "$starts" != "1" ] || [ "$hints" != "1" ]; then
  echo "[vibe-run-smoke] FAIL hint_shape: expected 1 diagnostic start and 1 indented hint, got $starts and $hints (#2361)" >&2
  sed 's/^/      /' "$hint_err" >&2
  exit 1
fi

echo "[vibe-run-smoke] ok (single=10, multi-file=42, compile failures explained)"
