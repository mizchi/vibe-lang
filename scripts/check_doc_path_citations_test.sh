#!/usr/bin/env bash
# Self-test for scripts/check_doc_path_citations.sh.
#
# Runs the check against a synthetic tree rather than this repository, so the
# cases stay fixed while the real backlog shrinks. Each case is one property the
# check has to have; the middle two exist because a review found them missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_doc_path_citations.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_doc_citation_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts" "$TMP/docs/spec" "$TMP/lib/@vibe/compiler/checker"
cp "$CHECK" "$TMP/scripts/"
: > "$TMP/lib/@vibe/compiler/checker/checker.vibe"
allow="$TMP/scripts/doc_path_citation_allowlist.txt"

# Run the check inside the synthetic tree.
run() { (cd "$TMP" && bash scripts/check_doc_path_citations.sh "$@" 2>&1); }

expect() { # expect <exit> <label> <needle-or-empty>
  local want="$1" label="$2" needle="${3:-}" out rc
  set +e; out="$(run)"; rc=$?; set -e
  if [ "$rc" != "$want" ]; then
    echo "doc-citation self-test: FAIL: $label -- exit $rc, wanted $want" >&2
    echo "$out" >&2
    exit 1
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" <<<"$out"; then
    echo "doc-citation self-test: FAIL: $label -- output did not mention '$needle'" >&2
    echo "$out" >&2
    exit 1
  fi
}

# A path that resolves under one of the prefixes is fine, and so is a bare
# filename (a name, not a location) and an import-syntax example.
cat > "$TMP/docs/ok.md" <<'EOF'
See `checker/checker.vibe` and `lib/@vibe/compiler/checker/checker.vibe`.
Bare names are names: `checker.vibe`, `index.vibe`, `Taskfile.pkl`.
Import syntax examples: `./foo.vibe`, `../module/path.vibe`.
EOF
: > "$allow"
expect 0 "resolving paths, bare names and import examples pass"

# A path that does not resolve fails, and says which file it was.
cat > "$TMP/docs/bad.md" <<'EOF'
See `lib/@vibe/compiler/gone/missing.vibe` for details.
EOF
expect 1 "a dangling citation fails" "lib/@vibe/compiler/gone/missing.vibe"

# Saying the file is gone is accepted -- naming a path precisely to record its
# removal is legitimate. The marker may be on a neighbouring line, since prose
# wraps.
cat > "$TMP/docs/bad.md" <<'EOF'
The old `lib/@vibe/compiler/gone/missing.vibe`
was removed in #999.
EOF
expect 0 "a citation marked as removed passes"

# The retired MoonBit host is exempt by rule: those rows are history.
cat > "$TMP/docs/bad.md" <<'EOF'
Implemented in `src/checker/typecheck_effects.mbt`.
EOF
expect 0 "src/**/*.mbt is exempt"

# Allowlisted debt passes...
cat > "$TMP/docs/bad.md" <<'EOF'
See `lib/@vibe/compiler/gone/missing.vibe`.
EOF
echo "docs/bad.md lib/@vibe/compiler/gone/missing.vibe" > "$allow"
expect 0 "allowlisted debt passes"

# ...but only in the document it was recorded against. Allowlisting a bad path
# once must not license the same path elsewhere, or the number of bad sites
# could grow with the allowlist unchanged.
cat > "$TMP/docs/spec/other.md" <<'EOF'
See `lib/@vibe/compiler/gone/missing.vibe`.
EOF
expect 1 "the allowlist is keyed by (document, path)" "docs/spec/other.md"
rm "$TMP/docs/spec/other.md"

# An entry whose document no longer cites it is deleted, not carried forever.
cat > "$TMP/docs/bad.md" <<'EOF'
Nothing dangling here any more.
EOF
expect 1 "a stale allowlist entry fails" "no longer cites"

# But an entry for a document this run did not scan is not evidence of
# staleness: the pre-commit hook lints a staged snapshot, which may not contain
# every document.
rm "$TMP/docs/bad.md"
expect 0 "an unscanned document's entry is left alone"

# Generated compiler artifacts are exempt by name -- they are build outputs, so
# a `git checkout-index` export does not contain them.
: > "$allow"
cat > "$TMP/docs/gen.md" <<'EOF'
The flat program is `lib/@vibe/compiler/_cli_adapter_module_source.vibe`,
and the fingerprint is `cache/codegen_fingerprint.vibe`.
EOF
# Both spellings: the full path, and the doc-relative one that only resolves on
# a machine where the artifact has been built. CI found the second the hard way.
expect 0 "generated artifacts are exempt by name, prefix-relative spelling too"

echo "doc-citation self-test: ok"
