import { compile } from "./generated/vibec.component.js";

// The compiler takes a closure of sources: `path\0source` pairs, the entry
// file first. Extra files are what the entry reaches with `import ./x.vibe`.
function sourcePayload(source: string, files: Record<string, string>): string {
  let closure = `playground.vibe\0${source}`;
  for (const [path, text] of Object.entries(files)) closure += `\0${path}\0${text}`;
  const bytes = new TextEncoder().encode(closure);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function compiledBytes(payload: string, entry: string): Uint8Array {
  const lengthText = compile(payload, `len-mode:mvp:${entry}`);
  const length = Number(lengthText);
  if (!Number.isSafeInteger(length) || length <= 8) {
    const diagnostic = compile(payload, `error-mode:mvp:${entry}`);
    throw new Error(diagnostic || `Compilation failed. Check the source and its ${entry} entry point.`);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (let chunk = 0; offset < length; chunk++) {
    const hex = compile(payload, `hex-chunk-mode:mvp:${entry}:${chunk}`);
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

const MAX_SLEEP_MS = 5000;

// `Process::exit` from the guest (an uncaught exception's boundary uses it too).
class GuestExit extends Error {
  constructor(readonly code: number) {
    super(`program exited with code ${code}`);
  }
}

// `entry` names the function the compiler roots the module at: `_start` for
// the playground presets, `main` for `fn main allows ...` programs.
export async function compileAndRun(
  source: string,
  entry = "_start",
  files: Record<string, string> = {},
): Promise<string> {
  const bytes = compiledBytes(sourcePayload(source, files), entry);
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
  function guestString(packed: bigint): string {
    const bits = BigInt.asUintN(64, packed);
    const pointer = Number(bits >> 32n);
    const length = Number(bits & 0xffffffffn);
    const bytes = new Uint8Array(memory().buffer);
    if (pointer + length > bytes.length) {
      throw new Error(`Program string is out of bounds: ${pointer}+${length}.`);
    }
    return decoder.decode(bytes.subarray(pointer, pointer + length));
  }
  // stderr shares the output pane; each stderr line is marked so it is not
  // mistaken for stdout, however many writes it took.
  let stderrLineOpen = false;
  function writeStderr(text: string): void {
    for (const piece of text.split(/(?<=\n)/)) {
      if (piece === "") continue;
      if (!stderrLineOpen) stdout += "[stderr] ";
      stdout += piece;
      stderrLineOpen = !piece.endsWith("\n");
    }
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
          stderrLineOpen = false;
          written += length;
        }
        view.setUint32(_written, written, true);
        return 0;
      },
    },
    vibe: {
      stdout_write_stream(packed: bigint): void {
        stdout += guestString(packed);
        stderrLineOpen = false;
      },
      stdout_write_char(code: bigint): void {
        stdout += String.fromCharCode(Number(code & 0xffffn));
        stderrLineOpen = false;
      },
      stderr_write_stream(packed: bigint): bigint {
        writeStderr(guestString(packed));
        return 0n;
      },
      stderr_write_char(code: bigint): bigint {
        writeStderr(String.fromCharCode(Number(code & 0xffffn)));
        return 0n;
      },
      // `sleep(ms)` blocks the instance (a parked task group waits here for
      // its next wake-up). A synchronous import cannot yield to the tab, so
      // the wait is a busy loop, and one long enough to freeze the page is
      // refused rather than shortened.
      sleep(ms: bigint): bigint {
        const wait = Number(ms);
        if (wait > MAX_SLEEP_MS) {
          throw new Error(`sleep(${wait}) would freeze this tab; the playground waits at most ${MAX_SLEEP_MS} ms.`);
        }
        const until = performance.now() + wait;
        while (performance.now() < until) {
          // busy-wait: the guest asked to block
        }
        return 0n;
      },
      // Unwinds the guest; the output it wrote so far is still returned.
      process_exit(code: bigint): bigint {
        throw new GuestExit(Number(code));
      },
    },
  };
  const module = await WebAssembly.compile(bytes.buffer as ArrayBuffer);
  instance = await WebAssembly.instantiate(module, imports);
  const start = instance.exports[entry];
  if (typeof start !== "function") throw new Error(`Compiled program has no ${entry} export.`);
  // A named entry such as `main` takes its closure environment as an i64;
  // a top-level entry has none, so pass 0 the way scripts/wasm_vibe_host_runner.js does.
  try {
    if (start.length > 0) start(0n);
    else start();
  } catch (error) {
    if (!(error instanceof GuestExit)) throw error;
    if (error.code !== 0) stdout += `${stdout === "" || stdout.endsWith("\n") ? "" : "\n"}[exit ${error.code}]\n`;
  }
  return stdout;
}
