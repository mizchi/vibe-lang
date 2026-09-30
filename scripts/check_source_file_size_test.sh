#!/usr/bin/env bash
# Exercise the source-size gate against real files in an isolated Git index.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/source_file_size_test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$ROOT/scripts/check_source_file_size.mjs" "$SCRATCH/check_source_file_size.mjs"
cd "$SCRATCH"
git init -q
printf '_build/\n' > .gitignore

write_lines() {
  python3 - "$1" "$2" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("// source\n" * int(sys.argv[2]))
PY
}

expect_ok() {
  if ! node check_source_file_size.mjs > result.log 2>&1; then
    cat result.log >&2
    echo "source-file-size self-test: FAIL ($1)" >&2
    exit 1
  fi
}

expect_oversized() {
  if node check_source_file_size.mjs > result.log 2>&1; then
    echo "source-file-size self-test: FAIL ($1): oversized source passed" >&2
    exit 1
  fi
  grep -qF 'sample.vibe: 3001 lines (maximum 3000)' result.log || {
    cat result.log >&2
    exit 1
  }
}

write_lines sample.vibe 3000
git add sample.vibe .gitignore check_source_file_size.mjs
expect_ok '3000 lines is allowed'
write_lines sample.vibe 3001
expect_oversized 'tracked source exceeds the limit'
rm sample.vibe
expect_ok 'deleted tracked source is skipped'
git rm --cached -q sample.vibe
write_lines sample.vibe 3001
expect_oversized 'untracked maintained source exceeds the limit'
rm sample.vibe
write_lines _build/generated.vibe 3001
expect_ok 'ignored generated source is excluded'
echo 'source-file-size self-test: all real-input controls passed'
