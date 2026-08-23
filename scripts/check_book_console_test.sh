#!/usr/bin/env bash
# Red/green for check_book_console.sh.
#
# The gate proves book ch12's ```console transcripts by RUNNING `vibe test`,
# which needs a real stage2 and takes far too long to be a self-test that every
# gate run executes. So the cases below hand it a STUB compiler: the transcript
# comparison then fails for everyone, identically, and what each case asserts
# is the message the mutation adds ON TOP of that -- extraction, ja/en parity,
# and whether the chapter's documented 42 -> 43 edit still applies. Each of
# those is a claim the gate makes on its own inputs, and each is decidable
# without a compiler. Measured: ~0.3s per case.
#
# The control case is the load-bearing one: on an UNMUTATED tree the gate must
# emit none of those three messages, which is what makes their appearance
# attributable to the mutation rather than to the scratch tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_book_console_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "book-console self-test: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }

W="$TMP_ROOT/tree"
build_tree() {
  rm -rf "$W"
  mkdir -p "$W/scripts" "$W/book/en" "$W/book/ja" "$W/runtime"
  cp "$SCRIPT_DIR/check_book_console.sh" "$W/scripts/"
  # Symlinked, not copied: the gate must run against the real launcher and the
  # real stage2 resolver, so a change to either is exercised here too.
  ln -sf "$SCRIPT_DIR/resolve_stage2.sh" "$W/scripts/resolve_stage2.sh"
  ln -sf "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" "$W/scripts/run_wasm_vibe_host_runner.sh"
  ln -sf "$ROOT_DIR/runtime/vibe" "$W/runtime/vibe"
  cp "$ROOT_DIR/book/en/12_tests.vibe.md" "$W/book/en/"
  cp "$ROOT_DIR/book/ja/12_tests.vibe.md" "$W/book/ja/"
  : > "$W/stub.wasm"
}

# run -> always expected to exit non-zero (the stub compiler cannot produce the
# transcript); the verdict of each case is which message appears.
run() {
  if BOOK_CONSOLE_STAGE2="$W/stub.wasm" timeout 300 bash "$W/scripts/check_book_console.sh" \
      >"$TMP_ROOT/out" 2>&1; then
    fail "the gate passed with a stub compiler -- it is not running the transcripts"
  fi
}

says() { grep -qF "$1" "$TMP_ROOT/out"; }

# --- control: no mutation, so none of the three mutation messages.
build_tree
run
for m in 'console' 'translation parity' 'no longer applies'; do
  case "$m" in
    console) says 'expected exactly 2' && fail "unmutated tree reported a block-count problem" ;;
    *) says "$m" && fail "unmutated tree reported: $m" ;;
  esac
done
ok "an unmutated tree reports none of the mutation messages"

# --- the oracle is missing: fail closed, and say which override was wrong.
build_tree
if BOOK_CONSOLE_STAGE2="$W/does-not-exist.wasm" timeout 60 bash "$W/scripts/check_book_console.sh" \
    >"$TMP_ROOT/out" 2>&1; then
  fail "a missing compiler override was accepted"
fi
says 'override does not exist' || { cat "$TMP_ROOT/out" >&2; fail "missing override did not name itself"; }
ok "a missing compiler override fails closed"

# --- the chapter loses a ```console block.
build_tree
python3 - "$W/book/en/12_tests.vibe.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
out, depth, dropping, dropped = [], 0, False, False
for l in lines:
    if l.startswith("```"):
        if depth == 0:
            if l[3:].strip() == "console" and not dropped:
                dropping, dropped, depth = True, True, 1
                continue
            depth = 1
        else:
            depth = 0
            if dropping:
                dropping = False
                continue
    if not dropping:
        out.append(l)
assert dropped, "fixture did not drop a console block"
open(p, "w", encoding="utf-8").write("\n".join(out))
PY
grep -c '^```console' "$W/book/en/12_tests.vibe.md" | grep -qx 1 \
  || fail "fixture did not leave exactly one console block"
run
says 'expected exactly 2' || { cat "$TMP_ROOT/out" >&2; fail "a missing console block was accepted"; }
ok "a chapter with the wrong number of console blocks is rejected"

# --- the ja translation records a different report.
build_tree
# Asserted by CONTENT, not by a checksum: under `pkf run` the nix PATH shadows
# coreutils with binaries that die on a GLIBC mismatch (#2258), and `cksum`
# is one of them -- a fixture guard that cannot run is worse than none.
sed -i 's/^ok   demo_test\.vibe$/ok   demo_test.vibe (edited)/' "$W/book/ja/12_tests.vibe.md"
grep -qF 'ok   demo_test.vibe (edited)' "$W/book/ja/12_tests.vibe.md" || fail "ja fixture did not land"
run
says 'translation parity' || { cat "$TMP_ROOT/out" >&2; fail "a ja/en transcript divergence was accepted"; }
ok "a ja transcript that differs from en is rejected"

# --- the prose-documented edit no longer applies to the chapter's source.
build_tree
sed -i 's/assert_eq(double(21), 42)/assert_eq(double(21), 40 + 2)/' "$W/book/en/12_tests.vibe.md"
grep -qF 'assert_eq(double(21), 40 + 2)' "$W/book/en/12_tests.vibe.md" || fail "edit fixture did not land"
run
says 'no longer applies' || { cat "$TMP_ROOT/out" >&2; fail "a stale documented edit was accepted"; }
ok "a documented edit that no longer applies to the source is rejected"

echo "[book-console-test] ok"
