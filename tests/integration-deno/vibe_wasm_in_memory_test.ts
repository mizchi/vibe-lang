import { createVibeService } from "../../clients/js/index.js";

function assertTrue(actual: boolean, msg?: string): void {
  if (!actual) {
    throw new Error(msg ?? `assertTrue failed: actual=${actual}`);
  }
}

Deno.test("vibe wasm artifact instantiates in deno", async () => {
  const service = await createVibeService();
  const report = await service.check("1 + 2\n") as { ok: boolean };
  assertTrue(report.ok);
});

Deno.test("vibe wasm artifact instantiates from precompiled module", async () => {
  const bytes = await Deno.readFile("_build/wasm-gc/release/build/lib/lib.wasm");
  const wasmModule = await WebAssembly.compile(bytes);
  const service = await createVibeService({ wasmModule });
  const report = await service.check("1 + 2\n") as { ok: boolean };
  assertTrue(report.ok);
});
