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
import { pickStaleArtifact, readModuleArtifacts } from "./cache_artifacts.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const stage2 = process.argv[2] || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !fs.existsSync(stage2)) {
  throw new Error("pass a freshly built stage2.wasm, or set VIBE_STAGE2_WASM");
}
const units = process.argv.slice(3).includes("--units");
// The edit rows are cheap (one three-module project) and the corpus rows are
// not, so the self-test that mutates the corpus runs only the former.
const onlyEdits = process.argv.slice(3).includes("--only-edits");
const editCorpus = process.env.VIBE_CHECKED_MODULE_EDIT_CORPUS
  || path.join(root, "bench/incremental/checked_module_edit");
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
    this.counters = null;
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
      // 4/5 is 2/3 plus the two lane-parse counters (#2766/#2767): 5 carries
      // the checked-module-artifact reuse class, 4 does not, as 3 and 2 did.
      const expectedSchema = this.mode === "off" ? 4 : 5;
      if (counters.schema !== expectedSchema) throw new Error(`expected telemetry schema ${expectedSchema} in ${this.mode}`);
      this.hits += counters.modules_reused_checked_module_artifact || 0;
      this.checks += counters.checker_executions;
      // Kept beside the result rather than in it: the edit rows below ask this
      // run's decision shape, while the mode-to-mode rows compare only what a
      // user can see, and reuse counters differ between modes by design.
      this.counters = counters;
    } else if (fs.existsSync(this.telemetry)) {
      throw new Error(`failed compile retained success telemetry: ${source}`);
    }
    // Release a large completed compiler before another mode allocates its
    // heap. Waiting until this mode's next request retains three large heaps.
    if (this.heap > 400_000_000) this.stop();
    return { status: response.exit_code, bytes: bytes ? sha(bytes) : null, diagnostic };
  }
}

// #2875: every comparison below assumes the three compiles of a case read ONE
// input. Nothing enforced that, and when it broke the gate still blamed the
// cache: a session editing `lib/@vibe/compiler/**` and running
// `scripts/vibe_test.sh` (which regenerates the bundles through
// `ensure_generated.sh`) changed the sources under a running gate, and what it
// printed was `parity mismatch: fixtures/contract_conformance_test.vibe`. The
// artifacts said otherwise -- all 45 `assert_eq failed. at off=<N>` strings
// baked into them differed by exactly 70, which is one compile reading 70 more
// bytes of source than the other, not a cache that disagrees with itself.
//
// So: fingerprint what a run compiles, and when it moves, say THAT. Stat only
// (path, size, mtime) over the two trees a case can read -- 21 ms for 2833
// files here, so it is taken at the start, again whenever a comparison is
// about to fail, and once more at the end. A run whose inputs moved has no
// verdict to give, whether its comparisons happened to agree or not.
const TREE_ROOTS = ["lib", "fixtures"];
function treeFingerprint() {
  const entries = new Map();
  const walk = dir => {
    let listing;
    try { listing = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of listing) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      const key = path.relative(root, full);
      let stat;
      try { stat = fs.statSync(full); } catch { entries.set(key, "gone"); continue; }
      entries.set(key, `${stat.size}:${stat.mtimeMs}`);
    }
  };
  for (const dir of TREE_ROOTS) walk(path.join(root, dir));
  return entries;
}
function treeChanges(before, after) {
  const changed = [];
  for (const [file, stamp] of after) {
    const was = before.get(file);
    if (was === undefined) changed.push(`added ${file}`);
    else if (was !== stamp) changed.push(`changed ${file}`);
  }
  for (const file of before.keys()) if (!after.has(file)) changed.push(`removed ${file}`);
  return changed;
}
const treeBefore = treeFingerprint();
function refuseIfTreeMoved(context) {
  const changed = treeChanges(treeBefore, treeFingerprint());
  if (!changed.length) return;
  const shown = changed.slice(0, 10).join("\n  ");
  throw new Error(`the source tree changed during the run, so ${context} cannot be compared`
    + ` -- ${changed.length} file(s) under ${TREE_ROOTS.join(", ")} moved:\n  ${shown}`
    + (changed.length > 10 ? `\n  ... and ${changed.length - 10} more` : "")
    + `\nRe-run on a tree nobody is editing. A gate and \`scripts/vibe_test.sh\``
    + ` (which regenerates the bundles) cannot share a checkout.`);
}

function equal(expected, actual, label) {
  if (JSON.stringify(expected) !== JSON.stringify(actual)) {
    // The tree first: a mismatch explained by a moving input is not a mismatch,
    // and naming the cache there sends the reader after the wrong thing.
    refuseIfTreeMoved(`\`${label}\``);
    fs.writeFileSync(path.join(work, "failure.json"), JSON.stringify({ label, expected, actual }, null, 2));
    throw new Error(`parity mismatch: ${label}; see ${work}/failure.json`);
  }
}
function moduleFiles(dir) {
  return readModuleArtifacts(dir).map(entry => entry.file);
}

// ---------------------------------------------------------------------------
// Invalidation across an EDIT (#1959).
//
// Every row above compiles a program ONCE. That proves the transport is sound
// and that a hostile cache falls back, but it never asks the question reuse
// exists to answer: after an edit, which modules may keep their artifact?
// Both halves of that answer can be wrong, and they fail in opposite ways --
// reusing too little only costs time, while reusing a module whose dependency
// changed its public interface is a silently wrong build. So each case here
// asserts BOTH: the warm result equals a cold compile of the same tree at the
// same paths (bytes, diagnostic and exit status), and the decision shape is
// exactly the expected one.
//
// The counts are exact, not bounds. A change that reuses MORE is not
// automatically an improvement here -- it is the invalidation contract
// changing -- so it should land as a deliberate edit to this table together
// with the measurement that justifies it.
//
// `plants` is the same kind of count for the stale-artifact probe below: how
// many modules this edit gives a SAME-PATH earlier artifact to plant. It is a
// function of which modules the edit moved, so it is stated here rather than
// discovered at run time -- a probe that silently plants nothing is the shape
// #2836 is about.
const editCases = [
  // An untouched tree keeps every artifact -- and so has no earlier artifact
  // for any module, which is why the probe below must decline rather than
  // reach for a neighbour's bytes.
  { name: "noop", after: "leaf.vibe", rechecked: 0, reused: 3, plants: 0 },
  // A comment is not in the leaf's public environment, so the two consumers
  // hold. The leaf itself misses: the input identity binds its verbatim
  // source, which is what keeps `///` docs and source offsets honest.
  { name: "comment", after: "edits/comment.vibe", rechecked: 1, reused: 2, plants: 1 },
  // The same shape for a private body change, whose output legitimately
  // differs from the pre-edit build -- and still equals a cold build of it.
  { name: "private_body", after: "edits/private_body.vibe", rechecked: 1, reused: 2, plants: 1 },
  // A new export changes the leaf's public environment, so its direct
  // consumer misses. `entry` imports only `mid_value`, whose own environment
  // did not change, so a public edit does not invalidate the whole closure.
  { name: "public_additive", after: "edits/public_additive.vibe", rechecked: 2, reused: 1, plants: 2 },
  // The strongest row: the edit makes the consumer ILL-TYPED. A stale
  // consumer artifact would emit a wasm here where a clean build reports an
  // arity mismatch, so "invalidates every affected consumer" is observable as
  // success-versus-diagnostic rather than only as a counter.
  { name: "public_breaking", after: "edits/public_breaking.vibe", diagnosed: true, plants: 1 },
  // And the reverse: a cache warmed on a BROKEN tree may not keep the
  // diagnosis alive once the interface is repaired.
  { name: "repair", before: "edits/public_breaking.vibe", after: "leaf.vibe", rechecked: 3, reused: 0, plants: 1 },
];

function writeProject(dir, leafFile) {
  fs.mkdirSync(dir, { recursive: true });
  for (const name of ["entry.vibe", "mid.vibe"]) {
    fs.copyFileSync(path.join(editCorpus, name), path.join(dir, name));
  }
  fs.copyFileSync(path.join(editCorpus, leafFile), path.join(dir, "leaf.vibe"));
}

async function runEditCases() {
  const planted = [];
  for (const editCase of editCases) {
    const name = editCase.name;
    const dir = path.join(work, `edit-${name}`);
    const entry = path.relative(root, path.join(dir, "entry.vibe"));
    writeProject(dir, editCase.before || "leaf.vibe");
    const warm = new Compiler("on", path.join(work, `edit-cache-${name}`));
    await warm.compile(entry, "main", `${name}-warmup`);
    const stalePool = readModuleArtifacts(warm.cache);
    writeProject(dir, editCase.after);
    const reused = await warm.compile(entry, "main", `${name}-warm`);
    const counters = warm.counters;
    // `verify` re-checks every module and refuses to publish a body that
    // disagrees with what is already stored, so running it on the edited tree
    // proves the artifacts the warm run KEPT are what a fresh check produces.
    const verified = new Compiler("verify", warm.cache);
    equal(reused, await verified.compile(entry, "main", `${name}-verify`), `edit ${name} verify`);
    verified.stop();
    // The cold control: same paths, same bytes on disk, empty cache.
    const cold = new Compiler("off", path.join(work, `edit-cold-${name}`));
    equal(await cold.compile(entry, "main", `${name}-cold`), reused, `edit ${name} cold parity`);
    cold.stop();
    if (editCase.diagnosed) {
      if (reused.bytes || !reused.diagnostic) throw new Error(`edit ${name}: expected a diagnosed tree`);
    } else {
      if (!reused.bytes) throw new Error(`edit ${name}: expected an emitted artifact, got ${reused.diagnostic}`);
      // The graph first: the counts below are only meaningful against the
      // three-module chain they were measured on, so a corpus that no longer
      // has that shape must say so rather than fail as a surprising count.
      if (counters.modules_planned !== 3) throw new Error(`edit ${name}: planned ${counters.modules_planned} of 3 modules`);
      equal({ rechecked: editCase.rechecked, reused: editCase.reused },
        { rechecked: counters.modules_rechecked, reused: counters.modules_reused_checked_module_artifact },
        `edit ${name} decision shape`);
    }
    // WHICH artifacts the edited tree consults, and what they must contain:
    // a cold `on` compile of the same tree publishes exactly that set. The
    // warm cache also still holds the pre-edit artifacts of every module the
    // edit changed, and nothing looks those up again -- planting into one of
    // those would assert a repair no run owes.
    const canonicalCache = path.join(work, `edit-canonical-${name}`);
    const canonicalRun = new Compiler("on", canonicalCache);
    equal(reused, await canonicalRun.compile(entry, "main", `${name}-canonical`), `edit ${name} cold artifact cache`);
    canonicalRun.stop();
    for (const file of moduleFiles(canonicalCache)) {
      const consulted = path.join(warm.cache, path.basename(file));
      const canonical = fs.readFileSync(file);
      if (!fs.existsSync(consulted)) throw new Error(`edit ${name}: warm cache lacks ${path.basename(file)}`);
      // Reuse must publish the bytes a clean build publishes, not merely
      // produce the same wasm from them.
      if (!fs.readFileSync(consulted).equals(canonical)) {
        throw new Error(`edit ${name}: warm artifact differs from the cold one: ${path.basename(file)}`);
      }
      // A stale artifact is the realistic corruption after an edit: same
      // path, same envelope, an earlier source. The corpus probe plants
      // another PROGRAM's artifact; this plants one THIS MODULE published a
      // moment ago, which is the shape a torn cache actually takes.
      //
      // Pairing by module is the whole point (#2836 §3). The identity embeds
      // `normalize_path(path)`, so a neighbour's artifact is refused for its
      // PATH -- which a decoder that wrongly accepted an earlier source for
      // the right module would also pass. Picking "any artifact whose bytes
      // differ" therefore proved the weaker property while claiming this one.
      const stale = pickStaleArtifact(canonical, stalePool);
      if (!stale) continue;
      fs.writeFileSync(consulted, stale.bytes);
      warm.stop();
      equal(reused, await warm.compile(entry, "main", `${name}-stale`), `edit ${name} stale artifact`);
      if (!fs.readFileSync(consulted).equals(canonical)) throw new Error(`edit ${name}: stale artifact was not repaired`);
      planted.push({ case: name, module: stale.path });
    }
    warm.stop();
    const plants = planted.filter(entry => entry.case === name).length;
    if (plants !== editCase.plants) {
      throw new Error(`edit ${name}: planted ${plants} same-module stale artifact(s), expected ${editCase.plants}`);
    }
  }
  if (!planted.length) throw new Error("no stale artifact was ever planted; the edit probe proved nothing");
  return { cases: editCases.length, planted };
}


// The whole-corpus rows: every typecheck fixture through off/verify/on, then
// the hostile-cache and invalid-mode probes. `--only-edits` skips all of it,
// which is what makes the companion self-test affordable to run per mutation.
async function runCorpusCases() {
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
  return { cases: corpus.length, accepted, rejected, published,
    hostile_cases: 2 * (mutations.length + 1), invalid_mode_cases: 1,
    verified_checker_executions: verify.checks, reused_checker_executions: on.checks,
    checked_module_hits: on.hits };
}

try {
  const corpusReport = onlyEdits ? {} : await runCorpusCases();
  const edits = await runEditCases();
  const report = { stage2: path.resolve(stage2), stage2_sha256: sha(fs.readFileSync(stage2)),
    ...corpusReport, edit_cases: edits.cases,
    edit_stale_artifacts_planted: edits.planted.length,
    // WHICH module each plant displaced: the evidence that the probe paired by
    // module rather than settling for a neighbour's bytes.
    edit_stale_artifact_modules: edits.planted.map(entry => `${entry.case}:${entry.module}`) };
  // Nothing disagreed -- but a run whose inputs moved was measuring two trees,
  // so it has no verdict either way (#2875).
  refuseIfTreeMoved("this run's results");
  fs.writeFileSync(path.join(work, "report.json"), JSON.stringify(report, null, 2));
  console.log(`[checked-module-parity] ok ${JSON.stringify(report)}`);
  console.log(`[checked-module-parity] evidence: ${work}`);
} finally {
  for (const daemon of daemons) daemon.stop();
}
