#!/usr/bin/env bash
# Red test for scripts/check_gc_host_import_counts.sh (#2248).
#
# Four mutations, on a COPY of the real source. Each is a defect that actually
# happened rather than an invented one: the first two were both measured while
# #2758 added a single import, and each produced a module that failed to
# instantiate in a different way.
#
# Every case asserts the mutation LANDED before trusting the failure -- an edit
# that matches nothing passes while proving nothing -- and asserts the gate is
# green on the unmutated copy first, so a failure is attributable to the
# mutation and not to the environment (#2252).
set -euo pipefail

unset GC_HOST_IMPORT_COUNTS_SRC

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_gc_host_import_counts.sh"
REAL="lib/@vibe/compiler/codegen/gc/backend_body.vibe"
WORK="_build/_gate_gc_host_import_counts_selftest"
rm -rf "$WORK"; mkdir -p "$WORK"

fail() { echo "gc-host-import-counts-selftest: FAIL: $*" >&2; exit 1; }

# --- GREEN ------------------------------------------------------------------
if ! GC_HOST_IMPORT_COUNTS_SRC="$REAL" bash "$GATE" >"$WORK/green.log" 2>&1; then
  cat "$WORK/green.log" >&2
  fail "the gate does not pass on the tree as committed, so a later failure would prove nothing"
fi

# <case> <python mutation> <needle the failure must mention>
run_case() {
  local name="$1" mutation="$2" needle="$3"
  local copy="$WORK/$name.vibe"
  cp "$REAL" "$copy"
  python3 - "$copy" "$mutation" <<'PY'
import re, sys
path, which = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
before = s
if which == "hbo":
    s = re.sub(r"(let hbo = if use_host \{\s*)(\d+)",
               lambda m: m.group(1) + str(int(m.group(2)) - 1), s, count=1)
elif which == "vec":
    s = re.sub(r"(bytebuf_push_vec_header\(imp_content,\s*)(\d+)",
               lambda m: m.group(1) + str(int(m.group(2)) - 1), s, count=1)
elif which == "import":
    # Drop the LAST host_imports entry, as an edit that removes a builtin
    # without touching hbo would.
    s = re.sub(r',\n      \("fs_remove_tree", 1\)\n    \]', "\n    ]", s, count=1)
elif which == "dup":
    # Two host_defs entries claiming the same absolute import index.
    s = s.replace('("Fs::remove_tree", 1, 23, 0)', '("Fs::remove_tree", 1, 22, 0)', 1)
if s == before:
    sys.stderr.write(f"gc-host-import-counts-selftest: mutation '{which}' matched nothing\n")
    sys.exit(2)
open(path, "w", encoding="utf-8").write(s)
PY
  if ! diff -q "$REAL" "$copy" >/dev/null 2>&1; then :; else
    fail "mutation '$name' did not change the copy"
  fi
  if GC_HOST_IMPORT_COUNTS_SRC="$copy" bash "$GATE" >"$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    fail "the gate PASSED with mutation '$name' applied -- it cannot see that defect"
  fi
  if ! grep -qi "$needle" "$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    fail "mutation '$name' failed, but not for its own reason (wanted /$needle/)"
  fi
  echo "gc-host-import-counts-selftest:   red ok: $name"
}

run_case hbo    hbo    "hbo is"
run_case vec    vec    "vector header"
run_case import import "host_imports has"
run_case dup    dup    "not 1..N"

rm -rf "$WORK"
echo "gc-host-import-counts-selftest: ok (green on the tree; red on 4 mutations, each for its own reason)"
