"use strict";

const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const test = require("node:test");
const { createHostRuntime } = require("./wasm_vibe_host_runtime.js");

test("TaskGroup host SHA-256 reads raw bytes without decoding the payload", () => {
  const host = createHostRuntime();
  host.HOST_IMPORT_ABI = "raw";
  const memory = new WebAssembly.Memory({ initial: 1 });
  const instance = { exports: { memory } };
  const ptr = 16;
  const prefix = Buffer.from("\0vibe:taskgroup:sha256:", "ascii");
  function request(bytes) {
    new Uint8Array(memory.buffer).set(bytes, ptr);
    const packed = (BigInt(ptr) << 32n) | BigInt(bytes.length);
    return host.taskGroupSha256Request(instance, packed);
  }

  assert.equal(request(Buffer.from("PATH")), undefined);
  assert.equal(request(Buffer.concat([prefix, Buffer.from("?")])), "1");
  assert.equal(request(Buffer.concat([prefix, Buffer.from("invalid")])), undefined);
  for (const bytes of [Buffer.alloc(0), Buffer.from([0xef, 0xbb, 0xbf, 0, 0xff, 0xc0, 0x0a])]) {
    assert.equal(request(Buffer.concat([prefix, Buffer.from([0]), bytes])),
      createHash("sha256").update(bytes).digest("hex"));
  }
  host.HOST_IMPORT_ABI = "tagged";
  assert.equal(request(Buffer.concat([prefix, Buffer.from("?")])), undefined);
});
