#!/usr/bin/env bash
# Self-test for scripts/check_compile_only_size.sh (#2248 rule: a gate must
# prove it can fail). Every case mutates a REAL input -- the compile-only
# artifact, its build receipt, the CLI stage2, the baseline -- and asserts the
# gate fails with the message for that mutation.
#
#   control   the real pair against a scratch baseline at the measured
#             separation passes
#   boundary  the artifact padded by exactly the margin passes, padded by one
#             byte more fails: the budget arithmetic is the one documented,
#             and each mutation is shown to have hit (the gate reports the
#             padded size)
#   swapped   the full CLI presented as the compile-only artifact fails
#   tampered  a padded artifact beside its ORIGINAL receipt is refused
#   compiler  a receipt naming another compiler is refused
#   sources   a receipt naming other generated sources is refused
#   receipt   an artifact with no receipt is refused
#   cli       a CLI stage2 that no longer matches its generation is refused
#   baseline  a baseline without separation_bytes is refused
#
# The artifact and stage2 are the gate's own (HEAD's generation, or the
# COMPILE_ONLY_STAGE2 / VIBE_STAGE2_WASM override): the gate is run once with
# --print first, which reuses or builds the named compile-only artifact.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"
GATE="scripts/check_compile_only_size.sh"
STAGE2="$(resolve_stage2_strict compile-only-size-test "${COMPILE_ONLY_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
STAGE2="$(cd "$(dirname "$STAGE2")" && pwd)/$(basename "$STAGE2")"
ART="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_size_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

die() { echo "check_compile_only_size_test: FAIL: $*" >&2; exit 1; }

# Run the gate with an explicit stage2, so nothing inherited can pick another.
gate() { # <stage2> <gate args...>
  local stage2="$1"; shift
  env -u COMPILE_ONLY_STAGE2 VIBE_STAGE2_WASM="$stage2" bash "$GATE" "$@"
}

gate "$STAGE2" --print >"$TMP/print.txt" 2>"$TMP/print.err" \
  || { cat "$TMP/print.err" >&2; die "the gate could not measure the real pair"; }
field() { awk -v k="$1" '$1 == "#" && $2 == k { print $3 }' "$TMP/print.txt"; }
SEP="$(field separation_bytes)"
CO_BYTES="$(field compile_only_bytes)"
[ -n "$SEP" ] && [ "$SEP" -gt 0 ] && [ -n "$CO_BYTES" ] || die "no measurement in the gate's --print output"
[ -f "$ART.receipt.json" ] || die "the gate left no receipt beside $ART"

# A scratch baseline at the measured separation, so this test exercises the
# gate's machinery whatever today's verdict against the committed one is.
TOL=5
FLOOR=$(( SEP * (100 - TOL) / 100 ))
MARGIN=$(( SEP - FLOOR ))
printf 'separation_bytes %s\ntolerance_pct %s\n' "$SEP" "$TOL" >"$TMP/baseline.txt"

# <in.wasm> <out.wasm> <bytes>: append a custom section of exactly that many
# bytes. Custom sections other than `name` are measured, so this is the
# smallest real growth of the artifact.
pad() {
  node - "$@" <<'JS'
const fs = require("node:fs");
const [src, dst, want] = [process.argv[2], process.argv[3], Number(process.argv[4])];
const uleb = (n) => { const o = []; do { let b = n & 127; n >>>= 7; if (n) b |= 128; o.push(b); } while (n); return o; };
for (let nameLen = 1; nameLen <= 8; nameLen++) {
  const payload = want - 1 - nameLen - 1;
  for (let p = payload; p >= payload - 8 && p >= 0; p--) {
    const body = 1 + nameLen + p;
    if (1 + uleb(body).length + body !== want) continue;
    const section = Buffer.from([0, ...uleb(body), nameLen, ...Buffer.from("p".repeat(nameLen)), ...Buffer.alloc(p)]);
    fs.writeFileSync(dst, Buffer.concat([fs.readFileSync(src), section]));
    process.exit(0);
  }
}
throw new Error(`cannot pad by exactly ${want} bytes`);
JS
}

# <artifact> <field> <value>: (re)write the receipt beside <artifact> from the
# real one, with the artifact's own digest and one field optionally replaced.
receipt() {
  node - "$ART.receipt.json" "$@" <<'JS'
const fs = require("node:fs");
const crypto = require("node:crypto");
const [real, artifact, key, value] = process.argv.slice(2);
const r = JSON.parse(fs.readFileSync(real, "utf8"));
const bytes = fs.readFileSync(artifact);
r.artifact_sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
r.artifact_bytes = bytes.length;
if (key) r[key] = value;
fs.writeFileSync(`${artifact}.receipt.json`, JSON.stringify(r, null, 2) + "\n");
JS
}

expect() { # <ok|fail> <case> <needle> <stage2> <gate args...>
  local want="$1" label="$2" needle="$3" stage2="$4"; shift 4
  local log="$TMP/$label.log" rc=0
  gate "$stage2" "$@" >"$log" 2>&1 || rc=$?
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then
    cat "$log" >&2; die "($label) the gate failed on an input it must accept"
  fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    cat "$log" >&2; die "($label) the gate passed on a mutated input"
  fi
  grep -qF -- "$needle" "$log" || { cat "$log" >&2; die "($label) the gate's output does not say '$needle'"; }
  echo "check_compile_only_size_test: ok ($label): ${want/fail/failed as expected}"
}

# control: the artifact as built, with its own receipt.
cp "$ART" "$TMP/control.wasm"; cp "$ART.receipt.json" "$TMP/control.wasm.receipt.json"
expect ok control "margin $MARGIN B" "$STAGE2" --artifact "$TMP/control.wasm" --baseline "$TMP/baseline.txt"

# boundary: exactly the margin passes with no margin left; one byte more fails
# by one byte. Both name the padded size, so the mutation is shown to have hit.
pad "$ART" "$TMP/edge.wasm" "$MARGIN"; receipt "$TMP/edge.wasm"
expect ok boundary-at-floor "compile-only $(( CO_BYTES + MARGIN )) B" "$STAGE2" \
  --artifact "$TMP/edge.wasm" --baseline "$TMP/baseline.txt"
pad "$ART" "$TMP/over.wasm" "$(( MARGIN + 1 ))"; receipt "$TMP/over.wasm"
expect fail boundary-over "is $(( CO_BYTES + MARGIN + 1 )) B, over its budget" "$STAGE2" \
  --artifact "$TMP/over.wasm" --baseline "$TMP/baseline.txt"
grep -qF "1 B that only the full CLI carried" "$TMP/boundary-over.log" \
  || { cat "$TMP/boundary-over.log" >&2; die "(boundary-over) the overrun is not reported as exactly 1 B"; }

# swapped: the full CLI is no compile-only artifact, receipt or not.
cp "$STAGE2" "$TMP/swapped.wasm"; receipt "$TMP/swapped.wasm"
expect fail swapped "over its budget" "$STAGE2" --artifact "$TMP/swapped.wasm" --baseline "$TMP/baseline.txt"

# tampered: the file changed after its receipt was written.
cp "$TMP/over.wasm" "$TMP/tampered.wasm"; cp "$ART.receipt.json" "$TMP/tampered.wasm.receipt.json"
expect fail tampered "does not match its build receipt" "$STAGE2" \
  --artifact "$TMP/tampered.wasm" --baseline "$TMP/baseline.txt"

# compiler / sources: built by another compiler, or from other generated
# sources, than the ones it is compared with.
OTHER_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cp "$ART" "$TMP/compiler.wasm"; receipt "$TMP/compiler.wasm" compiler_sha256 "$OTHER_SHA"
expect fail compiler "not by the stage2 it is compared with" "$STAGE2" \
  --artifact "$TMP/compiler.wasm" --baseline "$TMP/baseline.txt"
cp "$ART" "$TMP/sources.wasm"; receipt "$TMP/sources.wasm" generated_fingerprint "$OTHER_SHA"
expect fail sources "was built from generated sources" "$STAGE2" \
  --artifact "$TMP/sources.wasm" --baseline "$TMP/baseline.txt"

# receipt: no receipt at all.
cp "$ART" "$TMP/bare.wasm"
expect fail receipt "has no build receipt" "$STAGE2" --artifact "$TMP/bare.wasm" --baseline "$TMP/baseline.txt"

# cli: a stage2 whose bytes no longer match its generation receipt (one byte
# of the last section flipped), beside a copy of that receipt.
mkdir -p "$TMP/gen"
cp "$(dirname "$STAGE2")/generation.json" "$TMP/gen/generation.json"
node -e 'const fs=require("fs");const b=fs.readFileSync(process.argv[1]);b[b.length-1]^=1;fs.writeFileSync(process.argv[2],b)' \
  "$STAGE2" "$TMP/gen/stage2.wasm"
cmp -s "$STAGE2" "$TMP/gen/stage2.wasm" && die "(cli) the stage2 mutation did not change the file"
expect fail cli "stage2 does not match its generation receipt" "$TMP/gen/stage2.wasm" \
  --artifact "$TMP/control.wasm" --baseline "$TMP/baseline.txt"

# baseline: the budget line is required, not defaulted.
printf 'tolerance_pct 5\n' >"$TMP/no_sep.txt"
expect fail baseline "no separation_bytes entry" "$STAGE2" --artifact "$TMP/control.wasm" --baseline "$TMP/no_sep.txt"

echo "check_compile_only_size_test: ok (10 cases)"
