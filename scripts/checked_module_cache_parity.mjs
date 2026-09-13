#!/usr/bin/env node
// Compare real FS compiles with checked-module reuse off, freshly verified,
// and consumed. A separate probe moves corrupt and cross-mode transport into
// a valid slot, then requires both identical output and canonical repair.
import fs from "node:fs";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import readline from "node:readline";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const stage2 = process.argv[2] || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !fs.existsSync(stage2)) {
  throw new Error("pass a freshly built stage2.wasm, or set VIBE_STAGE2_WASM");
}
const units = process.argv.slice(3).includes("--units");
const work = fs.mkdtempSync(path.join(root, "_build/checked-module-parity-"));
const runner = path.join(root, "scripts/run_wasm_vibe_host_runner.sh");
const baseEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("VIBE_")));
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const daemons = [];

class Compiler {
  constructor(mode, cache, extra = {}) {
    this.mode = mode;
    this.cache = cache;
    this.extra = extra;
    this.heap = 0;
    this.hits = 0;
    this.checks = 0;
    this.telemetry = path.join(work, `telemetry-${daemons.length}.json`);
    daemons.push(this);
  }
  stop() {
    this.lines?.close();
    this.process?.kill("SIGKILL");
    this.process = null;
  }
  async compile(source, entry, label) {
    // A compiler-closure test can itself approach a gigabyte. Recycling here
    // also makes a compiler trap local to the request that caused it.
    if (!this.process || this.process.exitCode !== null || this.heap > 400_000_000) {
      this.stop();
      fs.mkdirSync(this.cache, { recursive: true });
      const errorLog = fs.openSync(path.join(work, `${label}.host.log`), "a");
      this.process = spawn("bash", [runner, "--daemon", "--invoke", "cli_main", path.resolve(stage2)], {
        cwd: root,
        env: { ...baseEnv, VIBE_PREOPEN_DIR: root, VIBE_LIB: path.join(root, "lib"),
          VIBE_IMPORT_ABI: "raw", VIBE_FS_COMPILE: "1", VIBE_RC: "1",
          VIBE_CODEGEN_BODY_CACHE: "off", VIBE_UNSTABLE: "1",
          VIBE_INCREMENTAL_TELEMETRY_OUT: this.telemetry,
          VIBE_CHECKED_MODULE_CACHE: this.mode, VIBE_BUILD_CACHE_DIR: this.cache, ...this.extra },
        stdio: ["pipe", "pipe", errorLog],
      });
      fs.closeSync(errorLog);
      this.lines = readline.createInterface({ input: this.process.stdout });
      this.heap = 0;
    }
    const output = path.join(work, `${label}.wasm`);
    fs.rmSync(output, { force: true });
    fs.rmSync(`${output}.diag`, { force: true });
    const proc = this.process;
    const response = await new Promise((resolve, reject) => {
      const finish = (error, value) => {
        clearTimeout(timer);
        proc.off("close", closed);
        this.lines.off("line", line);
        if (error) reject(error); else resolve(value);
      };
      const closed = code => finish(new Error(`compiler exited ${code}: ${source}`));
      const line = text => {
        try { finish(null, JSON.parse(text)); }
        catch { finish(new Error(`invalid compiler response: ${text}`)); }
      };
      const timer = setTimeout(() => {
        finish(new Error(`compiler timed out: ${source}`));
        this.stop();
      }, 300_000);
      proc.once("close", closed);
      this.lines.once("line", line);
      proc.stdin.write(`${JSON.stringify({ args: [source, output, entry] })}\n`);
    });
    this.heap = response.heap_ptr || 0;
    const bytes = fs.existsSync(output) ? fs.readFileSync(output) : null;
    const diagnostic = fs.existsSync(`${output}.diag`) ? fs.readFileSync(`${output}.diag`, "utf8") : "";
    if (response.error) throw new Error(`${this.mode} ${source} ${entry}: ${response.error} (heap ${this.heap})`);
    if (!bytes && !diagnostic) throw new Error(`neither output nor diagnostic: ${source}`);
    if (bytes) {
      const counters = parseIncrementalTelemetry(fs.readFileSync(this.telemetry, "utf8"), this.telemetry);
      const expectedSchema = this.mode === "off" ? 2 : 3;
      if (counters.schema !== expectedSchema) throw new Error(`expected telemetry schema ${expectedSchema} in ${this.mode}`);
      this.hits += counters.modules_reused_checked_module_artifact || 0;
      this.checks += counters.checker_executions;
    } else if (fs.existsSync(this.telemetry)) {
      throw new Error(`failed compile retained success telemetry: ${source}`);
    }
    // Release a large completed compiler before another mode allocates its
    // heap. Waiting until this mode's next request retains three large heaps.
    if (this.heap > 400_000_000) this.stop();
    return { status: response.exit_code, bytes: bytes ? sha(bytes) : null, diagnostic };
  }
}

function equal(expected, actual, label) {
  if (JSON.stringify(expected) !== JSON.stringify(actual)) {
    fs.writeFileSync(path.join(work, "failure.json"), JSON.stringify({ label, expected, actual }, null, 2));
    throw new Error(`parity mismatch: ${label}; see ${work}/failure.json`);
  }
}
function moduleFiles(dir) {
  return fs.readdirSync(dir).map(name => path.join(dir, name)).filter(file => {
    if (!fs.statSync(file).isFile()) return false;
    const fd = fs.openSync(file, "r");
    const prefix = Buffer.alloc(14);
    const n = fs.readSync(fd, prefix, 0, 14, 0);
    fs.closeSync(fd);
    return n === 14 && prefix.subarray(0, 5).toString() === "VART1" &&
      prefix.subarray(9).equals(Buffer.from([118, 77, 79, 68, 1]));
  });
}

try {
  const off = new Compiler("off", path.join(work, "off-cache"));
  const verify = new Compiler("verify", path.join(work, "reuse-cache"));
  const on = new Compiler("on", path.join(work, "reuse-cache"));
  const rows = fs.readFileSync(path.join(root, "fixtures/typecheck/expected.tsv"), "utf8")
    .split("\n").filter(row => row && !row.startsWith("#"));
  const corpus = rows.flatMap(row => {
    const name = row.split("\t")[0];
    let source = `fixtures/typecheck/${name}.vibe`;
    if (!fs.existsSync(path.join(root, source))) source = `fixtures/${name}.vibe`;
    if (!fs.existsSync(path.join(root, source))) throw new Error(`missing corpus source: ${source}`);
    return ["__no_entry__", "main"].map(entry => [source, entry]);
  });
  if (units) {
    const files = execFileSync("bash", ["scripts/unit_test_runner.sh", "--list"], { cwd: root, encoding: "utf8" }).trim().split("\n");
    corpus.push(...files.map(source => [source, "__no_entry__"]));
  } else {
    // This imports the compiler, including its multi-megabyte bundle strings.
    // Small syntax fixtures missed an artifact decoder/encoder memory failure.
    corpus.push(["fixtures/contract_conformance_test.vibe", "__no_entry__"]);
  }
  // Repeat after publication to exercise warm verification of the large body.
  corpus.push(["fixtures/contract_conformance_test.vibe", "__no_entry__"]);
  let accepted = 0, rejected = 0;
  for (let i = 0; i < corpus.length; i++) {
    const [source, entry] = corpus[i];
    const baseline = await off.compile(source, entry, "off");
    const checked = await verify.compile(source, entry, "verify");
    const reused = await on.compile(source, entry, "on");
    equal(baseline, checked, `${source} ${entry} verify`);
    equal(baseline, reused, `${source} ${entry} on`);
    if (baseline.bytes) accepted++; else rejected++;
    if ((i + 1) % 50 === 0) console.log(`[checked-module-parity] ${i + 1}/${corpus.length}`);
  }
  if (!accepted || !rejected) throw new Error("corpus must exercise both emitted output and diagnostics");
  const published = moduleFiles(path.join(work, "reuse-cache")).length;
  if (!published) throw new Error("no checked module artifacts were published; the cache lane was never exercised");
  if (!on.hits || verify.hits || on.checks >= verify.checks) {
    throw new Error(`reuse did not skip real checks: on=${on.checks}/${on.hits}, verify=${verify.checks}/${verify.hits}`);
  }
  // The corruption probe uses its own cache so the one artifact is identified
  // by the real envelope, without guessing the implementation's filename hash.
  const probeSource = path.join(work, "probe.vibe");
  fs.writeFileSync(probeSource, "fn main() -> Int { 42 }\n");
  const probeDir = path.join(work, "probe-cache");
  const probe = new Compiler("on", probeDir);
  const original = await off.compile(probeSource, "main", "probe-off");
  equal(original, await probe.compile(probeSource, "main", "probe-on"), "probe baseline");
  const files = moduleFiles(probeDir);
  if (files.length !== 1) throw new Error(`expected one probe artifact, got ${files.length}`);
  const target = files[0];
  const canonical = fs.readFileSync(target);
  const changed = Buffer.from(canonical);
  changed[changed.length - 1] ^= 1;
  const foreignSource = path.join(work, "foreign.vibe");
  fs.writeFileSync(foreignSource, "fn main() -> Int { 99 }\n");
  await probe.compile(foreignSource, "main", "foreign");
  const foreign = moduleFiles(probeDir).find(file => file !== target);
  const relaxed = new Compiler("on", path.join(work, "relaxed-cache"), { VIBE_CHECK_ERROR_ROW: "0" });
  await relaxed.compile(probeSource, "main", "relaxed");
  const crossMode = moduleFiles(path.join(work, "relaxed-cache"));
  if (crossMode.length !== 1) throw new Error("missing cross-mode artifact");
  const mutations = [canonical.subarray(0, canonical.length - 1), changed,
    fs.readFileSync(foreign), fs.readFileSync(crossMode[0])];
  const verifyProbe = new Compiler("verify", probeDir);
  for (const consumer of [probe, verifyProbe]) {
    for (let i = 0; i < mutations.length; i++) {
      fs.writeFileSync(target, mutations[i]);
      consumer.stop();
      equal(original, await consumer.compile(probeSource, "main", `repair-${consumer.mode}-${i}`), `hostile ${consumer.mode} cache ${i}`);
      if (!fs.readFileSync(target).equals(canonical)) throw new Error(`artifact was not repaired: ${consumer.mode} case ${i}`);
    }
    fs.rmSync(target);
    consumer.stop();
    equal(original, await consumer.compile(probeSource, "main", `missing-${consumer.mode}`), "missing artifact");
    if (!fs.readFileSync(target).equals(canonical)) throw new Error("missing artifact was not republished");
  }
  const invalid = new Compiler("invalid", path.join(work, "invalid-cache"));
  fs.writeFileSync(invalid.telemetry, '{"stale":true}');
  let refused = false;
  try { await invalid.compile(probeSource, "main", "invalid-mode"); }
  catch (error) {
    // The CLI prints an uncaught configuration error on stderr, then traps;
    // the daemon response carries only "unreachable" for that final trap.
    const message = fs.readFileSync(path.join(work, "invalid-mode.host.log"), "utf8");
    if (!message.includes("set VIBE_CHECKED_MODULE_CACHE to off, verify, or on")) throw error;
    refused = true;
  }
  if (!refused || fs.existsSync(invalid.telemetry)) throw new Error("invalid cache mode retained stale success telemetry");
  const report = { stage2: path.resolve(stage2), stage2_sha256: sha(fs.readFileSync(stage2)),
    cases: corpus.length, accepted, rejected, published, hostile_cases: 2 * (mutations.length + 1), invalid_mode_cases: 1,
    verified_checker_executions: verify.checks, reused_checker_executions: on.checks, checked_module_hits: on.hits };
  fs.writeFileSync(path.join(work, "report.json"), JSON.stringify(report, null, 2));
  console.log(`[checked-module-parity] ok ${JSON.stringify(report)}`);
  console.log(`[checked-module-parity] evidence: ${work}`);
} finally {
  for (const daemon of daemons) daemon.stop();
}
