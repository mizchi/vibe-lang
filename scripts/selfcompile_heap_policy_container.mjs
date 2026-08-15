#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import {
  closeSync, constants, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync,
  openSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { canonicalJson } from "./selfcompile_heap_policy_canonical_json.mjs";
import { writeHostileWasmFixtures } from "./selfcompile_heap_policy_hostile_wasm.mjs";

const PREFIX = "VIBE_HEAP_POLICY_RESULT_V1 ";
const ROOT = "/workspace/repo";
const POLICY = "/opt/policy";
const BUILD = `${ROOT}/_build/selfcompile-policy`;
const MAX_LOG = 8 * 1024 * 1024;
const POLICY_RUNNER = `${POLICY}/scripts/run_wasm_vibe_host_runner.sh`;
const POLICY_BASE_RUNNER = `${POLICY}/scripts/run_wasm_vibe_host_runner_base.sh`;
const POLICY_SEED = `${POLICY}/bootstrap/seed/compiler.wasm`;

function policyEnvironment(writeRoot, extra = {}) {
  return {
    VIBE_POLICY_RAW_FS_ROOT: ROOT,
    VIBE_POLICY_RAW_FS_WRITE_ROOT: writeRoot,
    VIBE_POLICY_BASE_RUNNER: POLICY_BASE_RUNNER,
    VIBE_GENERATE_BUNDLE_RUNNER_SCRIPT: POLICY_RUNNER,
    VIBE_GENERATE_BUNDLE_SEED_WASM: POLICY_SEED,
    VIBE_GENERATION_RUNNER_SCRIPT: POLICY_RUNNER,
    VIBE_GENERATION_SEED_ARTIFACT: POLICY_SEED,
    ...extra,
  };
}

function die(reason, details = {}) {
  const error = new Error(reason);
  error.reason = reason;
  error.details = details;
  throw error;
}

function run(command, args, { cwd = ROOT, env = {}, capture = false, timeout = 900_000 } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env: { PATH: "/usr/local/bin:/usr/bin:/bin", HOME: `${BUILD}/home`, TMPDIR: "/tmp", LANG: "C", LC_ALL: "C", TZ: "UTC", SOURCE_DATE_EPOCH: "0", ...env },
    encoding: "utf8",
    maxBuffer: MAX_LOG,
    timeout,
    stdio: ["ignore", capture ? "pipe" : "ignore", "pipe"],
  });
  if (result.error || result.status !== 0 || result.signal) {
    die("container-command-failed", {
      command, status: result.status, signal: result.signal,
      error: result.error?.code ?? null,
      stderr: String(result.stderr ?? "").slice(-4000),
    });
  }
  return capture ? String(result.stdout ?? "") : String(result.stderr ?? "");
}

function contained(root, candidate) {
  const absolute = resolve(candidate);
  const rel = relative(root, absolute);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function rejectSymlinks(path, root = path) {
  const info = lstatSync(path);
  if (info.isSymbolicLink()) die("source-symlink-rejected", { path: relative(ROOT, path) });
  if (!info.isDirectory()) return;
  for (const name of readdirSync(path)) rejectSymlinks(join(path, name), root);
}

function safePinnedInput(relativePath) {
  if (typeof relativePath !== "string" || relativePath === "" || isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes("..")) {
    die("unsafe-pinned-input");
  }
  const path = resolve(ROOT, relativePath);
  if (!contained(ROOT, path)) die("unsafe-pinned-input");
  let cursor = ROOT;
  for (const part of relativePath.split("/")) {
    cursor = join(cursor, part);
    if (existsSync(cursor) && lstatSync(cursor).isSymbolicLink()) die("unsafe-pinned-input");
  }
  return path;
}

function overwritePinnedInput(path) {
  const blob = readFileSync("/opt/input/benchmark");
  mkdirSync(dirname(path), { recursive: true });
  let fd;
  try {
    fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
    writeFileSync(fd, blob);
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function installTrustedRuntime() {
  const scripts = `${ROOT}/scripts`;
  rmSync(scripts, { recursive: true, force: true });
  mkdirSync(scripts, { recursive: true });
  for (const name of [
    "run_wasm_vibe_host_runner.sh",
    "run_wasm_vibe_host_runner_base.sh",
    "wasm_vibe_host_runner.js",
    "wasm_vibe_host_runner_http_worker.js",
    "wasm_vibe_host_runner_tcp_worker.js",
  ]) copyFileSync(`${POLICY}/scripts/${name}`, `${scripts}/${name}`);
  mkdirSync(`${ROOT}/bootstrap/seed`, { recursive: true });
  copyFileSync(`${POLICY}/bootstrap/seed.json`, `${ROOT}/bootstrap/seed.json`);
  copyFileSync(`${POLICY}/bootstrap/seed/compiler.wasm`, `${ROOT}/bootstrap/seed/compiler.wasm`);
}

function parseRunner(stderr) {
  const memory = stderr.split(/\r?\n/).filter(line => line.startsWith("[wasm-memory]"));
  const attest = stderr.split(/\r?\n/).filter(line => line.startsWith("[policy-stat-token]"));
  if (memory.length !== 1 || attest.length !== 1) die("malformed-kpi-output");
  const mm = memory[0].match(/^\[wasm-memory\] run pages=([0-9]+) bytes=([0-9]+) heap_ptr=([0-9]+) host_alloc_ptr=([0-9]+) rss=([0-9]+)$/);
  const aa = attest[0].match(/^\[policy-stat-token\] mode=content-v1 calls=([0-9]+) unique=([0-9]+) transcript=([0-9a-f]{64})$/);
  if (!mm || !aa) die("malformed-kpi-output");
  return { heap: Number(mm[3]), attestation: { mode: "content-v1", calls: Number(aa[1]), unique: Number(aa[2]), transcript: aa[3] } };
}

function measure(stage2, input, trial) {
  const work = `${BUILD}/kpi-work-${trial}`;
  rmSync(work, { recursive: true, force: true });
  mkdirSync(`${work}/cache`, { recursive: true });
  const output = `${work}/out.wasm`;
  const result = spawnSync("bash", [
    POLICY_RUNNER,
    "--invoke", "cli_main", stage2, input, output, "__no_entry__",
  ], {
    cwd: ROOT,
    env: {
      PATH: "/usr/local/bin:/usr/bin:/bin", HOME: `${BUILD}/home`, TMPDIR: "/tmp",
      LANG: "C", LC_ALL: "C", TZ: "UTC", SOURCE_DATE_EPOCH: "0", VIBE_RC: "0",
      VIBE_PREOPEN_DIR: ROOT, VIBE_FS_COMPILE: "1", VIBE_IMPORT_ABI: "raw",
      VIBE_WASM_MEMORY_STATS: "1", VIBE_BUILD_CACHE_DIR: `${work}/cache`,
      VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
      ...policyEnvironment(BUILD),
    },
    encoding: "utf8", maxBuffer: MAX_LOG, timeout: 300_000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error || result.status !== 0 || result.signal) die("measurement-failed", { trial, status: result.status, signal: result.signal, stderr: String(result.stderr ?? "").slice(-4000) });
  if (!existsSync(output) || !statSync(output).isFile() || statSync(output).size === 0) die("measurement-output-missing", { trial });
  const parsed = parseRunner(String(result.stderr ?? ""));
  return { ...parsed, output_sha256: createHash("sha256").update(readFileSync(output)).digest("hex") };
}

function runHostileWasmFixtures() {
  const fixtureDir = `${BUILD}/hostile-wasm`;
  const fixtures = writeHostileWasmFixtures(fixtureDir, ROOT);
  let denied = 0;
  let safe = 0;
  let timedOut = 0;
  let fakePrefixCaptured = 0;
  let positiveStatCalls = 0;
  const preview2Escape = `${ROOT}/policy-preview2-escape`;
  rmSync(preview2Escape, { recursive: true, force: true });
  symlinkSync("/tmp", preview2Escape);
  for (const fixture of fixtures) {
    const runner = fixture.defaultMode ? POLICY_BASE_RUNNER : POLICY_RUNNER;
    const result = spawnSync("bash", [runner, "--invoke", "probe", fixture.path], {
      cwd: ROOT,
      env: {
        PATH: "/usr/local/bin:/usr/bin:/bin", HOME: `${BUILD}/home`, TMPDIR: "/tmp",
        LANG: "C", LC_ALL: "C", TZ: "UTC", VIBE_IMPORT_ABI: "raw",
        VIBE_PREOPEN_DIR: ROOT, VIBE_WASM_MEMORY_STATS: "1",
        ...(fixture.defaultMode ? {} : policyEnvironment(fixture.authority === "measurement" ? BUILD : `${ROOT}/_build`)),
      },
      encoding: "utf8", maxBuffer: 1024 * 1024,
      timeout: fixture.timeout ? 500 : 10_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stderr = String(result.stderr ?? "");
    const stdout = String(result.stdout ?? "");
    if (fixture.timeout) {
      if (result.error?.code !== "ETIMEDOUT" && result.signal !== "SIGTERM" && result.signal !== "SIGKILL") {
        die("hostile-timeout-not-enforced", { fixture: fixture.name, status: result.status, signal: result.signal, error: result.error?.code ?? null });
      }
      timedOut += 1;
    } else if (fixture.deny) {
      const diagnosticMatched = fixture.exactDeny
        ? stderr.split(/\r?\n/).includes(`Error: ${fixture.deny}`)
        : stderr.includes(fixture.deny);
      if (result.status === 0 || !diagnosticMatched) {
        die("hostile-import-not-denied", { fixture: fixture.name, status: result.status, stderr: stderr.slice(-1000) });
      }
      denied += 1;
    } else {
      if (result.error || result.status !== 0 || result.signal) {
        die("hostile-safe-probe-failed", { fixture: fixture.name, status: result.status, signal: result.signal, stderr: stderr.slice(-1000) });
      }
      safe += 1;
      if (fixture.created) {
        if (!existsSync(fixture.created) || readFileSync(fixture.created, "utf8") !== (fixture.createdContent ?? "owned")) die("hostile-generation-write-missing", { fixture: fixture.name });
        rmSync(fixture.created, { force: true });
      }
      if (fixture.fake) {
        if (!stdout.includes("VIBE_HEAP_POLICY_RESULT_V1 forged forged")) die("hostile-fake-prefix-not-exercised");
        fakePrefixCaptured += 1;
      }
      if (fixture.name === "safe-stat") {
        const match = stderr.match(/\[policy-stat-token\] mode=content-v1 calls=([0-9]+) unique=([0-9]+)/);
        if (!match || Number(match[1]) <= 0 || Number(match[2]) <= 0) die("hostile-safe-attestation-missing");
        positiveStatCalls = Number(match[1]);
      }
    }
  }
  rmSync(preview2Escape, { recursive: true, force: true });
  for (const marker of [
    "/tmp/policy-hostile-marker",
    "/tmp/policy-preview2-symlink-marker",
    "/opt/policy-hostile-marker",
    "/etc/policy-hostile-marker",
    `${ROOT}/outside-policy-write`,
    `${ROOT}/preview2-repo-top-marker`,
    `${ROOT}/_build/final-policy-sibling-write`,
    `${ROOT}/_build/preview2-measurement-sibling-marker`,
  ]) {
    if (existsSync(marker)) die("hostile-marker-created", { marker });
  }
  return { schema: 1, denied, safe, timed_out: timedOut, fake_prefix_captured: fakePrefixCaptured, positive_stat_calls: positiveStatCalls, markers_absent: true };
}

function main() {
  // docker's attached stdin reaches EOF immediately after this read. Keep fd 0
  // open at EOF because closing a libuv-managed stdio fd trips Node's uv__close
  // assertion when later child processes are reaped; the key never enters a
  // child environment, argv, file, or guest memory.
  const keyText = readFileSync(0, "utf8").trim();
  if (!/^[0-9a-f]{64}$/.test(keyText)) die("invalid-result-key");
  const key = Buffer.from(keyText, "hex");
  const config = JSON.parse(Buffer.from(process.argv[2], "base64url").toString("utf8"));
  if (Object.keys(config).sort().join(",") !== "hostile_fixtures,input,label,oid,tree" || typeof config.hostile_fixtures !== "boolean" || !/^[0-9a-f]{40}$/.test(config.oid) || !/^[0-9a-f]{40}$/.test(config.tree) || !["base", "current"].includes(config.label)) die("invalid-container-config");

  mkdirSync(ROOT, { recursive: true, mode: 0o700 });
  run("tar", ["--no-same-owner", "--no-same-permissions", "-xf", "/opt/input/source.tar", "-C", ROOT], { cwd: "/workspace" });
  if (existsSync(`${ROOT}/_build`)) die("reserved-path-present");
  rejectSymlinks(`${ROOT}/lib`);
  const input = safePinnedInput(config.input);
  overwritePinnedInput(input);
  installTrustedRuntime();
  mkdirSync(`${BUILD}/home`, { recursive: true });
  const hostileFixtureAttestation = config.hostile_fixtures ? runHostileWasmFixtures() : null;

  run("bash", [`${POLICY}/scripts/generate_bundle.sh`], {
    env: {
      VIBE_PROJECT_ROOT: ROOT,
      VIBE_REGEN_MODULE_SOURCE: "1",
      VIBE_ADAPTER_MODULE_SOURCE_OUT: `${ROOT}/lib/@vibe/compiler/_cli_adapter_module_source.vibe`,
      VIBE_IMPORT_ABI: "raw",
      VIBE_GENERATION_AUTO_FETCH_SEED: "0",
      VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
      ...policyEnvironment(`${ROOT}/_build`),
    },
  });
  const moduleSource = `${ROOT}/lib/@vibe/compiler/_cli_adapter_module_source.vibe`;
  if (!existsSync(moduleSource) || statSync(moduleSource).size === 0) die("generated-module-source-missing");

  const generation = `${BUILD}/generation`;
  run("bash", [`${POLICY}/scripts/generations.sh`, "build", "--manifest", `${ROOT}/bootstrap/seed.json`, "--out-dir", generation, "--skip-run-validation"], {
    timeout: 1_200_000,
    env: {
      VIBE_PROJECT_ROOT: ROOT,
      VIBE_PREBUILT_MODULE_SOURCE: moduleSource,
      VIBE_GENERATION_AUTO_FETCH_SEED: "0",
      VIBE_GENERATION_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_RC: "0",
      ...policyEnvironment(`${ROOT}/_build`),
    },
  });
  const stage2 = `${generation}/stage2.wasm`;
  if (!existsSync(stage2) || statSync(stage2).size === 0) die("stage2-missing");
  const stage2Sha256 = createHash("sha256").update(readFileSync(stage2)).digest("hex");
  const measurements = [measure(stage2, input, 1), measure(stage2, input, 2)];
  if (measurements[0].heap !== measurements[1].heap) die("nondeterministic-heap");
  if (JSON.stringify(measurements[0].attestation) !== JSON.stringify(measurements[1].attestation)) die("nondeterministic-stat-token");

  const record = {
    schema: 1, label: config.label, oid: config.oid, tree: config.tree,
    canonical_root: ROOT,
    heap_bytes: measurements[0].heap,
    trials: measurements.map(item => item.heap),
    stage2_sha256: stage2Sha256,
    output_sha256: measurements.map(item => item.output_sha256),
    stat_token_attestations: measurements.map(item => item.attestation),
    hostile_fixture_attestation: hostileFixtureAttestation,
  };
  const payload = Buffer.from(canonicalJson(record)).toString("base64url");
  const mac = createHmac("sha256", key).update("vibe:selfcompile-heap-policy:result:v1\0").update(payload).digest("hex");
  process.stdout.write(`${PREFIX}${payload} ${mac}\n`);
}

try { main(); } catch (error) {
  console.error(`[selfcompile-policy-container] ${error.reason ?? "container-failed"} ${JSON.stringify(error.details ?? { message: String(error?.stack ?? error) })}`);
  process.exit(1);
}
