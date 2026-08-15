"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  buildFsMetadataHashParts,
  configurePolicyStatToken,
  contentStatToken,
  parseArgs,
  projectContentStatDigest,
} = require("./wasm_vibe_host_runner.js");

function fixture() {
  const outer = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), "vibe-stat-token-"));
  const root = path.join(outer, "root");
  fs.mkdirSync(root);
  return { outer, root };
}

function withCwd(dir, fn) {
  const old = process.cwd();
  process.chdir(dir);
  try { return fn(); } finally { process.chdir(old); }
}

function config(root) {
  return withCwd(root, () => configurePolicyStatToken("content-v1", root));
}

function assertToken(value) {
  assert.ok(value >= 1n << 60n && value <= (1n << 61n) - 1n);
  assert.match(value.toString(), /^[1-9][0-9]{18}$/);
}

test("content-v1 is inode, mtime, root, alias, and path independent", () => {
  const a = fixture();
  const b = fixture();
  try {
    fs.writeFileSync(path.join(a.root, "one.vibe"), "same bytes\n");
    fs.writeFileSync(path.join(a.root, "two.vibe"), "same bytes\n");
    fs.writeFileSync(path.join(b.root, "one.vibe"), "same bytes\n");
    fs.utimesSync(path.join(a.root, "one.vibe"), new Date(1_000), new Date(1_000));
    fs.utimesSync(path.join(b.root, "one.vibe"), new Date(9_000), new Date(9_000));
    const ca = config(a.root);
    const cb = config(b.root);
    const token = contentStatToken("one.vibe", ca);
    assertToken(token);
    assert.equal(contentStatToken("./one.vibe", ca), token);
    assert.equal(contentStatToken("x/../one.vibe", ca), token);
    assert.equal(contentStatToken(path.join(a.root, "one.vibe"), ca), token);
    assert.equal(contentStatToken("two.vibe", ca), token);
    assert.equal(contentStatToken("one.vibe", cb), token);
  } finally {
    fs.rmSync(a.outer, { recursive: true, force: true });
    fs.rmSync(b.outer, { recursive: true, force: true });
  }
});

test("same-size content changes invalidate even with restored mtime", () => {
  const f = fixture();
  try {
    const file = path.join(f.root, "input.vibe");
    fs.writeFileSync(file, "aaaa");
    const stamp = new Date(12_000);
    fs.utimesSync(file, stamp, stamp);
    const c = config(f.root);
    const before = contentStatToken(file, c);
    fs.writeFileSync(file, "bbbb");
    fs.utimesSync(file, stamp, stamp);
    const after = contentStatToken(file, c);
    assert.notEqual(after, before);
    assertToken(after);
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("pre/post fstat rejects a deterministic mutation during the read", () => {
  const f = fixture();
  try {
    const file = path.join(f.root, "racy.vibe");
    fs.writeFileSync(file, "before");
    const c = config(f.root);
    c.testBeforeFinalFileStat = target => fs.writeFileSync(target, "changed-during-read");
    assert.throws(() => contentStatToken(file, c), /unstable policy stat observation/);
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("directories are byte-sorted, fixed-width, and invalidate on entry changes", () => {
  const f = fixture();
  try {
    const dir = path.join(f.root, "pkg");
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, "b"), "x");
    const c = config(f.root);
    const before = contentStatToken(dir, c);
    assertToken(before);
    fs.writeFileSync(path.join(dir, "a"), "x");
    const added = contentStatToken(dir, c);
    assert.notEqual(added, before);
    fs.rmSync(path.join(dir, "a"));
    fs.mkdirSync(path.join(dir, "a"));
    const replaced = contentStatToken(dir, c);
    assert.notEqual(replaced, added);
    assert.notEqual(replaced, before);
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("final symlink is -1 while ancestor and lexical/absolute escapes fail", () => {
  const f = fixture();
  try {
    const outside = path.join(f.outer, "outside");
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, "file"), "outside");
    fs.writeFileSync(path.join(f.root, "inside"), "inside");
    fs.symlinkSync("inside", path.join(f.root, "final"));
    fs.symlinkSync(outside, path.join(f.root, "ancestor"), "dir");
    const c = config(f.root);
    assert.equal(contentStatToken("final", c), -1n);
    assert.throws(() => contentStatToken("ancestor/file", c), /symlink ancestor/);
    assert.throws(() => contentStatToken("../outside/file", c), /escapes root/);
    assert.throws(() => contentStatToken(path.join(outside, "file"), c), /escapes root/);
    assert.throws(() => contentStatToken("missing", c));
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("unsupported nonregular entries fail closed", { skip: process.platform === "win32" }, () => {
  const f = fixture();
  try {
    const fifo = path.join(f.root, "fifo");
    const made = spawnSync("mkfifo", [fifo]);
    if (made.status !== 0) return;
    const c = config(f.root);
    assert.throws(() => contentStatToken(fifo, c), /unsupported/);
    assert.throws(() => contentStatToken(f.root, c), /unsupported directory entry/);
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("Unix sockets fail closed as targets and directory entries", { skip: process.platform === "win32" }, async () => {
  const f = fixture();
  const socketPath = path.join(f.root, "socket");
  const server = net.createServer();
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    const c = config(f.root);
    assert.throws(() => contentStatToken(socketPath, c), /unsupported/);
    assert.throws(() => contentStatToken(f.root, c), /unsupported directory entry/);
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(f.outer, { recursive: true, force: true });
  }
});

test("truncation collisions fail closed", () => {
  const f = fixture();
  try {
    const c = config(f.root);
    const one = crypto.createHash("sha256").update("one").digest();
    const two = crypto.createHash("sha256").update("two").digest();
    const forced = 1n << 60n;
    assert.equal(projectContentStatDigest(one, c, forced), forced);
    assert.throws(() => projectContentStatDigest(two, c, forced), /collision/);
  } finally { fs.rmSync(f.outer, { recursive: true, force: true }); }
});

test("default metadata helper remains metadata-sensitive", () => {
  const a = fixture();
  const b = fixture();
  try {
    const ap = path.join(a.root, "x");
    const bp = path.join(b.root, "x");
    fs.writeFileSync(ap, "same");
    fs.writeFileSync(bp, "same");
    fs.utimesSync(ap, new Date(1_000), new Date(1_000));
    fs.utimesSync(bp, new Date(8_000), new Date(8_000));
    assert.notDeepEqual(buildFsMetadataHashParts(ap), buildFsMetadataHashParts(bp));
  } finally {
    fs.rmSync(a.outer, { recursive: true, force: true });
    fs.rmSync(b.outer, { recursive: true, force: true });
  }
});

test("policy selectors are consumed before wasm and never reach guest argv", () => {
  const root = path.resolve("/tmp/policy-root");
  const parsed = parseArgs([
    "--policy-stat-token", "content-v1", "--policy-stat-root", root,
    "--invoke", "cli_main", "compiler.wasm", "input.vibe", "out.wasm", "__no_entry__",
  ]);
  assert.equal(parsed.policyStatToken, "content-v1");
  assert.equal(parsed.policyStatRoot, root);
  assert.deepEqual(parsed.passthroughArgs, ["input.vibe", "out.wasm", "__no_entry__"]);
  assert.throws(() => parseArgs(["--policy-stat-token", "content-v1", "compiler.wasm"]));
  assert.throws(() => parseArgs(["compiler.wasm", "--policy-stat-root", root]));
});
