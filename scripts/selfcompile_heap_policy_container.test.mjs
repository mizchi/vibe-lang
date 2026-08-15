import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  dockerCreateArgs,
  dockerEnvironment,
  inspectDockerAuthority,
  parseDockerContextEndpoint,
  validateDockerAuthorityEnvironment,
  verifyPinnedRepoDigest,
  verifyRecord,
} from "./selfcompile_heap_policy_docker.mjs";
import { canonicalJson } from "./selfcompile_heap_policy_canonical_json.mjs";
import { writeHostileWasmFixtures } from "./selfcompile_heap_policy_hostile_wasm.mjs";

const lock = JSON.parse(readFileSync(new URL("./selfcompile_heap_policy_image.lock.json", import.meta.url), "utf8"));

test("immutable policy wrapper contains every generation and measurement runner invocation", () => {
  const wrapper = readFileSync(new URL("./selfcompile_heap_policy_policy_runner.sh", import.meta.url), "utf8");
  for (const selector of ["--policy-stat-token", "--policy-stat-root", "--policy-raw-fs-root", "--policy-raw-fs-write-root"]) assert.ok(wrapper.includes(selector));
  for (const authority of ["/workspace/repo/_build", "selfcompile-policy"]) assert.ok(wrapper.includes(authority));
  assert.ok(wrapper.includes("VIBE_POLICY_RAW_FS_WRITE_ROOT"));
  assert.ok(wrapper.includes("/opt/policy/scripts/run_wasm_vibe_host_runner_base.sh"));
  const bundle = readFileSync(new URL("./generate_bundle.sh", import.meta.url), "utf8");
  assert.equal((bundle.match(/run_bundle_runner /g) ?? []).length, 5);
  assert.equal(/bash scripts\/run_wasm_vibe_host_runner\.sh/.test(bundle), false);
  const generations = readFileSync(new URL("./generations.sh", import.meta.url), "utf8");
  assert.ok(generations.includes('bash "$RUNNER_SCRIPT"'));
  assert.ok(generations.includes("/opt/policy/bootstrap/seed/compiler.wasm"));
  const container = readFileSync(new URL("./selfcompile_heap_policy_container.mjs", import.meta.url), "utf8");
  assert.ok(container.includes("policyEnvironment(`${ROOT}/_build`)"));
  assert.ok(container.includes("policyEnvironment(BUILD)"));
  assert.equal(container.includes('"--policy-raw-fs-root", ROOT'), false);
});

test("hostile Wasm fixture modules are real and cover denied imports, paths, fake output, and timeout", () => {
  const dir = mkdtempSync(join(os.tmpdir(), "vibe-policy-hostile-wasm-"));
  try {
    const fixtures = writeHostileWasmFixtures(dir);
    assert.ok(fixtures.length >= 29);
    for (const fixture of fixtures) {
      const module = new WebAssembly.Module(readFileSync(fixture.path));
      assert.equal(typeof WebAssembly.Module.exports(module).find(item => item.name === "probe"), "object", fixture.name);
    }
    for (const name of [
      "chdir-write", "shell", "sh-lines", "sh-capture", "tcp", "http", "read-etc", "read-proc", "read-policy",
      "write-tmp", "write-opt", "write-etc", "write-repo", "write-generation-temp",
      "write-measurement-sibling", "fake-result", "infinite", "preview2-open-repo-top-0.2.6",
      "preview2-open-measurement-sibling-0.3.0", "preview2-open-symlink-escape-0.2.6",
      "preview2-socket-tcp", "preview2-socket-network", "preview2-http", "preview2-cli-environment",
      "preview2-cli-exit", "preview2-cli-stdin", "preview2-cli-stdout", "preview2-cli-stderr",
      "preview2-io-streams", "wasi-preview1-allowed", "default-preview2-open",
    ]) assert.ok(fixtures.some(fixture => fixture.name === name), `missing fixture ${name}`);
    const preview2 = fixtures.filter(fixture => fixture.name.startsWith("preview2-") || fixture.name === "default-preview2-open");
    for (const fixture of preview2) {
      const imports = WebAssembly.Module.imports(new WebAssembly.Module(readFileSync(fixture.path)));
      assert.ok(imports.some(item => item.module.startsWith("wasi:")), fixture.name);
      if (!fixture.defaultMode) assert.equal(fixture.exactDeny, true, fixture.name);
    }
    const preview1 = fixtures.find(fixture => fixture.name === "wasi-preview1-allowed");
    assert.deepEqual(WebAssembly.Module.imports(new WebAssembly.Module(readFileSync(preview1.path))).map(item => item.module), ["wasi_snapshot_preview1"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("real Wasm policy gate denies wasi: imports, allows Preview1, and leaves default Preview2 working", () => {
  const dir = realpathSync(mkdtempSync(join(os.tmpdir(), "vibe-policy-wasi-gate-")));
  try {
    mkdirSync(join(dir, "lib"));
    const fixtures = writeHostileWasmFixtures(dir, dir);
    const run = (fixture, policy) => spawnSync(process.execPath, [
      new URL("./wasm_vibe_host_runner.js", import.meta.url).pathname,
      ...(policy ? ["--policy-stat-token", "content-v1", "--policy-stat-root", dir, "--policy-raw-fs-root", dir, "--policy-raw-fs-write-root", dir] : []),
      "--invoke", "probe", fixture.path,
    ], { cwd: dir, encoding: "utf8", env: { PATH: process.env.PATH, VIBE_IMPORT_ABI: "raw", VIBE_PREOPEN_DIR: dir } });
    const chdir = fixtures.find(fixture => fixture.name === "chdir-write");
    const chdirDenied = run(chdir, true);
    assert.notEqual(chdirDenied.status, 0);
    assert.ok(chdirDenied.stderr.split(/\r?\n/).includes("Error: policy raw import denied: fs_chdir"));
    assert.equal(existsSync(join(dir, "lib/_build/policy-chdir-marker")), false);
    const chdirDefault = run(chdir, false);
    assert.equal(chdirDefault.status, 0, chdirDefault.stderr);
    assert.equal(readFileSync(join(dir, "lib/_build/policy-chdir-marker"), "utf8"), "owned");
    const denied = fixtures.find(fixture => fixture.name === "preview2-socket-tcp");
    const deniedResult = run(denied, true);
    assert.notEqual(deniedResult.status, 0);
    assert.ok(deniedResult.stderr.split(/\r?\n/).includes("Error: policy raw module import denied: wasi:sockets/tcp@0.2.0"));
    const preview1Result = run(fixtures.find(fixture => fixture.name === "wasi-preview1-allowed"), true);
    assert.equal(preview1Result.status, 0, preview1Result.stderr);
    const defaultResult = run(fixtures.find(fixture => fixture.name === "default-preview2-open"), false);
    assert.equal(defaultResult.status, 0, defaultResult.stderr);
    assert.equal(existsSync(join(dir, "_build/selfcompile-policy/default-preview2-marker")), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("Docker execution argv is pinned, non-root, no-bind, no-network, and read-only", () => {
  const args = dockerCreateArgs({ lock, seccompPath: "/trusted/seccomp.json", label: "base" });
  assert.equal(args[0], "create");
  assert.ok(args.includes("--read-only"));
  assert.deepEqual(args.slice(args.indexOf("--network"), args.indexOf("--network") + 2), ["--network", "none"]);
  assert.deepEqual(args.slice(args.indexOf("--user"), args.indexOf("--user") + 2), ["--user", "65532:65532"]);
  assert.ok(args.includes("ALL"));
  assert.ok(args.includes("no-new-privileges=true"));
  assert.ok(args.includes("3g"));
  assert.ok(args.includes("128"));
  assert.ok(args.includes(lock.image));
  assert.ok(args.includes("linux/amd64"));
  for (const forbidden of ["-v", "--volume", "--mount", "--privileged", "host", "/var/run/docker.sock", "--env", "-e"]) {
    assert.equal(args.includes(forbidden), false, `forbidden Docker arg: ${forbidden}`);
  }
});

test("digest pin and post-pull RepoDigest verification need no Docker Content Trust", () => {
  assert.match(lock.image, /@sha256:[0-9a-f]{64}$/);
  const digest = lock.image.slice(lock.image.indexOf("@") + 1);
  assert.equal(verifyPinnedRepoDigest(lock, JSON.stringify([`node@${digest}`])), digest);
  assert.throws(() => verifyPinnedRepoDigest(lock, JSON.stringify([`node@sha256:${"0".repeat(64)}`])), /pinned-image-mismatch/);
  assert.deepEqual(dockerEnvironment({ PATH: "/bin", DOCKER_CONTENT_TRUST: "1" }), { PATH: "/bin" });
});

test("Docker authority rejects all environment overrides before inspecting an arbitrary selected context", () => {
  assert.doesNotThrow(() => validateDockerAuthorityEnvironment({}));
  for (const env of [
    { DOCKER_HOST: "tcp://remote:2375" },
    { DOCKER_HOST: "unix:///var/run/docker.sock" },
    { DOCKER_CONTEXT: "default" },
    { DOCKER_CONTEXT: "colima" },
  ]) assert.throws(() => validateDockerAuthorityEnvironment(env), /remote-docker-forbidden/);
  const calls = [];
  const result = inspectDockerAuthority(args => {
    calls.push(args);
    if (args[1] === "show") return { stdout: "colima\n" };
    return { stdout: '"unix:///Users/alice/.colima/custom/docker.sock"\n' };
  }, {});
  assert.deepEqual(result, { context: "colima", endpoint: "unix:///Users/alice/.colima/custom/docker.sock" });
  assert.deepEqual(calls, [
    ["context", "show"],
    ["context", "inspect", "colima", "--format", "{{json .Endpoints.docker.Host}}"],
  ]);
  let called = false;
  assert.throws(() => inspectDockerAuthority(() => { called = true; return { stdout: "" }; }, { DOCKER_CONTEXT: "default" }), /remote-docker-forbidden/);
  assert.equal(called, false);
});

test("Docker authority accepts only empty-authority absolute unix endpoints", () => {
  for (const endpoint of [
    "unix:///var/run/docker.sock",
    "unix:///run/user/1000/docker.sock",
    "unix:///Users/alice/.colima/default/docker.sock",
    "unix:///Users/alice/.colima/custom/docker.sock",
  ]) assert.equal(parseDockerContextEndpoint(`${JSON.stringify(endpoint)}\n`), endpoint);
  for (const endpoint of [
    "tcp://127.0.0.1:2375", "tcp://remote:2375", "ssh://host/run/docker.sock",
    "npipe:////./pipe/docker_engine", "http://host", "https://host", "fd://3",
    "/var/run/docker.sock", "relative.sock", "unix://host/path", "unix:relative", "unix:/relative", "unix://",
  ]) assert.throws(() => parseDockerContextEndpoint(`${JSON.stringify(endpoint)}\n`), /remote-docker-forbidden/, endpoint);
  for (const malformed of ["", "not-json\n", "null\n", '"unix:///one"\n"unix:///two"\n']) {
    assert.throws(() => parseDockerContextEndpoint(malformed), /remote-docker-forbidden/);
  }
});

test("seccomp denies socket and privileged kernel surfaces", () => {
  const profile = JSON.parse(readFileSync(new URL("./selfcompile_heap_policy_seccomp.json", import.meta.url), "utf8"));
  const denied = new Set(profile.syscalls.flatMap(row => row.action === "SCMP_ACT_ERRNO" ? row.names : []));
  for (const name of ["socket", "connect", "ptrace", "mount", "bpf"]) assert.ok(denied.has(name));
});

function signPayload(payloadText, key = Buffer.alloc(32, 7)) {
  const payload = Buffer.from(payloadText).toString("base64url");
  const mac = createHmac("sha256", key).update("vibe:selfcompile-heap-policy:result:v1\0").update(payload).digest("hex");
  return { key, line: `VIBE_HEAP_POLICY_RESULT_V1 ${payload} ${mac}\n` };
}

function signedRecord(overrides = {}, key = Buffer.alloc(32, 7)) {
  const attestation = { mode: "content-v1", calls: 12, unique: 3, transcript: "a".repeat(64) };
  const record = {
    schema: 1,
    label: "base",
    oid: "1".repeat(40),
    tree: "2".repeat(40),
    canonical_root: "/workspace/repo",
    heap_bytes: 100,
    trials: [100, 100],
    stage2_sha256: "3".repeat(64),
    output_sha256: ["4".repeat(64), "4".repeat(64)],
    stat_token_attestations: [attestation, attestation],
    hostile_fixture_attestation: null,
    ...overrides,
  };
  return signPayload(canonicalJson(record), key);
}

test("authenticated result accepts exactly one expected canonical record", () => {
  const signed = signedRecord();
  const result = verifyRecord(signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "bench/perf/selfcompile_input.vibe", hostileFixtures: false,
  });
  assert.equal(result.heap_bytes, 100);
  assert.deepEqual(result.output_sha256, ["4".repeat(64), "4".repeat(64)]);
});

test("authenticated result requires canonical JSON and positive hostile/stat attestations", () => {
  const hostile = { schema: 1, denied: 12, safe: 2, timed_out: 1, fake_prefix_captured: 1, positive_stat_calls: 1, markers_absent: true };
  const signed = signedRecord({ hostile_fixture_attestation: hostile });
  assert.equal(verifyRecord(signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: true,
  }).hostile_fixture_attestation.denied, 12);
  const parsed = JSON.parse(Buffer.from(signed.line.split(" ")[1], "base64url").toString("utf8"));
  const verifyHostile = candidate => verifyRecord(candidate.line, candidate.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: true,
  });
  const noncanonicalVariants = [
    JSON.stringify(parsed, null, 2),
    JSON.stringify(Object.fromEntries(Object.entries(parsed).reverse())),
    JSON.stringify({ ...parsed, hostile_fixture_attestation: Object.fromEntries(Object.entries(parsed.hostile_fixture_attestation).reverse()) }),
  ];
  for (const text of noncanonicalVariants) {
    assert.throws(() => verifyHostile(signPayload(text, signed.key)), /noncanonical-container-result/);
  }
  for (const invalidHostile of [
    { ...hostile, denied: 11 },
    { ...hostile, denied: 11.5 },
    { ...hostile, safe: 2.5 },
    { ...hostile, denied: Number.MAX_SAFE_INTEGER + 1 },
    { ...hostile, safe: Number.MAX_SAFE_INTEGER + 1 },
  ]) {
    assert.throws(() => verifyHostile(signedRecord({ hostile_fixture_attestation: invalidHostile }, signed.key)), /invalid-container-result/);
  }
  const invalid = signedRecord({ stat_token_attestations: [{ mode: "content-v1", calls: 0, unique: 0, transcript: "a".repeat(64) }, { mode: "content-v1", calls: 0, unique: 0, transcript: "a".repeat(64) }] });
  assert.throws(() => verifyRecord(invalid.line, invalid.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result/);
  const divergentOutput = signedRecord({ output_sha256: ["4".repeat(64), "5".repeat(64)] });
  assert.throws(() => verifyRecord(divergentOutput.line, divergentOutput.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result/);
});

test("canonical JSON recursively sorts object keys while preserving arrays and primitive encoding", () => {
  assert.equal(canonicalJson({ z: 1, nested: { b: true, a: null }, array: [{ d: 4, c: "x" }, 2] }), '{"array":[{"c":"x","d":4},2],"nested":{"a":null,"b":true},"z":1}');
});

test("authenticated result rejects tamper, duplicate, and wrong identity", () => {
  const signed = signedRecord();
  assert.throws(() => verifyRecord(signed.line.replace(/ [0-9a-f]{64}\n$/, ` ${"0".repeat(64)}\n`), signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result-mac/);
  assert.throws(() => verifyRecord(signed.line + signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result/);
  assert.throws(() => verifyRecord(signed.line, signed.key, {
    label: "current", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result/);
});
