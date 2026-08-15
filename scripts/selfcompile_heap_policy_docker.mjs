import { execFileSync, spawnSync } from "node:child_process";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PREFIX = "VIBE_HEAP_POLICY_RESULT_V1 ";
const MAX_LOG = 16 * 1024 * 1024;
const SCRIPTS = [
  "selfcompile_heap_policy_container.mjs",
  "selfcompile_heap_policy_hostile_wasm.mjs",
  "selfcompile_heap_policy_policy_runner.sh",
  "generations.sh", "generate_bundle.sh", "trace_lib.sh",
  "wasm_vibe_host_runner.js",
  "wasm_vibe_host_runner_http_worker.js", "wasm_vibe_host_runner_tcp_worker.js",
];

function fail(reason, details = {}) {
  const error = new Error(reason);
  error.reason = reason;
  error.details = details;
  throw error;
}

export function dockerEnvironment(source = process.env) {
  const env = { ...source };
  // The tool image is immutable digest-pinned and verified after pull.
  // Docker Content Trust is legacy Notary-v1 tag signing; forcing it makes a
  // digest reference fail when the registry publishes no Notary metadata.
  // Scrub an inherited setting so caller state cannot re-enable that unrelated
  // tag policy for this digest-authoritative lane.
  delete env.DOCKER_CONTENT_TRUST;
  return env;
}

function docker(args, { input = null, capture = true, timeout = 1_800_000 } = {}) {
  const result = spawnSync("docker", args, {
    input, encoding: "utf8", timeout, maxBuffer: MAX_LOG,
    stdio: [input === null ? "ignore" : "pipe", capture ? "pipe" : "ignore", "pipe"],
    env: dockerEnvironment(),
  });
  if (result.error || result.status !== 0 || result.signal) {
    fail("docker-failed", { args: args.slice(0, 3), status: result.status, signal: result.signal, error: result.error?.code ?? null, stderr: String(result.stderr ?? "").slice(-4000) });
  }
  return { stdout: String(result.stdout ?? ""), stderr: String(result.stderr ?? "") };
}

function parseLock(path) {
  let lock;
  try { lock = JSON.parse(readFileSync(path, "utf8")); } catch { fail("malformed-image-lock"); }
  const keys = Object.keys(lock).sort().join(",");
  if (keys !== "image,node,platform,python,schema" || lock.schema !== 1 || lock.platform !== "linux/amd64" || !/^node:24\.12\.0-bookworm@sha256:[0-9a-f]{64}$/.test(lock.image) || lock.node !== "24.12.0" || lock.python !== "3.11.2") fail("malformed-image-lock");
  return lock;
}

function makeWorldReadable(path) {
  const info = lstatSync(path);
  if (info.isDirectory()) {
    chmodSync(path, 0o755);
    for (const name of readdirSync(path)) makeWorldReadable(join(path, name));
  } else if (info.isFile()) chmodSync(path, 0o644);
  else fail("unsafe-container-input-node", { path });
}

function prepareTrustedPolicy(trustedRoot, lease, seedSha) {
  const policy = join(lease, "container-policy");
  rmSync(policy, { recursive: true, force: true });
  mkdirSync(join(policy, "scripts"), { recursive: true, mode: 0o700 });
  for (const name of SCRIPTS) {
    const source = join(trustedRoot, "scripts", name);
    if (!existsSync(source) || !statSync(source).isFile()) fail("trusted-harness-missing", { name });
    cpSync(source, join(policy, "scripts", name));
  }
  const baseRunner = join(trustedRoot, "scripts", "run_wasm_vibe_host_runner.sh");
  if (!existsSync(baseRunner) || !statSync(baseRunner).isFile()) fail("trusted-harness-missing", { name: "run_wasm_vibe_host_runner.sh" });
  cpSync(baseRunner, join(policy, "scripts", "run_wasm_vibe_host_runner_base.sh"));
  cpSync(join(trustedRoot, "scripts", "selfcompile_heap_policy_policy_runner.sh"), join(policy, "scripts", "run_wasm_vibe_host_runner.sh"));
  mkdirSync(join(policy, "bootstrap", "seed"), { recursive: true });
  cpSync(join(trustedRoot, "bootstrap", "seed.json"), join(policy, "bootstrap", "seed.json"));
  const seed = join(trustedRoot, "bootstrap", "seed", "compiler.wasm");
  const actual = existsSync(seed) ? createHash("sha256").update(readFileSync(seed)).digest("hex") : "";
  if (actual !== seedSha) fail("trusted-seed-missing-or-stale", { expected: seedSha, actual });
  cpSync(seed, join(policy, "bootstrap", "seed", "compiler.wasm"));
  makeWorldReadable(policy);
  return policy;
}

export function dockerCreateArgs({ lock, seccompPath, label, image = lock.image }) {
  return [
    "create", "-i", "--platform", lock.platform,
    "--name", `vibe-selfcompile-policy-${label}-${process.pid}`,
    "--read-only", "--network", "none", "--user", "65532:65532",
    "--cap-drop", "ALL", "--security-opt", "no-new-privileges=true",
    "--security-opt", `seccomp=${seccompPath}`,
    "--memory", "3g", "--memory-swap", "3g", "--cpus", "2",
    "--pids-limit", "128", "--ulimit", "core=0", "--ulimit", "nofile=1024:1024",
    "--tmpfs", "/workspace:rw,nosuid,nodev,noexec,size=1g,uid=65532,gid=65532,mode=0700",
    "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700",
    "--entrypoint", "node", image,
    "/opt/policy/scripts/selfcompile_heap_policy_container.mjs",
  ];
}

export function validateDockerAuthorityEnvironment(env, activeContext) {
  if (env.DOCKER_HOST) fail("remote-docker-forbidden");
  if (env.DOCKER_CONTEXT && env.DOCKER_CONTEXT !== "default") fail("remote-docker-forbidden");
  if (activeContext !== "default") fail("remote-docker-forbidden");
}

export function verifyPinnedRepoDigest(lock, repoDigestsText) {
  const at = lock.image.indexOf("@");
  const digest = at >= 0 ? lock.image.slice(at + 1) : "";
  if (!/^sha256:[0-9a-f]{64}$/.test(digest) || !String(repoDigestsText).includes(digest)) {
    fail("pinned-image-mismatch");
  }
  return digest;
}

function verifyImage(lock) {
  const activeContext = docker(["context", "show"]).stdout.trim();
  validateDockerAuthorityEnvironment(process.env, activeContext);
  docker(["version", "--format", "{{.Server.Version}}"]);
  docker(["pull", "--platform", lock.platform, lock.image], { capture: false, timeout: 600_000 });
  const inspected = docker(["image", "inspect", lock.image, "--format", "{{json .RepoDigests}}"]);
  verifyPinnedRepoDigest(lock, inspected.stdout);
}

export function verifyRecord(output, key, expected) {
  const lines = output.split(/\r?\n/).filter(line => line.startsWith(PREFIX));
  if (lines.length !== 1) fail("invalid-container-result", { records: lines.length });
  const parts = lines[0].slice(PREFIX.length).split(" ");
  if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[0-9a-f]{64}$/.test(parts[1])) fail("invalid-container-result");
  const want = createHmac("sha256", key).update("vibe:selfcompile-heap-policy:result:v1\0").update(parts[0]).digest();
  const got = Buffer.from(parts[1], "hex");
  if (got.length !== want.length || !timingSafeEqual(got, want)) fail("invalid-container-result-mac");
  let record;
  try { record = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8")); } catch { fail("invalid-container-result"); }
  if (Buffer.from(JSON.stringify(record)).toString("base64url") !== parts[0]) fail("noncanonical-container-result");
  const keys = Object.keys(record).sort().join(",");
  const safePositive = value => Number.isSafeInteger(value) && value > 0;
  const validAttestation = value => value !== null && typeof value === "object" && !Array.isArray(value) && Object.keys(value).sort().join(",") === "calls,mode,transcript,unique" && value.mode === "content-v1" && safePositive(value.calls) && safePositive(value.unique) && value.unique <= value.calls && /^[0-9a-f]{64}$/.test(value.transcript);
  const hostile = record.hostile_fixture_attestation;
  const validHostile = expected.hostileFixtures
    ? hostile !== null && typeof hostile === "object" && !Array.isArray(hostile) && Object.keys(hostile).sort().join(",") === "denied,fake_prefix_captured,markers_absent,positive_stat_calls,safe,schema,timed_out" && hostile.schema === 1 && hostile.denied >= 11 && hostile.safe >= 2 && hostile.timed_out === 1 && hostile.fake_prefix_captured === 1 && hostile.markers_absent === true && safePositive(hostile.positive_stat_calls)
    : hostile === null;
  if (keys !== "canonical_root,heap_bytes,hostile_fixture_attestation,label,oid,output_sha256,schema,stage2_sha256,stat_token_attestations,tree,trials" || record.schema !== 1 || record.label !== expected.label || record.oid !== expected.oid || record.tree !== expected.tree || record.canonical_root !== "/workspace/repo" || !validHostile || !safePositive(record.heap_bytes) || !Array.isArray(record.trials) || record.trials.length !== 2 || record.trials.some(value => !safePositive(value)) || record.trials[0] !== record.trials[1] || record.heap_bytes !== record.trials[0] || !/^[0-9a-f]{64}$/.test(record.stage2_sha256) || !Array.isArray(record.output_sha256) || record.output_sha256.length !== 2 || record.output_sha256.some(hash => !/^[0-9a-f]{64}$/.test(hash)) || !Array.isArray(record.stat_token_attestations) || record.stat_token_attestations.length !== 2 || !record.stat_token_attestations.every(validAttestation) || JSON.stringify(record.stat_token_attestations[0]) !== JSON.stringify(record.stat_token_attestations[1])) fail("invalid-container-result");
  return {
    heap_bytes: record.heap_bytes,
    trials: record.trials,
    stage2_sha256: record.stage2_sha256,
    stat_token_attestations: record.stat_token_attestations,
    hostile_fixture_attestation: record.hostile_fixture_attestation,
    normalized_paths: { canonical_root: record.canonical_root, input: expected.input, stage2: "_build/selfcompile-policy/generation/stage2.wasm", output: "_build/selfcompile-policy/kpi-work/out.wasm", cache: "_build/selfcompile-policy/kpi-work/cache", home: "_build/selfcompile-policy/home", tmpdir: "/tmp", vibe_home: "_build/selfcompile-policy/home" },
  };
}

export function measureTreeInDocker({ trustedRoot, lease, archivePath, inputBlob, input, label, oid, tree, seedSha }) {
  const lockPath = join(trustedRoot, "scripts", "selfcompile_heap_policy_image.lock.json");
  const lock = parseLock(lockPath);
  verifyImage(lock);
  const policy = prepareTrustedPolicy(trustedRoot, lease, seedSha);
  const inputDir = join(lease, `container-input-${label}`);
  rmSync(inputDir, { recursive: true, force: true });
  mkdirSync(inputDir, { recursive: true });
  cpSync(archivePath, join(inputDir, "source.tar"));
  writeFileSync(join(inputDir, "benchmark"), inputBlob, { mode: 0o644 });
  makeWorldReadable(inputDir);
  const hostileFixtures = process.env.VIBE_HEAP_POLICY_HOSTILE_FIXTURES === "1";
  const config = Buffer.from(JSON.stringify({ label, oid, tree, input, hostile_fixtures: hostileFixtures })).toString("base64url");
  // docker cp cannot populate a container whose rootfs is already marked
  // read-only. Create a never-started staging container, copy the immutable
  // inputs, commit that filesystem as a content-addressed local layer, then
  // execute only a fresh --read-only container from that layer.
  const nonce = randomBytes(12).toString("hex");
  const staging = docker(["create", "--platform", lock.platform, "--name", `vibe-selfcompile-policy-stage-${nonce}`, lock.image, "true"]).stdout.trim();
  if (!/^[0-9a-f]{12,64}$/.test(staging)) fail("docker-create-failed");
  const derivedImage = `vibe-selfcompile-policy-input:${nonce}`;
  let id = null;
  try {
    docker(["cp", `${policy}/.`, `${staging}:/opt/policy`]);
    docker(["cp", `${inputDir}/.`, `${staging}:/opt/input`]);
    docker(["commit", "--pause=false", staging, derivedImage], { capture: false, timeout: 300_000 });
    docker(["rm", "-f", staging], { capture: false, timeout: 30_000 });
    const createArgs = dockerCreateArgs({ lock, seccompPath: join(trustedRoot, "scripts", "selfcompile_heap_policy_seccomp.json"), label, image: derivedImage });
    createArgs.push(config);
    id = docker(createArgs).stdout.trim();
    if (!/^[0-9a-f]{12,64}$/.test(id)) fail("docker-create-failed");
    const key = randomBytes(32);
    const started = docker(["start", "-a", "-i", id], { input: `${key.toString("hex")}\n`, timeout: 1_800_000 });
    return verifyRecord(started.stdout, key, { label, oid, tree, input, hostileFixtures });
  } finally {
    try { docker(["rm", "-f", staging], { capture: false, timeout: 30_000 }); } catch {}
    if (id) try { docker(["rm", "-f", id], { capture: false, timeout: 30_000 }); } catch {}
    if (process.env.VIBE_HEAP_POLICY_KEEP_DOCKER !== "1") try { docker(["image", "rm", "-f", derivedImage], { capture: false, timeout: 60_000 }); } catch {}
  }
}
