#!/usr/bin/env bash
# #1949: the documented first program must compile and run from a directory
# that cannot see the repository lib/ tree.
#
# It now DERIVES that program from the documents instead of restating it. The
# restating version passed while the documents were broken: it wrote the
# program with `printf 'fn main ... "42\\n"'`, where printf turns `\\n` into a
# real newline, while README.md and docs/install.md wrote the same line with
# `echo '...'`, where `\\n` stays two literal characters. So the gate ran
# `"42\n"` and the reader ran `"42\\n"` -- which prints `42\n` and no newline,
# under a comment claiming `-> 42`. Same failure shape as the freeze list
# before check_freeze_surface.sh read it back: a second copy that drifts.
#
# What it checks, per document:
#   1. the quickstart block exists (deleting it must not silently disable this)
#   2. the program in it compiles with no repo lib/ on the search path
#   3. its stdout equals the output the same line claims after `# ->`
# and across documents:
#   4. README.md and docs/install.md document the SAME program -- they are one
#      quickstart printed twice, and they had already drifted once.
#   5. Every document that teaches a first program names the SAME entry row.
#      Measured 2026-08-19: three of four said `fn main with Console` and
#      docs/cheatsheet.md said `fn main with Stdout` -- the legacy label, in the
#      one document CLAUDE.md tells you to read first. Both compile, so nothing
#      failed; a reader just learned a different program from the reference than
#      from the book. The shell-quickstart docs write their program inside
#      `echo '...'` and the reference docs write it in a fenced block, so this
#      compares the entry row rather than trying to parse four block shapes.
#
# Host-builtin only; this smoke does not install. The installed-toolchain
# prelude import is pinned in tests/integration/install/install_test.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-install-hello.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DOCS="README.md docs/install.md"
# Every document whose first program a newcomer might copy.
ROW_DOCS="README.md docs/install.md docs/cheatsheet.md book/en/01_getting_started.vibe.md"

# Extract `echo '<program>' > <file>.vibex` and the `# -> <expected>` on the
# following `vibe run <file>` line. Inside shell single quotes the program is
# literal, so it is emitted verbatim -- that is the point of the check.
extract() {
  ROOT_DIR="$ROOT_DIR" DOC="$1" python3 - <<'PYEOF'
import os, re, sys

path = os.path.join(os.environ["ROOT_DIR"], os.environ["DOC"])
text = open(path, encoding="utf-8").read()

m = re.search(
    r"^echo '(?P<prog>.*)' > (?P<file>[\w.-]+\.vibex)\s*$\n"
    r"^vibe run (?P=file)\s*#\s*->\s*(?P<want>.*?)\s*$",
    text, re.M)
if not m:
    sys.exit(f"no quickstart (`echo '...' > X.vibex` + `vibe run X.vibex  # -> ...`) in {os.environ['DOC']}")

# Two NUL-free lines: the program, then the expected stdout.
print(m.group("prog"))
print(m.group("want"))
PYEOF
}

unset VIBE_LIB || true
export VIBE_HOME="$WORK/empty-home"
mkdir -p "$VIBE_HOME"

bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"

first_prog=""
first_doc=""

for doc in $DOCS; do
  if ! pair="$(extract "$doc")"; then
    echo "[install-hello-smoke] FAIL: $pair" >&2
    exit 1
  fi
  prog="$(printf '%s\n' "$pair" | sed -n '1p')"
  want="$(printf '%s\n' "$pair" | sed -n '2p')"

  # 4. One quickstart, printed twice -- compare before spending a compile.
  if [ -z "$first_doc" ]; then
    first_prog="$prog"; first_doc="$doc"
  elif [ "$prog" != "$first_prog" ]; then
    echo "[install-hello-smoke] FAIL: $first_doc and $doc document different first programs." >&2
    echo "  $first_doc: $first_prog" >&2
    echo "  $doc: $prog" >&2
    exit 1
  fi

  dir="$WORK/$(printf '%s' "$doc" | tr '/.' '__')"
  mkdir -p "$dir"
  printf '%s\n' "$prog" > "$dir/hello.vibex"
  ( cd "$dir" && \
    VIBE_PREOPEN_DIR="$dir" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$seed" "hello.vibex" "hello.wasm" "main" >/dev/null 2>&1 ) || true

  if [ ! -s "$dir/hello.wasm" ]; then
    echo "[install-hello-smoke] FAIL: the first program in $doc does not compile" >&2
    echo "  program: $prog" >&2
    [ -s "$dir/hello.wasm.diag" ] && sed 's/^/  /' "$dir/hello.wasm.diag" >&2
    exit 1
  fi

  out="$(VIBE_PREOPEN_DIR="$dir" VIBE_RUNNER_EXIT_WITH_RESULT=1 \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke main "$dir/hello.wasm" \
    | tr -d '\r' | sed -n '1p')"
  out="${out%"${out##*[![:space:]]}"}"

  if [ "$out" != "$want" ]; then
    echo "[install-hello-smoke] FAIL: $doc claims '# -> $want' but the program prints '$out'." >&2
    echo "  program: $prog" >&2
    echo "  (shell single quotes are literal: '\\\\n' in the document is a backslash and an n, not a newline.)" >&2
    exit 1
  fi
done

# 5. One entry row across every document that teaches a first program.
row_first=""
row_first_doc=""
for doc in $ROW_DOCS; do
  [ -f "$ROOT_DIR/$doc" ] || { echo "[install-hello-smoke] FAIL: no such document: $doc" >&2; exit 1; }
  row="$(grep -oE 'fn main with [A-Za-z]+' "$ROOT_DIR/$doc" | head -1 || true)"
  if [ -z "$row" ]; then
    echo "[install-hello-smoke] FAIL: $doc teaches no \`fn main with <Row>\` program." >&2
    echo "  Every document a newcomer copies from must show one, so this check cannot be disabled by deleting the example." >&2
    exit 1
  fi
  if [ -z "$row_first_doc" ]; then
    row_first="$row"; row_first_doc="$doc"
  elif [ "$row" != "$row_first" ]; then
    echo "[install-hello-smoke] FAIL: the taught entry row differs between documents." >&2
    echo "  $row_first_doc: $row_first" >&2
    echo "  $doc: $row" >&2
    echo "  Both may compile -- that is why this drifted. Pick the current capability and use it everywhere." >&2
    exit 1
  fi
done

echo "[install-hello-smoke] ok ($DOCS document one first program: $first_prog -- it compiles with no repo lib/ and prints what they claim; $row_first across $ROW_DOCS)"
