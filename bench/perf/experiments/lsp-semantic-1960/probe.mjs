#!/usr/bin/env node
// Measure the real editor entries before choosing a semantic retention boundary.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const digest = (text) => createHash("sha256").update(text).digest("hex");
const intSource = "/// Subtract one.\nexport fn transform(value: Int) -> Int { value - 1 }\nexport fn use_transform() -> Int { transform(value = 7) }\n";
const stringSource = "/// Keep the text.\nexport fn transform(value: String) -> String { value }\nexport fn use_transform() -> String { transform(value = \"seven\") }\n";
const dependencySource = "import ./dep.vibe { imported }\nexport fn use_transform() -> Int { imported() }\n";
const dep = "/// Imported count.\nexport fn imported() -> Int { 7 }\nfn private_offset() -> Int { 1 }\n";

// Disk and editor text are separate inputs. In particular the unsaved edit
// deliberately disagrees with app.vibe on disk in BOTH the replay and oracle.
export const scenarios = [
  { name: "initial", source: intSource },
  { name: "no_op", source: intSource },
  { name: "unsaved_type_edit", source: stringSource, disk: intSource },
  { name: "doc_only_edit", source: stringSource.replace("Keep the text.", "Keep the current buffer text.") },
  { name: "moved_locations", source: "// 😀 moved\n\n" + intSource },
  { name: "utf16_column", source: intSource.replace("{ transform(value = 7) }", "{ let emoji = \"😀\"; transform(value = String::length(emoji)) }") },
  { name: "parse_error", source: intSource.replace("value = 7", "value =") },
  { name: "recovered", source: intSource },
  { name: "close_reopen", source: stringSource, reopen: true },
  { name: "dependency_initial", source: dependencySource, dependency: dep, word: "imported" },
  { name: "dependency_unsaved_edit", source: dependencySource, dependency: dep, dependency_buffer: "export fn imported() -> String { \"unsaved\" }\n", word: "imported" },
  { name: "dependency_doc_edit", source: dependencySource, dependency: dep.replace("Imported count.", "Current dependency documentation."), word: "imported" },
  { name: "dependency_moved_locations", source: dependencySource, dependency: "// Moved dependency.\n\n" + dep, word: "imported" },
  { name: "dependency_private_edit", source: dependencySource, dependency: dep.replace("{ 1 }", "{ 2 }"), word: "imported" },
  { name: "dependency_public_edit", source: dependencySource, dependency: dep + "export fn extra() -> Int { 9 }\n", word: "imported" },
  { name: "dependency_breaking_edit", source: dependencySource, dependency: "export fn imported() -> String { \"seven\" }\n", word: "imported" },
  { name: "dependency_missing", source: dependencySource, dependency: null, word: "imported" },
  { name: "dependency_recovered", source: dependencySource, dependency: dep, word: "imported" },
  { name: "dependency_plan_edit", source: dependencySource.replace("./dep.vibe", "./alt.vibe"), disk: dependencySource, dependency: dep, alternate_dependency: "export fn imported() -> Int { 42 }\n", word: "imported" },
];

export function position(source, word) {
  const at = source.lastIndexOf(word);
  assert(at >= 0, `missing queried token ${word}`);
  const before = source.slice(0, at);
  return { line: before.split("\n").length - 1, character: at - before.lastIndexOf("\n") - 1 };
}

export function assertSnapshot(snapshot, label) {
  assert(snapshot && typeof snapshot === "object", `${label}: no snapshot`);
  assert(Array.isArray(snapshot.diagnostics), `${label}: missing diagnostics`);
  assert(Object.hasOwn(snapshot, "hover"), `${label}: missing hover result`);
  assert(Array.isArray(snapshot.references), `${label}: missing references`);
  assert(Array.isArray(snapshot.symbols), `${label}: missing symbols`);
  assert(typeof snapshot.doc === "string", `${label}: missing doc query`);
}

// Compare the actual answer, including messages, locations and docs. A repeat
// agreeing with its own previous answer is insufficient: use a NEW server and
// an EMPTY disk cache on the current state as the oracle.
export function compareSnapshots(actual, fresh, label) {
  assertSnapshot(actual, label);
  assertSnapshot(fresh, `${label} fresh`);
  for (const field of ["diagnostics", "hover", "references", "symbols", "doc"]) {
    assert.deepEqual(actual[field], fresh[field], `${label}: stale ${field}`);
  }
}

function textAtRange(source, range) {
  const lines = source.split("\n");
  assert.equal(range.start.line, range.end.line, "expected a single identifier range");
  return lines[range.start.line]?.slice(range.start.character, range.end.character);
}

// Cold/replay parity alone could be two empty answers. Pin concrete answers
// for the supported standalone cases as well as every returned UTF-16 span.
export function assertCurrentAnswers(snapshot, scenario) {
  assertSnapshot(snapshot, scenario.name);
  if (scenario.name === "parse_error") {
    assert(snapshot.diagnostics.some((diag) => diag.severity === 1 && diag.message.includes("unexpected token")), "missing parse-error diagnostic");
    return;
  }
  const word = scenario.word ?? "transform";
  for (const reference of snapshot.references) {
    assert.equal(textAtRange(scenario.source, reference.range), word, `${scenario.name}: reference points at another token`);
  }
  for (const symbol of snapshot.symbols) {
    assert.equal(textAtRange(scenario.source, symbol.selectionRange), symbol.name, `${scenario.name}: symbol points at another token`);
  }
  if (word === "transform") {
    const type = scenario.source.includes("value: String") ? "(String) -> String" : "(Int) -> Int";
    assert(snapshot.hover?.contents?.value.includes(type), `${scenario.name}: missing current type ${type}`);
    assert(snapshot.references.length >= 2, `${scenario.name}: no binding references`);
    assert(snapshot.symbols.some((symbol) => symbol.name === "transform"), `${scenario.name}: no declaration`);
    const doc = scenario.source.split("\n").find((line) => line.startsWith("/// ")).slice(4);
    assert.equal(snapshot.doc, doc, `${scenario.name}: wrong current doc`);
  }
}

class Client {
  constructor(command, args, env, logPath) {
    this.child = spawn(command, args, { cwd: root, env, stdio: ["pipe", "pipe", "pipe"] });
    this.buffer = Buffer.alloc(0);
    this.inbox = [];
    this.waiters = [];
    this.nextId = 1;
    this.stderr = "";
    this.transcript = [];
    this.logPath = logPath;
    this.failure = null;
    this.child.stderr.on("data", (chunk) => { this.stderr += chunk.toString(); });
    this.exited = new Promise((resolveExit) => {
      this.child.on("exit", (code, signal) => { this.exit = { code, signal }; resolveExit(this.exit); });
      this.child.on("error", (error) => { this.failure = error; resolveExit({ error: error.message }); });
    });
    this.child.stdout.on("data", (chunk) => {
      try { this.receive(chunk); } catch (error) { this.failure = error; }
    });
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const end = this.buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const header = /^Content-Length: (\d+)$/im.exec(this.buffer.subarray(0, end).toString("ascii"));
      assert(header, "server emitted an invalid LSP frame");
      const length = Number(header[1]);
      if (this.buffer.length < end + 4 + length) return;
      const msg = JSON.parse(this.buffer.subarray(end + 4, end + 4 + length).toString("utf8"));
      this.buffer = this.buffer.subarray(end + 4 + length);
      this.transcript.push(msg);
      const index = this.waiters.findIndex((waiter) => waiter.predicate(msg));
      if (index < 0) this.inbox.push(msg);
      else {
        const [waiter] = this.waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(msg);
      }
    }
  }

  send(method, params = {}, id = undefined) {
    const data = Buffer.from(JSON.stringify({ jsonrpc: "2.0", method, params, ...(id === undefined ? {} : { id }) }));
    this.child.stdin.write(`Content-Length: ${data.length}\r\n\r\n`);
    this.child.stdin.write(data);
  }

  wait(predicate) {
    if (this.failure) return Promise.reject(this.failure);
    const index = this.inbox.findIndex(predicate);
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0]);
    return new Promise((resolveWait, reject) => {
      const waiter = { predicate, resolve: resolveWait };
      waiter.timer = setTimeout(() => reject(this.failure || new Error(`LSP timeout: ${this.stderr.slice(-4000)}`)), 60000);
      this.waiters.push(waiter);
    });
  }

  async request(method, params = {}) {
    const id = this.nextId++;
    const start = performance.now();
    this.send(method, params, id);
    const response = await this.wait((msg) => msg.id === id);
    assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
    assert(Object.hasOwn(response, "result"), `${method}: no result`);
    return { result: response.result, wall_ms: performance.now() - start };
  }

  async close(success) {
    try {
      if (success && !this.exit) {
        await this.request("shutdown");
        this.send("exit");
        this.child.stdin.end();
        const timer = setTimeout(() => this.child.kill("SIGKILL"), 10000);
        await this.exited;
        clearTimeout(timer);
        assert.deepEqual(this.exit, { code: 0, signal: null }, "server failed during shutdown");
        assert.equal(this.buffer.length, 0, "truncated LSP frame");
      }
    } finally {
      if (!this.exit) { this.child.kill("SIGKILL"); await this.exited; }
      for (const waiter of this.waiters) clearTimeout(waiter.timer);
      writeFileSync(this.logPath, JSON.stringify({ pid: this.child.pid, exit: this.exit, stderr: this.stderr, messages: this.transcript }, null, 2) + "\n");
    }
  }
}

function putProject(project, scenario) {
  writeFileSync(join(project, "app.vibe"), scenario.disk ?? scenario.source);
  if (scenario.dependency == null) rmSync(join(project, "dep.vibe"), { force: true });
  else writeFileSync(join(project, "dep.vibe"), scenario.dependency);
  if (scenario.alternate_dependency == null) rmSync(join(project, "alt.vibe"), { force: true });
  else writeFileSync(join(project, "alt.vibe"), scenario.alternate_dependency);
}

// PID-bearing temp paths are transport details, but locations and diagnostic
// contents are not. Replace ONLY the temp basenames this exact Node process
// owns; leave every other character for the equality oracle to compare.
function normalize(value, pid, project) {
  return JSON.parse(JSON.stringify(value)
    .replaceAll(`.vibe-lsp-${pid}-`, ".vibe-lsp-PID-")
    .replaceAll(project, "<project>"));
}

async function documentChange(client, uri, scenario, index) {
  if (scenario.dependency_buffer !== undefined) {
    const dependencyUri = new URL("dep.vibe", uri).href;
    client.send("textDocument/didOpen", { textDocument: { uri: dependencyUri, languageId: "vibe", version: 1, text: scenario.dependency_buffer } });
    await client.wait((msg) => msg.method === "textDocument/publishDiagnostics" && msg.params.uri === dependencyUri);
  }
  if (scenario.reopen) {
    client.send("textDocument/didClose", { textDocument: { uri } });
    const closed = await client.wait((msg) => msg.method === "textDocument/publishDiagnostics" && msg.params.uri === uri);
    assert.deepEqual(closed.params.diagnostics, [], "didClose must clear diagnostics");
  }
  if (index === 0 || scenario.reopen) {
    client.send("textDocument/didOpen", { textDocument: { uri, languageId: "vibe", version: 1, text: scenario.source } });
  } else {
    client.send("textDocument/didChange", { textDocument: { uri, version: index + 1 }, contentChanges: [{ text: scenario.source }] });
  }
  const notification = await client.wait((msg) => msg.method === "textDocument/publishDiagnostics" && msg.params.uri === uri);
  assert(Array.isArray(notification.params.diagnostics), "no diagnostics array");
  return notification.params.diagnostics;
}

// doc-at is a separate query in the default server: it does not yet include
// /// docs in hover. Record the compiler answer too, so that missing LSP
// coverage cannot be mistaken for a sound doc invalidation implementation.
async function docQuery(launcher, env, project, scenario) {
  const source = join(project, "doc-buffer.vibe");
  writeFileSync(source, scenario.source);
  const pos = position(scenario.source, scenario.word ?? "transform");
  const line = scenario.source.split("\n")[pos.line];
  const col = Buffer.byteLength(line.slice(0, pos.character)) + 1;
  const child = spawn("bash", [launcher, "doc-at", source, String(pos.line + 1), String(col)], { cwd: root, env });
  const timer = setTimeout(() => child.kill("SIGKILL"), 60000);
  let stdout = "", stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const result = await new Promise((resolveExit, reject) => {
    child.on("error", reject);
    child.on("exit", (code, signal) => resolveExit({ code, signal }));
  });
  clearTimeout(timer);
  // doc-at returns no doc for syntax errors; infrastructure failures must not
  // be interpreted as "no doc".
  assert.equal(result.signal, null, `doc-at died: ${stderr}`);
  assert.equal(result.code, 0, `doc-at failed: ${stderr}`);
  return stdout.trimEnd();
}

async function sample(client, uri, project, scenario, diagnostics, launcher, env) {
  const params = { textDocument: { uri }, position: position(scenario.source, scenario.word ?? "transform") };
  const hover = await client.request("textDocument/hover", params);
  const repeat = await client.request("textDocument/hover", params);
  assert.deepEqual(repeat.result, hover.result, `${scenario.name}: repeated hover drift`);
  const references = await client.request("textDocument/references", { ...params, context: { includeDeclaration: true } });
  const symbols = await client.request("textDocument/documentSymbol", { textDocument: { uri } });
  const doc = await docQuery(launcher, env, project, scenario);
  const snapshot = normalize({ diagnostics, hover: hover.result, references: references.result, symbols: symbols.result, doc }, client.child.pid, project);
  assertCurrentAnswers(snapshot, scenario);
  return {
    snapshot,
    wall_ms: { hover: hover.wall_ms, repeat_hover: repeat.wall_ms, references: references.wall_ms, symbols: symbols.wall_ms },
  };
}

async function session(engine, env, output, project, selected, label) {
  const launcher = join(root, "runtime/vibe");
  const args = engine === "node" ? [join(root, "clients/js/lsp_server.js")] : [launcher, "lsp", "--selfhost"];
  const client = new Client(engine === "node" ? process.execPath : "bash", args, { ...env, VIBE_BIN: launcher }, join(output, `${label}.json`));
  const uri = pathToFileURL(join(project, "app.vibe")).href;
  let success = false;
  const rows = [];
  try {
    const initialize = await client.request("initialize", { rootUri: pathToFileURL(project).href, capabilities: {} });
    assert(initialize.result.capabilities.hoverProvider, "hover capability absent");
    client.send("initialized");
    for (const [index, scenario] of selected.entries()) {
      putProject(project, scenario);
      const updateStart = performance.now();
      const diagnostics = await documentChange(client, uri, scenario, index);
      const updateMs = performance.now() - updateStart;
      const row = { name: scenario.name, ...(await sample(client, uri, project, scenario, diagnostics, launcher, env)) };
      row.wall_ms.document_update = updateMs;
      rows.push(row);
      if (scenario.dependency_buffer !== undefined) {
        const dependencyUri = new URL("dep.vibe", uri).href;
        client.send("textDocument/didClose", { textDocument: { uri: dependencyUri } });
        const closed = await client.wait((msg) => msg.method === "textDocument/publishDiagnostics" && msg.params.uri === dependencyUri);
        assert.deepEqual(closed.params.diagnostics, [], "dependency didClose must clear diagnostics");
      }
    }
    success = true;
    return { initialize_ms: initialize.wall_ms, rows };
  } finally { await client.close(success); }
}

export async function run(stageArg, outArg, rounds = 3) {
  assert(Number.isInteger(rounds) && rounds >= 3, "at least three independent rounds required");
  const stage2 = resolve(stageArg), output = resolve(outArg);
  const runner = join(root, "runtime/viberun/target/release/viberun");
  assert(existsSync(stage2), "explicit stage2 is required; no seed fallback");
  assert(existsSync(runner), "build the native viberun runner first");
  assert(!existsSync(output), "output directory must be new (no stale receipts)");
  mkdirSync(output, { recursive: true });
  const project = join(output, "project"), cache = join(output, "cache");
  mkdirSync(project);
  const cleanEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("VIBE_") && !key.startsWith("NODE_")));
  const env = {
    ...cleanEnv, VIBE_CLI_WASM: stage2, VIBE_RUNNER: runner, VIBE_LIB: join(root, "lib"),
    VIBE_HOME: join(output, "home"), VIBE_BUILD_DIR: join(output, "build"), VIBE_BUILD_CACHE_DIR: cache,
    VIBE_RC: "0", VIBE_UNSTABLE: "0", VIBE_CHECKED_MODULE_CACHE: "off", VIBE_CODEGEN_BODY_CACHE: "off",
  };
  const records = [];
  for (let round = 0; round < rounds; round++) {
    for (const engine of round % 2 ? ["selfhost", "node"] : ["node", "selfhost"]) {
      rmSync(cache, { recursive: true, force: true });
      const replay = await session(engine, env, output, project, scenarios, `${engine}-${round}-replay`);
      for (const scenario of scenarios) {
        rmSync(cache, { recursive: true, force: true });
        const fresh = await session(engine, env, output, project, [scenario], `${engine}-${round}-${scenario.name}-fresh`);
        const row = replay.rows.find((item) => item.name === scenario.name);
        let equivalent = true;
        try { compareSnapshots(row.snapshot, fresh.rows[0].snapshot, `${engine}/${round}/${scenario.name}`); }
        catch (error) {
          equivalent = false;
          console.error(`lsp-semantic-1960: ${engine}/${round}/${scenario.name}: current-state comparison FAILED (${error.message.split("\n")[0]})`);
        }
        records.push({ engine, round, ...row, equivalent, fresh_snapshot: fresh.rows[0].snapshot, fresh_wall_ms: fresh.rows[0].wall_ms, initialize_ms: replay.initialize_ms, fresh_initialize_ms: fresh.initialize_ms });
      }
      console.error(`lsp-semantic-1960: ${engine} round ${round + 1}: ${scenarios.length} current-state comparisons recorded`);
    }
  }
  const hashFile = (file) => digest(readFileSync(join(root, file)));
  const result = {
    schema: 1, scope: "workload and invalidation inventory; no semantic retention enabled", rounds,
    compiler_sha256: digest(readFileSync(stage2)), runner_sha256: digest(readFileSync(runner)), node: process.version,
    harness_sha256: digest(readFileSync(fileURLToPath(import.meta.url))),
    inputs: Object.fromEntries(["runtime/vibe", "clients/js/lsp_server.js", "lib/@vibe/lsp/lsp_server.vibe", "lib/@vibe/compiler/query/type_at.vibe", "lib/@vibe/compiler/query/doc_at.vibe"].map((file) => [file, hashFile(file)])),
    settings: Object.fromEntries(Object.entries(env).filter(([key]) => key.startsWith("VIBE_")).map(([key, value]) => [key, value.replaceAll(root, "<repo>").replaceAll(output, "<output>")])),
    scenarios: scenarios.map((scenario) => ({ ...scenario, source_sha256: digest(scenario.source), dependency_sha256: scenario.dependency == null ? null : digest(scenario.dependency) })),
    passed: records.every((record) => record.equivalent), records,
  };
  writeFileSync(join(output, "receipt.json"), JSON.stringify(result, null, 2) + "\n");
  assert(result.passed, "current-state parity failed; inspect receipt.json (not a successful measurement)");
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert(process.argv.length === 4, "usage: probe.mjs <explicit-stage2.wasm> <new-output-directory>");
  await run(process.argv[2], process.argv[3]);
}
