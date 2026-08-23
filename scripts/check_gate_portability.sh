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
findings="$(
  # No `| sort`: under `pkf run` the nix PATH puts a `sort` on it that dies
  # with a GLIBC mismatch, and a gate that cannot run in the runner that
  # invokes it is the exact failure this gate exists to stop. The order of
  # findings is cosmetic; the verdict is not.
  find "$SCAN_DIR" -type f -name '*.sh' | while IFS= read -r f; do
    case "$(basename "$f")" in "$SELF" | "$SELF_TEST") continue ;; esac
    printf '%s\n' "$f"
  done | xargs -r awk -v root="$ROOT/" '
    FNR == 1 { rel = FILENAME; sub("^" root, "", rel) }

    # Whole-line comments carry no behaviour. An inline `#` can sit inside a
    # pattern, so only the unambiguous form is dropped.
    /^[[:space:]]*#/ { next }

    # 1. ripgrep, anywhere it is spelled as its own word. Deliberately blunt:
    #    "do not write rg in a gate" is the rule, and a mention inside a
    #    message string is a mention that will be copied into a call.
    /(^|[^A-Za-z0-9_.\/-])rg([^A-Za-z0-9_.\/-]|$)/ {
      printf "  %s:%d: uses `rg`; CI has no ripgrep -- use grep (-E/-F/-q/-n/-o)\n", rel, FNR
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
        if (seg[i] ~ /(^|[^$])'"'"'[^'"'"']*\\[td]/) {
          printf "  %s:%d: grep pattern contains \\t or \\d; grep does not interpret them -- use $%s...%s\n", rel, FNR, "'"'"'", "'"'"'"
          break
        }
      }
    }
  '
)"

if [ -n "$findings" ]; then
  echo "[gate-portability] FAIL: gates that cannot run, or patterns that do not mean what they say:" >&2
  printf '%s\n' "$findings" >&2
  exit 1
fi

echo "[gate-portability] ok (no ripgrep dependency; no uninterpreted \\t in grep patterns)"
