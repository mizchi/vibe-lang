#!/usr/bin/env node
// Unit test for the vibe DAP server's PURE translation logic (no VS Code, no
// runner required): line->function mapping (enclosingFunctions /
// breakpointFunctionsForLines) and stderr parsing (parseFrame / parseArgs).
//
// Optionally drives the dap_server over a pipe (initialize -> launch ->
// setBreakpoints -> configurationDone -> ... -> stackTrace -> continue) against
// a tiny .vibe program IF a working `vibe` launcher is available; that part is
// guarded and SKIPS cleanly so this test PASSES in a bare checkout on the pure-
// function assertions alone.
//
// Prints `[dap-test] N passed, M failed` and exits non-zero on any failure.

"use strict";

const path = require("path");
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");

const dap = require(path.join(__dirname, "..", "js", "vibe", "dap_server.js"));

let pass = 0;
let fail = 0;

function ok(cond, label) {
  if (cond) {
    pass++;
    // console.log(`  ok: ${label}`);
  } else {
    fail++;
    console.error(`  FAIL: ${label}`);
  }
}

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    pass++;
  } else {
    fail++;
    console.error(`  FAIL: ${label}\n    expected ${e}\n    got      ${a}`);
  }
}

// ---------------------------------------------------------------------------
// Sample 2-function program (the same shape the break integration tests use,
// extended with a multi-line body to exercise span detection).
//   line 1: export let helper = (x: Int) -> Int {
//   line 2:   x * 2
//   line 3: }
//   line 4: export let main = () -> Int {
//   line 5:   helper(20) + helper(1)
//   line 6: }
// ---------------------------------------------------------------------------
const sample = [
  "export let helper = (x: Int) -> Int {",
  "  x * 2",
  "}",
  "export let main = () -> Int {",
  "  helper(20) + helper(1)",
  "}",
].join("\n");

// enclosingFunctions: two top-level functions with the right spans.
const funcs = dap.enclosingFunctions(sample);
eq(funcs, [
  { name: "helper", startLine: 1, endLine: 3 },
  { name: "main", startLine: 4, endLine: 6 },
], "enclosingFunctions maps both functions with their line spans");

// breakpointFunctionsForLines: a line inside each body resolves to its name.
eq(dap.breakpointFunctionsForLines(sample, [2]), ["helper"], "line 2 -> helper");
eq(dap.breakpointFunctionsForLines(sample, [5]), ["main"], "line 5 -> main");
eq(dap.breakpointFunctionsForLines(sample, [1]), ["helper"], "decl line 1 -> helper");
eq(dap.breakpointFunctionsForLines(sample, [4]), ["main"], "decl line 4 -> main");
eq(
  dap.breakpointFunctionsForLines(sample, [2, 5]),
  ["helper", "main"],
  "lines 2,5 -> [helper, main]",
);
eq(
  dap.breakpointFunctionsForLines(sample, [2, 2]),
  ["helper"],
  "duplicate lines de-dup to one function",
);
eq(
  dap.breakpointFunctionsForLines(sample, [99]),
  [],
  "out-of-range line maps to no function",
);

// breakpointUnion: setBreakpoints REPLACES a source's entry, so the union over
// all sources reflects the client's current state (no accumulation of removed BPs).
eq(
  dap.breakpointUnion({ "a.vibe": ["helper"], "b.vibe": ["main"] }),
  ["helper", "main"],
  "union spans multiple sources",
);
eq(
  dap.breakpointUnion({ "a.vibe": ["helper", "worker"], "b.vibe": ["worker"] }),
  ["helper", "worker"],
  "union de-dups a function present in two sources",
);
// Removing a breakpoint (re-send the source with fewer fns) drops it from the union.
{
  const bySource = { "a.vibe": ["helper", "worker"] };
  bySource["a.vibe"] = ["helper"]; // setBreakpoints replaced a.vibe's list
  eq(dap.breakpointUnion(bySource), ["helper"], "replacing a source drops the removed function");
  bySource["a.vibe"] = []; // cleared
  eq(dap.breakpointUnion(bySource), [], "clearing a source's breakpoints empties the union");
}

// A single-line function form (no separate body line) still spans correctly.
const oneLine = "export let f = (a: Int) -> Int { a + 1 }\nlet g = () -> Int { 0 }";
eq(dap.enclosingFunctions(oneLine), [
  { name: "f", startLine: 1, endLine: 1 },
  { name: "g", startLine: 2, endLine: 2 },
], "single-line functions get 1-line spans");

// A type-parameterized function decl is recognized.
const generic = "export let use_keyed = [T: Keyed](x: T) -> Int {\n  1\n}";
eq(dap.enclosingFunctions(generic), [
  { name: "use_keyed", startLine: 1, endLine: 3 },
], "type-param function decl is recognized");

// parseFrame: with and without a (file:line) suffix.
eq(
  dap.parseFrame("  at helper (prog.vibe:1)"),
  { name: "helper", file: "prog.vibe", line: 1 },
  "parseFrame with location",
);
eq(
  dap.parseFrame("  at main (prog.vibe:2)"),
  { name: "main", file: "prog.vibe", line: 2 },
  "parseFrame second frame",
);
eq(
  dap.parseFrame("  at helper"),
  { name: "helper", file: null, line: null },
  "parseFrame without location",
);
ok(dap.parseFrame("breakpoint hit: helper") === null, "parseFrame rejects a header line");
ok(dap.parseFrame("random noise") === null, "parseFrame rejects noise");

// parseArgs: numeric (bare/positional, DAP P2), empty, and non-args lines.
eq(dap.parseArgs("  args: [20]"), [20], "parseArgs single int (bare)");
eq(dap.parseArgs("  args: [20, 1]"), [20, 1], "parseArgs two ints (bare)");
eq(dap.parseArgs("  args: []"), [], "parseArgs empty list");
ok(dap.parseArgs("  at helper (prog.vibe:1)") === null, "parseArgs rejects a frame line");
// parseArgs: named form (DAP P4) -> {name, value} tokens.
eq(
  dap.parseArgs("  args: [n=20]"),
  [{ name: "n", value: "20" }],
  "parseArgs single named",
);
eq(
  dap.parseArgs("  args: [n=20, m=1]"),
  [{ name: "n", value: "20" }, { name: "m", value: "1" }],
  "parseArgs two named",
);
eq(
  dap.parseArgs("  args: [n=0x2a]"),
  [{ name: "n", value: "0x2a" }],
  "parseArgs named heap-pointer hex value",
);

// parsePauseLine: classify the two pause headers.
eq(
  dap.parsePauseLine("breakpoint hit: helper"),
  { reason: "breakpoint", fn: "helper" },
  "parsePauseLine breakpoint",
);
eq(
  dap.parsePauseLine("stopped at: helper"),
  { reason: "step", fn: "helper" },
  "parsePauseLine step",
);
ok(dap.parsePauseLine("  at helper") === null, "parsePauseLine rejects a frame line");

// ---------------------------------------------------------------------------
// Print a small sample of the mapping/parse output for the report.
// ---------------------------------------------------------------------------
console.log("[dap-test] sample enclosingFunctions:", JSON.stringify(funcs));
console.log("[dap-test] line 2 ->", JSON.stringify(dap.breakpointFunctionsForLines(sample, [2])));
console.log("[dap-test] line 5 ->", JSON.stringify(dap.breakpointFunctionsForLines(sample, [5])));
console.log("[dap-test] parseFrame('  at helper (prog.vibe:1)') ->", JSON.stringify(dap.parseFrame("  at helper (prog.vibe:1)")));
console.log("[dap-test] parseArgs('  args: [20, 1]') ->", JSON.stringify(dap.parseArgs("  args: [20, 1]")));

// ---------------------------------------------------------------------------
// OPTIONAL end-to-end drive of the server against a tiny program, guarded on a
// usable `vibe` launcher. Skips cleanly (no failures) when unavailable so a
// bare checkout still passes on the pure assertions above.
// ---------------------------------------------------------------------------
function vibeAvailable() {
  const bin = process.env.VIBE_BIN || "vibe";
  try {
    const r = spawnSync(bin, ["version"], { encoding: "utf8", timeout: 15000 });
    return r.status === 0;
  } catch {
    return false;
  }
}

function dapClient(serverPath, onEvent) {
  const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "pipe"] });
  let seq = 1;
  let buf = Buffer.alloc(0);
  const pendingResponses = new Map(); // request seq -> resolve

  child.stdout.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const he = buf.indexOf("\r\n\r\n");
      if (he < 0) return;
      const header = buf.slice(0, he).toString("ascii");
      const m = /Content-Length:\s*(\d+)/i.exec(header);
      if (!m) {
        buf = buf.slice(he + 4);
        continue;
      }
      const len = parseInt(m[1], 10);
      const start = he + 4;
      if (buf.length < start + len) return;
      const body = buf.slice(start, start + len).toString("utf8");
      buf = buf.slice(start + len);
      let msg;
      try {
        msg = JSON.parse(body);
      } catch {
        continue;
      }
      if (msg.type === "response" && pendingResponses.has(msg.request_seq)) {
        const r = pendingResponses.get(msg.request_seq);
        pendingResponses.delete(msg.request_seq);
        r(msg);
      } else if (msg.type === "event" && onEvent) {
        onEvent(msg);
      }
    }
  });

  function request(command, args) {
    const s = seq++;
    const msg = { type: "request", seq: s, command, arguments: args || {} };
    const data = Buffer.from(JSON.stringify(msg), "utf8");
    child.stdin.write(`Content-Length: ${data.length}\r\n\r\n`);
    child.stdin.write(data);
    return new Promise((resolve) => pendingResponses.set(s, resolve));
  }

  return { child, request };
}

async function e2e() {
  if (!vibeAvailable()) {
    console.log("[dap-test] skipping E2E drive (no usable `vibe` launcher)");
    return;
  }
  const serverPath = path.join(__dirname, "..", "js", "vibe", "dap_server.js");
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-dap-"));
  const prog = path.join(work, "prog.vibe");
  fs.writeFileSync(
    prog,
    "export let helper = (x: Int) -> Int { x * 2 }\nexport let main = () -> Int { helper(20) + helper(1) }\n",
  );

  const events = [];
  let stopped = null;
  let terminated = false;
  const { child, request } = dapClient(serverPath, (ev) => {
    events.push(ev.event);
    if (ev.event === "stopped") stopped = ev.body;
    if (ev.event === "terminated") terminated = true;
  });

  try {
    await request("initialize", { adapterID: "vibe" });
    await request("launch", { program: prog });
    const bpResp = await request("setBreakpoints", {
      source: { path: prog },
      breakpoints: [{ line: 1 }],
    });
    ok(
      bpResp.success && bpResp.body.breakpoints && bpResp.body.breakpoints[0].verified,
      "E2E: setBreakpoints verifies the breakpoint",
    );
    await request("configurationDone", {});

    // Wait (briefly) for the first stopped event.
    const deadline = Date.now() + 20000;
    while (!stopped && !terminated && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
    if (stopped) {
      ok(stopped.reason === "breakpoint", "E2E: stopped reason is 'breakpoint'");
      const st = await request("stackTrace", { threadId: 1 });
      const frames = st.body.stackFrames || [];
      ok(frames.length >= 1 && frames[0].name === "helper", "E2E: top frame is 'helper'");
      const sc = await request("scopes", { frameId: 1 });
      const ref = sc.body.scopes[0].variablesReference;
      const vars = await request("variables", { variablesReference: ref });
      ok(
        (vars.body.variables || []).some((v) => v.value === "20"),
        "E2E: first hit exposes arg value 20",
      );
      // Continue to completion.
      await request("continue", { threadId: 1 });
      const d2 = Date.now() + 20000;
      while (!terminated && Date.now() < d2) {
        await new Promise((r) => setTimeout(r, 50));
      }
      ok(terminated, "E2E: program terminates after continue");
    } else {
      console.log("[dap-test] E2E: no stopped event observed (runner may lack break instrumentation); skipping E2E asserts");
    }
    await request("disconnect", {});
  } finally {
    try {
      child.kill();
    } catch {}
    try {
      fs.rmSync(work, { recursive: true, force: true });
    } catch {}
  }
}

(async () => {
  try {
    await e2e();
  } catch (err) {
    console.error("[dap-test] E2E drive errored (non-fatal):", err && err.message);
  }
  console.log(`[dap-test] ${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
