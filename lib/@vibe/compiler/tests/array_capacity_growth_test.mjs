import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

function u32(bytes, cursor) {
  let result = 0;
  let shift = 0;
  for (;;) {
    const byte = bytes[cursor.pos++];
    result += (byte & 127) * 2 ** shift;
    if (!(byte & 128)) return result;
    shift += 7;
  }
}

function leb(value) {
  const out = [];
  do {
    const byte = value & 127;
    value >>>= 7;
    out.push(byte | (value ? 128 : 0));
  } while (value);
  return out;
}

// Keep this boundary test small even if a regression attempts a multi-GB grow.
// These compiler fixtures each define one wasm32 memory; pin its maximum to
// its initial size without changing the functions or initial data.
function capMemory(bytes) {
  const cursor = { pos: 8 };
  while (cursor.pos < bytes.length) {
    const start = cursor.pos;
    const id = bytes[cursor.pos++];
    const length = u32(bytes, cursor);
    const end = cursor.pos + length;
    if (id === 5) {
      assert.equal(u32(bytes, cursor), 1);
      const flags = u32(bytes, cursor);
      assert.ok(flags === 0 || flags === 1);
      const minimum = u32(bytes, cursor);
      const body = [1, 1, ...leb(minimum), ...leb(minimum)];
      return Uint8Array.from([
        ...bytes.subarray(0, start), 5, ...leb(body.length), ...body,
        ...bytes.subarray(end),
      ]);
    }
    cursor.pos = end;
  }
  assert.fail("missing memory section");
}

for (const op of ["push", "push_all"]) {
  for (let mode = 0; mode < 4; mode++) {
    const label = op + "/" + mode;
    const path = process.argv[2] + op + "_" + mode + ".wasm";
    const module = await WebAssembly.compile(capMemory(readFileSync(path)));
    let guest;
    let scenario;
    const onOutput = () => {
      if (scenario.seen) return 0;
      scenario.seen = true;
      const heap = guest.__heap_ptr;
      const memory = new DataView(guest.memory.buffer);
      // Locate the fresh [7] buffer without depending on allocations made
      // by the backend's stdout wrapper. The push_all source holds [11].
      const end = heap.value >>> 0;
      const element = mode === 1 || mode === 2 ? 14n : 7n;
      const matches = [];
      for (let p = Math.floor((end - 28) / 4) * 4; p >= Math.max(0, end - 1024); p -= 4) {
        if (memory.getUint32(p, true) === 2 &&
            memory.getUint32(p + 4, true) === 1 &&
            memory.getUint32(p + 8, true) === p + 12 &&
            memory.getBigInt64(p + 12, true) === element) matches.push(p);
      }
      assert.equal(matches.length, 1, label + ": unique reserved array");
      const ptr = matches[0];
      scenario.normalHeap = heap.value;
      memory.setUint32(ptr, scenario.capacity, true);
      memory.setUint32(ptr + 4, scenario.grows ? scenario.capacity : 1, true);
      if (scenario.frontier !== undefined) heap.value = scenario.frontier;
      scenario.beforeHeap = heap.value;
      scenario.ptr = ptr;
      scenario.beforeArray = new Uint8Array(guest.memory.buffer, ptr, 28).slice();
      return 0;
    };
    const { exports } = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: { fd_write: onOutput },
      vibe: { stdout_write_stream: onOutput, stdout_write_char: onOutput },
    });
    guest = exports;

    // A large capacity with one spare physical slot must still take the
    // allocation-free fast path. The guard belongs only on the growth path.
    scenario = { capacity: 536870908, grows: false };
    assert.equal(exports.main(0n), 2n);
    assert.ok(scenario.seen);
    assert.equal(exports.__heap_ptr.value, scenario.beforeHeap);

    function refusesGrowth(capacity, frontier) {
      scenario = { capacity, frontier, grows: true };
      assert.throws(() => exports.main(0n), error =>
        error instanceof WebAssembly.RuntimeError && /unreachable/.test(error.message),
      label + ": checked growth at capacity " + capacity);
      assert.ok(scenario.seen);
      assert.equal(exports.__heap_ptr.value, scenario.beforeHeap, label + ": heap unchanged");
      assert.deepEqual(new Uint8Array(exports.memory.buffer, scenario.ptr, 28), scenario.beforeArray,
        label + ": array unchanged");
      exports.__heap_ptr.value = scenario.normalHeap;
    }

    for (const capacity of [268435454, 268435455, 268435456, 268435457, 536870908]) {
      refusesGrowth(capacity);
    }
    // The slot count fits, but adding its byte size to the frontier does not.
    refusesGrowth(128, 0xfffffff0);
  }
}
console.log("ok");
