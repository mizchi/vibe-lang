#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT/artifacts/selfcompile-policy-validation"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log "$LOG_DIR"/*.json 2>/dev/null || true

cap_logs() {
  local f tmp
  for f in "$LOG_DIR"/*; do
    [ -f "$f" ] || continue
    if [ "$(wc -c < "$f")" -gt 1048576 ]; then
      tmp="$f.tail"
      tail -c 1048576 "$f" > "$tmp"
      mv "$tmp" "$f"
    fi
  done
}
trap cap_logs EXIT

fail() {
  echo "selfcompile policy Docker validation: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail "docker-unavailable"
docker version >"$LOG_DIR/docker-version.log" 2>&1 || fail "docker-daemon-unavailable"
[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" = "linux/x86_64" ] || \
  fail "native linux/amd64 Docker is required"

base="$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}')"
controller=(node "$ROOT/scripts/selfcompile_heap_policy.mjs" --repo "$ROOT" --base "$base" --latest-base-ref "$base" --head "$base" --synthesize-merge --pr-number 1798)

VIBE_HEAP_POLICY_HOSTILE_FIXTURES=1 "${controller[@]}" >"$LOG_DIR/same-tree.json" 2>"$LOG_DIR/same-tree.log" || fail "same-tree controller failed"
node - "$LOG_DIR/same-tree.json" <<'NODE'
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (result.decision !== "pass" || result.delta_bytes !== 0) throw new Error("same-tree decision/delta mismatch");
if (result.stage2_sha256.base !== result.stage2_sha256.current) throw new Error("same-tree stage2 mismatch");
if (JSON.stringify(result.output_sha256.base) !== JSON.stringify(result.output_sha256.current)) throw new Error("same-tree emitted output mismatch");
if (JSON.stringify(result.trials.base) !== JSON.stringify(result.trials.current)) throw new Error("same-tree heap trials mismatch");
if (JSON.stringify(result.stat_token_attestations.base) !== JSON.stringify(result.stat_token_attestations.current)) throw new Error("same-tree stat-token mismatch");
if (result.normalized_paths.canonical_root !== "/workspace/repo") throw new Error("canonical container path mismatch");
for (const label of ["base", "current"]) {
  const authority = result.docker_authority?.[label];
  if (!authority || typeof authority.context !== "string" || !authority.endpoint.startsWith("unix:///")) throw new Error("Docker authority attestation missing");
}
NODE

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/vibe-policy-hostile.XXXXXX")"
trap 'rm -rf "$scratch"; cap_logs' EXIT
git clone --quiet --no-local "$ROOT" "$scratch/repo"
git -C "$scratch/repo" config user.name selfcompile-policy-test
git -C "$scratch/repo" config user.email selfcompile-policy-test@example.invalid

# Every native project helper that the trusted closure must bypass becomes a
# fail-fast poison pill. A green comparison proves none was executed from the
# materialized current archive.
for script in \
  ensure_generated.sh ensure_seed.sh fetch_compiler.sh selfcompile_kpi.sh \
  generations.sh generate_bundle.sh run_wasm_vibe_host_runner.sh; do
  cat >"$scratch/repo/scripts/$script" <<EOF
#!/usr/bin/env bash
echo 'HEAD_SCRIPT_EXECUTED:$script' >&2
exit 97
EOF
  chmod +x "$scratch/repo/scripts/$script"
done
git -C "$scratch/repo" add scripts
git -C "$scratch/repo" commit --quiet -m 'hostile materialized script sentinels'
head="$(git -C "$scratch/repo" rev-parse --verify 'HEAD^{commit}')"
VIBE_HEAP_POLICY_HOSTILE_FIXTURES=1 node "$ROOT/scripts/selfcompile_heap_policy.mjs" \
  --repo "$scratch/repo" --base "$base" --latest-base-ref "$base" \
  --head "$head" --synthesize-merge --pr-number 1798 \
  >"$LOG_DIR/hostile-scripts.json" 2>"$LOG_DIR/hostile-scripts.log" || \
  fail "materialized-script sentinel comparison failed"
if grep -R 'HEAD_SCRIPT_EXECUTED' "$LOG_DIR/hostile-scripts."* >/dev/null 2>&1; then
  fail "a materialized head script executed"
fi
node - "$LOG_DIR/hostile-scripts.json" <<'NODE'
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (result.decision !== "pass" || result.delta_bytes !== 0) throw new Error("hostile-script comparison mismatch");
if (result.stage2_sha256.base !== result.stage2_sha256.current) throw new Error("hostile scripts changed trusted stage2");
NODE

# Wrong supplied merge identity and tracked reserved state must fail before any
# untrusted container execution.
set +e
node "$ROOT/scripts/selfcompile_heap_policy.mjs" \
  --repo "$scratch/repo" --base "$base" --latest-base-ref "$base" \
  --head "$head" --current "$base" --pr-number 1798 \
  >"$LOG_DIR/wrong-tree.json" 2>"$LOG_DIR/wrong-tree.log"
wrong_status=$?
set -e
[ "$wrong_status" -ne 0 ] || fail "wrong merge tree was accepted"
grep -q 'stale-or-wrong-merge-result' "$LOG_DIR/wrong-tree.json" || fail "wrong-tree reason mismatch"

git -C "$scratch/repo" reset --hard --quiet "$base"
mkdir -p "$scratch/repo/_build"
printf 'hostile\n' >"$scratch/repo/_build/tracked"
git -C "$scratch/repo" add -f _build/tracked
git -C "$scratch/repo" commit --quiet -m 'hostile tracked build state'
reserved_head="$(git -C "$scratch/repo" rev-parse --verify 'HEAD^{commit}')"
set +e
node "$ROOT/scripts/selfcompile_heap_policy.mjs" \
  --repo "$scratch/repo" --base "$base" --latest-base-ref "$base" \
  --head "$reserved_head" --synthesize-merge --pr-number 1798 \
  >"$LOG_DIR/reserved-path.json" 2>"$LOG_DIR/reserved-path.log"
reserved_status=$?
set -e
[ "$reserved_status" -ne 0 ] || fail "tracked reserved path was accepted"
grep -q 'reserved-path-present' "$LOG_DIR/reserved-path.json" || fail "reserved-path reason mismatch"

[ -z "$(docker ps -aq --filter name=vibe-selfcompile-policy)" ] || fail "policy containers leaked"
[ -z "$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^vibe-selfcompile-policy-input:' || true)" ] || fail "policy input images leaked"

echo "selfcompile policy Docker validation: ok"
