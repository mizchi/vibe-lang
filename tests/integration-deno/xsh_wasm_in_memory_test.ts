import { createXshService } from "../../js/xsh/index.js";

function assertTrue(actual: boolean, msg?: string): void {
  if (!actual) {
    throw new Error(msg ?? `assertTrue failed: actual=${actual}`);
  }
}

Deno.test("xsh wasm artifact instantiates in deno", async () => {
  const service = await createXshService();
  const report = await service.check("1 + 2\n") as { ok: boolean };
  assertTrue(report.ok);
});
