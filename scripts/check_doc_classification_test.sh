#!/usr/bin/env bash
# check_doc_classification_test.sh -- red test for check_doc_classification.sh.
#
# Per AGENTS.md ("a passing gate means nothing until it is known to be able to
# fail"): every case below MUTATES a synthetic tree and asserts the gate goes
# red, with an unmutated tree as the control. The control runs FIRST, so a
# mutation that silently changed nothing shows up as "the control and the
# mutation agree" rather than as a pass.
#
# The tree is synthetic rather than the repository's own docs/, so the cases
# stay fixed while docs/ changes. The gate's ability to fail on the REAL tree
# was established separately: on the commit that introduced it, it reported all
# five documents that had drifted out of docs/README.md.
#
# #2252: the gate's own environment variable is unset at the top and set
# explicitly per case. Inheriting it from a shell (or from a session hook) is
# how five self-tests were once quietly turned into no-ops.

set -euo pipefail

unset VIBE_DOC_CLASSIFICATION_ROOT

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/check_doc_classification.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_doc_classification_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf 'doc-classification-test: ok: %s\n' "$1"; }
fail() { printf 'doc-classification-test: FAIL: %s\n' "$1" >&2; fails=1; }

# Build a well-formed synthetic tree at $1.
build_tree() {
  root="$1"
  rm -rf "$root"
  mkdir -p "$root/docs/spec" "$root/docs/report" "$root/docs/archive"
  printf '# install\n' > "$root/docs/install.md"
  printf '# syntax\n' > "$root/docs/spec/syntax.md"
  printf '# memory\n' > "$root/docs/spec/memory-contract.md"
  printf '# bench a\n' > "$root/docs/report/bench-a.md"
  printf '# bench b\n' > "$root/docs/report/bench-b.md"
  printf '# old\n' > "$root/docs/archive/old.md"
  cat > "$root/docs/README.md" <<'EOF'
# docs/

Router.

## 1. User documentation

| Current path | Later home | Notes |
| --- | --- | --- |
| [install.md](install.md) | `user/getting-started/` | |
| [spec/syntax.md](spec/syntax.md) | `user/reference/` | |
| [../book/](../book/README.md) | `user/book/` | outside docs/, skipped |

## 2. Maintainer / internal

### Design

| Current path | Later home | Notes |
| --- | --- | --- |
| [spec/memory-contract.md](spec/memory-contract.md) | `internal/design/` | |

### Reports

| Current path | Later home | Notes |
| --- | --- | --- |
| [report/](report/) | `internal/reports/` | children: [bench-a.md](report/bench-a.md) |

## 4. Archive

| Current path | Notes |
| --- | --- |
| [archive/old.md](archive/old.md) | |

## Inventory coverage

`install.md`, `spec`, `report`, `archive`
EOF
}

run_gate() { VIBE_DOC_CLASSIFICATION_ROOT="$1" bash "$gate" >"$2" 2>&1; }

# --- control: the unmutated tree passes --------------------------------------
#
# First, and load-bearing. Every case below asserts a FAILURE; if the gate
# rejected everything, they would all "pass" while proving nothing.

t="$work/control"
build_tree "$t"
if run_gate "$t" "$work/control.out"; then
  pass "control: a well-formed tree passes"
else
  fail "control: a well-formed tree was rejected -- every red case below is now meaningless"
  cat "$work/control.out" >&2
fi

# The control also proves two positive behaviours that no red case can:
#   - a file under a DIRECTORY row (report/bench-b.md, which the Notes column
#     does not mention) is classified by the directory;
#   - docs/README.md itself is not required to be classified.
if grep -q "6 documents" "$work/control.out"; then
  pass "control: the directory row covers a child the notes do not name, and the router is not in its own corpus"
else
  fail "control: expected 6 documents in the corpus, got: $(cat "$work/control.out")"
fi

# --- case 1: an unclassified document ----------------------------------------

t="$work/unclassified"
build_tree "$t"
printf '# new\n' > "$t/docs/brand-new.md"
if run_gate "$t" "$work/unclassified.out"; then
  fail "case 1: an unclassified document passed"
else
  if grep -q "brand-new.md is in no class table" "$work/unclassified.out"; then
    pass "case 1: an unclassified document fails, and the message names it"
  else
    fail "case 1: failed for the wrong reason: $(cat "$work/unclassified.out")"
  fi
fi

# --- case 2: a document claimed by two classes -------------------------------

t="$work/ambiguous"
build_tree "$t"
# Add install.md to the Archive table as well as the User table -- INSIDE the
# table, not appended to the file. Appending puts the row after
# "## Inventory coverage", where it is not a class row at all: the first
# attempt at this case did exactly that, the gate stayed green, and the case
# reported a failure it had not actually created. Verified below.
awk '
  { print }
  /^\| \[archive\/old\.md\]\(archive\/old\.md\) \| \|$/ {
    print "| [install.md](install.md) | duplicate of the user row |"
  }
' "$t/docs/README.md" > "$t/docs/README.new"
mv "$t/docs/README.new" "$t/docs/README.md"
# The mutation has to have landed inside the Archive table, i.e. before the
# "## Inventory coverage" heading. A mutation that matched nothing would let
# this case pass while proving nothing (AGENTS.md, gate discipline).
if [ "$(awk '/^## Inventory coverage/ { exit } /^\| \[install\.md\]/ { n++ } END { print n+0 }' "$t/docs/README.md")" = "2" ]; then
  pass "case 2 (mutation landed): install.md now has two rows above the coverage heading"
else
  fail "case 2: the mutation did not land -- the assertion below would prove nothing"
fi
if run_gate "$t" "$work/ambiguous.out"; then
  fail "case 2: a document in two classes passed"
else
  if grep -q "install.md is claimed by 2 classes" "$work/ambiguous.out"; then
    pass "case 2: two classes for one document fails"
  else
    fail "case 2: failed for the wrong reason: $(cat "$work/ambiguous.out")"
  fi
fi

# --- case 3: a row that points at nothing ------------------------------------
#
# This is what a move without a link rewrite leaves behind, which is the defect
# every later phase of #2002 can introduce.

t="$work/stale"
build_tree "$t"
rm "$t/docs/install.md"
if run_gate "$t" "$work/stale.out"; then
  fail "case 3: a row pointing at a deleted file passed"
else
  if grep -q "classifies docs/install.md" "$work/stale.out"; then
    pass "case 3: a stale row fails, and the message gives the router line"
  else
    fail "case 3: failed for the wrong reason: $(cat "$work/stale.out")"
  fi
fi

# --- case 4: a router the parser cannot read ---------------------------------
#
# Silence is not safety. A router whose headings or rows changed shape parses to
# zero rows, and "zero rows" would otherwise make every document unclassified
# OR -- if the logic were inverted anywhere -- make the gate vacuously green.
# It must refuse to answer instead.

t="$work/unparseable"
build_tree "$t"
# Demote the class headings so no `## <n>. ` heading remains.
sed 's/^## 1\./### 1./; s/^## 2\./### 2./; s/^## 4\./### 4./' \
  "$t/docs/README.md" > "$t/docs/README.new"
mv "$t/docs/README.new" "$t/docs/README.md"
if run_gate "$t" "$work/unparseable.out"; then
  fail "case 4: a router with no parseable class headings passed"
else
  if grep -q "parsed no rows" "$work/unparseable.out"; then
    pass "case 4: an unparseable router refuses to answer instead of passing"
  else
    fail "case 4: failed for the wrong reason: $(cat "$work/unparseable.out")"
  fi
fi

# --- case 5: an empty corpus -------------------------------------------------
#
# The other way to see nothing and call it ok.

t="$work/empty"
build_tree "$t"
find "$t/docs" -type f ! -name README.md -exec rm {} +
if run_gate "$t" "$work/empty.out"; then
  fail "case 5: an empty docs/ passed"
else
  if grep -q "found no files" "$work/empty.out"; then
    pass "case 5: an empty docs/ refuses to answer instead of passing"
  else
    fail "case 5: failed for the wrong reason: $(cat "$work/empty.out")"
  fi
fi

# --- case 6: the "## Inventory coverage" section is not a fifth class --------
#
# It lists names in backticks. If the parser treated any `## ` heading as a
# class, those names could classify documents -- and the gate would then be
# reading the router's hand-maintained list, which is the proxy it exists to
# replace.

t="$work/coverage-not-a-class"
build_tree "$t"
printf '# new\n' > "$t/docs/brand-new.md"
printf '\n| [brand-new.md](brand-new.md) | listed under coverage |\n' >> "$t/docs/README.md"
if run_gate "$t" "$work/coverage.out"; then
  fail "case 6: a row under '## Inventory coverage' classified a document"
else
  if grep -q "brand-new.md is in no class table" "$work/coverage.out"; then
    pass "case 6: a row after a non-class heading does not classify"
  else
    fail "case 6: failed for the wrong reason: $(cat "$work/coverage.out")"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "doc-classification-test: FAILED" >&2
  exit 1
fi
echo "doc-classification-test: ok (control + 6 red cases)"
