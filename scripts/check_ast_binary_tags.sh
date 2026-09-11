#!/usr/bin/env bash
# The AST binary ABI's tag tables must describe THIS compiler's AST (#2510).
#
# They did not. docs/ast_binary_abi.md shipped tag tables for the retired
# MoonBit host's AST -- `Int` / `Float` / `Record` / `Map` / `Set` /
# `ArrayBuilder`, plus whole enums (`ModuleRef`, `ParamLabel`, `EffectAtom`)
# this compiler has never had. `src/` was removed in #594; the tables outlived
# it by a year because nothing compared them to anything. Implementing that
# document would have encoded a shape the compiler does not have.
#
# Tag assignment is a FORWARD-COMPATIBILITY CONTRACT: the format promises a new
# variant takes a new tag and an old consumer raises UnknownTag rather than
# misreading. A table that names variants the AST does not have, or omits ones
# it does, breaks that promise silently -- an encoder written from it produces
# bytes no reader can interpret, and nothing fails until something reads them.
#
# So this checks what must hold forever:
#   - each enum's doc section exists, and its "(N variants)" count is N
#   - every declared variant has exactly one row, signature for signature
#   - every row names a variant that is actually declared
#   - tags are unique within a table
#
# It deliberately does NOT require tag == declaration position. Today they
# coincide because the tables were assigned in declaration order in one pass,
# but the contract is that a tag is FROZEN: a variant inserted mid-list later
# must take the next free tag, which would make the positions disagree while
# the format stays correct.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${VIBE_AST_BINARY_TAGS_ROOT:-$(dirname "$SCRIPT_DIR")}"

VPKG="$ROOT/lib/@vibe/ast/index.vpkg"
DOC="$ROOT/docs/ast_binary_abi.md"

for f in "$VPKG" "$DOC"; do
  if [ ! -f "$f" ]; then
    echo "[ast-binary-tags] FAIL: missing $f" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ast_binary_tags.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

status=0

for enum in TypeExpr Pat ImportKind Expr Stmt; do
  src="$tmp_dir/$enum.src"
  tags="$tmp_dir/$enum.tags"

  # Declared variants, one per line, comments stripped and trailing ';' removed.
  awk -v name="$enum" '
    $0 ~ "^export enum " name " \\{" { inside = 1; next }
    inside && /^\}/ { inside = 0 }
    inside {
      line = $0
      sub(/\/\/.*/, "", line)
      sub(/;[ \t]*$/, "", line)
      gsub(/[ \t]+/, " ", line)
      gsub(/^ | $/, "", line)
      if (line != "") print line
    }
  ' "$VPKG" > "$src"

  if [ ! -s "$src" ]; then
    echo "[ast-binary-tags] FAIL: no 'export enum $enum' found in $VPKG" >&2
    status=1
    continue
  fi

  section="$(grep -n "^### $enum tags" "$DOC" || true)"
  if [ -z "$section" ]; then
    echo "[ast-binary-tags] FAIL: docs/ast_binary_abi.md has no '### $enum tags' section" >&2
    status=1
    continue
  fi

  # Rows of that section only: stop at the next heading.
  awk -v name="$enum" -F'|' '
    $0 ~ "^### " name " tags" { inside = 1; next }
    inside && (/^###/ || /^## /) { inside = 0 }
    inside && /^\| 0x/ {
      tag = $2; sig = $3
      gsub(/[ \t]+/, " ", tag); gsub(/^ | $/, "", tag)
      gsub(/`/, "", sig); gsub(/[ \t]+/, " ", sig); gsub(/^ | $/, "", sig)
      print tag "\t" sig
    }
  ' "$DOC" > "$tags"

  declared_count="$(sed -n "s/^### $enum tags (\([0-9][0-9]*\) variants)$/\1/p" "$DOC" | head -1)"
  actual_count="$(awk 'END { print NR }' "$src")"
  if [ -z "$declared_count" ]; then
    echo "[ast-binary-tags] FAIL: '### $enum tags' heading must end with '(N variants)'" >&2
    status=1
  elif [ "$declared_count" != "$actual_count" ]; then
    echo "[ast-binary-tags] FAIL: $enum heading says $declared_count variants, $VPKG declares $actual_count" >&2
    status=1
  fi

  # Duplicate tags and the two set differences, all in awk. `sort` is POSIX
  # but is not reliably usable here: under the task runner this container's
  # `sort` dies on a glibc mismatch, which would fail this gate for a reason
  # that has nothing to do with the tag tables -- and a gate that fails for
  # an unrelated reason gets exempted rather than fixed (#2252).
  if ! awk -v enum="$enum" -v vpkg="$VPKG" '
    FILENAME == ARGV[1] { src[$0]++; order[++n] = $0; next }
    {
      split($0, parts, "\t")
      tag = parts[1]; sig = parts[2]
      if (tag in seen_tag) { dup[tag] = 1 } else { seen_tag[tag] = 1 }
      doc[sig]++
      doc_order[++m] = sig
    }
    END {
      bad = 0
      for (t in dup) {
        printf "[ast-binary-tags] FAIL: %s has a duplicate tag %s\n", enum, t > "/dev/stderr"
        bad = 1
      }
      for (i = 1; i <= n; i++) {
        v = order[i]
        if (!(v in doc)) {
          printf "[ast-binary-tags] FAIL: %s variant declared in %s has no row: %s\n", enum, vpkg, v > "/dev/stderr"
          bad = 1
        } else if (doc[v] != src[v]) {
          printf "[ast-binary-tags] FAIL: %s variant has %d rows, expected %d: %s\n", enum, doc[v], src[v], v > "/dev/stderr"
          bad = 1
        }
      }
      for (i = 1; i <= m; i++) {
        v = doc_order[i]
        if (!(v in src)) {
          printf "[ast-binary-tags] FAIL: %s row names no declared variant: %s\n", enum, v > "/dev/stderr"
          bad = 1
        }
      }
      exit bad
    }
  ' "$src" "$tags"; then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi

echo "[ast-binary-tags] ok"
