import { createVibeService } from "../../clients/js/index.js";

function assertTrue(actual: boolean, msg?: string): void {
  if (!actual) {
    throw new Error(msg ?? `assertTrue failed: actual=${actual}`);
  }
}

function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual !== expected) {
    throw new Error(
      msg ?? `assertEquals failed: actual=${actual}, expected=${expected}`,
    );
  }
}

Deno.test("eval: basic expression", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: "1 + 2" });
  assertTrue(result.ok);
  if (result.ok) {
    assertEquals(result.value, "3");
    assertEquals(result.value_type, "Int");
  }
});

Deno.test("eval: let binding accumulates in session", async () => {
  const service = await createVibeService();
  const r1 = await service.eval({ source: "let x = 10" });
  assertTrue(r1.ok, "first eval should succeed");
  const r2 = await service.eval({ source: "x + 1" });
  assertTrue(r2.ok, "second eval should succeed");
  if (r2.ok) {
    assertEquals(r2.value, "11");
    assertEquals(r2.value_type, "Int");
  }
});

Deno.test("eval: type error returns structured diagnostics", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: '1 + "hello"' });
  assertTrue(!result.ok, "type error should fail");
  assertTrue(
    result.diagnostics.length > 0,
    "should have diagnostics",
  );
});

Deno.test("eval: evalReset clears session state", async () => {
  const service = await createVibeService();
  const r1 = await service.eval({ source: "let y = 42" });
  assertTrue(r1.ok, "first eval should succeed");

  const reset = await service.evalReset();
  assertTrue(reset.ok, "reset should succeed");

  // After reset, y should not be accessible
  const r2 = await service.eval({ source: "y" });
  assertTrue(!r2.ok, "y should not be defined after reset");
});

Deno.test("eval: function definition and call", async () => {
  const service = await createVibeService();
  const r1 = await service.eval({
    source: "let double = (x: Int) -> Int { x * 2 }",
  });
  assertTrue(r1.ok, "function definition should succeed");

  const r2 = await service.eval({ source: "double(21)" });
  assertTrue(r2.ok, "function call should succeed");
  if (r2.ok) {
    assertEquals(r2.value, "42");
    assertEquals(r2.value_type, "Int");
  }
});

Deno.test("eval: string value", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: '"hello"' });
  assertTrue(result.ok);
  if (result.ok) {
    assertEquals(result.value, '"hello"');
    assertEquals(result.value_type, "String");
  }
});

Deno.test("eval: boolean value", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: "1 < 2" });
  assertTrue(result.ok);
  if (result.ok) {
    assertEquals(result.value, "true");
    assertEquals(result.value_type, "Bool");
  }
});

Deno.test("eval: parse error returns diagnostics", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: "let x =" });
  assertTrue(!result.ok, "parse error should fail");
  assertTrue(result.diagnostics.length > 0, "should have diagnostics");
});

Deno.test("eval: let binding returns bound value", async () => {
  const service = await createVibeService();
  const result = await service.eval({ source: "let x = 42" });
  assertTrue(result.ok);
  if (result.ok) {
    assertEquals(result.value, "42");
    assertEquals(result.value_type, "Int");
  }
});
