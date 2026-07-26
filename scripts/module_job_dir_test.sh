#!/usr/bin/env bash
# #906 Phase 2: the worker transport contract.
#
# A worker receives a JOB DIRECTORY and nothing else -- that directory is its
# entire filesystem sandbox (VIBE_PREOPEN_DIR). It cannot open the project
# tree, and it cannot look its own dependencies up in the type-env cache
# (the key derives from the whole transitive source snapshot). The driver
# therefore hands dependency environments over as values.
#
# The case that matters is a module WITH an import. Before this, the
# selfhost bridge could only check leaf snapshots, which is why
# docs/compiler-parallelism.md lists an in-memory ModuleJob -> ModuleArtifact
# API as the blocker for a parallel frontend.
#
# Usage:
#   bash scripts/module_job_dir_test.sh <stage2.wasm>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${1:-}"
if [ -z "$STAGE2" ] || [ ! -s "$STAGE2" ]; then
  echo "[module-job] usage: bash scripts/module_job_dir_test.sh <stage2.wasm>" >&2
  exit 2
fi
STAGE2_ABS="$(cd "$(dirname "$STAGE2")" && pwd)/$(basename "$STAGE2")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The logical root is never opened -- it only has to be the directory each
# import resolves against. Using a path that does not exist on this machine
# is the point: if the worker ever tried to read the real file, it would
# fail here instead of silently succeeding against the project tree.
LOGICAL_ROOT="/virtual/pkg"

fail=0
note() { echo "[module-job] $*"; }
die() { echo "[module-job] FAIL: $*" >&2; fail=1; }

# run_job <jobdir> -> sets JOB_EXIT, JOB_OUTCOME, JOB_DIAG
run_job() {
  local dir="$1"
  rm -f "$dir/outcome.txt" "$dir/env.out" "$dir/diag.txt" "$dir/worker.out.diag"
  set +e
  # The job dir is passed ABSOLUTE. The host runner resolves guest paths
  # against the process working directory, not against VIBE_PREOPEN_DIR, so
  # a relative "." would read the caller's tree instead of the sandbox.
  VIBE_PREOPEN_DIR="$dir" VIBE_MODULE_JOB_DIR=1 VIBE_IMPORT_ABI=raw \
    timeout 300 bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$STAGE2_ABS" "$dir" "$dir/worker.out" "__no_entry__" \
    >/dev/null 2>&1
  JOB_EXIT=$?
  set -e
  JOB_OUTCOME="$(cat "$dir/outcome.txt" 2>/dev/null || true)"
  JOB_DIAG="$(cat "$dir/diag.txt" 2>/dev/null || true)"
}

# --- job 1: a leaf module, no dependencies -------------------------------
leaf="$work/leaf"; mkdir -p "$leaf"
cat > "$leaf/source.vibe" <<'EOF'
export fn dep_value(n: Int) -> Int {
  n + 41
}
EOF
printf 'version\t1\npath\t%s/dep.vibe\nfingerprint\tleaf-fp\n' "$LOGICAL_ROOT" > "$leaf/job.txt"

run_job "$leaf"
if [ "$JOB_EXIT" -ne 0 ]; then
  die "leaf job exited $JOB_EXIT"
elif [ "$JOB_OUTCOME" != "ok" ]; then
  die "leaf job outcome=$JOB_OUTCOME diag=$JOB_DIAG"
elif [ ! -s "$leaf/env.out" ]; then
  die "leaf job produced no env.out"
else
  note "leaf ok ($(wc -c < "$leaf/env.out") B env)"
fi

if ! grep -q "dep_value" "$leaf/env.out" 2>/dev/null; then
  die "leaf env.out does not export dep_value -- the artifact is not the module's interface"
fi

# --- jobs 2-4: a module WITH an import -----------------------------------
#
# Merely calling an imported name proves nothing: an unresolved import is
# LENIENT (the import statement introduces the name, and its type is left
# unknown), so a module that calls `dep_value(1)` checks clean whether or
# not the dependency environment was installed. The first version of this
# test asserted exactly that and would have passed against a transport that
# discarded dep0.env entirely.
#
# The discriminator has to be the dependency's TYPE. Calling dep_value with
# a String is an error only if the real signature arrived:
#
#   good + env  => ok     (the environment is accepted and usable)
#   bad  + env  => diag   (the SIGNATURE arrived, not just the name)
#   bad  - env  => ok     (control: without the env the same call is lenient)
#
# The middle case is the real assertion; the third is what makes it one.
mk_importer() {
  # $1 dir, $2 argument expression
  mkdir -p "$1"
  cat > "$1/source.vibe" <<EOF
import ./dep.vibe {
  dep_value
}

export fn answer() -> Int {
  dep_value($2)
}
EOF
  printf 'version\t1\npath\t%s/main.vibe\nfingerprint\timporter-fp\ndep\t%s/dep.vibe\n' \
    "$LOGICAL_ROOT" "$LOGICAL_ROOT" > "$1/job.txt"
}

good="$work/importer_good"
mk_importer "$good" "1"
cp "$leaf/env.out" "$good/dep0.env"
run_job "$good"
if [ "$JOB_EXIT" -ne 0 ]; then
  die "importer job exited $JOB_EXIT"
elif [ "$JOB_OUTCOME" != "ok" ]; then
  die "well-typed importer with supplied dependency env: outcome=$JOB_OUTCOME diag=$JOB_DIAG"
else
  note "importer + supplied dependency env ok"
fi

bad="$work/importer_bad"
mk_importer "$bad" '"not an int"'
cp "$leaf/env.out" "$bad/dep0.env"
run_job "$bad"
if [ "$JOB_OUTCOME" != "diag" ]; then
  die "calling dep_value(String) with the dependency env supplied checked as '$JOB_OUTCOME' -- the dependency's SIGNATURE did not arrive, only its name"
else
  note "dependency signature arrived: $(echo "$JOB_DIAG" | head -1)"
fi

rm -f "$bad/dep0.env"
run_job "$bad"
if [ "$JOB_OUTCOME" != "ok" ]; then
  die "control: without dep0.env the same call reported '$JOB_OUTCOME', so the diagnostic above cannot be attributed to the supplied env"
else
  note "control ok (same call is lenient with no dependency env)"
fi

# --- job 4: a type error is a VALUE, not a worker failure ----------------
broken="$work/broken"; mkdir -p "$broken"
cat > "$broken/source.vibe" <<'EOF'
export fn broken() -> Int {
  "not an int"
}
EOF
printf 'version\t1\npath\t%s/broken.vibe\nfingerprint\tbroken-fp\n' "$LOGICAL_ROOT" > "$broken/job.txt"

run_job "$broken"
if [ "$JOB_EXIT" -ne 0 ]; then
  die "type error escaped as a worker failure (exit $JOB_EXIT) instead of a diagnostic value"
elif [ "$JOB_OUTCOME" != "diag" ]; then
  die "type error: expected outcome=diag, got '$JOB_OUTCOME'"
elif [ -z "$JOB_DIAG" ]; then
  die "type error produced an empty diag.txt"
else
  note "type error returned as a value: $(echo "$JOB_DIAG" | head -1)"
fi

# --- job 5: a malformed job is an INFRASTRUCTURE failure -----------------
# The coordinator has to tell "this module has errors" apart from "this
# worker is broken". A bad job dir must not look like a clean check.
bad="$work/bad"; mkdir -p "$bad"
printf 'version\t9\npath\t%s/bad.vibe\n' "$LOGICAL_ROOT" > "$bad/job.txt"
: > "$bad/source.vibe"

run_job "$bad"
if [ "$JOB_EXIT" -eq 0 ]; then
  die "unsupported job version exited 0 -- infrastructure failure is indistinguishable from success"
elif [ -n "$JOB_OUTCOME" ]; then
  die "unsupported job version still wrote outcome.txt='$JOB_OUTCOME'"
else
  note "malformed job rejected without an outcome (exit $JOB_EXIT)"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "[module-job] worker transport ok (leaf, import + supplied env, negative control, diagnostic value, malformed job)"
