#!/usr/bin/env bash
# check_tutorial_translation_parity.sh -- keep book/src tour chapters and
# book/ja translations from drifting apart.
#
# AGENTS.md "Language and documentation policy" makes the English chapter the
# source of truth and the `-ja` file a translation of prose and comments only:
# the program in each ```vibe run block stays the same program. That invariant
# is what makes the pair maintainable -- fix a bug in one chapter and the other
# needs a prose edit, not a re-derivation.
#
# `scripts/vibe_md.sh check` already proves each file individually: every block
# compiles, runs, and matches its own recorded ```output. What it cannot see is
# the pair. So the check here is exactly the part that survives that: two files
# that run the same programs record the same outputs, in the same order. If the
# code in one copy drifts, either its own output block goes stale (vibe_md.sh
# catches it) or the output changes (this catches it).
#
# Comparing outputs rather than sources is deliberate. The sources legitimately
# differ -- comments are translated -- so a source diff would be noise, and
# normalizing comments away would just re-encode the same guess about which
# differences are allowed.
#
# Usage: bash scripts/check_tutorial_translation_parity.sh
# Exit 0 = every chapter has a translation and every pair agrees.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tutorial_dir="$repo_root/book/src"
ja_dir="$repo_root/book/ja"

# Emit the ```output blocks of a .vibe.md, in order, with a separator between
# them so that "same text, different block boundaries" is still a difference.
extract_outputs() {
  awk '
    /^```output$/ { inblock = 1; next }
    /^```$/       { if (inblock) { print "---end-of-output-block---"; inblock = 0 }; next }
    inblock       { print }
  ' "$1"
}

fail=0

shopt -s nullglob
english=("$tutorial_dir"/[0-9][0-9]_*.vibe.md)
shopt -u nullglob

if [ ${#english[@]} -eq 0 ]; then
  echo "check-tutorial-translation-parity: FAIL: no chapters found under book/src" >&2
  exit 1
fi

for en in "${english[@]}"; do
  case "$en" in
    *-ja.vibe.md) continue ;;
  esac

  ja="$ja_dir/$(basename "$en")"
  if [ ! -f "$ja" ]; then
    # New English-only book chapters are allowed. The original tour pair
    # (01..07) must keep a translation under book/ja/.
    case "$(basename "$en")" in
      01_values_functions.vibe.md|02_control_flow.vibe.md|03_data.vibe.md|04_option.vibe.md|05_effects.vibe.md|06_tests.vibe.md|07_modules_packages.vibe.md)
        echo "check-tutorial-translation-parity: FAIL: $(basename "$en") has no translation" >&2
        echo "  expected book/ja/$(basename "$en")" >&2
        fail=1
        ;;
    esac
    continue
  fi

  if ! diff -u \
      --label "$(basename "$en") output blocks" \
      --label "$(basename "$ja") output blocks" \
      <(extract_outputs "$en") <(extract_outputs "$ja"); then
    echo "check-tutorial-translation-parity: FAIL: $(basename "$en") and its translation ran different programs" >&2
    echo '  The two files must run the SAME programs, so their ```output blocks must match.' >&2
    echo "  Port the code change to both, then: bash scripts/vibe_md.sh write book/src/*.vibe.md book/ja/*.vibe.md" >&2
    fail=1
  fi
done

# A translation whose canonical chapter is gone is the same drift seen from the
# other side -- it will never be checked or updated again.
shopt -s nullglob
for ja in "$ja_dir"/[0-9][0-9]_*.vibe.md; do
  en="$tutorial_dir/$(basename "$ja")"
  if [ ! -f "$en" ]; then
    echo "check-tutorial-translation-parity: FAIL: book/ja/$(basename "$ja") has no canonical English chapter" >&2
    echo "  expected book/src/$(basename "$ja") -- the translation is the copy, not the source." >&2
    fail=1
  fi
done
shopt -u nullglob

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check-tutorial-translation-parity: ok (${#english[@]} chapters incl. translations)"
