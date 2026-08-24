#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPT="$PROJECT_ROOT/scripts/generations.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_generations.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bootstrap" "$TMP_ROOT/_build/selfhost/seed" "$TMP_ROOT/lib/@vibe/compiler"
printf 'export let main = () -> Int { 0 }\n' > "$TMP_ROOT/lib/@vibe/compiler/index.vibe"
printf 'seed-compiler\n' > "$TMP_ROOT/_build/selfhost/seed/selfhost_compiler.wasm"
seed_sha="$(shasum -a 256 "$TMP_ROOT/_build/selfhost/seed/selfhost_compiler.wasm" | awk '{print $1}')"

cat > "$TMP_ROOT/bootstrap/seed.json" <<EOF
{
  "schema": 1,
  "policy": "rust-style-stage0-stage1-stage2",
  "seed": {
    "name": "test-seed",
    "tag": "test-seed-tag",
    "source_commit": "abc123",
    "entry": "lib/@vibe/compiler/index.vibe",
    "entry_name": "cli_main",
    "artifact": {
      "path": "_build/selfhost/seed/selfhost_compiler.wasm",
      "sha256": "$seed_sha"
    },
    "runtime": {
      "runner": "node",
      "compile_flag": "--wasm-mvp",
      "wasmtime_flags": "unknown-imports-default=y exceptions=y"
    }
  }
}
EOF

cat > "$TMP_ROOT/fake_cli_runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "--invoke" ] || { echo "fake_cli_runner: expected --invoke, got $1" >&2; exit 2; }
invoke_name="$2"; compiler="$3"; entry="$4"; out="$5"; entry_name="${6:-}"
mkdir -p "$(dirname "$out")"
printf 'fake-wasm compiler=%s entry=%s invoke=%s entry_name=%s\n' \
  "$(basename "$compiler")" "$(basename "$entry")" "$invoke_name" "$entry_name" > "$out"
EOF
chmod +x "$TMP_ROOT/fake_cli_runner.sh"

VIBE_PROJECT_ROOT="$TMP_ROOT" \
VIBE_GENERATION_RUNNER_SCRIPT="$TMP_ROOT/fake_cli_runner.sh" \
VIBE_GENERATION_VALIDATE_WASM=0 \
VIBE_GENERATION_VALIDATE_RUN=0 \
  bash "$SCRIPT" build --manifest "$TMP_ROOT/bootstrap/seed.json" --out-dir "$TMP_ROOT/out" --stage3

test -s "$TMP_ROOT/out/stage0_seed.wasm"
test -s "$TMP_ROOT/out/stage1.wasm"
test -s "$TMP_ROOT/out/stage2.wasm"
test -s "$TMP_ROOT/out/stage3.wasm"
test -s "$TMP_ROOT/out/generation.json"

node - "$TMP_ROOT/out/generation.json" <<'NODE'
const assert = require("node:assert");
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.equal(data.policy, "rust-style-stage0-stage1-stage2");
assert.equal(data.seed.name, "test-seed");
assert.equal(data.source.entry, "lib/@vibe/compiler/index.vibe");
assert.equal(data.stages.stage0.built_by, "fixed-seed");
assert.equal(data.stages.stage1.built_by, "stage0");
assert.equal(data.stages.stage2.built_by, "stage1");
assert.equal(data.stages.stage3.built_by, "stage2");
assert.equal(typeof data.result.stage3_equal_stage2, "boolean");
NODE

status_out="$(VIBE_PROJECT_ROOT="$TMP_ROOT" bash "$SCRIPT" status \
  --manifest "$TMP_ROOT/bootstrap/seed.json" --out-dir "$TMP_ROOT/out")"
echo "$status_out" | grep -qE "^seed\.name=test-seed$" || { echo "status missing seed.name" >&2; echo "$status_out" >&2; exit 1; }
echo "$status_out" | grep -qE "^seed\.artifact\.pin=ok " || { echo "status missing pin ok" >&2; echo "$status_out" >&2; exit 1; }
echo "$status_out" | grep -qE "^generation\.manifest=" || { echo "status missing generation manifest" >&2; echo "$status_out" >&2; exit 1; }
echo "$status_out" | grep -qE "^stage2\.sha256=" || { echo "status missing stage2 sha" >&2; echo "$status_out" >&2; exit 1; }
echo "$status_out" | grep -qE "^stage3_equal_stage2=" || { echo "status missing stage3_equal_stage2" >&2; echo "$status_out" >&2; exit 1; }

# status against an unbuilt out-dir reports not-built without failing.
status_empty="$(VIBE_PROJECT_ROOT="$TMP_ROOT" bash "$SCRIPT" status \
  --manifest "$TMP_ROOT/bootstrap/seed.json" --out-dir "$TMP_ROOT/never-built")"
echo "$status_empty" | grep -qE "^generation\.status=not-built$" || { echo "status missing not-built state" >&2; echo "$status_empty" >&2; exit 1; }

echo "selfhost generations status self-test: ok"

cp "$TMP_ROOT/bootstrap/seed.json" "$TMP_ROOT/bootstrap/bad-seed.json"
node - "$TMP_ROOT/bootstrap/bad-seed.json" <<'NODE'
const fs = require("node:fs");
const p = process.argv[2];
const data = JSON.parse(fs.readFileSync(p, "utf8"));
data.seed.artifact.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
fs.writeFileSync(p, `${JSON.stringify(data, null, 2)}\n`);
NODE

set +e
VIBE_PROJECT_ROOT="$TMP_ROOT" \
VIBE_GENERATION_RUNNER_SCRIPT="$TMP_ROOT/fake_cli_runner.sh" \
VIBE_GENERATION_VALIDATE_WASM=0 \
VIBE_GENERATION_VALIDATE_RUN=0 \
VIBE_GENERATION_AUTO_FETCH_SEED=0 \
  bash "$SCRIPT" build --manifest "$TMP_ROOT/bootstrap/bad-seed.json" --out-dir "$TMP_ROOT/bad-out" >"$TMP_ROOT/bad.stdout" 2>"$TMP_ROOT/bad.stderr"
bad_status=$?
set -e
if [ "$bad_status" -eq 0 ]; then
  echo "expected sha mismatch to fail" >&2
  exit 1
fi
if ! grep -qE "sha256 mismatch" "$TMP_ROOT/bad.stderr"; then
  echo "expected sha mismatch diagnostic" >&2
  cat "$TMP_ROOT/bad.stderr" >&2
  exit 1
fi

printf 'new-seed\n' > "$TMP_ROOT/new_seed.wasm"
VIBE_PROJECT_ROOT="$TMP_ROOT" \
  bash "$SCRIPT" adopt \
    --manifest "$TMP_ROOT/bootstrap/seed.json" \
    --artifact "$TMP_ROOT/new_seed.wasm" \
    --name next-seed \
    --tag next-tag \
    --source-commit def456

node - "$TMP_ROOT/bootstrap/seed.json" "$TMP_ROOT/_build/selfhost/seed/selfhost_compiler.wasm" <<'NODE'
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const [manifestPath, artifactPath] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const sha = crypto.createHash("sha256").update(fs.readFileSync(artifactPath)).digest("hex");
assert.equal(data.seed.name, "next-seed");
assert.equal(data.seed.tag, "next-tag");
assert.equal(data.seed.source_commit, "def456");
assert.equal(data.seed.artifact.sha256, sha);
NODE

echo "selfhost generations self-test: ok"

CLI_ROOT="$TMP_ROOT/cli_seed"
mkdir -p "$CLI_ROOT/bootstrap" "$CLI_ROOT/bootstrap/seed" "$CLI_ROOT/scripts" "$CLI_ROOT/lib/@vibe/compiler"
printf 'import ./dep.vibe { dep }\nexport let cli_main = () -> Int { dep() }\n' > "$CLI_ROOT/lib/@vibe/compiler/cli_support.vibe"
printf 'export let dep = () -> Int { 0 }\n' > "$CLI_ROOT/lib/@vibe/compiler/dep.vibe"
printf 'seed-cli\n' > "$CLI_ROOT/bootstrap/seed/compiler.wasm"
cli_seed_sha="$(shasum -a 256 "$CLI_ROOT/bootstrap/seed/compiler.wasm" | awk '{print $1}')"

cat > "$CLI_ROOT/bootstrap/seed.json" <<EOF
{
  "schema": 1,
  "policy": "rust-style-stage0-stage1-stage2",
  "seed": {
    "name": "test-cli-seed",
    "tag": "test-cli-seed-tag",
    "source_commit": "abc123",
    "entry": "lib/@vibe/compiler/cli_support.vibe",
    "entry_name": "cli_main",
    "artifact": {
      "path": "bootstrap/seed/compiler.wasm",
      "sha256": "$cli_seed_sha"
    }
  }
}
EOF

cat > "$CLI_ROOT/scripts/generate_bundle.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${VIBE_ADAPTER_MODULE_SOURCE_OUT:-}" ] || {
  echo "missing VIBE_ADAPTER_MODULE_SOURCE_OUT" >&2
  exit 2
}
mkdir -p "$(dirname "$VIBE_ADAPTER_MODULE_SOURCE_OUT")"
printf 'export let cli_main = () -> Int { 0 }\n' > "$VIBE_ADAPTER_MODULE_SOURCE_OUT"
EOF
chmod +x "$CLI_ROOT/scripts/generate_bundle.sh"

cat > "$CLI_ROOT/scripts/run_wasm_vibe_host_runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "--invoke" ] || { echo "missing --invoke" >&2; exit 2; }
[ "$2" = "cli_main" ] || { echo "expected cli_main" >&2; exit 2; }
compiler="$3"
input="$4"
output="$5"
entry_name="$6"
printf '%s\n' "$input" >> invocations.log
mkdir -p "$(dirname "$output")"
printf 'fake cli compiler=%s input=%s entry=%s\n' "$(basename "$compiler")" "$input" "$entry_name" > "$output"
EOF
chmod +x "$CLI_ROOT/scripts/run_wasm_vibe_host_runner.sh"

VIBE_PROJECT_ROOT="$CLI_ROOT" \
VIBE_GENERATION_VALIDATE_WASM=0 \
VIBE_GENERATION_VALIDATE_RUN=0 \
  bash "$SCRIPT" build --manifest "$CLI_ROOT/bootstrap/seed.json" --out-dir "$CLI_ROOT/out"

test -s "$CLI_ROOT/out/cli_adapter_module_source.vibe"
test -s "$CLI_ROOT/out/stage1.wasm"
test -s "$CLI_ROOT/out/stage2.wasm"
if grep -qE '^lib/@vibe/compiler/cli_support\.vibe$' "$CLI_ROOT/invocations.log"; then
  echo "expected cli seed build to use generated flat compiler source, not import entry" >&2
  cat "$CLI_ROOT/invocations.log" >&2
  exit 1
fi
if ! grep -qE '^out/cli_adapter_module_source\.vibe$' "$CLI_ROOT/invocations.log"; then
  echo "expected cli seed build to invoke generated flat compiler source" >&2
  cat "$CLI_ROOT/invocations.log" >&2
  exit 1
fi

echo "selfhost generations cli-seed self-test: ok"

mkdir -p "$CLI_ROOT/lib/@vibe/cli"
printf 'export let cli_main: () -> Int = () -> { 0 }\n' > "$CLI_ROOT/lib/@vibe/cli/entry.vibe"

set +e
VIBE_PROJECT_ROOT="$CLI_ROOT" \
VIBE_GENERATION_VALIDATE_WASM=0 \
VIBE_GENERATION_VALIDATE_RUN=0 \
  bash "$SCRIPT" build \
    --manifest "$CLI_ROOT/bootstrap/seed.json" \
    --out-dir "$CLI_ROOT/split-out" \
    --entry lib/@vibe/cli/entry.vibe >"$CLI_ROOT/split.stdout" 2>"$CLI_ROOT/split.stderr"
split_status=$?
set -e
if [ "$split_status" -eq 0 ]; then
  echo "expected legacy seed to reject split CLI generation before bootstrap bump" >&2
  exit 1
fi
if ! grep -qE "split CLI generation requires a bootstrap bump" "$CLI_ROOT/split.stderr"; then
  echo "expected split CLI bootstrap bump diagnostic" >&2
  cat "$CLI_ROOT/split.stderr" >&2
  exit 1
fi

echo "selfhost generations split-cli-entry guard self-test: ok"

# #1890: a failed compile must fail the build, even when an earlier build left
# an artifact at the same path. The runner reports failure by exit status and
# writes the diagnostics to `<out>.diag`, so a build that only asks "does the
# output file exist?" reports success for a stale artifact -- and the stage2 it
# then hands to the gate predates the source it was supposed to compile.
FAIL_ROOT="$TMP_ROOT/failing_compile"
mkdir -p "$FAIL_ROOT/bootstrap" "$FAIL_ROOT/_build/selfhost/seed" \
  "$FAIL_ROOT/lib/@vibe/compiler" "$FAIL_ROOT/out"
printf 'export let main = () -> Int { 0 }\n' > "$FAIL_ROOT/lib/@vibe/compiler/index.vibe"
printf 'seed-compiler\n' > "$FAIL_ROOT/_build/selfhost/seed/selfhost_compiler.wasm"
fail_seed_sha="$(shasum -a 256 "$FAIL_ROOT/_build/selfhost/seed/selfhost_compiler.wasm" | awk '{print $1}')"

cat > "$FAIL_ROOT/bootstrap/seed.json" <<EOF
{
  "schema": 1,
  "policy": "rust-style-stage0-stage1-stage2",
  "seed": {
    "name": "fail-seed",
    "tag": "fail-seed-tag",
    "source_commit": "abc123",
    "entry": "lib/@vibe/compiler/index.vibe",
    "entry_name": "cli_main",
    "artifact": {
      "path": "_build/selfhost/seed/selfhost_compiler.wasm",
      "sha256": "$fail_seed_sha"
    }
  }
}
EOF

# Exactly what the real runner does on a compile error: non-zero exit, the
# reason in the .diag sidecar, and no .wasm.
cat > "$FAIL_ROOT/fail_runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="$5"
mkdir -p "$(dirname "$out")"
printf 'synthetic compile error for the #1890 regression test\n' > "$out.diag"
exit 1
EOF
chmod +x "$FAIL_ROOT/fail_runner.sh"

# The artifacts from "the previous build", which is what made the failure
# invisible: the generation directory is named after the commit, so a rebuild at
# the same commit (different backend, different flags) lands on top of a
# complete set of stage outputs. Every stage has to be stale for the build to
# report success, which is exactly what a repeat build gives it.
printf 'stale-wasm-from-an-earlier-build\n' > "$FAIL_ROOT/out/stage1.wasm"
printf 'stale-wasm-from-an-earlier-build\n' > "$FAIL_ROOT/out/stage2.wasm"
# ...including its manifest, which is what `status` and compiler_gate.sh read.
printf '{"result":{"stage2_distribution_candidate":true}}\n' > "$FAIL_ROOT/out/generation.json"

set +e
VIBE_PROJECT_ROOT="$FAIL_ROOT" \
VIBE_GENERATION_RUNNER_SCRIPT="$FAIL_ROOT/fail_runner.sh" \
VIBE_GENERATION_VALIDATE_WASM=0 \
VIBE_GENERATION_VALIDATE_RUN=0 \
  bash "$SCRIPT" build --manifest "$FAIL_ROOT/bootstrap/seed.json" \
    --out-dir "$FAIL_ROOT/out" >"$FAIL_ROOT/fail.stdout" 2>"$FAIL_ROOT/fail.stderr"
fail_status=$?
set -e
if [ "$fail_status" -eq 0 ]; then
  echo "expected a failing compile to fail the build (#1890)" >&2
  exit 1
fi
if ! grep -qE "compile failed \(exit 1\)" "$FAIL_ROOT/fail.stderr"; then
  echo "expected the compile's exit status to be reported" >&2
  cat "$FAIL_ROOT/fail.stderr" >&2
  exit 1
fi
# Without this the terminal shows only that the build stopped, never why.
if ! grep -qE "synthetic compile error" "$FAIL_ROOT/fail.stderr"; then
  echo "expected the .diag contents on stderr" >&2
  cat "$FAIL_ROOT/fail.stderr" >&2
  exit 1
fi
if [ -e "$FAIL_ROOT/out/stage1.wasm" ]; then
  echo "expected the stale artifact to be removed before compiling" >&2
  exit 1
fi
# A failed build must not leave the previous build's verdict standing: the
# manifest is written last, so without retracting it up front the directory
# still answers "stage2 is a distribution candidate" for artifacts it no
# longer has.
if [ -e "$FAIL_ROOT/out/generation.json" ]; then
  echo "expected the previous generation.json to be retracted before building" >&2
  cat "$FAIL_ROOT/out/generation.json" >&2
  exit 1
fi
fail_status_out="$(VIBE_PROJECT_ROOT="$FAIL_ROOT" bash "$SCRIPT" status \
  --manifest "$FAIL_ROOT/bootstrap/seed.json" --out-dir "$FAIL_ROOT/out")"
if ! echo "$fail_status_out" | grep -qE "^generation\.status=not-built$"; then
  echo "expected status to report not-built after a failed build" >&2
  echo "$fail_status_out" >&2
  exit 1
fi

echo "selfhost generations failed-compile self-test: ok"
