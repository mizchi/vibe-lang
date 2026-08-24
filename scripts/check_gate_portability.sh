#!/usr/bin/env bash
# Gates must be able to RUN, and their patterns must mean what they look like.
#
# Two failure modes, both measured in #2252, both of which produced a gate that
# reported an answer nobody could act on:
#
#   1. `rg` (ripgrep) is installed in the dev container and NOT in CI. Five
#      self-tests failed there with `rg: command not found` -- a failure that
#      says nothing about the property under test, so they were exempted rather
#      than fixed, and the gates behind them went unchecked for weeks. POSIX
#      `grep` is always present.
#
#   2. `grep -E` does not interpret `\t`. Converting `rg -q '^x:finding\t'` to
#      `grep -qE '^x:finding\t'` silently rewrites the pattern to `...findingt`,
#      which never matches -- so the check answers "no finding" forever and
#      still exits 0 wherever that is the passing side. Tabs belong in ANSI-C
#      quoting: `grep -qE $'^x:finding\t'`. `\d` is the same trap (grep has no
#      `\d`; `\s`, `\w` and `\b` are real GNU extensions and stay allowed).
#
# Both are lexical, so both are decidable from the text.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${VIBE_GATE_PORTABILITY_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_DIR="$ROOT/scripts"
SELF="$(basename "$0")"
SELF_TEST="${SELF%.sh}_test.sh"

if [ ! -d "$SCAN_DIR" ]; then
  echo "[gate-portability] FAIL: nothing to scan: $SCAN_DIR" >&2
  exit 1
fi

# A gate must not be able to see itself. The rules below are spelled out in
# this file's own comments and regex literals, and its self-test carries
# deliberate violations as fixtures; a checker that reads either as evidence
# certifies exactly what it exists to reject (#2138 hit that twice).
# No `| sort`: under `pkf run` the nix PATH puts a `sort` on it that dies with a
# GLIBC mismatch, and a gate that cannot run in the runner that invokes it is
# the exact failure this gate exists to stop. The order of findings is
# cosmetic; the verdict is not.
#
# No `xargs -r` either: `-r`/`--no-run-if-empty` is a GNU extension that stock
# BSD/macOS xargs rejects, which would abort this gate -- the same defect, in
# the gate written to stop it (#2248 review). The list is collected into an
# array and its emptiness is decided here instead.
scan_files=()
while IFS= read -r f; do
  case "$(basename "$f")" in "$SELF" | "$SELF_TEST") continue ;; esac
  scan_files+=("$f")
done < <(find "$SCAN_DIR" -type f -name '*.sh')

if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "[gate-portability] FAIL: no shell scripts found under $SCAN_DIR" >&2
  exit 1
fi

findings="$(
  awk -v root="$ROOT/" '
    FNR == 1 { rel = FILENAME; sub("^" root, "", rel) }

    # Whole-line comments carry no behaviour. An inline `#` can sit inside a
    # pattern, so only the unambiguous form is dropped.
    /^[[:space:]]*#/ { next }

    # 1. ripgrep, anywhere it is spelled as its own word. Deliberately blunt:
    #    "do not write rg in a gate" is the rule, and a mention inside a
    #    message string is a mention that will be copied into a call.
    #
    #    Two alternatives, because `/` cannot be treated the same on both
    #    sides. On the RIGHT it must stay excluded (`rg/` is a directory, not
    #    the tool). On the LEFT excluding it let `/usr/bin/rg -q ...` through
    #    entirely -- an absolute path is the straightforward way to bring the
    #    dependency back with this audit still green (#2248 review). So a
    #    path ending in `/rg` is matched explicitly.
    /(^|[^A-Za-z0-9_.\/-])rg([^A-Za-z0-9_.\/-]|$)/ ||
    /(^|[^A-Za-z0-9_.-])[A-Za-z0-9_.\/-]*\/rg([^A-Za-z0-9_.\/-]|$)/ {
      printf "  %s:%d: uses `rg`; CI has no ripgrep -- use grep (-E/-F/-q/-n/-o)\n", rel, FNR
      next
    }

    # 3. `sed -i` with no suffix. GNU takes an optional one, BSD/macOS REQUIRES
    #    one, so the bare form aborts there. Lexical, and a real instance:
    #    check_book_console_test.sh -- a release-check dependency -- used it,
    #    so the default gate could not run on the environment this file exists
    #    to protect (#2248 review). `sed -i.bak` and `sed -i ''` both pass.
    /(^|[^A-Za-z0-9_.-])sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i([[:space:]]|$)/ {
      printf "  %s:%d: `sed -i` with no suffix; BSD/macOS requires one -- use a temp file, or `sed -i.bak` and remove it\n", rel, FNR
      next
    }

    # 2. a grep pattern in PLAIN single quotes carrying \t or \d.
    #
    #    Judged per pipeline segment, not per line: `awk -F%s\t%s ... | grep -qx X`
    #    is correct, because awk does interpret \t, and a line-wide match
    #    reported it as a grep defect. A quoted literal only means anything
    #    here if it belongs to the grep command.
    {
      n = split($0, seg, "|")
      for (i = 1; i <= n; i++) {
        if (seg[i] !~ /(^|[^A-Za-z0-9_.])grep([[:space:]]|$)/) continue
        # BOTH quote styles. `grep -qE "^row\tvalue$"` is exactly as broken as
        # the single-quoted spelling -- double quotes do not make the shell
        # produce a tab either (#2248 review). Only `$'"'"'...'"'"'` does, and its
        # opening quote is preceded by `$`, which the first alternative excludes.
        if (seg[i] ~ /(^|[^$])'"'"'[^'"'"']*\\[td]/ || seg[i] ~ /"[^"]*\\[td]/) {
          printf "  %s:%d: grep pattern contains \\t or \\d; grep does not interpret them -- use $%s...%s\n", rel, FNR, "'"'"'", "'"'"'"
          break
        }
      }
    }
  ' "${scan_files[@]}"
)"

if [ -n "$findings" ]; then
  echo "[gate-portability] FAIL: gates that cannot run, or patterns that do not mean what they say:" >&2
  printf '%s\n' "$findings" >&2
  exit 1
fi

echo "[gate-portability] ok (no ripgrep dependency; no bare sed -i; no uninterpreted \\t in grep patterns)"
