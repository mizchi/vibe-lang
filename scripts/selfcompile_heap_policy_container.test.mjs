import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  dockerCreateArgs,
  dockerEnvironment,
  validateDockerAuthorityEnvironment,
  verifyPinnedRepoDigest,
  verifyRecord,
} from "./selfcompile_heap_policy_docker.mjs";
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
    assert.ok(fixtures.length >= 14);
    for (const fixture of fixtures) assert.doesNotThrow(() => new WebAssembly.Module(readFileSync(fixture.path)), fixture.name);
    for (const name of [
      "shell", "sh-lines", "sh-capture", "tcp", "http", "read-etc", "read-proc", "read-policy",
      "write-tmp", "write-opt", "write-etc", "write-repo", "write-generation-temp",
      "write-measurement-sibling", "fake-result", "infinite",
    ]) assert.ok(fixtures.some(fixture => fixture.name === name), `missing fixture ${name}`);
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

test("Docker authority rejects host overrides and nondefault active contexts in all modes", () => {
  assert.doesNotThrow(() => validateDockerAuthorityEnvironment({}, "default"));
  assert.doesNotThrow(() => validateDockerAuthorityEnvironment({ DOCKER_CONTEXT: "default" }, "default"));
  assert.throws(() => validateDockerAuthorityEnvironment({ DOCKER_HOST: "tcp://remote:2375" }, "default"), /remote-docker-forbidden/);
  assert.throws(() => validateDockerAuthorityEnvironment({ DOCKER_CONTEXT: "remote" }, "remote"), /remote-docker-forbidden/);
  assert.throws(() => validateDockerAuthorityEnvironment({}, "colima"), /remote-docker-forbidden/);
});

test("seccomp denies socket and privileged kernel surfaces", () => {
  const profile = JSON.parse(readFileSync(new URL("./selfcompile_heap_policy_seccomp.json", import.meta.url), "utf8"));
  const denied = new Set(profile.syscalls.flatMap(row => row.action === "SCMP_ACT_ERRNO" ? row.names : []));
  for (const name of ["socket", "connect", "ptrace", "mount", "bpf"]) assert.ok(denied.has(name));
});

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
  const payload = Buffer.from(JSON.stringify(record)).toString("base64url");
  const mac = createHmac("sha256", key).update("vibe:selfcompile-heap-policy:result:v1\0").update(payload).digest("hex");
  return { key, line: `VIBE_HEAP_POLICY_RESULT_V1 ${payload} ${mac}\n` };
}

test("authenticated result accepts exactly one expected canonical record", () => {
  const signed = signedRecord();
  const result = verifyRecord(signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "bench/perf/selfcompile_input.vibe", hostileFixtures: false,
  });
  assert.equal(result.heap_bytes, 100);
});

test("authenticated result requires canonical JSON and positive hostile/stat attestations", () => {
  const hostile = { schema: 1, denied: 11, safe: 2, timed_out: 1, fake_prefix_captured: 1, positive_stat_calls: 1, markers_absent: true };
  const signed = signedRecord({ hostile_fixture_attestation: hostile });
  assert.equal(verifyRecord(signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: true,
  }).hostile_fixture_attestation.denied, 11);
  const parsed = JSON.parse(Buffer.from(signed.line.split(" ")[1], "base64url").toString("utf8"));
  const noncanonicalPayload = Buffer.from(JSON.stringify(parsed, null, 2)).toString("base64url");
  const mac = createHmac("sha256", signed.key).update("vibe:selfcompile-heap-policy:result:v1\0").update(noncanonicalPayload).digest("hex");
  assert.throws(() => verifyRecord(`VIBE_HEAP_POLICY_RESULT_V1 ${noncanonicalPayload} ${mac}\n`, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: true,
  }), /noncanonical-container-result/);
  const invalid = signedRecord({ stat_token_attestations: [{ mode: "content-v1", calls: 0, unique: 0, transcript: "a".repeat(64) }, { mode: "content-v1", calls: 0, unique: 0, transcript: "a".repeat(64) }] });
  assert.throws(() => verifyRecord(invalid.line, invalid.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x", hostileFixtures: false,
  }), /invalid-container-result/);
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
