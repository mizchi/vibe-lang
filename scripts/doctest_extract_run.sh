#!/usr/bin/env bash
# doctest_extract_run.sh — executable-docs harness (0.3.0 roadmap: doctest / *.vibe.md).
#
# Extracts ```vibe fenced code blocks from one or more markdown files and
# compiles each one with the selfhost stage2 compiler (moon-free). Reports a
# per-block PASS/FAIL/SKIP line and exits 1 if any block fails, so docs code
# examples cannot silently rot.
#
# Usage:
#   bash scripts/doctest_extract_run.sh <file.md> [more.md ...]
#
# Block classification (info string on the opening fence):
#   ```vibe        compile check only (entry __no_entry__)   [default]
#   ```vibe run    compile with entry _start, then invoke _start
#                  (block must export `_start`; non-zero exit or trap = FAIL)
#   ```vibe skip   excluded from verification (convention: put the reason in a
#                  comment on the first line of the block)
#   any other fence language is ignored.
#
# Blocks are compiled AS-IS as standalone programs (no implicit wrapping):
# top-level `let` / `fn` / `enum` / `struct` / `effect` / `import` fragments
# compile fine with __no_entry__; bare-expression fragments do not and should
# be made self-contained or tagged `vibe skip`. Imports of the form
# `./lib/...` resolve as if the block lived at the repo root (a `lib` symlink
# is placed in the work dir).
#
# One retry heuristic: a declaration-only block (types / suberror / effect
# signatures with no function values) fails with "no functions found to
# compile"; such a block is retried once with an appended
# `export let __doctest_anchor: () -> Int = () -> { 0 }` so that
# "parses + typechecks" is still verified.
#
# Environment:
#   DOCTEST_STAGE2   compiler wasm to use. Default: newest
#                    _build/selfhost/generations/*/stage2.wasm, resolved ONCE
#                    at startup (concurrent bootstrap runs cannot swap it
#                    mid-run); falls back to bootstrap/seed/selfhost_compiler.wasm.
#   DOCTEST_WORKDIR  scratch dir for extracted sources / wasm (default _build/doctest/<pid>)
#   DOCTEST_KEEP=1   keep the work dir (default: removed on exit)
#   DOCTEST_TIMEOUT  per-block compile/run timeout in seconds (default 120)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

if [ $# -lt 1 ]; then
  echo "usage: bash scripts/doctest_extract_run.sh <file.md> [more.md ...]" >&2
  exit 2
fi

# --- resolve compiler once (pin: do NOT re-resolve later in the run) --------
stage2="${DOCTEST_STAGE2:-}"
if [ -z "$stage2" ]; then
  # newest generation that actually HAS a stage2.wasm — a concurrent bootstrap
  # run may have created a newer, still-incomplete generation dir
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${gen}stage2.wasm" ]; then
      stage2="${gen}stage2.wasm"
      break
    fi
  done
  if [ -z "$stage2" ]; then
    # NOTE: docs document the CURRENT language; the committed seed (previous
    # bootstrap tag) may be too old to compile them. Prefer a built stage2
    # (or pass DOCTEST_STAGE2 explicitly).
    stage2="bootstrap/seed/selfhost_compiler.wasm"
  fi
fi
if [ ! -s "$stage2" ]; then
  echo "doctest: compiler wasm not found: $stage2" >&2
  exit 2
fi

workdir="${DOCTEST_WORKDIR:-_build/doctest/$$}"
mkdir -p "$workdir"
# a generation build may race-delete the resolved stage2 dir: pin a copy
cp "$stage2" "$workdir/compiler.wasm"
compiler="$workdir/compiler.wasm"
# make `import ./lib/...` in doc examples resolve as if the block sat at repo root
ln -sfn "$ROOT_DIR/lib" "$workdir/lib"

cleanup() {
  if [ "${DOCTEST_KEEP:-0}" != "1" ]; then rm -rf "$workdir"; fi
}
trap cleanup EXIT

timeout_s="${DOCTEST_TIMEOUT:-120}"
timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then timeout_cmd=(timeout "$timeout_s"); fi

echo "doctest: compiler = $stage2"

total=0; pass=0; fail=0; skipped=0
declare -a failures=()

for md in "$@"; do
  if [ ! -f "$md" ]; then
    echo "doctest: no such file: $md" >&2
    exit 2
  fi
  base="$(basename "$md" .md | tr -c 'A-Za-z0-9_' '_')"

  # --- extract ```vibe blocks -> $workdir/${base}_bNN_LLLL.vibe + manifest ---
  manifest="$workdir/${base}.manifest"
  python3 - "$md" "$workdir" "$base" > "$manifest" <<'PY'
import re, sys
md, workdir, base = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(md, encoding="utf-8").read().splitlines()
in_block = False
fence = mode = None
start = 0
buf = []
n = 0
for i, line in enumerate(lines, 1):
    if not in_block:
        m = re.match(r"^(\s*)(`{3,})\s*(\S*)\s*(.*)$", line)
        if m and m.group(3):
            lang = m.group(3)
            arg = m.group(4).strip()
            in_block = True
            fence = m.group(2)
            if lang == "vibe":
                start = i + 1
                buf = []
                if arg.startswith("run"):
                    mode = "run"
                elif arg.startswith("skip"):
                    mode = "skip"
                else:
                    mode = "check"
            else:
                mode = None  # non-vibe block: swallow until close
        elif m and m.group(2):
            in_block = True
            fence = m.group(2)
            mode = None  # bare/stray fence: swallow until close
    else:
        if re.match(r"^\s*%s\s*$" % re.escape(fence), line):
            if mode in ("check", "run", "skip"):
                n += 1
                path = "%s/%s_b%02d_L%04d.vibe" % (workdir, base, n, start)
                open(path, "w", encoding="utf-8").write("\n".join(buf) + "\n")
                print("%s\t%d\t%s\t%s" % (path, start, mode, md))
            in_block = False
            fence = mode = None
        elif mode in ("check", "run", "skip"):
            buf.append(line)
PY

  if [ ! -s "$manifest" ]; then
    echo "doctest: $md: no \`\`\`vibe blocks found"
    continue
  fi

  while IFS=$'\t' read -r src line mode srcmd; do
    total=$((total + 1))
    label="$srcmd:$line"
    if [ "$mode" = "skip" ]; then
      skipped=$((skipped + 1))
      echo "SKIP  $label"
      continue
    fi
    out="${src%.vibe}.wasm"
    entry="__no_entry__"
    if [ "$mode" = "run" ]; then entry="_start"; fi
    compile_log="${src%.vibe}.compile.log"
    compile_ok=0
    if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
        "${timeout_cmd[@]}" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
        "$compiler" "$src" "$out" "$entry" >"$compile_log" 2>&1 && [ -s "$out" ]; then
      compile_ok=1
    elif [ "$mode" = "check" ] && \
        grep -q "no functions found to compile" "$compile_log" "$out.diag" 2>/dev/null; then
      # declaration-only block: retry once with an anchor fn so the block's
      # "parses + typechecks" contract is still verified
      anchored="${src%.vibe}.anchored.vibe"
      { cat "$src"; printf '\nexport let __doctest_anchor: () -> Int = () -> { 0 }\n'; } > "$anchored"
      if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
          "${timeout_cmd[@]}" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
          "$compiler" "$anchored" "$out" "$entry" >"$compile_log" 2>&1 && [ -s "$out" ]; then
        compile_ok=1
      fi
    fi
    if [ "$compile_ok" = "1" ]; then
      if [ "$mode" = "run" ]; then
        run_log="${src%.vibe}.run.log"
        if VIBE_PREOPEN_DIR="$ROOT_DIR" \
            "${timeout_cmd[@]}" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start \
            "$out" >"$run_log" 2>&1; then
          pass=$((pass + 1))
          echo "PASS  $label (run)"
        else
          fail=$((fail + 1))
          reason="$(grep -m1 -iE 'error|trap|unreachable|abort' "$run_log" 2>/dev/null || tail -1 "$run_log" 2>/dev/null || true)"
          reason="${reason//$workdir\//}"
          failures+=("$label [run] ${reason:-runtime failure}")
          echo "FAIL  $label (run) ${reason:-runtime failure}"
        fi
      else
        pass=$((pass + 1))
        echo "PASS  $label"
      fi
    else
      fail=$((fail + 1))
      diag="$out.diag"
      reason=""
      if [ -s "$diag" ]; then reason="$(head -1 "$diag")"; fi
      if [ -z "$reason" ]; then reason="$(grep -v '^$' "$compile_log" | head -1 || true)"; fi
      reason="${reason//$workdir\//}"
      failures+=("$label [compile] ${reason:-compile failure}")
      echo "FAIL  $label ${reason:-compile failure}"
    fi
  done < "$manifest"
done

echo
echo "doctest: $total blocks — $pass pass, $fail fail, $skipped skip"
if [ "$fail" -gt 0 ]; then
  echo "doctest: failing blocks:" >&2
  for f in "${failures[@]}"; do echo "  $f" >&2; done
  exit 1
fi
