import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const { __test } = require("./wasm_vibe_host_runner.js");

function mutableI32Global(value) {
  return new WebAssembly.Global({ value: "i32", mutable: true }, value);
}

test("allocPreview2Buffer keeps non-shared __heap_ptr fallback", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const heapPtr = mutableI32Global(8);
  const instance = {
    exports: {
      memory,
      __heap_ptr: heapPtr,
    },
  };

  const ptr = __test.allocPreview2Buffer(instance, 5, 4);

  assert.equal(ptr, 8);
  assert.equal(heapPtr.value, 16);
});

test("allocPreview2Buffer uses cabi_realloc even for shared memory", () => {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
  const calls = [];
  const instance = {
    exports: {
      memory,
      cabi_realloc: (...args) => {
        calls.push(args);
        return 64;
      },
    },
  };

  const ptr = __test.allocPreview2Buffer(instance, 12, 8);

  assert.equal(ptr, 64);
  assert.deepEqual(calls, [[0, 0, 8, 12]]);
  assert.equal(__test.memoryUsesSharedBuffer(memory), true);
});

test("allocPreview2Buffer rejects shared memory __heap_ptr fallback", () => {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
  const instance = {
    exports: {
      memory,
      __heap_ptr: mutableI32Global(8),
    },
  };

  assert.throws(
    () => __test.allocPreview2Buffer(instance, 4, 4),
    /shared memory.*cabi_realloc/i,
  );
});
