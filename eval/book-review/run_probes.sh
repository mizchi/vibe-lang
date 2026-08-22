#!/usr/bin/env bash
# Compile and run every probe in eval/book-review/probes/ against the
# CURRENT stage2, printing a per-probe report (compile ok/fail, the
# diagnostic if any, run output if it compiled). The report is the
# measurement — a probe that fails to compile is data, not a harness
# error, so this script always exits 0 unless the harness itself broke.
#
# usage: bash eval/book-review/run_probes.sh [probe.vibe ...]
set -uo pipefail

cd "$(dirname "$0")/../.."
OUT_DIR=_build/evalprobe-book
mkdir -p "$OUT_DIR"

# Same "which compiler answered?" discipline as eval/lang-review: the
# subject is the current compiler's behavior and diagnostic text, so a
# wrong compiler must be a loud error, never a silent fallback.
if [ -n "${BOOK_REVIEW_STAGE2:-}" ]; then
  # An explicit override is the caller's deliberate choice -- but a
  # mistyped path must not fall through to whatever is on disk.
  if [ ! -f "$BOOK_REVIEW_STAGE2" ]; then
    echo "[book-review] BOOK_REVIEW_STAGE2 is set but does not exist:" >&2
    echo "[book-review]   $BOOK_REVIEW_STAGE2" >&2
    exit 2
  fi
  S2="$BOOK_REVIEW_STAGE2"
else
  gen_dir=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)
  S2="${gen_dir}stage2.wasm"
  if [ -z "$gen_dir" ] || [ ! -f "$S2" ]; then
    echo "[book-review] no stage2 found. Build one first:" >&2
    echo "[book-review]   bash scripts/generations.sh build" >&2
    echo "[book-review] or pass BOOK_REVIEW_STAGE2=<stage2.wasm>." >&2
    echo "[book-review] Refusing to measure the committed seed silently." >&2
    exit 2
  fi
  # The generation manifest is the artifact's birth certificate:
  # generations.sh deletes it before rebuilding and writes it only at
  # the very end, so its presence proves a COMPLETED build, and it
  # records the source commit, whether the tree was dirty, and the
  # stage2's sha256. Read it instead of trusting directory names.
  manifest="$gen_dir/generation.json"
  if [ ! -f "$manifest" ]; then
    echo "[book-review] newest generation has no generation.json -- its build" >&2
    echo "[book-review] never completed, so the stage2 there proves nothing." >&2
    echo "[book-review] Rebuild (bash scripts/generations.sh build), or pass a" >&2
    echo "[book-review] compiler explicitly via BOOK_REVIEW_STAGE2." >&2
    exit 2
  fi
  read -r man_commit man_dirty man_sha < <(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["source"]["commit"],
      str(m["source"].get("dirty", True)).lower(),
      m["stages"]["stage2"]["sha256"])' "$manifest")
  head_full=$(git rev-parse HEAD 2>/dev/null || echo unknown)
  if [ "$man_commit" != "$head_full" ]; then
    echo "[book-review] newest stage2 was built from ${man_commit:0:9}, HEAD is ${head_full:0:9}." >&2
    echo "[book-review] Its answers would describe THAT compiler, not this checkout." >&2
    echo "[book-review] Rebuild (bash scripts/generations.sh build), or pass the" >&2
    echo "[book-review] compiler you mean explicitly: BOOK_REVIEW_STAGE2=$S2" >&2
    exit 2
  fi
  if [ "$man_dirty" != "false" ]; then
    echo "[book-review] newest stage2 was built from a DIRTY tree (manifest" >&2
    echo "[book-review] source.dirty) -- it cannot be tied to any commit. Rebuild" >&2
    echo "[book-review] from a clean tree, or pass BOOK_REVIEW_STAGE2 explicitly." >&2
    exit 2
  fi
  actual_sha=$(sha256sum "$S2" | cut -d' ' -f1)
  if [ "$actual_sha" != "$man_sha" ]; then
    echo "[book-review] stage2.wasm does not match the sha256 its manifest" >&2
    echo "[book-review] recorded -- the artifact was altered after the build." >&2
    echo "[book-review] Rebuild (bash scripts/generations.sh build)." >&2
    exit 2
  fi
  # A matching commit is not enough when the compiler sources carry
  # uncommitted edits -- the artifact cannot be proven to contain them
  # (same trap as vibe_test.sh's ahead-of-seed notice, from the
  # refusing side).
  if [ -n "$(git status --porcelain -- lib/@vibe lib/@vibex bootstrap/seed 2>/dev/null)" ]; then
    echo "[book-review] compiler sources have uncommitted changes; the newest" >&2
    echo "[book-review] generation cannot be proven to contain them. Rebuild" >&2
    echo "[book-review] (bash scripts/generations.sh build), or pass the compiler" >&2
    echo "[book-review] you mean explicitly: BOOK_REVIEW_STAGE2=$S2" >&2
    exit 2
  fi
fi
echo "[book-review] compiler: $S2"

# --- CLI-verb lane -----------------------------------------------------
# A probe may carry `//! cli: <verb> [args...]` directives. Each runs the
# REAL launcher verb (runtime/vibe) against the probe with the same
# stage2, so CLI-side answers -- `vibe check` diagnostics and warnings,
# `type-at`/`symbols`, the launcher's own test reporter -- are reproduced
# by this harness rather than by a comment asking the reader to re-run
# them. `vibe check` resolves imports; it is NOT interchangeable with the
# compile lane above, which is exactly why probes that measure it say so
# explicitly. The verb's output and exit code are probe data (a check
# that answers a diagnostic is a measurement); only a missing launcher
# or runner-shim failure is a harness error.
#
# The launcher needs a `viberun` host; provide the same node-runner shim
# the gates use, routing the CLI wasm to cli_main and program wasm to
# _start. Mode env vars are the launcher's to set -- the shim adds none.
LAUNCHER=runtime/vibe
SHIM="$OUT_DIR/viberun-shim"
cat > "$SHIM" <<SHIM_EOF
#!/usr/bin/env bash
# The COMPILER goes to cli_main, program wasm to _start. The compiler is
# recognized by its exact path (the launcher passes VIBE_CLI_WASM
# verbatim), never by basename alone -- a BOOK_REVIEW_STAGE2 override
# with any filename must still reach cli_main, or its CLI measurements
# would silently record wrong-entry failures as probe data.
first="\$1"; shift
if [ "\$first" = "$S2" ]; then
  : "\${VIBE_PREOPEN_DIR:=\$PWD}"; export VIBE_PREOPEN_DIR
  : "\${VIBE_IMPORT_ABI:=raw}"; export VIBE_IMPORT_ABI
  exec bash "$PWD/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "\$first" "\$@"
fi
exec bash "$PWD/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "\$first" "\$@"
SHIM_EOF
chmod +x "$SHIM"

run_cli_directives() {
  local src="$1" name="$2" directive verb rest rc n=0
  while IFS= read -r directive; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    set -- ${directive#*cli:}
    verb="${1:-}"
    shift 2>/dev/null || true
    rest="$*"
    if [ -z "$verb" ]; then
      echo "--- HARNESS ERROR: empty cli directive in $src"
      harness_fail=1
      continue
    fi
    echo "--- cli: vibe $verb $src${rest:+ $rest}"
    if [ ! -f "$LAUNCHER" ]; then
      echo "--- HARNESS ERROR: launcher not found: $LAUNCHER"
      harness_fail=1
      return
    fi
    # shellcheck disable=SC2086
    VIBE_RUNNER="$PWD/$SHIM" VIBE_CLI_WASM="$S2" VIBE_TEST_CLI_WASM="$S2" \
      bash "$LAUNCHER" "$verb" "$src" $rest >"$OUT_DIR/$name.cli$n.log" 2>&1
    rc=$?
    sed 's/^/    /' "$OUT_DIR/$name.cli$n.log"
    echo "    (exit $rc)"
  done < <(grep -E '^//! cli:' "$src" || true)
}

probes=("$@")
if [ ${#probes[@]} -eq 0 ]; then
  # .vibex probes are first-class: the executable-root contract (entry
  # shape, import rejection, export acceptance #2229) can only be
  # measured on files that actually carry the extension.
  probes=(eval/book-review/probes/p*.vibe eval/book-review/probes/p*.vibex)
fi

harness_fail=0
for src in "${probes[@]}"; do
  if [ ! -f "$src" ]; then
    # An unexpanded glob or a typo must not be recorded as a probe
    # result (the compile lane would report it as a diagnostic).
    echo ""
    echo "=== $src"
    echo "--- HARNESS ERROR: probe file not found (run from the repo root," >&2
    echo "    e.g. eval/book-review/probes/p01_*.vibe)" >&2
    harness_fail=1
    continue
  fi
  name=$(basename "$src")
  name="${name%.vibe}"
  name="${name%.vibex}"
  wasm="$OUT_DIR/$name.wasm"
  rm -f "$wasm" "$wasm.diag"
  echo ""
  echo "=== $name"
  # Lane selection is by CONTENT: a probe declaring a top-level `test`
  # block runs on the test lane, everything else on the compile lane.
  # (A filename marker would silently misroute a probe that does not
  # follow it.)
  if grep -qE '^[[:space:]]*test([[:space:]]*\{|[[:space:]]+")' "$src"; then
      # test-block probes go through vibe test, not the compile lane
      test_log="$OUT_DIR/$name.test.log"
      VIBE_TEST_CLI_WASM="$S2" bash scripts/vibe_test.sh "$src" >"$test_log" 2>&1
      sed 's/^/    /' "$test_log"
      # A test-lane answer contains a per-test report (an `ok:` line or
      # a `failing test:` line) -- an assertion FAILURE is probe data.
      # A run that produced neither (seed setup failure, invalid
      # compiler artifact, compile failure before any test ran) is
      # infrastructure, not a compiler answer. Probes that are MEANT
      # to fail compilation belong on the compile lane, not here.
      if ! grep -qE 'failing test:|^ok[[:space:]]' "$test_log"; then
        echo "--- HARNESS ERROR: test lane produced no test report;"
        echo "    this is not a compiler answer."
        harness_fail=1
      fi
      run_cli_directives "$src" "$name"
      continue
  fi
  if VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$S2" "$src" "$wasm" main >"$OUT_DIR/$name.compile.log" 2>&1; then
    echo "--- compiles; run output:"
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$wasm" \
      2>"$OUT_DIR/$name.run.err" | sed 's/^/    /'
    if [ -s "$OUT_DIR/$name.run.err" ]; then
      echo "--- run stderr:"
      sed 's/^/    /' "$OUT_DIR/$name.run.err"
    fi
  else
    if [ -s "$wasm.diag" ]; then
      echo "--- does NOT compile; diagnostic:"
      sed 's/^/    /' "$wasm.diag"
    else
      # No sidecar means the RUNNER failed (bad artifact, host error),
      # not that the compiler rejected the probe -- recording it as a
      # compiler answer would corrupt the round.
      echo "--- HARNESS ERROR: runner failed without a .diag sidecar;"
      echo "    this is not a compiler answer. Compile log tail:"
      tail -5 "$OUT_DIR/$name.compile.log" | sed 's/^/    /'
      harness_fail=1
    fi
  fi
  run_cli_directives "$src" "$name"
done

if [ "$harness_fail" -ne 0 ]; then
  echo ""
  echo "[book-review] HARNESS ERRORS occurred -- results above are incomplete." >&2
  exit 2
fi
