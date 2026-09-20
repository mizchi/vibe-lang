#!/usr/bin/env bash
# #2913 section 2: a name the CHECKER admits must EMIT something.
#
# The defect class this stands against has shipped seven times that anyone has
# counted -- #774, #777, #778, `@vibe/lsp`, then #2900's own two families, then
# the nine names found by running this sweep by hand (#2939, #2942). Every
# instance has the same shape: a clean `vibe check` followed by
#
#   internal compiler error: `X` (local, @call) reached code generation
#   unresolved. The type checker should have bound or rejected this name ...
#
# which tells a reader their correct-looking program is a compiler bug to
# report, when the whole fault is a missing import or a name that never
# existed.
#
# ORACLE. Compile -- not check -- one CALL probe per `declare` in
# builtins/declarations.vibe, and read the diagnostic:
#
#   contains "reached code generation unresolved"  -> FINDING
#   contains "unknown name"                        -> not admitted; fine
#   empty                                          -> compiled; fine
#   anything else                                  -> INCONCLUSIVE
#
# The CALL form and not the value form: the checker's `ECall` arm resolves the
# callee through `direct_builtin_return` and does not re-check the callee
# `EIdent`, so a name reached only by that fast path types as a call while the
# value form still says `unknown name`. Probing values would miss exactly the
# names this gate exists to catch (the same reason tests/gates/early/run.sh's
# 4g probes both).
#
# TWO PROBE REFINEMENTS, both derived rather than curated. Without them 84 of
# 257 probes were inconclusive and four real findings sat inside that bucket:
#
#   * a declared parameter of bare `T` is a type formal the probe cannot
#     spell, so a concrete type is substituted;
#   * a capability builtin needs a row, so when the checker answers
#     "no 'with' clause, requires { R }" the probe is retried ONCE with
#     `with R` -- the row comes from the compiler, not from a table here.
#
# A wrong guess in either can only produce some OTHER diagnostic, which stays
# inconclusive. Neither can turn a missing lowering into a false "it emits".
#
# INCONCLUSIVE IS NOT A PASS. Silence is "unchecked", not "safe" (#2248), so
# the inconclusive set must match scripts/builtin_emits_inconclusive.txt
# EXACTLY: a new one fails, and so does a listed name that has become
# conclusive, which makes the list shrink-only.
#
# Env:
#   VIBE_BUILTIN_EMITS_COMPILER  stage2 override (default: resolve_stage2)
#   VIBE_BUILTIN_EMITS_RUNNER    host-runner override -- the self-test's stub
#   VIBE_BUILTIN_EMITS_DECLS     declarations file override (self-test)
#   VIBE_BUILTIN_EMITS_ALLOWLIST inconclusive list override (self-test)
#   VIBE_BUILTIN_EMITS_FLOOR     minimum corpus size (default 200)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"

DECLS_FILE="${VIBE_BUILTIN_EMITS_DECLS:-lib/@vibe/compiler/builtins/declarations.vibe}"
ALLOWLIST="${VIBE_BUILTIN_EMITS_ALLOWLIST:-scripts/builtin_emits_inconclusive.txt}"
RUNNER="${VIBE_BUILTIN_EMITS_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}"
FLOOR="${VIBE_BUILTIN_EMITS_FLOOR:-200}"

STAGE2="$(resolve_stage2 builtin-emits "${VIBE_BUILTIN_EMITS_COMPILER:-}")" || exit 1
[ -f "$DECLS_FILE" ] || { echo "builtin-emits: FAIL: no declarations file: $DECLS_FILE" >&2; exit 1; }
[ -f "$ALLOWLIST" ] || { echo "builtin-emits: FAIL: no inconclusive list: $ALLOWLIST" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_builtin_emits.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# `name|T0,T1,...` for every declaration in the file.
decls="$(awk '
  /^declare / {
    line = $0; sub(/^declare /, "", line)
    name = line; sub(/\(.*$/, "", name)
    params = line; sub(/^[^(]*\(/, "", params); sub(/\).*$/, "", params)
    gsub(/ /, "", params)
    print name "|" params
  }' "$DECLS_FILE")"

corpus_size="$(printf '%s\n' "$decls" | grep -c . || true)"
# A floor, because an empty or broken scan would otherwise report "no findings"
# and pass -- the gate would be green about a corpus it never read.
if [ "${corpus_size:-0}" -lt "$FLOOR" ]; then
  echo "builtin-emits: FAIL: scanned only $corpus_size declarations in $DECLS_FILE (floor $FLOOR)." >&2
  echo "builtin-emits:   The file moved or the scan broke; an empty scan would pass this gate vacuously." >&2
  exit 1
fi

# Compile one probe. Echoes the diagnostic (empty = it compiled).
probe_diag() { # <sig> <name> <args> <row>
  p_sig="$1"; p_name="$2"; p_args="$3"; p_row="$4"
  p_with=""
  [ -n "$p_row" ] && p_with=" with $p_row"
  printf 'fn probe(%s) -> Int%s {\n  let _r = %s(%s)\n  0\n}\n' \
    "$p_sig" "$p_with" "$p_name" "$p_args" > "$WORK/p.vibe"
  rm -f "$WORK/p.out" "$WORK/p.out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$STAGE2" \
    "$WORK/p.vibe" "$WORK/p.out" __no_entry__ >/dev/null 2>&1
  cat "$WORK/p.out.diag" 2>/dev/null || true
}

# The declared parameter types, with bare type formals made concrete.
probe_sig_args() { # <params> -> sets SIG and ARGS
  SIG=""; ARGS=""
  [ -n "$1" ] || return 0
  s_saved="$IFS"
  IFS=','
  s_n=0
  for s_ty in $1; do
    s_ty="$(printf '%s' "$s_ty" | sed 's/\bT\b/Int/g; s/\bU\b/Int/g; s/\bV\b/Int/g; s/\bK\b/Int/g')"
    if [ -n "$SIG" ]; then SIG="$SIG, "; ARGS="$ARGS, "; fi
    SIG="${SIG}a${s_n}: ${s_ty}"
    ARGS="${ARGS}a${s_n}"
    s_n=$((s_n + 1))
  done
  IFS="$s_saved"
}

classify() { # <name> <params> -> echoes "ICE|UNKNOWN|CLEAN|OTHER<tab>detail"
  c_name="$1"
  probe_sig_args "$2"
  c_diag="$(probe_diag "$SIG" "$c_name" "$ARGS" "")"
  case "$c_diag" in
    *"no 'with' clause, requires {"*)
      c_row="$(printf '%s' "$c_diag" | sed -n "s/.*no 'with' clause, requires { \([^}]*\) }.*/\1/p" | head -1)"
      if [ -n "$c_row" ]; then
        c_diag="$(probe_diag "$SIG" "$c_name" "$ARGS" "$c_row")"
      fi
      ;;
  esac
  case "$c_diag" in
    *"reached code generation unresolved"*) printf 'ICE' ;;
    *"unknown name"*) printf 'UNKNOWN' ;;
    "") printf 'CLEAN' ;;
    *) printf 'OTHER %s' "$(printf '%s' "$c_diag" | head -1 | cut -c1-140)" ;;
  esac
}

# --- LIVENESS, before the sweep ---------------------------------------------
# A runner that produces nothing writes an empty `.diag`, which this gate reads
# as "it compiled" -- so a dead runner would sweep 257 names and report no
# findings. These two controls make that state impossible: one name MUST answer
# with a diagnostic, another MUST answer with none. An empty `.diag` cannot
# satisfy the first; a runner that always errors cannot satisfy the second.
live_must_speak="Lines::parse"
live_must_compile="Http::close"
live_a="$(classify "$live_must_speak" "String")"
case "$live_a" in
  UNKNOWN) : ;;
  *) echo "builtin-emits: FAIL: the liveness control '$live_must_speak' answered '$live_a', not UNKNOWN." >&2
     echo "builtin-emits:   It is import-required (#2939), so a bare call must say \`unknown name\`." >&2
     echo "builtin-emits:   An empty diagnostic here means the probes are not running at all." >&2
     exit 1 ;;
esac
live_b="$(classify "$live_must_compile" "Int")"
case "$live_b" in
  CLEAN) : ;;
  *) echo "builtin-emits: FAIL: the liveness control '$live_must_compile' answered '$live_b', not CLEAN." >&2
     echo "builtin-emits:   It is a real host-import builtin and must compile bare." >&2
     exit 1 ;;
esac

# --- the sweep ---------------------------------------------------------------
: >"$WORK/ice.txt"
: >"$WORK/other.txt"
n_clean=0; n_unknown=0
while IFS='|' read -r name params; do
  [ -n "$name" ] || continue
  verdict="$(classify "$name" "$params")"
  case "$verdict" in
    ICE) printf '%s\n' "$name" >>"$WORK/ice.txt" ;;
    UNKNOWN) n_unknown=$((n_unknown + 1)) ;;
    CLEAN) n_clean=$((n_clean + 1)) ;;
    OTHER*) printf '%s\t%s\n' "$name" "${verdict#OTHER }" >>"$WORK/other.txt" ;;
  esac
done <<DECLS
$decls
DECLS

fails=0
n_ice="$(grep -c . "$WORK/ice.txt" || true)"
if [ "${n_ice:-0}" -gt 0 ]; then
  echo "builtin-emits: FAIL: the checker admits these names and codegen has no lowering for them:" >&2
  while read -r n; do
    [ -n "$n" ] || continue
    echo "    $n   (compiles clean under \`vibe check\`, then ICEs)" >&2
  done <"$WORK/ice.txt"
  echo "builtin-emits:   Either it is a library function that needs its import reserved," >&2
  echo "builtin-emits:   or it is a phantom and the checker must stop admitting it." >&2
  echo "builtin-emits:   Add a builtin_no_lowering_hint row either way, so the" >&2
  echo "builtin-emits:   diagnostic names the edit (#2900, #2913)." >&2
  fails=1
fi

# Inconclusive must match the list EXACTLY -- shrink-only.
cut -f1 "$WORK/other.txt" | sort -u >"$WORK/other_names.txt"
grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' | sort -u >"$WORK/allowed.txt"
new_inconclusive="$(comm -23 "$WORK/other_names.txt" "$WORK/allowed.txt")"
gone_inconclusive="$(comm -13 "$WORK/other_names.txt" "$WORK/allowed.txt")"
if [ -n "$new_inconclusive" ]; then
  echo "builtin-emits: FAIL: these probes answered with neither a finding nor a clean" >&2
  echo "builtin-emits:   compile, and are not on the list. Inconclusive is UNCHECKED, not safe:" >&2
  printf '%s\n' "$new_inconclusive" | while read -r n; do
    [ -n "$n" ] || continue
    echo "    $n   $(grep -F "$n	" "$WORK/other.txt" | head -1 | cut -f2)" >&2
  done
  echo "builtin-emits:   Teach the probe to spell it, or add it to $ALLOWLIST with a reason." >&2
  fails=1
fi
if [ -n "$gone_inconclusive" ]; then
  echo "builtin-emits: FAIL: these are on the inconclusive list but the probe now answers" >&2
  echo "builtin-emits:   for them. The list only shrinks -- drop them:" >&2
  printf '    %s\n' $gone_inconclusive >&2
  fails=1
fi

if [ "$fails" -ne 0 ]; then
  exit 1
fi
echo "builtin-emits: ok ($corpus_size declared names: $n_clean emit, $n_unknown are not admitted, 0 admitted-without-a-lowering, $(grep -c . "$WORK/other_names.txt" || true) inconclusive and all listed)"
