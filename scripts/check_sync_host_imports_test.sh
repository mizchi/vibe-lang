#!/usr/bin/env bash
# Red test for check_sync_host_imports.sh (#2248: a gate means nothing until it
# is shown to be able to FAIL).
#
# #1346 criterion 5 asks for "a mutation that changes one real signature or
# semantic case and is rejected", so the cases below mutate REAL inputs -- a
# copy of the emitter source and a copy of the inventory -- rather than feeding
# the gate a synthetic fixture that shares none of its shape.
#
# Every case first asserts the mutation LANDED. An edit that matched nothing
# passes while proving nothing, which is the failure this file exists to
# prevent, not to repeat.
#
# Environment: the gate's three overrides are unset at the top and set
# explicitly per case (#2252 -- five self-tests were once silent no-ops because
# they inherited a variable the session hook exported).
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

unset SYNC_HOST_IMPORTS_LINKED SYNC_HOST_IMPORTS_GC SYNC_HOST_IMPORTS_TSV || true

GATE="$ROOT_DIR/scripts/check_sync_host_imports.sh"
LINKED="lib/@vibe/compiler/codegen/wasi/linked_compile.vibe"
GC="lib/@vibe/compiler/codegen/gc/backend_body.vibe"
TSV="scripts/sync_host_import_surface.tsv"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_sync_host_imports_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

run_gate() { # <linked> <gc> <tsv>
  SYNC_HOST_IMPORTS_LINKED="$1" SYNC_HOST_IMPORTS_GC="$2" SYNC_HOST_IMPORTS_TSV="$3" \
    bash "$GATE" 2>&1 || true
}

# GREEN control first. If the unmutated inputs do not pass, every red case
# below would "fail" for a reason that has nothing to do with its mutation.
out="$(run_gate "$LINKED" "$GC" "$TSV")"
if printf '%s\n' "$out" | grep -q '^\[sync-host-imports\] ok'; then
  ok "the unmutated tree passes"
else
  bad "green control did not pass, so no red case below means anything: $out"
fi

# RED 1: the emitter gains a host import the inventory does not list. This is
# the case that matters -- adding a `vibe.*` import is an ABI change for every
# host, and today nothing else in the tree would notice.
cp "$LINKED" "$WORK/linked_add.vibe"
python3 - "$WORK/linked_add.vibe" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '  emit_name(import_content, "vibe")\n'
i = s.index(anchor)
j = s.index("\n", i + len(anchor)) + 1
s = s[:j] + '    emit_name(import_content, "vibe")\n    emit_name(import_content, "totally_new_capability")\n' + s[j:]
open(p, "w").write(s)
PY
if grep -q 'totally_new_capability' "$WORK/linked_add.vibe"; then
  out="$(run_gate "$WORK/linked_add.vibe" "$GC" "$TSV")"
  if printf '%s\n' "$out" | grep -q 'totally_new_capability'; then
    ok "an emitter that gains a host import is rejected, and the field is named"
  else
    bad "a new host import was not rejected: $out"
  fi
else
  bad "RED 1's mutation did not land -- the case would have proved nothing"
fi

# RED 2: the inventory lists a field the emitter does not emit (a rename that
# updated only one side, or a stale row left after a removal).
cp "$TSV" "$WORK/tsv_extra.tsv"
printf 'ghost_import\t-\n' >> "$WORK/tsv_extra.tsv"
if grep -q '^ghost_import' "$WORK/tsv_extra.tsv"; then
  out="$(run_gate "$LINKED" "$GC" "$WORK/tsv_extra.tsv")"
  if printf '%s\n' "$out" | grep -q 'ghost_import'; then
    ok "an inventory row with no emitter behind it is rejected, and named"
  else
    bad "a stale inventory row was not rejected: $out"
  fi
else
  bad "RED 2's mutation did not land"
fi

# RED 3: a field is RENAMED in the emitter. Both directions must fire -- the
# old name is missing and the new one is unlisted -- because a rename that only
# reported one side would read as an addition or a removal.
cp "$LINKED" "$WORK/linked_rename.vibe"
if grep -q '"fs_read_file"' "$WORK/linked_rename.vibe"; then
  # A suffixed -i is required for BSD sed and optional for GNU, so a temp file
  # is used instead (check_gate_portability.sh rejects a bare `sed -i`).
  sed 's/"fs_read_file"/"fs-read-file"/' "$WORK/linked_rename.vibe" > "$WORK/linked_rename.tmp"
  mv "$WORK/linked_rename.tmp" "$WORK/linked_rename.vibe"
  if grep -q '"fs-read-file"' "$WORK/linked_rename.vibe"; then
    out="$(run_gate "$WORK/linked_rename.vibe" "$GC" "$TSV")"
    if printf '%s\n' "$out" | grep -q 'fs-read-file' && printf '%s\n' "$out" | grep -q 'fs_read_file'; then
      ok "a renamed host import is rejected from BOTH directions"
    else
      bad "a rename was not reported both ways: $out"
    fi
  else
    bad "RED 3's rename did not land"
  fi
else
  bad "RED 3 could not find fs_read_file to rename"
fi

# RED 4: the gc backend declares a DIFFERENT arity than the inventory records.
# This is the "one real signature" case: the field name is untouched and only
# its shape moved.
cp "$GC" "$WORK/gc_arity.vibe"
if grep -q '("fs_read_file", 3)' "$WORK/gc_arity.vibe"; then
  sed 's/("fs_read_file", 3)/("fs_read_file", 9)/' "$WORK/gc_arity.vibe" > "$WORK/gc_arity.tmp"
  mv "$WORK/gc_arity.tmp" "$WORK/gc_arity.vibe"
  if grep -q '("fs_read_file", 9)' "$WORK/gc_arity.vibe"; then
    out="$(run_gate "$LINKED" "$WORK/gc_arity.vibe" "$TSV")"
    if printf '%s\n' "$out" | grep -q 'gc arity 9'; then
      ok "a changed gc arity is rejected, naming both values"
    else
      bad "a changed signature was not rejected: $out"
    fi
  else
    bad "RED 4's arity mutation did not land"
  fi
else
  bad "RED 4 could not find the ('fs_read_file', 3) pair to mutate"
fi

# RED 5: the emitter's SHAPE changes so the extraction reads a subset. The gate
# must fail rather than compare a truncated reading against the inventory and
# report whatever that happens to say -- an extraction that silently reads less
# is how a gate ends up agreeing with a lie.
cp "$LINKED" "$WORK/linked_shape.vibe"
python3 - "$WORK/linked_shape.vibe" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# One extra bare module emission with no field after it: the two counts diverge.
anchor = '  emit_name(import_content, "vibe")\n'
i = s.index(anchor)
s = s[:i] + '  emit_name(import_content, "vibe")\n  let _shape_probe = 0\n' + s[i:]
open(p, "w").write(s)
PY
if grep -q '_shape_probe' "$WORK/linked_shape.vibe"; then
  out="$(run_gate "$WORK/linked_shape.vibe" "$GC" "$TSV")"
  if printf '%s\n' "$out" | grep -q 'module-then-field'; then
    ok "an extraction that would read a subset FAILS instead of comparing it"
  else
    bad "a changed emitter shape was not detected: $out"
  fi
else
  bad "RED 5's mutation did not land"
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
