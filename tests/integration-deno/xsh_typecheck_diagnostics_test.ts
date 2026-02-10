import { createXshService } from "../../js/xsh/index.js";

function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual !== expected) {
    throw new Error(
      msg ?? `assertEquals failed: actual=${actual} expected=${expected}`,
    );
  }
}

function assertTrue(actual: boolean, msg?: string): void {
  if (!actual) {
    throw new Error(msg ?? `assertTrue failed: actual=${actual}`);
  }
}

Deno.test("xsh wasm api returns type diagnostics json", async () => {
  const service = await createXshService();
  const report = await service.check("1 + true\n") as {
    ok: boolean;
    error_count: number;
    diagnostics: Array<{ stage: string; message: string }>;
  };
  assertEquals(report.ok, false);
  assertTrue(report.error_count >= 1);
  assertTrue(report.diagnostics.length >= 1);
  assertEquals(report.diagnostics[0].stage, "type");
});

Deno.test("xsh wasm api returns ok for valid source", async () => {
  const service = await createXshService();
  const report = await service.check("1 + 2\n") as {
    ok: boolean;
    error_count: number;
  };
  assertEquals(report.ok, true);
  assertEquals(report.error_count, 0);
});

Deno.test("xsh wasm api init injects prelude and kv", async () => {
  const service = await createXshService();
  const init = await service.init({
    prelude: "let triple = (x: Int) -> Int { x * 3 }",
    kv: {
      "/lib.xsh": "export let value = 7\n",
    },
  }) as { ok: boolean; kv_count?: number; prelude?: boolean };
  assertEquals(init.ok, true);
  assertEquals(init.prelude, true);
  assertEquals(init.kv_count, 1);

  const preludeReport = await service.check("triple(2)\n") as {
    ok: boolean;
    error_count: number;
  };
  assertEquals(preludeReport.ok, true);
  assertEquals(preludeReport.error_count, 0);

  const projectReport = await service.checkProject({
    entry: "/main.xsh",
    files: {
      "/main.xsh": 'import { value } from "./lib.xsh"\nlet out = value\n',
    },
  }) as {
    ok: boolean;
    error_count: number;
  };
  assertEquals(projectReport.ok, true);
  assertEquals(projectReport.error_count, 0);
});

Deno.test("xsh wasm api bootstrap option initializes state", async () => {
  const service = await createXshService({
    bootstrap: {
      prelude: "let inc = (x: Int) -> Int { x + 1 }",
    },
  });
  const report = await service.check("inc(3)\n") as {
    ok: boolean;
    error_count: number;
  };
  assertEquals(report.ok, true);
  assertEquals(report.error_count, 0);
});

Deno.test("xsh wasm api formats source", async () => {
  const service = await createXshService();
  const report = await service.format("let  x=1") as {
    ok: boolean;
    changed: boolean;
    formatted: string;
  };
  assertEquals(report.ok, true);
  assertEquals(report.changed, true);
  assertTrue(report.formatted.includes("let x = 1"));
});

Deno.test("xsh wasm api checkProject works for single-file entry", async () => {
  const service = await createXshService();
  const report = await service.checkProject({
    entry: "/main.xsh",
    files: {
      "/main.xsh": "1 + 2\n",
    },
  }) as {
    ok: boolean;
    error_count: number;
    entry: string;
    unsupported_imports: boolean;
  };
  assertEquals(report.ok, true);
  assertEquals(report.error_count, 0);
  assertEquals(report.entry, "/main.xsh");
  assertEquals(report.unsupported_imports, false);
});

Deno.test("xsh wasm api checkProject resolves imports", async () => {
  const service = await createXshService();
  const report = await service.checkProject({
    entry: "/main.xsh",
    files: {
      "/main.xsh": 'import { value } from "./lib.xsh"\nlet out = value\n',
      "/lib.xsh": "export let value = 1\n",
    },
  }) as {
    ok: boolean;
    error_count: number;
    entry: string;
    unsupported_imports: boolean;
  };
  assertEquals(report.ok, true);
  assertEquals(report.error_count, 0);
  assertEquals(report.entry, "/main.xsh");
  assertEquals(report.unsupported_imports, false);
});

Deno.test("xsh wasm api ide outline returns symbols", async () => {
  const service = await createXshService();
  const result = await service.ideOutline({
    source: "let foo = 1\nlet bar = foo\n",
    path: "/main.xsh",
  }) as {
    ok: boolean;
    symbols?: Array<{ name: string }>;
  };
  assertEquals(result.ok, true);
  assertTrue(Array.isArray(result.symbols));
  assertTrue(result.symbols!.some((s) => s.name === "foo"));
});

Deno.test("xsh wasm api ide peek-def and search work", async () => {
  const service = await createXshService();
  const source = "let foo = 1\nlet bar = foo\n";

  const peek = await service.idePeekDef({
    source,
    path: "/main.xsh",
    symbol: "foo",
  }) as {
    ok: boolean;
    matches?: Array<{ name: string }>;
  };
  assertEquals(peek.ok, true);
  assertTrue(Array.isArray(peek.matches));
  assertTrue(peek.matches!.length >= 1);

  const search = await service.ideSearch({
    source,
    path: "/main.xsh",
    query: "bar",
  }) as {
    ok: boolean;
    matches?: Array<{ name: string }>;
  };
  assertEquals(search.ok, true);
  assertTrue(Array.isArray(search.matches));
  assertTrue(search.matches!.some((m) => m.name === "bar"));
});

Deno.test("xsh wasm api ide supports imports via project request", async () => {
  const service = await createXshService();
  const files = {
    "/main.xsh": 'import { value } from "./lib.xsh"\nlet out = value\n',
    "/lib.xsh": "export let value = 1\n",
  };

  const outline = await service.ideOutline({
    entry: "/main.xsh",
    path: "/main.xsh",
    files,
  }) as {
    ok: boolean;
    symbols?: Array<{ name: string }>;
  };
  assertEquals(outline.ok, true);
  assertTrue(Array.isArray(outline.symbols));
  assertTrue(outline.symbols!.some((s) => s.name === "out"));

  const peek = await service.idePeekDef({
    entry: "/main.xsh",
    path: "/main.xsh",
    files,
    symbol: "value",
  }) as {
    ok: boolean;
    matches?: Array<{ path: string; name: string }>;
  };
  assertEquals(peek.ok, true);
  assertTrue(Array.isArray(peek.matches));
  assertTrue(
    peek.matches!.some((m) => m.path === "/lib.xsh" && m.name === "value"),
  );
});
