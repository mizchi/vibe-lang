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
printf 'version\t1\npath\t%s/dep.vibe\n' "$LOGICAL_ROOT" > "$leaf/job.txt"

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

# fingerprint.out is check_module's OWN output (build_fingerprint), never a
# value supplied by the caller -- job.txt has no `fingerprint` row at all
# (a leftover row of that name is now an unknown-row parse error, which
# doubles as a check that the format actually changed). #1121 shipped this
# job/outcome seam with the caller's fingerprint threaded through UNUSED:
# check_module just echoed it back, so nothing a worker published could
# ever land at the persistent-cache key the serial compiler would look
# under. This block is the regression pin for that fix.
LEAF_FP="$(cat "$leaf/fingerprint.out" 2>/dev/null || true)"
if [ -z "$LEAF_FP" ]; then
  die "leaf job outcome=ok but produced no fingerprint.out"
else
  note "leaf fingerprint: $LEAF_FP"
fi

# Determinism: the SAME source with NO dependencies must fingerprint the
# same way every time (build_fingerprint is a pure function of source and
# dependency fingerprints, nothing else).
run_job "$leaf"
LEAF_FP_2="$(cat "$leaf/fingerprint.out" 2>/dev/null || true)"
if [ "$LEAF_FP_2" != "$LEAF_FP" ]; then
  die "leaf fingerprint is not deterministic: '$LEAF_FP' then '$LEAF_FP_2' for identical input"
else
  note "leaf fingerprint is deterministic across runs"
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
# job.txt `dep` rows are 3 columns: path AND the dependency's OWN
# fingerprint (in DECLARATION order -- build_fingerprint folds it as a
# sequence, not a set). There is still no `fingerprint` row for the
# importer's OWN identity; that is this job's output, computed from job.txt
# 's dep fingerprint plus the importer's own source.
mk_importer() {
  # $1 dir, $2 argument expression, $3 dependency fingerprint
  mkdir -p "$1"
  cat > "$1/source.vibe" <<EOF
import ./dep.vibe {
  dep_value
}

export fn answer() -> Int {
  dep_value($2)
}
EOF
  printf 'version\t1\npath\t%s/main.vibe\ndep\t%s/dep.vibe\t%s\n' \
    "$LOGICAL_ROOT" "$LOGICAL_ROOT" "$3" > "$1/job.txt"
}

good="$work/importer_good"
mk_importer "$good" "1" "$LEAF_FP"
cp "$leaf/env.out" "$good/dep0.env"
run_job "$good"
if [ "$JOB_EXIT" -ne 0 ]; then
  die "importer job exited $JOB_EXIT"
elif [ "$JOB_OUTCOME" != "ok" ]; then
  die "well-typed importer with supplied dependency env: outcome=$JOB_OUTCOME diag=$JOB_DIAG"
else
  note "importer + supplied dependency env ok"
fi
IMPORTER_FP="$(cat "$good/fingerprint.out" 2>/dev/null || true)"
if [ -z "$IMPORTER_FP" ]; then
  die "importer job outcome=ok but produced no fingerprint.out"
fi

# Sensitivity: change ONLY the dependency's fingerprint (same importer
# source, same dep0.env) and the importer's OWN fingerprint must change
# too. If it didn't, the importer's identity would be a function of its own
# source alone -- exactly the bug this fix closes, since two builds where a
# dependency's interface changed would then collide on one persistent-cache
# key.
mk_importer "$good" "1" "${LEAF_FP}-changed"
cp "$leaf/env.out" "$good/dep0.env"
run_job "$good"
IMPORTER_FP_2="$(cat "$good/fingerprint.out" 2>/dev/null || true)"
if [ "$JOB_OUTCOME" != "ok" ]; then
  die "importer with a different dep fingerprint: outcome=$JOB_OUTCOME diag=$JOB_DIAG"
elif [ -z "$IMPORTER_FP_2" ] || [ "$IMPORTER_FP_2" = "$IMPORTER_FP" ]; then
  die "importer fingerprint did not change when the dependency's fingerprint changed ('$IMPORTER_FP' both times) -- the dependency's identity is not reaching build_fingerprint"
else
  note "importer fingerprint is sensitive to its dependency's fingerprint"
fi
mk_importer "$good" "1" "$LEAF_FP"

bad="$work/importer_bad"
mk_importer "$bad" '"not an int"' "$LEAF_FP"
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

# --- job 3b: a TRUNCATED dependency env is an infrastructure failure -----
# Codex review (P1) on #1121. The dangerous case is not a missing
# dependency env but a present-and-unusable one: skipping it would make the
# importer's imports lenient again, so a truncated file would turn the type
# error above into a clean check. Silent leniency is the failure mode this
# whole transport exists to prevent, so it must fail the run instead.
: > "$bad/dep0.env"
run_job "$bad"
if [ "$JOB_EXIT" -eq 0 ]; then
  die "truncated dep0.env exited 0 -- an unusable dependency env was silently treated as 'no env', which makes imports lenient"
elif [ -n "$JOB_OUTCOME" ]; then
  die "truncated dep0.env still wrote outcome.txt='$JOB_OUTCOME'"
else
  note "truncated dependency env rejected (exit $JOB_EXIT)"
fi
rm -f "$bad/dep0.env"

# --- job 4: a type error is a VALUE, not a worker failure ----------------
broken="$work/broken"; mkdir -p "$broken"
cat > "$broken/source.vibe" <<'EOF'
export fn broken() -> Int {
  "not an int"
}
EOF
printf 'version\t1\npath\t%s/broken.vibe\n' "$LOGICAL_ROOT" > "$broken/job.txt"

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

# A `dep` row missing its fingerprint column must be rejected too, not
# silently accepted with an empty/absent fingerprint -- that would let a
# dependency's identity quietly drop out of the fold.
badfp="$work/badfp"; mkdir -p "$badfp"
printf 'version\t1\npath\t%s/badfp.vibe\ndep\t%s/dep.vibe\n' "$LOGICAL_ROOT" "$LOGICAL_ROOT" > "$badfp/job.txt"
: > "$badfp/source.vibe"

run_job "$badfp"
if [ "$JOB_EXIT" -eq 0 ]; then
  die "a dep row with no fingerprint column exited 0"
elif [ -n "$JOB_OUTCOME" ]; then
  die "a dep row with no fingerprint column still wrote outcome.txt='$JOB_OUTCOME'"
else
  note "dep row missing its fingerprint column rejected (exit $JOB_EXIT)"
fi

# Codex review (#1126): a `dep` row with an EMPTY fingerprint column (still
# 3 tab-separated parts, so the column-count check alone would accept it)
# must also be rejected -- an empty fingerprint folds into build_fingerprint
# identically regardless of which dependency revision produced it, so two
# different revisions would silently collide on one fingerprint instead of
# the job being treated as malformed.
badfpempty="$work/badfpempty"; mkdir -p "$badfpempty"
printf 'version\t1\npath\t%s/badfpempty.vibe\ndep\t%s/dep.vibe\t\n' "$LOGICAL_ROOT" "$LOGICAL_ROOT" > "$badfpempty/job.txt"
: > "$badfpempty/source.vibe"

run_job "$badfpempty"
if [ "$JOB_EXIT" -eq 0 ]; then
  die "a dep row with an empty fingerprint column exited 0"
elif [ -n "$JOB_OUTCOME" ]; then
  die "a dep row with an empty fingerprint column still wrote outcome.txt='$JOB_OUTCOME'"
else
  note "dep row with empty fingerprint column rejected (exit $JOB_EXIT)"
fi

# Same for an empty PATH column.
badpathempty="$work/badpathempty"; mkdir -p "$badpathempty"
printf 'version\t1\npath\t%s/badpathempty.vibe\ndep\t\tsome-fp\n' "$LOGICAL_ROOT" > "$badpathempty/job.txt"
: > "$badpathempty/source.vibe"

run_job "$badpathempty"
if [ "$JOB_EXIT" -eq 0 ]; then
  die "a dep row with an empty path column exited 0"
elif [ -n "$JOB_OUTCOME" ]; then
  die "a dep row with an empty path column still wrote outcome.txt='$JOB_OUTCOME'"
else
  note "dep row with empty path column rejected (exit $JOB_EXIT)"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "[module-job] worker transport ok (leaf, import + supplied env, negative control, diagnostic value, malformed job)"
