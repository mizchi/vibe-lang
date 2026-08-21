#!/usr/bin/env bash
# Every ` ```vibe skip ` block in the book claims the compiler REJECTS it.
# Nothing checked that claim, and it is the one place in the book doctest
# cannot look: `vibe_md.sh` compiles and runs `vibe run` blocks and skips
# these by definition.
#
# So they rot silently, and one had. Chapter 20's handle-eligibility example
# was wrong twice over (#2156 review): as written it failed with an unrelated
# `return type mismatch`, and once THAT was fixed it compiled clean -- the
# example gave its local binding an effect row, which is one of the four
# repairs the eligibility diagnostic lists. The block was demonstrating the
# fix, labelled as the failure, and it read as authoritative.
#
# This gate compiles each skip block and asserts:
#
#   1. the compiler rejects it -- a block that compiles is a block whose
#      premise is gone
#   2. a diagnostic is quoted beneath it, and the compiler still produces
#      that text
#
# (2) is what would have caught chapter 20: it was rejected, so a
# rejection-only check passes it, but for the wrong reason and with a message
# nothing compared. Quoting is therefore mandatory, not optional -- an
# unquoted block is a claim with no evidence attached.
#
# WHICH COMPILER: resolve_stage2 -- explicit VIBE_SKIP_BLOCK_CLI_WASM, else the
# generation built from HEAD, else newest (loudly), else the seed (loudly). A
# gate that asks the compiler a question has to be told which compiler
# (AGENTS.md).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# resolve_stage2 rather than a hand-rolled fallback: it prefers the generation
# whose directory carries HEAD's short sha, falls back loudly, and is the same
# resolution every other compiler-probing gate uses. Mine picked `ls -t`, which
# on a reused workspace selects an unrelated generation, and dropped to the
# seed in silence -- the exact failure AGENTS.md's "Which compiler answered?"
# describes, in a gate written to stop documentation from lying (#2156 review).
# The task also carries `deps { selfhostGeneration }` so the checkout's stage2
# exists before this runs.
. "$(dirname "$0")/resolve_stage2.sh"
cli="$(resolve_stage2 check-book-skip-blocks "${VIBE_SKIP_BLOCK_CLI_WASM:-}")" || exit 1
echo "check-book-skip-blocks: compiler = $cli"

# Repo-local, not `mktemp -d` under /tmp. The runner reads and writes real
# paths here (VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw), so /tmp does work on
# this host -- measured -- but that is undocumented behavior to lean a
# required gate on, and every other compiler probe in scripts/ stays inside
# the tree. #2156 review raised the preopen question; this removes it rather
# than answering it.
work="$ROOT_DIR/_build/book_skip_blocks"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY' > "$work/blocks.tsv"
import os, re, sys, json
work = sys.argv[1]
out = []
for d in ("book/en", "book/ja"):
    for name in sorted(os.listdir(d)):
        if not name.endswith(".vibe.md"):
            continue
        path = os.path.join(d, name)
        lines = open(path).read().split("\n")
        i = 0
        while i < len(lines):
            if lines[i].strip() == "```vibe skip":
                start = i + 1
                j = start
                while j < len(lines) and lines[j].strip() != "```":
                    j += 1
                body = lines[start:j]
                # The leading `// skip: ...` note is harness metadata, not
                # part of the example -- a reader copying the block drops it.
                # Keeping it shifts every line number in the quoted
                # diagnostic by one.
                while body and body[0].strip().startswith("// skip:"):
                    body = body[1:]
                code = "\n".join(body)
                # A plain ``` fence immediately after (blank lines allowed)
                # holds the expected diagnostic.
                k = j + 1
                while k < len(lines) and lines[k].strip() == "":
                    k += 1
                expected = ""
                if k < len(lines) and lines[k].strip() == "```":
                    m = k + 1
                    while m < len(lines) and lines[m].strip() != "```":
                        m += 1
                    expected = "\n".join(lines[k + 1:m])
                out.append((path, start + 1, code, expected))
                i = j
            i += 1
for n, (path, line, code, expected) in enumerate(out):
    src = os.path.join(work, "blk%d.vibe" % n)
    open(src, "w").write(code + "\n")
    exp = os.path.join(work, "blk%d.expected" % n)
    open(exp, "w").write(expected)
    print("%s\t%d\t%s\t%s" % (path, line, src, exp))
PY

fail=0
count=0
while IFS=$'\t' read -r path line src exp; do
  count=$((count + 1))
  out_wasm="$src.wasm"
  rm -f "$out_wasm" "$out_wasm.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$cli" \
    "$src" "$out_wasm" main >/dev/null 2>&1 || true

  if [ -f "$out_wasm" ]; then
    echo "check-book-skip-blocks: FAIL: $path:$line compiles, but is marked \`\`\`vibe skip"
    echo "  A skip block claims the compiler rejects it. This one does not."
    echo "  Either the claim is stale (make it \`\`\`vibe run with its output), or"
    echo "  the example drifted into demonstrating the fix instead of the failure."
    fail=$((fail + 1))
    continue
  fi

  actual="$(cat "$out_wasm.diag" 2>/dev/null || true)"
  expected="$(cat "$exp")"
  if [ -z "$expected" ]; then
    echo "check-book-skip-blocks: FAIL: $path:$line has no quoted diagnostic"
    echo "  Add a plain \`\`\` block beneath it holding the message the compiler"
    echo "  produces, so the claim is checkable. It currently says:"
    echo "$actual" | sed 's/^/    /'
    fail=$((fail + 1))
    continue
  fi

  # Compare with whitespace collapsed: the book wraps these to fit the page.
  a="$(printf '%s' "$actual"   | tr '\n\t' '  ' | tr -s ' ')"
  e="$(printf '%s' "$expected" | tr '\n\t' '  ' | tr -s ' ')"
  case "$a" in
    *"$e"*) ;;
    *)
      echo "check-book-skip-blocks: FAIL: $path:$line quotes a diagnostic the compiler no longer produces"
      echo "  book:"
      echo "$expected" | sed 's/^/    /'
      echo "  compiler:"
      echo "$actual" | sed 's/^/    /'
      fail=$((fail + 1))
      ;;
  esac
done < "$work/blocks.tsv"

if [ "$fail" -gt 0 ]; then
  echo "check-book-skip-blocks: $fail of $count skip block(s) failed"
  exit 1
fi
echo "check-book-skip-blocks: ok ($count skip blocks rejected, each matching its quoted diagnostic)"
