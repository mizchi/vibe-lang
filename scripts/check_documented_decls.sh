#!/usr/bin/env bash
# #2822: ratchet the count of documented declarations under lib/.
#
# Consecutive `///` lines are one block attached to the following declaration.
# Inserting a function between a block and its target, or concatenating two
# blocks onto one declaration, silently transfers one doc and deletes another.
# `vibe symbols` already answers this: a documented declaration has a DOC
# field, an undocumented one does not. Merging N blocks into one always loses
# exactly N-1 documented declarations.
#
# A lexical "second line looks like `#NNNN:`" detector is a proxy: over lib/
# it hit 110 ordinary multi-issue blocks. This gate counts the compiler's
# answer instead.
#
# Per-file floors live in scripts/documented_decls_floor.txt. A file whose
# documented count DROPS below its floor fails. A new documented file with no
# floor fails until a row is added. A deliberate doc removal lowers the floor
# in the same change. Generated compiler bundles are excluded: they are not
# hand-edited and their `///` text is not documentation of a declaration.
#
# Usage:
#   bash scripts/check_documented_decls.sh
#   bash scripts/check_documented_decls.sh --print
#   DOC_DECL_STAGE2=<stage2.wasm> bash scripts/check_documented_decls.sh
set -euo pipefail
ROOT_DIR="${DOC_DECL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

mode="check"
case "${1:-}" in
  --print) mode="print" ;;
  "") ;;
  *) echo "documented-decls: unknown argument: $1 (expected --print)" >&2; exit 2 ;;
esac

SWEEP_ROOT="${DOC_DECL_ROOT:-lib}"
FLOOR="${DOC_DECL_FLOOR:-scripts/documented_decls_floor.txt}"
EXPECTED_UNREADABLE="${DOC_DECL_EXPECTED_UNREADABLE:-lib/@vibe/compiler/builtins/declarations.vibe}"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 documented-decls "${DOC_DECL_STAGE2:-}")" || exit 1

[ -e "$SWEEP_ROOT" ] || { echo "documented-decls: FAIL: sweep root does not exist: $SWEEP_ROOT" >&2; exit 1; }

# Per-process dir: `pkf run release-check` can run this gate and its self-test
# as siblings, and the self-test invokes the gate four more times. A shared
# `_build/_documented_decls` would let one invocation `rm -rf` another's sweep.
WORK="${DOC_DECL_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/vibe_doc_decls.XXXXXX")}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
[ -f "$RUNNER" ] || { echo "documented-decls: FAIL: missing host runner: $RUNNER" >&2; exit 1; }

# `vibe symbols --with-path`, driving cli_main the way check_builtin_shadowing.sh
# does, so the gate needs no installed `vibe`.
sym_run() { # <input path> <output path>
  env -u VIBE_FS_COMPILE -u VIBE_DIAGNOSTICS -u VIBE_NORMALIZE -u VIBE_FMT -u VIBE_TYPE_AT -u VIBE_DOC_AT \
      -u VIBE_BINDING_AT -u VIBE_ESCAPES -u VIBE_ESCAPES_STRICT -u VIBE_ALLOCS -u VIBE_DEPS -u VIBE_GREP \
      -u VIBE_COVERAGE -u VIBE_DEBUG -u VIBE_DEBUG_BREAK -u VIBE_EMIT_MODULE_SOURCE \
    VIBE_SYMBOLS=1 \
    VIBE_SYMBOLS_WITH_PATH=1 \
    VIBE_IMPORT_ABI=raw \
    VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
    bash "$RUNNER" --invoke cli_main "$STAGE2" "$1" "$2" >/dev/null 2>>"$WORK/runner.err" || true
}

SYMS="$WORK/syms.txt"
FALLBACK_CAP="${DOC_DECL_FALLBACK_CAP:-50}"

batch_worked=1
if [ "${DOC_DECL_NO_BATCH:-0}" = "1" ]; then
  : > "$SYMS"
  batch_worked=0
else
  sym_run "$SWEEP_ROOT" "$SYMS"
  if [ ! -s "$SYMS" ] && [ -d "$SWEEP_ROOT" ]; then
    if grep -q "EISDIR" "$SYMS.diag" 2>/dev/null; then
      batch_worked=0
    elif [ ! -s "$SYMS.diag" ]; then
      batch_worked=0
    fi
  fi
fi

if [ "$batch_worked" -eq 0 ]; then
  : > "$WORK/files.txt"
  find "$SWEEP_ROOT" \( -name '.*' -o -name '_build' -o -name 'node_modules' -o -name 'dist' -o -name 'target' -o -name 'deps' \) -prune -o \
       -type f \( -name '*.vibe' -o -name '*.vibex' \) -print > "$WORK/files.txt" 2>/dev/null || true
  n_files="$(wc -l < "$WORK/files.txt" | tr -d ' ')"
  if [ "$n_files" -gt "$FALLBACK_CAP" ]; then
    echo "documented-decls: FAIL: this compiler cannot sweep a directory (batch symbols is #2381)," >&2
    echo "  and '$SWEEP_ROOT' holds $n_files files -- more than the $FALLBACK_CAP-file fallback cap." >&2
    echo "  Build a compiler that has it:  pkf run generation" >&2
    echo "  (or hand one over:  DOC_DECL_STAGE2=<path to stage2.wasm>)" >&2
    exit 1
  fi
  : > "$SYMS"; : > "$SYMS.diag"
  while IFS= read -r one || [ -n "$one" ]; do
    [ -n "$one" ] || continue
    sym_run "$one" "$WORK/one.txt"
    if [ -s "$WORK/one.txt.diag" ]; then
      printf '%s: ' "$one" >> "$SYMS.diag"
      cat "$WORK/one.txt.diag" >> "$SYMS.diag"
      printf '\n' >> "$SYMS.diag"
    fi
    if [ -s "$WORK/one.txt" ]; then
      awk -v p="$one" '{ print p, $0 }' "$WORK/one.txt" >> "$SYMS"
    fi
    rm -f "$WORK/one.txt" "$WORK/one.txt.diag"
  done < "$WORK/files.txt"
fi

if [ ! -s "$SYMS" ]; then
  echo "documented-decls: FAIL: the symbols sweep produced nothing for '$SWEEP_ROOT'." >&2
  echo "  An empty sweep is NOT 'no documentation' -- it is an unchecked tree." >&2
  [ -s "$SYMS.diag" ] && sed 's/^/  diag: /' "$SYMS.diag" >&2
  [ -s "$WORK/runner.err" ] && sed 's/^/  runner: /' "$WORK/runner.err" >&2
  exit 1
fi

if [ -s "$SYMS.diag" ]; then
  while IFS= read -r diag_line || [ -n "$diag_line" ]; do
    [ -n "$diag_line" ] || continue
    case "$diag_line" in
      "$EXPECTED_UNREADABLE"*) : ;;
      *)
        echo "documented-decls: FAIL: a file under '$SWEEP_ROOT' could not be read, so its" >&2
        echo "  declarations were not inspected: $diag_line" >&2
        exit 1
        ;;
    esac
  done < "$SYMS.diag"
fi

# Generated bundles are not hand-edited documentation. Matching by basename so
# a moved generated file stays excluded without a path rewrite.
is_generated() {
  case "${1##*/}" in
    compiler_sources_bundle.vibe|cli_adapter_bundle.vibe|selfbuild_runtime_entry_bundle.vibe|_cli_adapter_module_source.vibe|codegen_fingerprint.vibe)
      return 0 ;;
  esac
  return 1
}

# Batch `vibe symbols` rows: PATH NAME KIND START END [DOC]. DOC is present
# iff there is a sixth field (it may contain spaces; NAME never does).
awk '
  # A package CONTRACT is out of scope, stated here rather than inherited.
  # Since #2898 the symbols sweep also reads `.vpkg` files -- but the
  # per-file FALLBACK below enumerates `.vibe` / `.vibex` only, so admitting
  # them would make the two lanes report different corpora for the same tree,
  # and a floor row written from the batch lane would fail in the fallback
  # with "is in the floor but the sweep did not report it". Ratcheting the
  # published API's own doc coverage is worth doing and is its own change:
  # it needs both lanes moved together.
  $1 ~ /\.vpkg$/ || $1 ~ /\.vibei$/ { next }
  NF >= 1 { files[$1] = 1 }
  NF >= 6 { docs[$1]++ }
  END {
    for (p in files) {
      n = docs[p] + 0
      print p "\t" n
    }
  }
' "$SYMS" | sort > "$WORK/counts.txt"

: > "$WORK/measured.txt"
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  path="${line%%	*}"
  n="${line#*	}"
  if is_generated "$path"; then
    continue
  fi
  printf '%s\t%s\n' "$path" "$n" >> "$WORK/measured.txt"
done < "$WORK/counts.txt"
sort "$WORK/measured.txt" -o "$WORK/measured.txt"

if [ "$mode" = "print" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n="${line#*	}"
    if [ "$n" -gt 0 ]; then
      printf '%s\n' "$line"
    fi
  done < "$WORK/measured.txt"
  exit 0
fi

if [ ! -f "$FLOOR" ]; then
  echo "documented-decls: FAIL: missing floor file $FLOOR" >&2
  echo "  Generate one with: bash scripts/check_documented_decls.sh --print > $FLOOR" >&2
  exit 1
fi

: > "$WORK/floor.txt"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  printf '%s\n' "$line" >> "$WORK/floor.txt"
done < "$FLOOR"
sort "$WORK/floor.txt" -o "$WORK/floor.txt"

status=0
above=0

# Every floor row must still exist, and its count must not drop.
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  path="${line%%	*}"
  want="${line#*	}"
  got="$(awk -F '\t' -v p="$path" '$1 == p { print $2 }' "$WORK/measured.txt")"
  if [ -z "$got" ]; then
    echo "documented-decls: FAIL: $path is in $FLOOR but the sweep did not report it" >&2
    echo "  (file gone, or it became a generated basename). Remove the floor row." >&2
    status=1
    continue
  fi
  if [ "$got" -lt "$want" ]; then
    echo "documented-decls: FAIL: $path documented declarations dropped: $got < floor $want" >&2
    echo "  Merging two /// blocks onto one declaration loses a doc. If this" >&2
    echo "  removal is deliberate, lower the floor in $FLOOR in the same change." >&2
    status=1
  elif [ "$got" -gt "$want" ]; then
    echo "documented-decls: NOTE: $path is at $got, above floor $want -- raise the floor to keep the ratchet tight" >&2
    above=$((above + 1))
  fi
done < "$WORK/floor.txt"

# A newly documented file with no floor is untracked: the next merge would
# be invisible. Fail until a row is added.
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  path="${line%%	*}"
  n="${line#*	}"
  [ "$n" -gt 0 ] || continue
  if ! awk -F '\t' -v p="$path" '$1 == p { found=1 } END { exit found ? 0 : 1 }' "$WORK/floor.txt"; then
    echo "documented-decls: FAIL: $path has $n documented declaration(s) but no floor row" >&2
    echo "  Add: $path	$n" >&2
    status=1
  fi
done < "$WORK/measured.txt"

if [ "$status" -ne 0 ]; then
  exit 1
fi

nfiles="$(wc -l < "$WORK/measured.txt" | tr -d ' ')"
echo "documented-decls: ok ($nfiles files swept; $above above their floor)"
