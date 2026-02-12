import { bindLspTransport, createLspBridge } from "../../js/vibe/index.js";

function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual !== expected) {
    throw new Error(msg ?? `assertEquals failed: actual=${actual} expected=${expected}`);
  }
}

function assertTrue(actual: boolean, msg?: string): void {
  if (!actual) {
    throw new Error(msg ?? `assertTrue failed: actual=${actual}`);
  }
}

function createMemoryTransport() {
  const sent: string[] = [];
  let listener: ((message: string) => void | Promise<void>) | null = null;
  return {
    transport: {
      send(message: string) {
        sent.push(message);
      },
      onMessage(handler: (message: string) => void | Promise<void>) {
        listener = handler;
        return () => {
          listener = null;
        };
      },
    },
    sent,
    async emit(message: string) {
      if (listener === null) {
        throw new Error("listener is not set");
      }
      await listener(message);
    },
  };
}

Deno.test("lsp transport bridge is transport-agnostic", async () => {
  const mem = createMemoryTransport();
  const stop = bindLspTransport(mem.transport, async (message: unknown) => {
    const req = message as { id: number; method: string };
    return { jsonrpc: "2.0", id: req.id, result: `ok:${req.method}` };
  });

  await mem.emit(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }));

  assertEquals(mem.sent.length, 1);
  const resp = JSON.parse(mem.sent[0]) as { id: number; result: string };
  assertEquals(resp.id, 1);
  assertEquals(resp.result, "ok:initialize");

  stop();
});

Deno.test("lsp bridge object handles raw message", async () => {
  const bridge = createLspBridge(async (message: unknown) => {
    const req = message as { id: number; method: string };
    return { jsonrpc: "2.0", id: req.id, result: req.method };
  });
  const resp = await bridge.handle({ id: 7, method: "textDocument/formatting" }) as {
    id: number;
    result: string;
  };
  assertTrue(resp.id === 7);
  assertEquals(resp.result, "textDocument/formatting");
});
