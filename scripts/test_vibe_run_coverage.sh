#!/usr/bin/env bash
# `vibe run --coverage` (#3674): an instrumented run writes a function / branch
# report beside the artifact, and every way to get no report is an error.
#
#   bash scripts/test_vibe_run_coverage.sh <stage2.wasm>
#
# The compiler is an argument because the committed seed predates the flag;
# the early compiler gate passes this checkout's stage2.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_vibe_run_coverage.sh <stage2.wasm>" >&2; exit 2; }

WORK="$ROOT_DIR/_build/test_vibe_run_coverage"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[vibe-run-coverage] FAIL $*" >&2; exit 1; }

# `pick` is reached on one arm only, and `unused` not at all.
cat > "$WORK/prog.vibex" <<'EOF'
fn pick(n: Int) -> Int {
  if n > 0 {
    1
  } else {
    2
  }
}

fn unused(n: Int) -> Int {
  n * 3
}

fn main() -> Unit allows Console {
  println("\{pick(5)}")
}
EOF

run() { # <runner> <vibe run args...>
  local runner="$1"; shift
  VIBE_RUNNER="$runner" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_BUILD_DIR="$WORK/build" "$ROOT_DIR/runtime/vibe" run "$@"
}
node_runner="$ROOT_DIR/scripts/viberun_node.sh"
report="$WORK/build/run/prog.cov.json"

# 1. The program's own output is unchanged, and the report says what ran.
status=0
out="$(run "$node_runner" --coverage "$WORK/prog.vibex" 2>"$WORK/err")" || status=$?
[ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "instrumented run exited $status"; }
[ "$out" = "1" ] || fail "stdout should be the program's alone, got: $(printf '%q' "$out")"
grep -q '^\[vibe-cov\] .* -> .*prog\.cov\.json$' "$WORK/err" || { cat "$WORK/err" >&2; fail "no [vibe-cov] summary on stderr"; }
[ -s "$report" ] || fail "no report at $report"
python3 - "$report" <<'PY' || fail "report contents"
import json, sys
r = json.load(open(sys.argv[1]))
hit, missed = r["hit_fns"], r["missed_fns"]
assert any(n.endswith("pick") for n in hit), hit
assert any(n.endswith("unused") for n in missed), missed
b = r["branch"]
pick = [v for k, v in b["per_fn"].items() if k.endswith("pick")]
assert pick and pick[0]["total"] == 2 and pick[0]["hit"] == 1, b["per_fn"]
PY

# 2. A stale report from an earlier run is not mistaken for this run's: a
#    runner that never writes one makes the run fail and say why.
cat > "$WORK/no_dump_runner.sh" <<EOF
#!/usr/bin/env bash
unset VIBE_COV_OUT
exec bash "$node_runner" "\$@"
EOF
chmod +x "$WORK/no_dump_runner.sh"
status=0
out="$(run "$WORK/no_dump_runner.sh" --coverage "$WORK/prog.vibex" 2>"$WORK/err")" || status=$?
[ "$status" != 0 ] || fail "a run that wrote no report exited 0"
[ "$out" = "1" ] || fail "the program should still have run, got: $(printf '%q' "$out")"
grep -q 'wrote no coverage report' "$WORK/err" || { cat "$WORK/err" >&2; fail "missing report not explained"; }
[ ! -e "$report" ] || fail "the earlier report was left in place"

# 3. Combinations that would measure another artifact are refused up front.
refused() { # <needle> <env...> -- <vibe run args...>
  local needle="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  status=0
  env ${envs[@]+"${envs[@]}"} VIBE_RUNNER="$node_runner" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_BUILD_DIR="$WORK/build" "$ROOT_DIR/runtime/vibe" run "$@" >/dev/null 2>"$WORK/err" || status=$?
  [ "$status" != 0 ] || fail "accepted: $*"
  grep -q "$needle" "$WORK/err" || { cat "$WORK/err" >&2; fail "refusal of '$*' does not say: $needle"; }
}
refused 'cannot be combined with --trace' -- --coverage --trace "$WORK/prog.vibex"
refused 'cannot be combined with --trace' -- --coverage --break pick "$WORK/prog.vibex"
refused 'instruments the linear backend' VIBE_BACKEND=gc -- --coverage "$WORK/prog.vibex"

# 4. An optional grant would answer NotGranted in the instrumented build even
#    under --allow-fs, so the report would measure another execution.
cat > "$WORK/optional.vibex" <<'EOF'
fn cached() -> Attempt[String, String] with Fs::read_file? {
  perform? Fs::read_file("prog.vibex")
}

fn main() -> Unit allows Console + Fs? {
  match cached() {
    NotGranted => println("not-granted"),
    Errored(_) => println("errored"),
    Granted(_) => println("granted")
  }
}
EOF
refused 'declares the optional grant `Fs?`' -- --coverage --allow-fs --allow-console "$WORK/optional.vibex"

echo "[vibe-run-coverage] ok (report written; missing report, --trace/--break, VIBE_BACKEND=gc and optional grants refused)"
