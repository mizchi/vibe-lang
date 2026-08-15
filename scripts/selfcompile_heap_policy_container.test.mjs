import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  dockerCreateArgs,
  dockerEnvironment,
  verifyPinnedRepoDigest,
  verifyRecord,
} from "./selfcompile_heap_policy_docker.mjs";

const lock = JSON.parse(readFileSync(new URL("./selfcompile_heap_policy_image.lock.json", import.meta.url), "utf8"));

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
    ...overrides,
  };
  const payload = Buffer.from(JSON.stringify(record)).toString("base64url");
  const mac = createHmac("sha256", key).update("vibe:selfcompile-heap-policy:result:v1\0").update(payload).digest("hex");
  return { key, line: `VIBE_HEAP_POLICY_RESULT_V1 ${payload} ${mac}\n` };
}

test("authenticated result accepts exactly one expected canonical record", () => {
  const signed = signedRecord();
  const result = verifyRecord(signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "bench/perf/selfcompile_input.vibe",
  });
  assert.equal(result.heap_bytes, 100);
});

test("authenticated result rejects tamper, duplicate, and wrong identity", () => {
  const signed = signedRecord();
  assert.throws(() => verifyRecord(signed.line.replace(/ [0-9a-f]{64}\n$/, ` ${"0".repeat(64)}\n`), signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x",
  }), /invalid-container-result-mac/);
  assert.throws(() => verifyRecord(signed.line + signed.line, signed.key, {
    label: "base", oid: "1".repeat(40), tree: "2".repeat(40), input: "x",
  }), /invalid-container-result/);
  assert.throws(() => verifyRecord(signed.line, signed.key, {
    label: "current", oid: "1".repeat(40), tree: "2".repeat(40), input: "x",
  }), /invalid-container-result/);
});
