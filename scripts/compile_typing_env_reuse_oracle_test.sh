#!/usr/bin/env bash
# Red self-test for scripts/compile_typing_env_reuse_oracle.mjs (#2248).
#
# The oracle's real inputs are the module bytes and the telemetry each compile
# produces, plus the reuse records it corrupts. A scripted runner stands in for
# the compiler: it answers each named build from a table and, for the builds
# that would publish reuse records, writes stand-in records into the cache. Each
# case perturbs ONE row and asserts the oracle rejects it with the assertion
# that owns that row. A green case runs first, so a harness that rejected
# everything would be caught.
#
# The last two cases use the real compiler, because an oracle that stops
# driving the real compile lane correctly would still satisfy a scripted
# runner: one unmutated run that must pass, and one where a wrapper lets the
# real compile happen and then flips one byte of the reuse-on module, which
# must fail.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

# The oracle drops every VIBE_* variable from its children; these are the ones
# this test reads itself, so none may arrive from the caller (#2252).
unset VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER VIBE_COMPILE_TYPING_REUSE_ORACLE_KEEP_TMP

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# The scripted runner. It ignores the compiler entirely and answers from a
# table keyed by the output name the oracle asked for: module bytes, telemetry,
# and whether to leave reuse records in the cache. The table path travels
# without a VIBE_ prefix, because the oracle drops that whole namespace.
cat > "$WORK/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
out=""
for arg in "$@"; do
  case "$arg" in *.wasm) out="$arg" ;; esac
done
name="$(basename "$out" .wasm)"
row="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$COMPILE_REUSE_ORACLE_FAKE_TABLE")"
if [ -z "$row" ]; then
  echo "fake runner: no table row for $name" >&2
  exit 3
fi
bytes="$(printf '%s' "$row" | cut -f2)"
tel="$(printf '%s' "$row" | cut -f3)"
records="$(printf '%s' "$row" | cut -f4)"
printf '%s' "$bytes" > "$out"
printf '%s' "$tel" > "$VIBE_INCREMENTAL_TELEMETRY_OUT"
if [ "$records" = 1 ]; then
  printf 'TDRE11A3:abc' > "$VIBE_BUILD_CACHE_DIR/vibe_selfhost_typing_dependency_env_reuse_v10_${name}.txt"
  printf 'TDRE10W1:k3:abc1:t' > "$VIBE_BUILD_CACHE_DIR/vibe_selfhost_typing_dependency_env_reuse_eligibility_v10_${name}.txt"
fi
RUNNER
chmod +x "$WORK/runner.sh"

tel() { # rechecked transport
  printf '{"modules_planned":3,"modules_rechecked":%s,"modules_reused":%s,"modules_reused_dependency_transport_env":%s}' \
    "$1" "$((3 - $1))" "$2"
}

# One argument per perturbable cell; the defaults are the good table.
write_table() {
  local edit_transport="${1:-2}" edit_bytes="${2:-P2}" edit_fresh_bytes="${3:-P2}" \
        corrupt_transport="${4:-0}" records="${5:-1}" control_transport="${6:-0}" \
        interface_transport="${7:-0}" edit_rechecked="${8:-1}"
  local f="$WORK/table.$RANDOM.tsv"
  {
    printf 'base-on\tP1\t%s\t%s\n'          "$(tel 3 0)" "$records"
    printf 'base-off\tP1\t%s\t0\n'          "$(tel 3 0)"
    printf 'edit-on\t%s\t%s\t%s\n'          "$edit_bytes" "$(tel "$edit_rechecked" "$edit_transport")" "$records"
    printf 'edit-fresh\t%s\t%s\t0\n'        "$edit_fresh_bytes" "$(tel 3 0)"
    printf 'control-cold\tP3\t%s\t0\n'      "$(tel 3 0)"
    printf 'control-edit\t%s\t%s\t0\n'      "$edit_fresh_bytes" "$(tel 3 "$control_transport")"
    printf 'corrupt-on\tP3\t%s\t0\n'        "$(tel 3 "$corrupt_transport")"
    printf 'corrupt-fresh\tP3\t%s\t0\n'     "$(tel 3 0)"
    printf 'interface-on\tP4\t%s\t0\n'      "$(tel 3 "$interface_transport")"
    printf 'interface-fresh\tP4\t%s\t0\n'   "$(tel 3 0)"
  } > "$f"
  echo "$f"
}

run_oracle() { # table -> exit code, stderr in $WORK/err
  VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER="$WORK/runner.sh" COMPILE_REUSE_ORACLE_FAKE_TABLE="$1" \
    node scripts/compile_typing_env_reuse_oracle.mjs "$WORK/fake-stage2.wasm" >"$WORK/out" 2>"$WORK/err"
}

expect_pass() {
  if run_oracle "$1"; then
    echo "ok   $2"
  else
    echo "FAIL $2: expected the oracle to pass"; sed -n '1,6p' "$WORK/err"; fails=$((fails + 1))
  fi
}

expect_fail() { # table label needle
  if run_oracle "$1"; then
    echo "FAIL $2: the oracle PASSED on a mutated input"; fails=$((fails + 1))
  elif grep -qF "$3" "$WORK/err"; then
    echo "ok   $2"
  else
    echo "FAIL $2: failed, but not on the expected assertion (wanted: $3)"; sed -n '1,6p' "$WORK/err"; fails=$((fails + 1))
  fi
}

printf 'stage2' > "$WORK/fake-stage2.wasm"

expect_pass "$(write_table)" "the scripted-good table passes"

expect_fail "$(write_table 0 P2 P2 0 1 0 0 3)" \
  "a meaning edit with no reuse hit is refused as vacuous" \
  "recorded no dependency-transport reuse"

expect_fail "$(write_table 1)" \
  "a meaning edit that reused fewer consumers than expected is refused" \
  "meaning edit with reuse on: expected"

expect_fail "$(write_table 2 P1 P1)" \
  "an edit that left the program unchanged is refused as proving nothing" \
  "did not change the program"

expect_fail "$(write_table 2 P2 P9)" \
  "a reuse-on module that differs from the fresh compile is refused" \
  "meaning edit: the reuse-on compile differs from a fresh reuse-off compile"

expect_fail "$(write_table 2 P2 P2 2)" \
  "reusing through corrupted records is refused" \
  "corrupted reuse records: expected"

expect_fail "$(write_table 2 P2 P2 0 0)" \
  "a corruption that found no records is refused" \
  "found no reuse records"

expect_fail "$(write_table 2 P2 P2 0 1 2)" \
  "a reuse hit with reuse off is refused" \
  "meaning edit with reuse off: expected"

expect_fail "$(write_table 2 P2 P2 0 1 0 2)" \
  "a reuse hit across an interface edit is refused" \
  "interface edit with reuse on: expected"

# Calls the real runner, then flips the last byte of the module ONE named build
# produced. The flip must APPLY: a module it cannot find exits non-zero rather
# than no-opping, because a silent no-op looks exactly like a passing gate.
cat > "$WORK/mutating_runner.sh" <<'MUTRUNNER'
#!/usr/bin/env bash
set -uo pipefail
bash "$COMPILE_REUSE_ORACLE_REAL_RUNNER" "$@" || exit $?
out=""
for arg in "$@"; do case "$arg" in *.wasm) out="$arg" ;; esac; done
[ "$(basename "$out" .wasm)" = "$COMPILE_REUSE_ORACLE_MUTATE_BUILD" ] || exit 0
python3 -c '
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
if not data:
    raise SystemExit("mutating runner: %s is empty" % path)
data[-1] ^= 0xFF
open(path, "wb").write(bytes(data))
' "$out"
MUTRUNNER
chmod +x "$WORK/mutating_runner.sh"

# ---- the real compiler ----------------------------------------------------
STAGE2="$(resolve_stage2 compile-typing-env-reuse-oracle-test "${COMPILE_REUSE_ORACLE_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || {
  echo "FAIL no compiler to run the real cases against" >&2; exit 1; }
case "$STAGE2" in /*) STAGE2_ABS="$STAGE2" ;; *) STAGE2_ABS="$ROOT_DIR/$STAGE2" ;; esac

if node scripts/compile_typing_env_reuse_oracle.mjs "$STAGE2_ABS" >"$WORK/out" 2>"$WORK/err"; then
  echo "ok   the real compiler passes the oracle unmutated"
else
  echo "FAIL the real compiler does not pass the oracle unmutated"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
fi

if COMPILE_REUSE_ORACLE_REAL_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
   COMPILE_REUSE_ORACLE_MUTATE_BUILD="edit-on" \
   VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER="$WORK/mutating_runner.sh" \
   node scripts/compile_typing_env_reuse_oracle.mjs "$STAGE2_ABS" >"$WORK/out" 2>"$WORK/err"; then
  echo "FAIL the oracle PASSED with the real reuse-on module altered"; fails=$((fails + 1))
elif grep -qF "meaning edit: the reuse-on compile differs from a fresh reuse-off compile" "$WORK/err"; then
  echo "ok   altering the REAL reuse-on module is refused"
else
  echo "FAIL real-module mutation failed on the wrong assertion"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
  echo "compile-typing-env-reuse-oracle self-test: ok (1 green + 8 red scripted, 1 green + 1 red against $STAGE2)"
else
  echo "compile-typing-env-reuse-oracle self-test: $fails case(s) failed" >&2
  exit 1
fi
