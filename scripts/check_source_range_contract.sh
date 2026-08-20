#!/usr/bin/env bash
# docs/source-range-contract.md, enforced.
#
# Six editor-query surfaces report positions and they have to agree on the
# unit: byte offsets, 0-based half-open; byte columns, 1-based; with the LSP
# boundary (`--json`, `vibe lsp`) the one place that converts to 0-based line +
# UTF-16 code units. ADR-0108 decided that; the document wrote it down; nothing
# checked it.
#
# The failure this exists for is SILENT. `vibe type-at` handed a codepoint or
# UTF-16 column does not error -- it answers about an earlier position, and
# empty output is the CLI's own spelling of "clean". A surface that quietly
# switched units would look like a file with nothing in it.
#
# So every assertion below runs against a source with two 4-byte emoji to the
# LEFT of the position under test, where byte / codepoint / UTF-16 columns are
# three different numbers. On a pure-ASCII fixture all three agree and the
# check proves nothing.
#
# Environment:
#   RANGE_STAGE2   compiler wasm (default: newest _build/selfhost generation,
#                  else bootstrap/seed/compiler.wasm). A path that does not
#                  exist is an ERROR, never a silent fallback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ranges.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fails=0

note() { printf 'source-range-contract: ok: %s\n' "$1"; }
bad() { printf 'source-range-contract: FAIL: %s\n' "$1" >&2; fails=1; }

# `\xf0\x9f\x8e\x89` is U+1F389: 4 bytes, 1 codepoint, 2 UTF-16 units. Two of
# them sit on line 3 before `n`, so that identifier is at byte column 40,
# codepoint column 34, and UTF-16 column 36. One position, three numbers.
E=$'\xf0\x9f\x8e\x89'
printf 'fn main() -> Unit {\n  let n = 1\n  let m = String::length("%s%s") + n\n  let _ = m\n}\n' "$E" "$E" > "$WORK/ok.vibe"
printf 'fn main() -> Unit {\n  let n = 1\n  let m = String::length("%s%s") + quux\n  let _ = m\n}\n' "$E" "$E" > "$WORK/bad.vibe"

# Derived, not hand-copied: if the fixture above is edited, these follow.
read -r BYTE_COL CP_COL N_OFF <<<"$(python3 - "$WORK/ok.vibe" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
lines = b.split(b'\n')
line3 = lines[2]
i = line3.rfind(b'n')                      # the trailing `+ n`
print(i + 1, len(line3[:i].decode()) + 1, len(lines[0]) + 1 + len(lines[1]) + 1 + i)
PY
)"
[ "$BYTE_COL" != "$CP_COL" ] || { echo "source-range-contract: the fixture does not separate byte from codepoint columns -- every assertion below would be vacuous" >&2; exit 1; }

# The compiler is resolved only after the fixture proves it can distinguish the
# three units -- a vacuous fixture is a defect in this check, and finding a
# compiler first would report it as a compiler problem.
STAGE2="${RANGE_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -s "$STAGE2" ] || { echo "source-range-contract: RANGE_STAGE2 does not exist: $STAGE2" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "$STAGE2" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "source-range-contract: no compiler available" >&2; exit 1; }
fi

run() { # run <file> <out-name> <env>...
  local f="$1" out="$2"; shift 2
  rm -f "$WORK/$out" "$WORK/$out.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$f" "$WORK/$out" >/dev/null 2>&1 || true
  cat "$WORK/$out" 2>/dev/null || true
}

# 1. `vibe symbols` -- NAME KIND START END, byte offsets. `main` starts at byte
#    3, which is also its codepoint offset (nothing multi-byte precedes it), so
#    this case alone cannot catch a unit switch -- it is here because the rest
#    of the outline check depends on the shape being right.
syms="$(run "$WORK/ok.vibe" syms VIBE_SYMBOLS=1)"
if [ "$syms" = "main 12 3 7" ]; then
  note "vibe symbols reports NAME KIND START END"
else
  bad "vibe symbols: got [$syms], want [main 12 3 7]"
fi

# 2. `vibe binding-at` -- BYTE column in, BYTE offsets out. This is the load
#    bearing one: the identifier sits behind 8 bytes of emoji.
# `sed '$!s/$/|/' | tr -d '\n'` joins the records with `|` WITHOUT inventing a
# trailing one. Plain `tr '\n' '|'` appended an empty field once the queries
# started terminating their last record (#2133) -- record separators and record
# terminators are not the same thing, which is the whole point of that fix.
occ="$(run "$WORK/ok.vibe" occ VIBE_BINDING_AT=1 VIBE_TYPE_LINE=3 VIBE_TYPE_COL="$BYTE_COL" | sed '$!s/$/|/' | tr -d '\n')"
if [ "$occ" = "26 27|$N_OFF $((N_OFF + 1))" ]; then
  note "vibe binding-at takes a byte column and answers in byte offsets"
else
  bad "vibe binding-at at byte col $BYTE_COL: got [$occ], want [26 27|$N_OFF $((N_OFF + 1))]"
fi

# 3. ...and the CODEPOINT column answers about a different position, without
#    erroring. This is the documented hazard, pinned so that a surface which
#    silently starts accepting codepoint columns is caught -- it would make
#    this case start succeeding.
occ_cp="$(run "$WORK/ok.vibe" occcp VIBE_BINDING_AT=1 VIBE_TYPE_LINE=3 VIBE_TYPE_COL="$CP_COL")"
if [ -z "$occ_cp" ]; then
  note "a codepoint column finds nothing (the silent failure the contract warns about)"
else
  bad "vibe binding-at at codepoint col $CP_COL returned [$occ_cp]; the contract says input columns are BYTES, so this must not resolve"
fi

# 4. `vibe type-at` -- same input convention.
ty="$(run "$WORK/ok.vibe" ty VIBE_TYPE_AT=1 VIBE_TYPE_LINE=3 VIBE_TYPE_COL="$BYTE_COL")"
ty_cp="$(run "$WORK/ok.vibe" tycp VIBE_TYPE_AT=1 VIBE_TYPE_LINE=3 VIBE_TYPE_COL="$CP_COL")"
if [ "$ty" = "Int" ] && [ -z "$ty_cp" ]; then
  note "vibe type-at takes a byte column"
else
  bad "vibe type-at: byte col gave [$ty] (want Int), codepoint col gave [$ty_cp] (want empty)"
fi

# 5. `vibe escapes` -- NAME START END, byte offsets, on a source whose `let mut`
#    sits behind multi-byte text.
printf 'fn main() -> Int {\n  let s = "%s%s"\n  let mut acc = String::length(s)\n  let bump = () -> Unit { acc = acc + 1 }\n  bump()\n  acc\n}\n' "$E" "$E" > "$WORK/esc.vibe"
esc_off="$(python3 - "$WORK/esc.vibe" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(b.find(b'acc'))
PY
)"
esc="$(run "$WORK/esc.vibe" esc VIBE_ESCAPES=1)"
if [ "$esc" = "acc $esc_off $((esc_off + 3))" ]; then
  note "vibe escapes reports byte offsets"
else
  bad "vibe escapes: got [$esc], want [acc $esc_off $((esc_off + 3))]"
fi

# 6. `vibe check` text -- `line L:C-E:` with a 1-based BYTE column.
chk="$(run "$WORK/bad.vibe" chk VIBE_CHECK_ONLY=1; cat "$WORK/chk.diag" 2>/dev/null || true)"
if grep -qF "line 3:$BYTE_COL-$((BYTE_COL + 4)): unknown name: quux" <<<"$chk"; then
  note "vibe check reports a 1-based byte column"
else
  bad "vibe check: got [$chk], want a 'line 3:$BYTE_COL-$((BYTE_COL + 4))' prefix"
fi

# 7. The one deliberate exception. The LSP JSON boundary converts to 0-based
#    lines and UTF-16 columns -- a DIFFERENT number for the same position, and
#    it has to keep being different. Two emoji are 8 bytes and 4 UTF-16 units,
#    so the UTF-16 column is the 0-based byte column minus 4.
json="$(run "$WORK/bad.vibe" json VIBE_DIAGNOSTICS=1 VIBE_DIAGNOSTICS_JSON=1)"
want_u16=$((BYTE_COL - 1 - 4))
if grep -qF "\"start\":{\"line\":2,\"character\":$want_u16}" <<<"$json"; then
  note "the LSP boundary converts to 0-based line + UTF-16 column"
else
  bad "vibe diagnostics --json: got [$json], want start line 2 character $want_u16"
fi

# 8. ...and the two must not have converged. If the START ever reports the byte
#    column, the conversion has been dropped and every editor client shifts.
#    Only the START is compared: the END of this range lands on UTF-16 39,
#    which happens to equal the 0-based byte column of the start, so a
#    whole-document substring search for that number always matches and would
#    make this case fire on a correct compiler.
if grep -qF "\"start\":{\"line\":2,\"character\":$((BYTE_COL - 1))}" <<<"$json"; then
  bad "the LSP JSON start reports the BYTE column ($((BYTE_COL - 1))); the UTF-16 conversion is gone"
else
  note "the LSP JSON start is not the byte column"
fi

# 9. EVERY type error carries a position (#1941). The contract is about which
#    UNIT a position is in, and a diagnostic with no position at all fails it
#    more completely than a wrong unit does -- there is nothing for a client to
#    convert. The shape that used to escape: a top-level `let` whose value is a
#    LITERAL. Literals carry no offset slot, so the value-anchored path had
#    nothing to report; the binder name is the fallback. The same code inside a
#    function was already located, which is what made the gap easy to miss.
cat > "$WORK/unlocated.vibe" <<'UNLOC'
let x: Int = 1
let y: Int = 2
let bad_one: Int = "not an int"

fn main() -> Unit { }
UNLOC
unloc="$(run "$WORK/unlocated.vibe" unloc VIBE_CHECK_ONLY=1; cat "$WORK/unloc.diag" 2>/dev/null || true)"
if grep -qE 'unlocated\.vibe: line 3:' <<<"$unloc"; then
  note "a top-level let bound to a literal reports a position, on its own line"
else
  bad "top-level let + literal value: got [$unloc], want a 'line 3:' position"
fi
# ...and it must name the RIGHT binder, not merely the first `let` in the file.
if grep -qF 'binding type mismatch for bad_one' <<<"$unloc"; then
  note "the located binder is the failing one"
else
  bad "top-level let + literal value: got [$unloc], want it to name 'bad_one'"
fi

if [ "$fails" -ne 0 ]; then
  echo "source-range-contract: see docs/source-range-contract.md -- a surface changed its position unit" >&2
  exit 1
fi
echo "source-range-contract: ok (10 checks; byte col $BYTE_COL, codepoint col $CP_COL, UTF-16 col $want_u16 all distinct)"
