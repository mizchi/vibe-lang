#!/usr/bin/env node
"use strict";

// Gate for the dormant immutable-publication capability. It deliberately does
// not add a compiler-source call before the bootstrap seed learns the builtin.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { publishImmutableTextSync } = require("./wasm_vibe_host_runner.js");

if (process.argv[2] === "--publish-child") {
  const ok = publishImmutableTextSync(process.argv[3], process.argv[4]);
  process.stdout.write(ok ? "true" : "false");
  process.exit(0);
}

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const includes = (file, text) =>
  assert.ok(read(file).includes(text), `${file} must contain ${text}`);

includes(
  "lib/@vibe/compiler/builtins/declarations.vibe",
  "declare Fs::publish_immutable_text(String, String) -> Bool",
);
includes(
  "lib/@vibe/compiler/core/builtin_registry.vibe",
  '("Fs::publish_immutable_text", CtFn(reg_p2(CtString, CtString), CtBool, Some("Fs")), true, false, true)',
);
includes(
  "lib/@vibe/compiler/codegen/wasi/linked_compile.vibe",
  '"Fs::publish_immutable_text" => fs_publish_immutable_text_idx',
);
includes(
  "lib/@vibe/compiler/codegen/wasi/linked_compile.vibe",
  'emit_name(import_content, "fs_publish_immutable_text")',
);
includes(
  "lib/@vibe/compiler/codegen/gc/backend_body.vibe",
  '("Fs::publish_immutable_text", 2, 8, 1)',
);
includes(
  "lib/@vibe/compiler/codegen/gc/backend_body.vibe",
  '("fs_publish_immutable_text", 4)',
);
includes(
  "scripts/wasm_vibe_host_runner.js",
  "fs_publish_immutable_text(pathTagged, contentTagged)",
);
includes("runtime/viberun/src/main.rs", '"fs_publish_immutable_text"');
includes("docs/spec/host-abi.md", "vibe::fs_publish_immutable_text");

function publishChild(target, text) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [__filename, "--publish-child", target, text], {
      stdio: ["ignore", "pipe", "inherit"],
    });
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(`publish child exited ${code}`));
      else resolve(stdout === "true");
    });
  });
}

async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-immutable-publish-"));
  try {
    const sequential = path.join(dir, "sequential.txt");
    assert.equal(publishImmutableTextSync(sequential, "hello ☃\n"), true);
    assert.equal(publishImmutableTextSync(sequential, "hello ☃\n"), true);
    assert.equal(publishImmutableTextSync(sequential, "different"), false);
    assert.deepEqual(fs.readFileSync(sequential), Buffer.from("hello ☃\n", "utf8"));

    const equal = path.join(dir, "equal.txt");
    const equalResults = await Promise.all(
      Array.from({ length: 8 }, () => publishChild(equal, "same 日本語\n")),
    );
    assert.ok(equalResults.every(Boolean), "all same-value racers must succeed");
    assert.deepEqual(fs.readFileSync(equal), Buffer.from("same 日本語\n", "utf8"));

    const unequal = path.join(dir, "unequal.txt");
    const values = ["alpha\n", "beta\n"];
    const unequalResults = await Promise.all(values.map((value) => publishChild(unequal, value)));
    assert.equal(unequalResults.filter(Boolean).length, 1, "exactly one unequal racer must win");
    assert.equal(fs.readFileSync(unequal, "utf8"), values[unequalResults.indexOf(true)]);

    assert.equal(publishImmutableTextSync(dir, "nonregular"), false);
    const symlink = path.join(dir, "symlink.txt");
    fs.symlinkSync(sequential, symlink);
    assert.equal(publishImmutableTextSync(symlink, "hello ☃\n"), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  console.log("immutable publish capability plumbing: gate passed");
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
