#!/usr/bin/env bash
# Prove book ch12's ```console transcripts against the real launcher
# `vibe test` (book-review round 3: they were the only output in the book's
# own format that no gate verified -- doctest compiles ```vibe blocks and
# checks ```output pairs, but a CLI transcript needs the VERB run for real,
# the way eval/book-review/run_probes.sh runs its `//! cli:` directives).
#
# Contract proven here:
#   - the chapter's first ```vibe block IS the demo file the transcripts run;
#   - console block 1 is the passing report for that file, verbatim;
#   - console block 2 is the failing report for the prose-documented edit
#     ("Change the expected value to 43"), verbatim, with exit 1;
#   - the ja chapter's transcripts are byte-identical to the en ones
#     (the same program prints the same report -- translation parity).
#
# Which compiler answers is explicit (the #2138 rule): the launcher runs the
# stage2 this script is handed, never whatever `pick_cli` would find.
#   BOOK_CONSOLE_STAGE2=<path>  override; otherwise scripts/resolve_stage2.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 book-console "${BOOK_CONSOLE_STAGE2:-}")" || exit 1
case "$STAGE2" in
  /*) : ;;
  *) STAGE2="$ROOT_DIR/$STAGE2" ;;
esac

fails=0
bad() { printf 'book-console: FAIL: %s\n' "$1" >&2; fails=1; }

# Extract fenced blocks from a chapter: prints each block as
#   <marker>\t<info>
# followed by its lines, so the caller can split with awk. Simpler: use
# python3 to write each wanted block to a file.
extract() { # extract <doc> <outdir>  -> writes vibe0.txt console0.txt console1.txt
  python3 - "$1" "$2" <<'PY'
import sys
doc, outdir = sys.argv[1], sys.argv[2]
lines = open(doc, encoding="utf-8").read().split("\n")
blocks = []  # (info, [lines])
cur = None
for l in lines:
    if l.startswith("```"):
        if cur is None:
            cur = (l[3:].strip(), [])
        else:
            blocks.append(cur)
            cur = None
    elif cur is not None:
        cur[1].append(l)
vibes = [b for b in blocks if b[0] == "vibe"]
consoles = [b for b in blocks if b[0] == "console"]
if not vibes:
    print("no ```vibe block found", file=sys.stderr); sys.exit(1)
if len(consoles) != 2:
    print(f"expected exactly 2 ```console blocks, found {len(consoles)}", file=sys.stderr); sys.exit(1)
open(f"{outdir}/vibe0.txt", "w").write("\n".join(vibes[0][1]) + "\n")
for i, c in enumerate(consoles):
    open(f"{outdir}/console{i}.txt", "w").write("\n".join(c[1]) + "\n")
PY
}

# run_transcript <workdir> <transcript-file> <expected-exit>
# The transcript's first line must be `$ vibe test demo_test.vibe`; the rest
# is the expected merged stdout+stderr. Runs from a FRESH cwd so the
# launcher's pass-cache cannot answer `(cached)` for a report the book shows
# uncached.
run_transcript() {
  local workdir="$1" transcript="$2" want_rc="$3"
  local cmd
  cmd="$(head -1 "$transcript")"
  if [ "$cmd" != "\$ vibe test demo_test.vibe" ]; then
    bad "unexpected transcript command: $cmd"
    return
  fi
  local rc=0
  (
    cd "$workdir"
    VIBE_RUNNER="$SHIM" VIBE_CLI_WASM="$STAGE2" VIBE_TEST_CLI_WASM="$STAGE2" \
      bash "$ROOT_DIR/runtime/vibe" test demo_test.vibe >transcript.actual 2>&1
  ) || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    bad "exit $rc, transcript implies $want_rc ($transcript)"
  fi
  tail -n +2 "$transcript" >"$workdir/transcript.expected"
  if ! diff -u "$workdir/transcript.expected" "$workdir/transcript.actual" >&2; then
    bad "transcript diverged from the launcher's real report ($transcript)"
  fi
}

WORK="$ROOT_DIR/_build/_book_console"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Launcher shim: route the compiler wasm (matched by exact path) to cli_main,
# program wasm to _start -- the same wiring run_probes.sh generates. Mode env
# vars are the launcher's to set; the shim adds none.
SHIM="$WORK/viberun"
cat >"$SHIM" <<SH
#!/usr/bin/env bash
first="\$1"; shift
if [ "\$first" = "$STAGE2" ]; then
  : "\${VIBE_PREOPEN_DIR:=\$PWD}"; export VIBE_PREOPEN_DIR
  : "\${VIBE_IMPORT_ABI:=raw}"; export VIBE_IMPORT_ABI
  exec bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "\$first" "\$@"
fi
exec bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "\$first" "\$@"
SH
chmod +x "$SHIM"

extract "book/en/12_tests.vibe.md" "$WORK" || { bad "block extraction failed (book/en/12_tests.vibe.md)"; exit 1; }

# ja parity: the program in each block is the same program, so the reports
# are the same bytes. Prove the en transcripts for real; hold ja to en.
mkdir -p "$WORK/ja"
extract "book/ja/12_tests.vibe.md" "$WORK/ja" || bad "block extraction failed (book/ja/12_tests.vibe.md)"
for i in 0 1; do
  if ! cmp -s "$WORK/console$i.txt" "$WORK/ja/console$i.txt"; then
    bad "ja console block $i differs from en (translation parity)"
  fi
done

# Pass case: the chapter's own source, verbatim.
mkdir -p "$WORK/pass"
cp "$WORK/vibe0.txt" "$WORK/pass/demo_test.vibe"
run_transcript "$WORK/pass" "$WORK/console0.txt" 0

# Fail case: the prose says "Change the expected value to 43 and the report
# names the test, shows both sides, and stops" -- apply exactly that edit.
mkdir -p "$WORK/fail"
sed 's/assert_eq(double(21), 42)/assert_eq(double(21), 43)/' "$WORK/vibe0.txt" >"$WORK/fail/demo_test.vibe"
if cmp -s "$WORK/vibe0.txt" "$WORK/fail/demo_test.vibe"; then
  bad "the documented edit (42 -> 43) no longer applies to the chapter's source"
fi
run_transcript "$WORK/fail" "$WORK/console1.txt" 1

if [ "$fails" -ne 0 ]; then
  exit 1
fi
echo "book-console: ok (2 transcripts proven against the launcher, ja parity held)"
