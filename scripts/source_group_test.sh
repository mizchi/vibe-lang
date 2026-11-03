#!/usr/bin/env bash
# Self-test for scripts/source_group.vibe (#3672), the vibe port of
# scripts/source_files.py's `read_source_group`.
#
# Both implementations serve gates until the last Python caller is ported, so
# the property is that they AGREE, byte for byte, and that the agreement is
# about the right answer:
#
#   1. On the real tree: every facade under lib/, the Rust runner's `mod`
#      group, the JS host's `require` group, and one ordinary file. The list
#      of facades is read from the tree (fewer than 20 means the marker
#      changed and this test can no longer see its subject).
#   2. On synthetic trees, the cases source_files_test.py pins, each checked
#      for its own answer as well as for parity: a cycle is read once, an
#      unreachable decoy is not read, an import outside the directory is not
#      scanned, a dependency outside the facade's prefix is not absorbed, an
#      ordinary file is not flattened -- and a missing module fails closed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The guest reads only inside the repository, so the trees live under _build/.
WORK="_build/source_group_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "source-group-test: FAIL: $*" >&2; exit 1; }

vibe_group() { bash scripts/vibe_run.sh scripts/source_group.vibex -- "$@"; }

# Python's answer in the CLI's format: a header per group when there are
# several.
python_group() {
  python3 - "$@" <<'PYEOF'
import sys
sys.path.insert(0, "scripts")
from source_files import read_source_group
paths = sys.argv[1:]
marker = "// Compatibility exports; implementations are grouped by their dependencies."
for p in paths:
    if len(paths) > 1:
        sys.stdout.write("==> %s <==\n" % p)
    sys.stdout.write(read_source_group(p).replace(marker, "// Flattened source group for a gate mutation."))
PYEOF
}

agree() { # <label> <path>...
  local label="$1"
  shift
  vibe_group "$@" >"$WORK/vibe.out" 2>"$WORK/vibe.err" \
    || { cat "$WORK/vibe.err" >&2; fail "$label: source_group.vibex failed"; }
  python_group "$@" >"$WORK/python.out"
  cmp -s "$WORK/vibe.out" "$WORK/python.out" \
    || { diff "$WORK/python.out" "$WORK/vibe.out" | head -20 >&2 || true; fail "$label: the vibe and Python groups differ"; }
}

# --- 1. the real tree --------------------------------------------------------

facades=()
while IFS= read -r f; do facades+=("$f"); done < <(grep -rlF --include='*.vibe' -e "// Compatibility exports; implementations are grouped" lib | LC_ALL=C sort)
[ "${#facades[@]}" -ge 20 ] \
  || fail "found ${#facades[@]} facades under lib/; the marker changed and this test no longer sees its subject"
real=("${facades[@]}" runtime/viberun/src/main.rs scripts/wasm_vibe_host_runner.js lib/@vibe/cli/commands/plans.vibe)
agree "real tree" "${real[@]}"
# The groups have to be groups: a facade that read as itself alone would agree
# with a Python that did the same.
for f in runtime/viberun/src/main.rs scripts/wasm_vibe_host_runner.js lib/@vibe/compiler/codegen/gc/backend_body.vibe; do
  [ "$(vibe_group "$f" 2>/dev/null | wc -c)" -gt "$(wc -c < "$f")" ] \
    || fail "real tree: the group of $f is no larger than the file; nothing was followed"
done
echo "source-group-test: ok: ${#real[@]} real groups agree (${#facades[@]} facades, mod, require, one ordinary file)"

# --- 2. synthetic trees ------------------------------------------------------

marker="// Compatibility exports; implementations are grouped by their dependencies."
G="$WORK/root/wasi"
reset_tree() {
  rm -rf "$WORK/root"
  mkdir -p "$G"
  printf '%s\nexport ./linked_compile_api.vibe { compile }\n' "$marker" > "$G/linked_compile.vibe"
  printf 'import ./linked_module_preparation.vibe { finish }\n' > "$G/linked_compile_api.vibe"
  printf 'import ./linked_compile_module_sections.vibe { emit }\nimport ./linked_compile.vibe { compile }\n' \
    > "$G/linked_module_preparation.vibe"
  printf 'fn emit() { emit_name(import_content, "fs_publish_immutable_text") }\n' \
    > "$G/linked_compile_module_sections.vibe"
}
needle='emit_name(import_content, "fs_publish_immutable_text")'

reset_tree
printf 'UNREACHABLE_DECOY\n' > "$G/linked_compile_unreachable.vibe"
agree "cycle" "$G/linked_compile.vibe"
[ "$(grep -cF -- "$needle" "$WORK/vibe.out")" = 1 ] || fail "cycle: the relocated section is not read exactly once"
grep -qF UNREACHABLE_DECOY "$WORK/vibe.out" && fail "cycle: an unreachable file in the directory was read"
echo "source-group-test: ok: a cycle is read once, and an unreachable decoy is not read"

reset_tree
cp "$G/linked_compile_module_sections.vibe" "$G/linked_compile_decoy.vibe"
printf 'fn emit() { () }\n' > "$G/linked_compile_module_sections.vibe"
agree "decoy" "$G/linked_compile.vibe"
grep -qF -- "$needle" "$WORK/vibe.out" && fail "decoy: a decoy stood in for the mutated section"
echo "source-group-test: ok: a decoy cannot stand in for a mutated section"

reset_tree
printf 'OUTSIDE_DECOY\n' > "$WORK/root/outside.vibe"
printf 'import ../outside.vibe { outside }\n' >> "$G/linked_compile_module_sections.vibe"
agree "outside" "$G/linked_compile.vibe"
grep -qF OUTSIDE_DECOY "$WORK/vibe.out" && fail "outside: an import outside the directory was scanned"
echo "source-group-test: ok: an import outside the facade's directory is not scanned"

reset_tree
printf '%s\nexport ./user_dispatch_impl.vibe { dispatch }\n' "$marker" > "$G/user_dispatch.vibe"
printf 'import ./cli_support.vibe { support }\nOWNED_DISPATCH\n' > "$G/user_dispatch_impl.vibe"
printf 'UNOWNED_DISPATCH_DEPENDENCY\n' > "$G/cli_support.vibe"
agree "prefix" "$G/user_dispatch.vibe"
grep -qF OWNED_DISPATCH "$WORK/vibe.out" || fail "prefix: the facade's own implementation was not read"
grep -qF UNOWNED_DISPATCH_DEPENDENCY "$WORK/vibe.out" && fail "prefix: a dependency outside the facade's prefix was absorbed"
echo "source-group-test: ok: a dependency outside the facade's prefix is not absorbed"

reset_tree
printf 'import ./linked_module_preparation.vibe { finish }\nfn ordinary() { () }\n' > "$G/ordinary.vibe"
agree "ordinary" "$G/ordinary.vibe"
cmp -s "$WORK/vibe.out" <(cat "$G/ordinary.vibe"; printf '\n') || fail "ordinary: a file that is not a facade was flattened"
echo "source-group-test: ok: an ordinary file is not flattened"

reset_tree
rm "$G/linked_compile_module_sections.vibe"
if vibe_group "$G/linked_compile.vibe" >"$WORK/vibe.out" 2>"$WORK/vibe.err"; then
  fail "missing: a group with a missing module printed instead of failing"
fi
grep -qF "linked_compile_module_sections.vibe is part of the source group" "$WORK/vibe.err" \
  || { cat "$WORK/vibe.err" >&2; fail "missing: failed without naming the missing module"; }
if python_group "$G/linked_compile.vibe" >/dev/null 2>&1; then
  fail "missing: the Python helper no longer fails closed, so the two disagree"
fi
echo "source-group-test: ok: a missing module fails closed, in both"

# The Rust and JS forms, on trees small enough to read.
rm -rf "$WORK/root"
mkdir -p "$WORK/root/rs" "$WORK/root/js/lib"
printf 'mod host_imports;\nmod extra;\npub mod skipped;\nfn main() {}\n' > "$WORK/root/rs/main.rs"
printf 'HOST_IMPORTS\n' > "$WORK/root/rs/host_imports.rs"
printf 'EXTRA\n' > "$WORK/root/rs/extra.rs"
printf 'SKIPPED\n' > "$WORK/root/rs/skipped.rs"
printf 'const a = require("./lib/a.js");\nconst fs = require("node:fs");\n' > "$WORK/root/js/main.js"
printf 'const b = require("./b.js");\nA\n' > "$WORK/root/js/lib/a.js"
printf 'B\n' > "$WORK/root/js/lib/b.js"
agree "rust and js" "$WORK/root/rs/main.rs" "$WORK/root/js/main.js"
for want in HOST_IMPORTS EXTRA A B; do
  grep -qx -- "$want" "$WORK/vibe.out" || fail "rust and js: $want was not followed"
done
grep -qx SKIPPED "$WORK/vibe.out" && fail "rust and js: a \`pub mod\` line was followed"
echo "source-group-test: ok: \`mod NAME;\` and \`require(\"./X.js\")\` are followed, \`pub mod\` and bare requires are not"

echo "source-group-test: ok"
