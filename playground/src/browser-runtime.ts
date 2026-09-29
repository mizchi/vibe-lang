import { compile } from "./generated/vibec.component.js";

function sourcePayload(source: string): string {
  const bytes = new TextEncoder().encode(`playground.vibe\0${source}`);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function compiledBytes(payload: string): Uint8Array {
  const lengthText = compile(payload, "len-mode:mvp:_start");
  const length = Number(lengthText);
  if (!Number.isSafeInteger(length) || length <= 8) {
    const diagnostic = compile(payload, "error-mode:mvp:_start");
    throw new Error(diagnostic || "Compilation failed. Check the source and its exported _start function.");
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (let chunk = 0; offset < length; chunk++) {
    const hex = compile(payload, `hex-chunk-mode:mvp:_start:${chunk}`);
    if (!hex || hex.length % 2 !== 0 || offset + hex.length / 2 > length) {
      throw new Error(`Compiler returned an invalid wasm chunk at ${offset}.`);
    }
    for (let index = 0; index < hex.length; index += 2) {
      const byte = Number.parseInt(hex.slice(index, index + 2), 16);
      if (Number.isNaN(byte)) throw new Error(`Compiler returned invalid hex at ${offset}.`);
      bytes[offset++] = byte;
    }
  }
  return bytes;
}

export async function compileAndRun(source: string): Promise<string> {
  const bytes = compiledBytes(sourcePayload(source));
  let instance: WebAssembly.Instance | undefined;
  let stdout = "";
  const decoder = new TextDecoder();
  function memory(): WebAssembly.Memory {
    const exported = instance?.exports.memory;
    if (!(exported instanceof WebAssembly.Memory)) {
      throw new Error("Program memory is unavailable to the stdout host.");
    }
    return exported;
  }
  const imports = {
    wasi_snapshot_preview1: {
      fd_write(_fd: number, iovs: number, count: number, _written: number): number {
        const exported = memory();
        const view = new DataView(exported.buffer);
        let written = 0;
        for (let index = 0; index < count; index++) {
          const pointer = view.getUint32(iovs + index * 8, true);
          const length = view.getUint32(iovs + index * 8 + 4, true);
          stdout += decoder.decode(new Uint8Array(exported.buffer, pointer, length));
          written += length;
        }
        view.setUint32(_written, written, true);
        return 0;
      },
    },
    vibe: {
      stdout_write_stream(packed: bigint): void {
        const bits = BigInt.asUintN(64, packed);
        const pointer = Number(bits >> 32n);
        const length = Number(bits & 0xffffffffn);
        const bytes = new Uint8Array(memory().buffer);
        if (pointer + length > bytes.length) {
          throw new Error(`Program stdout string is out of bounds: ${pointer}+${length}.`);
        }
        stdout += decoder.decode(bytes.subarray(pointer, pointer + length));
      },
      stdout_write_char(code: bigint): void {
        stdout += String.fromCharCode(Number(code & 0xffffn));
      },
    },
  };
  const module = await WebAssembly.compile(bytes.buffer as ArrayBuffer);
  instance = await WebAssembly.instantiate(module, imports);
  const start = instance.exports._start;
  if (typeof start !== "function") throw new Error("Compiled program has no _start export.");
  start();
  return stdout;
}
