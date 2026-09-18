#!/usr/bin/env bash
# Re-freeze the bench corpus from today's sources (#2865).
#
# The corpus under bench/perf/corpus/ is a byte-for-byte copy of three compiler
# sources, taken once. Reading the LIVE files made every checker PR move the
# input of the series that measures the parser; measured on one compiler with
# only the corpus swapped, `parse_checker_vibe` went 4,926,112 -> 5,780,608 B/op
# (+17.3%) across a checker PR that grew the file 9.7%.
#
# Bumping RESETS the series: every bytes-per-op number before the bump is about
# a different input, so the perf pipeline's history across it is not a
# comparison. Do it when the frozen program has drifted far enough from real
# code to stop representing it -- not to silence a flag, and never as part of a
# PR whose numbers are being read.
#
# It rewrites the banner and PROVENANCE.tsv together, which is what keeps
# check_bench_corpus.sh able to tell a bump from an edit.
#
# Usage:
#   bash scripts/bump_bench_corpus.sh            # re-freeze at HEAD
#   bash scripts/bump_bench_corpus.sh --check    # exit 1 if a snapshot does not
#                                                # match its recorded digest
set -euo pipefail
ROOT_DIR="${VIBE_BENCH_CORPUS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

MODE="bump"
case "${1:-}" in
  --check) MODE="check" ;;
  "") ;;
  *) echo "unknown argument: $1 (expected --check)" >&2; exit 2 ;;
esac

python3 - "$MODE" <<'PY'
import hashlib, pathlib, subprocess, sys

mode = sys.argv[1]
PROV = pathlib.Path("bench/perf/corpus/PROVENANCE.tsv")
PAIRS = [
    ("lib/@vibe/compiler/checker/checker.vibe", "bench/perf/corpus/checker.vibe.txt"),
    ("lib/@vibe/parser/lexer.vibe",             "bench/perf/corpus/lexer.vibe.txt"),
    ("lib/@vibe/parser/parser.vibe",            "bench/perf/corpus/parser.vibe.txt"),
]
BANNER = (
"// FROZEN BENCH CORPUS -- NOT A SOURCE FILE.\n"
"//\n"
"// A byte-for-byte copy of {src}, taken at {rev}, read by the\n"
"// lex/parse benchmark series in lib/@vibe/compiler/{{lexer,parser}}_bench.vibe.\n"
"//\n"
"// Editing the live file used to change the INPUT of the benchmark that is\n"
"// supposed to measure the lexer and the parser, so every checker PR of any\n"
"// size tripped the bytes-per-op flag and a real parser regression landing\n"
"// beside a checker edit was indistinguishable from corpus growth (#2865).\n"
"//\n"
"// Nothing imports this file and nothing compiles it. Do not edit it to fix a\n"
"// warning, to reformat it, or to keep it in step with the live source -- that\n"
"// is the whole defect. It is bumped DELIBERATELY, by\n"
"// `bash scripts/bump_bench_corpus.sh`, which rewrites this banner and the\n"
"// recorded digest together; bench/perf/corpus/README.md says when that is\n"
"// worth doing and what it costs.\n"
"\n"
)

def read_prov():
    rows = {}
    if not PROV.exists():
        return rows
    for line in PROV.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            print("[bench-corpus] FAIL: malformed PROVENANCE.tsv row: %s" % line, file=sys.stderr)
            sys.exit(1)
        rows[parts[0]] = parts
    return rows

if mode == "check":
    rows = read_prov()
    if len(rows) != len(PAIRS):
        print("[bench-corpus] FAIL: PROVENANCE.tsv records %d snapshot(s), expected %d"
              % (len(rows), len(PAIRS)), file=sys.stderr)
        sys.exit(1)
    bad = 0
    for src, dst in PAIRS:
        row = rows.get(dst)
        if row is None:
            print("[bench-corpus] FAIL: %s has no PROVENANCE.tsv row" % dst, file=sys.stderr)
            bad = 1
            continue
        p = pathlib.Path(dst)
        if not p.exists():
            print("[bench-corpus] FAIL: %s is recorded but missing" % dst, file=sys.stderr)
            bad = 1
            continue
        raw = p.read_bytes()
        got = hashlib.sha256(raw).hexdigest()
        if got != row[3]:
            print("[bench-corpus] FAIL: %s does not match its recorded digest" % dst, file=sys.stderr)
            print("  recorded %s" % row[3], file=sys.stderr)
            print("  actual   %s" % got, file=sys.stderr)
            print("  A frozen corpus is edited by scripts/bump_bench_corpus.sh and by "
                  "nothing else; an edit here silently restates every number in the series.",
                  file=sys.stderr)
            bad = 1
            continue
        if str(len(raw)) != row[4]:
            print("[bench-corpus] FAIL: %s byte count %d does not match the recorded %s"
                  % (dst, len(raw), row[4]), file=sys.stderr)
            bad = 1
    sys.exit(1 if bad else 0)

rev = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
out = ["# Frozen bench corpus (#2865). One row per snapshot.",
       "# corpus\tsource\ttaken_at\tsha256\tbytes"]
for src, dst in PAIRS:
    text = BANNER.format(src=src, rev=rev) + pathlib.Path(src).read_text()
    pathlib.Path(dst).write_text(text)
    raw = text.encode()
    out.append("\t".join([dst, src, rev, hashlib.sha256(raw).hexdigest(), str(len(raw))]))
    print("[bench-corpus] froze %s (%d bytes)" % (dst, len(raw)))
PROV.write_text("\n".join(out) + "\n")
print("[bench-corpus] wrote %s at %s" % (PROV, rev))
PY

if [ "$MODE" = check ]; then
  echo "[bench-corpus] ok (every snapshot matches its recorded digest)"
fi
