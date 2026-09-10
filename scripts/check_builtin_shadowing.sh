#!/usr/bin/env bash
# #2378 / #2602: no file under `lib/**` may DEFINE a name the builtin registry
# owns.
#
# Why it matters (#2378, P0): a top-level definition wins over the builtin for
# the WHOLE linked program -- not the defining file, not the importer's import
# list. A file that never mentions the name gets the override anyway, and
# nothing is reported. Measured there: `lib/@vibe/builtin/string.vibe` carried
# scalar re-implementations of six SIMD builtins, so importing ANY name from
# that package replaced `String::index_of` and five siblings program-wide --
# 0.8us -> 174us on a sparse search, and `String::split(s, "")` changed from a
# hard trap into `[s]`. The ANSWER differed, not just the speed.
#
# A gate for this existed and was removed, for a good reason recorded at the
# head of `lib/@vibe/builtin/string.vibe`: it was a lexical scan, and it
# "silently missed value aliases, declarations sharing a line, declarations
# behind an attribute, declarations wrapped after their keyword, and
# `r#`-spelled names -- deciding what a declaration binds is the compiler's
# job." Asking the compiler cost ~1.08 s per file, about 17 minutes for `lib/`.
#
# #2381 removed that blocker: `vibe symbols <dir>` now sweeps a whole tree in
# ONE process (measured: all of `lib/` in ~45 s, 25,904 declarations across 998
# files) and answers from the parsed AST. So this gate asks the compiler.
#
# It matters that it is the AST answer and not a regex: of the names this
# finds today, FIVE are kind 13 -- value aliases like
# `export let Fs::exists = exists` -- which an anchored `^(export )?fn` regex
# cannot see, and whose absence is what #2380 paid for.
#
# This is containment for THIS repository only. The language-level half of
# #2378 -- whether `vibe check` should reject or warn, and whether
# program-wide resolution is itself the bug -- is untouched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REGISTRY="lib/@vibe/compiler/core/builtin_registry.vibe"
ALLOWLIST="${BUILTIN_SHADOW_ALLOWLIST:-scripts/builtin_shadowing_allowlist.txt}"
SWEEP_ROOT="${BUILTIN_SHADOW_ROOT:-lib}"

# The ONE file under the sweep root that is not a vibe program: its `declare`
# form is read by the binary encoder, and the general parser rejects it by
# design. Named explicitly so an unreadable file is never inherited as noise --
# any OTHER unreadable path fails this gate.
EXPECTED_UNREADABLE="${BUILTIN_SHADOW_EXPECTED_UNREADABLE:-lib/@vibe/compiler/builtins/declarations.vibe}"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 builtin-shadowing "${BUILTIN_SHADOW_STAGE2:-}")" || exit 1

[ -f "$REGISTRY" ] || { echo "builtin-shadowing: FAIL: no registry at $REGISTRY" >&2; exit 1; }
[ -e "$SWEEP_ROOT" ] || { echo "builtin-shadowing: FAIL: sweep root does not exist: $SWEEP_ROOT" >&2; exit 1; }

WORK="$ROOT_DIR/_build/_builtin_shadowing"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
[ -f "$RUNNER" ] || { echo "builtin-shadowing: FAIL: missing host runner: $RUNNER" >&2; exit 1; }

# `vibe symbols <dir>`, one process for the whole tree. The launcher is not
# used: this drives cli_main directly, the same way scripts/vibe_grep_bin.sh
# does, so the gate needs no installed `vibe`.
SYMS="$WORK/syms.txt"
env -u VIBE_FS_COMPILE -u VIBE_DIAGNOSTICS -u VIBE_NORMALIZE -u VIBE_FMT -u VIBE_TYPE_AT -u VIBE_DOC_AT \
    -u VIBE_BINDING_AT -u VIBE_ESCAPES -u VIBE_ESCAPES_STRICT -u VIBE_ALLOCS -u VIBE_DEPS -u VIBE_GREP \
    -u VIBE_COVERAGE -u VIBE_DEBUG -u VIBE_DEBUG_BREAK -u VIBE_EMIT_MODULE_SOURCE \
  VIBE_SYMBOLS=1 \
  VIBE_SYMBOLS_WITH_PATH=1 \
  VIBE_IMPORT_ABI=raw \
  VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
  bash "$RUNNER" --invoke cli_main "$STAGE2" "$SWEEP_ROOT" "$SYMS" >/dev/null 2>"$WORK/runner.err" || true

if [ ! -s "$SYMS" ]; then
  echo "builtin-shadowing: FAIL: the symbols sweep produced nothing for '$SWEEP_ROOT'." >&2
  echo "  An empty sweep is NOT 'no shadowing' -- it is an unchecked tree." >&2
  [ -s "$WORK/syms.txt.diag" ] && sed 's/^/  diag: /' "$WORK/syms.txt.diag" >&2
  [ -s "$WORK/runner.err" ] && sed 's/^/  runner: /' "$WORK/runner.err" >&2
  exit 1
fi

# A file the sweep could not read is a HOLE, not a pass: its declarations were
# never inspected. Exactly one path is expected (see EXPECTED_UNREADABLE).
if [ -s "$SYMS.diag" ]; then
  while IFS= read -r diag_line || [ -n "$diag_line" ]; do
    [ -n "$diag_line" ] || continue
    case "$diag_line" in
      "$EXPECTED_UNREADABLE"*) : ;;
      *)
        echo "builtin-shadowing: FAIL: a file under '$SWEEP_ROOT' could not be read, so its" >&2
        echo "  declarations were not inspected: $diag_line" >&2
        exit 1
        ;;
    esac
  done < "$SYMS.diag"
fi

# Every name the registry owns. Rows look like
#   ("String::length", CtFn(..), true, false, true),
# and a row's first field is the name. checker_visible is NOT filtered on: a
# definition colliding with a codegen-internal name is still a collision, and
# fail-closed is the direction this gate wants.
awk '
  match($0, /^[ \t]*\("[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z0-9_]+)?"/) {
    s = substr($0, RSTART, RLENGTH)
    gsub(/^[ \t]*\("/, "", s); gsub(/"$/, "", s)
    print s
  }
' "$REGISTRY" | sort -u > "$WORK/registry.txt"

if [ ! -s "$WORK/registry.txt" ]; then
  echo "builtin-shadowing: FAIL: extracted zero names from $REGISTRY." >&2
  echo "  The row shape must have changed; this gate would pass vacuously." >&2
  exit 1
fi

# Declarations that BIND a value: KIND 12 (Function) and 13 (Variable). 13 is
# the one a regex misses (`export let Fs::exists = exists`).
awk '$3 == 12 || $3 == 13 { print $2 }' "$SYMS" | sort -u > "$WORK/declared.txt"
comm -12 "$WORK/registry.txt" "$WORK/declared.txt" > "$WORK/found.txt"

# Allowlist: `<name> <reason...>`. A row with no reason is rejected -- an
# unexplained exemption is how a list like this goes stale unnoticed.
: > "$WORK/allowed.txt"
allow_bad=0
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%% *}"
    reason="${line#"$name"}"
    reason="${reason# }"
    if [ -z "$reason" ] || [ "$reason" = "$name" ]; then
      echo "builtin-shadowing: FAIL: allowlist row has no reason: $line" >&2
      allow_bad=1
      continue
    fi
    printf '%s\n' "$name" >> "$WORK/allowed.txt"
  done < "$ALLOWLIST"
fi
[ "$allow_bad" -eq 0 ] || exit 1
sort -u "$WORK/allowed.txt" -o "$WORK/allowed.txt"

new_hits="$(comm -23 "$WORK/found.txt" "$WORK/allowed.txt")"
stale="$(comm -13 "$WORK/found.txt" "$WORK/allowed.txt")"

status=0
if [ -n "$new_hits" ]; then
  echo "builtin-shadowing: FAIL: these are declared under '$SWEEP_ROOT' and the builtin" >&2
  echo "  registry already owns them. A definition wins for the WHOLE linked program," >&2
  echo "  including files that never import it (#2378), so rename it:" >&2
  printf '%s\n' "$new_hits" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '    %s\n' "$n" >&2
    awk -v n="$n" '$2 == n && ($3 == 12 || $3 == 13) { printf "      %s (kind %s)\n", $1, $3 }' "$SYMS" >&2
  done
  status=1
fi

if [ -n "$stale" ]; then
  echo "builtin-shadowing: FAIL: allowlisted names that are no longer declared." >&2
  echo "  The list shrinks only -- delete these rows:" >&2
  printf '%s\n' "$stale" | sed 's/^/    /' >&2
  status=1
fi

[ "$status" -eq 0 ] || exit 1

files="$(awk '{ print $1 }' "$SYMS" | sort -u | wc -l | tr -d ' ')"
echo "builtin-shadowing: ok ($(wc -l < "$WORK/registry.txt" | tr -d ' ') registry names vs $(wc -l < "$WORK/declared.txt" | tr -d ' ') declared under '$SWEEP_ROOT' across $files files; $(wc -l < "$WORK/found.txt" | tr -d ' ') allowlisted, 0 new)"
