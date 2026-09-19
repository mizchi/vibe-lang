#!/usr/bin/env bash
# The `vibe.*` host import surface, pinned (#1346 criterion 5).
#
# 0.1.0 freezes this surface, and until now nothing said what it contains. The
# one list in the tree was `runtime/viberun/expected_imports.txt`, 32
# `__moonbit_fs_unstable` fields from a host retired in #594, read by nothing
# -- exactly the "second hand-maintained implementation list" this issue says
# the contract must not preserve. So this gate reads the EMITTERS and compares
# them to a checked-in inventory, and the inventory is regenerated from them
# rather than edited by hand.
#
# Three relations, and the first is what makes the other two trustworthy:
#
#   1. The linear emitter writes a module name and then a field name per
#      import. The number of `"vibe"` module emissions must equal the number of
#      fields extracted after them. If the emitter's SHAPE changes, those two
#      numbers diverge and this fails -- rather than the extraction silently
#      reading a subset and the inventory agreeing with a lie.
#   2. Every field must match the inventory, both ways. A new, renamed or
#      removed host import is an ABI change for every host that links these
#      fields; here it is a deliberate edit to a checked-in file.
#   3. The gc backend's fields must be a SUBSET of the linear ones, with the
#      arities it declares. A gc-only import would break every host that knows
#      only the linear surface.
#
# This gate deliberately does NOT judge the spelling. Measured, five fields are
# hyphenated (`args-get`, `args-len`, `env-get`, `profile-heap-bytes`,
# `profile-now-us`) and the rest underscored; which way that should go is an
# ABI decision for the owner (#1346). Pinning it means whichever is chosen, the
# change is visible.
#
# Usage:
#   bash scripts/check_sync_host_imports.sh
#   bash scripts/check_sync_host_imports.sh --print   # regenerate the inventory
#   SYNC_HOST_IMPORTS_LINKED=<path> SYNC_HOST_IMPORTS_GC=<path> \
#     SYNC_HOST_IMPORTS_TSV=<path> bash scripts/check_sync_host_imports.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LINKED="${SYNC_HOST_IMPORTS_LINKED:-lib/@vibe/compiler/codegen/wasi/linked_compile.vibe}"
GC="${SYNC_HOST_IMPORTS_GC:-lib/@vibe/compiler/codegen/gc/backend_body.vibe}"
TSV="${SYNC_HOST_IMPORTS_TSV:-scripts/sync_host_import_surface.tsv}"

for f in "$LINKED" "$GC"; do
  if [ ! -f "$f" ]; then
    echo "[sync-host-imports] FAIL: emitter source not found: $f" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_sync_host_imports.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Relation 1's two numbers. `emit_name(import_content, "vibe")` precedes each
# capability import's field name.
module_lines="$(grep -c 'emit_name(import_content, "vibe")' "$LINKED" || true)"
awk '/emit_name\(import_content, "vibe"\)/ {
       getline
       if (match($0, /"[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2)
     }' "$LINKED" | sort -u > "$WORK/linear.txt"
field_lines="$(grep -c . "$WORK/linear.txt" || true)"

if [ "$module_lines" != "$field_lines" ]; then
  echo "[sync-host-imports] FAIL: the linear emitter emitted \"vibe\" $module_lines time(s)" >&2
  echo "  but $field_lines distinct field name(s) followed those lines." >&2
  echo "  The extraction assumes module-then-field on consecutive lines; if the" >&2
  echo "  emitter's shape changed, fix this gate rather than the inventory --" >&2
  echo "  a subset read silently would make the inventory agree with a lie." >&2
  exit 1
fi

if [ "$field_lines" -eq 0 ]; then
  echo "[sync-host-imports] FAIL: read zero host imports from $LINKED." >&2
  echo "  An empty surface is not a pass; it is an unchecked one." >&2
  exit 1
fi

# The gc backend declares ("field", arity) pairs.
awk '/\("[a-z][a-z0-9_-]*", [0-9]+\)/ {
       if (match($0, /"[a-z][a-z0-9_-]*"/)) {
         n = substr($0, RSTART + 1, RLENGTH - 2)
         if (match($0, /, [0-9]+\)/)) print n "\t" substr($0, RSTART + 2, RLENGTH - 3)
       }
     }' "$GC" | sort -u > "$WORK/gc.txt"

if [ "${1:-}" = "--print" ]; then
  echo "# The \`vibe.*\` host import surface the shipped compiler EMITS (#1346 criterion 1)."
  echo "# Read off the emitters, not maintained by hand: regenerate with"
  echo "#   bash scripts/check_sync_host_imports.sh --print"
  echo "# and check the diff. \`scripts/check_sync_host_imports.sh\` fails when the"
  echo "# emitters and this file disagree, so a new, renamed or removed host import"
  echo "# is a deliberate edit here rather than a silent ABI change."
  echo "#"
  echo "# Columns: FIELD, then the gc backend's arity where it emits one ('-' when"
  echo "# only the linear backend does). The gc set is a strict SUBSET: a gc-only"
  echo "# import would break every host that knows the linear surface."
  echo "#"
  while read -r field; do
    arity="$(awk -F'\t' -v k="$field" '$1 == k { print $2 }' "$WORK/gc.txt" | head -1)"
    printf '%s\t%s\n' "$field" "${arity:--}"
  done < "$WORK/linear.txt"
  exit 0
fi

if [ ! -f "$TSV" ]; then
  echo "[sync-host-imports] FAIL: inventory not found: $TSV" >&2
  echo "  create it with: bash scripts/check_sync_host_imports.sh --print > $TSV" >&2
  exit 1
fi

grep -v '^#' "$TSV" | grep -c . > /dev/null 2>&1 || {
  echo "[sync-host-imports] FAIL: inventory $TSV has no rows." >&2
  exit 1
}
grep -v '^#' "$TSV" | grep . | cut -f1 | sort -u > "$WORK/want.txt"

status=0

# Relation 2, both directions, each named rather than a bare diff.
if ! comm -23 "$WORK/linear.txt" "$WORK/want.txt" | grep -q .; then :; else
  echo "[sync-host-imports] FAIL: the emitter has host import(s) the inventory does not:" >&2
  comm -23 "$WORK/linear.txt" "$WORK/want.txt" | sed 's/^/  + /' >&2
  status=1
fi
if ! comm -13 "$WORK/linear.txt" "$WORK/want.txt" | grep -q .; then :; else
  echo "[sync-host-imports] FAIL: the inventory has host import(s) the emitter does not:" >&2
  comm -13 "$WORK/linear.txt" "$WORK/want.txt" | sed 's/^/  - /' >&2
  status=1
fi

# Relation 3: gc is a subset, and its arities match what the inventory records.
cut -f1 "$WORK/gc.txt" | sort -u > "$WORK/gc_fields.txt"
if comm -23 "$WORK/gc_fields.txt" "$WORK/linear.txt" | grep -q .; then
  echo "[sync-host-imports] FAIL: the gc backend emits host import(s) the linear one does not:" >&2
  comm -23 "$WORK/gc_fields.txt" "$WORK/linear.txt" | sed 's/^/  gc-only: /' >&2
  echo "  A host that knows only the linear surface cannot link a gc-only import." >&2
  status=1
fi
while IFS="$(printf '\t')" read -r field arity; do
  case "$field" in ''|'#'*) continue ;; esac
  [ "$arity" = "-" ] && continue
  got="$(awk -F'\t' -v k="$field" '$1 == k { print $2 }' "$WORK/gc.txt" | head -1)"
  if [ -z "$got" ]; then
    echo "[sync-host-imports] FAIL: $field: the inventory records gc arity $arity, the gc emitter declares none" >&2
    status=1
  elif [ "$got" != "$arity" ]; then
    echo "[sync-host-imports] FAIL: $field: gc arity $got, inventory says $arity" >&2
    status=1
  fi
done < "$TSV"

if [ "$status" -ne 0 ]; then
  echo "  If the change is deliberate: bash scripts/check_sync_host_imports.sh --print > $TSV" >&2
  exit 1
fi

gc_n="$(grep -c . "$WORK/gc_fields.txt" || true)"
echo "[sync-host-imports] ok ($field_lines vibe.* fields; $gc_n also emitted by the gc backend)"
