#!/usr/bin/env bash
# Every scripts/**/*.vibex declares the least authority it runs with, and
# dropping any of it is refused before the tool runs (#3676):
#
#   bash scripts/check_vibex_grants.sh <cli.wasm> [file.vibex ...]
#
# For each `fn ... allows <row>` declaration (all of scripts/ by default):
#
# 1. The file checks clean as written.
# 2. Each label in the row is needed: with that label removed (the last one
#    becomes `allows ()`), `vibe check` must refuse the file. A label the file
#    still checks clean without is authority it does not use -- `Stderr` next
#    to `Console` is one, since `Console` already authorizes it.
# 3. The refusal is actionable: an `effect row mismatch` that names what is
#    missing and the edit (`hint: change 'allows ...' to ...`). A refusal for
#    any other reason proves nothing about the grant.
# 4. A whole capability is not granted where some of its operations are all
#    the file uses: removing `Fs` must be refused for `Fs` itself, not only for
#    `Fs::read_bytes`. A label is wider than a callee's declared row only when
#    that row says so; narrowing a callee's row is its own change.
#
# The check runs at compile time, so a refused grant never reaches the tool's
# own logic. Probes are written next to the file (relative imports must still
# resolve) under a dot-name, and removed on exit.
#
# VIBE_GRANTS_JOBS (default 4) bounds the concurrent `vibe check` calls.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- one probe: <cli> <file> <line> <label> --------------------------------
if [ "${1:-}" = "--probe" ]; then
  cli="$2"; file="$3"; line="$4"; label="$5"
  probe="$(dirname "$file")/.grant_probe_$$_$(basename "$file")"
  trap 'rm -f "$probe"' EXIT
  awk -v L="$line" -v X="$label" '
    NR == L {
      i = index($0, " allows ")
      head = substr($0, 1, i + 7); rest = substr($0, i + 8)
      j = index(rest, " {"); row = substr(rest, 1, j - 1); tail = substr(rest, j)
      n = split(row, parts, / \+ /); out = ""
      for (k = 1; k <= n; k++) if (parts[k] != X) out = out (out == "" ? "" : " + ") parts[k]
      if (out == "") out = "()"
      $0 = head out tail
    }
    { print }' "$file" > "$probe"
  status=0
  out="$(VIBE_CLI_WASM="$cli" VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" \
    bash "$ROOT_DIR/runtime/vibe" check "$probe" 2>&1)" || status=$?
  where="$file:$line"
  if [ "$status" = 0 ]; then
    printf 'FAIL %s: `%s` is not needed -- the file checks clean without it; drop it from `allows`\n' "$where" "$label"
  elif ! grep -q 'effect row mismatch' <<< "$out" || ! grep -q "hint: change 'allows" <<< "$out"; then
    printf 'FAIL %s: dropping `%s` was refused, but not as a missing grant with an edit to make:\n' "$where" "$label"
    printf '%s\n' "$out" | head -3 | sed 's/^/       /'
  else
    # A coarse label is also too wide when what the refusal asks for is only
    # some of its operations: `allows Fs` for a script that only reads is
    # `allows Fs::read_bytes`. A parameterized effect (`Exception[String]`)
    # counts as the label itself.
    missing="$(grep -o 'missing { [^}]* }' <<< "$out" | sed 's/^missing { //; s/ }$//' | tr ',' '\n' | sed 's/^ *//' | sort -u)"
    # `Console` also authorizes the legacy tty labels and their operations.
    family="$label"
    [ "$label" = Console ] && family="Console|Stdin|Stdout|Stderr"
    coarse="$(grep -cxE "($family)(\\[.*\\])?" <<< "$missing" || true)"
    ops="$(grep -E "^($family)::" <<< "$missing" | paste -sd'+' - | sed 's/+/ + /g' || true)"
    case "$label" in
      *::*) printf 'ok %s %s\n' "$where" "$label" ;;
      *) if [ "$coarse" = 0 ] && [ -n "$ops" ]; then
           printf 'FAIL %s: `%s` is wider than its use -- the file needs only `%s`\n' "$where" "$label" "$ops"
         else
           printf 'ok %s %s\n' "$where" "$label"
         fi ;;
    esac
  fi
  exit 0
fi

CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: check_vibex_grants.sh <cli.wasm> [file.vibex ...]" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
shift
files=("$@")
if [ "${#files[@]}" = 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(find scripts -name '*.vibex' ! -name '.*' | LC_ALL=C sort)
fi
[ "${#files[@]}" -gt 0 ] || { echo "[vibex-grants] FAIL: no .vibex file to check" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibex-grants.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail=0
: > "$WORK/tasks"
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "[vibex-grants] FAIL $f: no such file" >&2; fail=1; continue; }
  out="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" bash runtime/vibe check "$f" 2>&1)" \
    || { echo "[vibex-grants] FAIL $f: does not check clean as written:" >&2; printf '%s\n' "$out" | head -3 | sed 's/^/       /' >&2; fail=1; continue; }
  # The declarations, not doc comments that quote one.
  found=0
  while IFS=: read -r ln text; do
    row="$(printf '%s' "$text" | sed -E 's/.* allows ([^{]*[^ {]) *\{.*/\1/')"
    [ "$row" = "()" ] && continue
    found=1
    printf '%s\n' "$row" | sed 's/ + /\n/g' | while IFS= read -r label; do
      printf '%s\t%s\t%s\n' "$f" "$ln" "$label" >> "$WORK/tasks"
    done
  done < <(grep -nE '^[[:space:]]*(export[[:space:]]+)?fn [^/]* allows [^{]+\{' "$f" || true)
  if [ "$found" = 0 ] && grep -qE '^[[:space:]]*fn main\b' "$f"; then
    echo "[vibex-grants] FAIL $f: \`fn main\` declares no \`allows\` row this gate can read" >&2; fail=1
  fi
done

tr '\t\n' '\0\0' < "$WORK/tasks" | xargs -0 -n 3 -P "${VIBE_GRANTS_JOBS:-4}" \
  bash "$ROOT_DIR/scripts/check_vibex_grants.sh" --probe "$CLI" > "$WORK/results" || true
probes="$(grep -c . "$WORK/tasks" || true)"
answered="$(grep -c '^\(ok\|FAIL\) ' "$WORK/results" || true)"
if grep -q '^FAIL ' "$WORK/results"; then
  grep -A3 '^FAIL ' "$WORK/results" | grep -v '^ok \|^--$' >&2
  fail=1
fi
if [ "$answered" != "$probes" ]; then
  echo "[vibex-grants] FAIL: $probes label probes, $answered answered -- a probe died" >&2; fail=1
fi
[ "$fail" = 0 ] || exit 1
echo "[vibex-grants] ok (${#files[@]} files, $probes grant labels: each one needed, and dropping it is refused with the edit)"
