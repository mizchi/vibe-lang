#!/usr/bin/env node
// Opt-in comparison of two already-built compilers. The generated target is
// always linear RC; the compiler binaries determine their own memory mode.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { cpus, totalmem } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const SCRIPT = fileURLToPath(import.meta.url);
const ROOT = dirname(dirname(SCRIPT));
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const positive = n => Number.isSafeInteger(n) && n > 0;
const median = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const hasCache = dir => readdirSync(dir, { withFileTypes: true }).some(e =>
  e.isDirectory() ? hasCache(join(dir, e.name)) : e.isFile() && statSync(join(dir, e.name)).size > 0);

export function parseMemory(stderr) {
  const line = stderr.split("\n").filter(l => l.startsWith("[wasm-memory] ")).at(-1) ?? "";
  const fields = Object.fromEntries([...line.matchAll(/\b(pages|bytes|heap_ptr|rss)=(\d+)\b/g)].map(m => [m[1], Number(m[2])]));
  if (![fields.pages, fields.bytes, fields.heap_ptr, fields.rss].every(positive) ||
      fields.bytes !== fields.pages * 65536 || fields.heap_ptr > fields.bytes) throw new Error("invalid or missing memory stats");
  return { heap_ptr_bytes: fields.heap_ptr, linear_memory_bytes: fields.bytes, end_rss_bytes: fields.rss };
}

export function parsePeakRss(text, platform) {
  const match = platform === "darwin" ? text.match(/(\d+)\s+maximum resident set size/) : text.match(/peak_rss_kib=(\d+)/);
  const bytes = Number(match?.[1]) * (platform === "darwin" ? 1 : 1024);
  if (!positive(bytes)) throw new Error("invalid or missing peak RSS");
  return bytes;
}

function checkoutIdentity(root) {
  const git = args => spawnSync("git", args, { cwd: root, encoding: "utf8" });
  const commit = git(["rev-parse", "HEAD"]);
  const files = git(["ls-files", "-z", "--", "lib"]);
  const h = createHash("sha256");
  for (const path of files.stdout.split("\0").filter(p => /\.(vibe|vpkg)$/.test(p)).sort()) {
    h.update(path).update("\0").update(readFileSync(join(root, path))).update("\0");
  }
  return { commit: commit.status === 0 ? commit.stdout.trim() : null,
    lib_sources_sha256: files.status === 0 ? h.digest("hex") : null };
}

export function collect({ root = ROOT, baseline, candidate, out, rounds = 4, suite = "closure", allowCodegenDiff = false, run = spawnSync } = {}) {
  if (!Number.isSafeInteger(rounds) || rounds < 1 || rounds > 100) throw new Error("rounds must be between 1 and 100");
  if (!["closure", "full"].includes(suite)) throw new Error("suite must be closure or full");
  if (!["darwin", "linux"].includes(process.platform)) throw new Error("peak RSS measurement requires macOS or Linux");
  const artifacts = [baseline, candidate].map(path => {
    const absolute = resolve(root, path);
    const bytes = readFileSync(absolute);
    if (!WebAssembly.validate(bytes)) throw new Error(`invalid compiler Wasm: ${absolute}`);
    return { path: absolute, sha256: hash(bytes), bytes: bytes.length };
  });
  out = resolve(root, out);
  mkdirSync(dirname(out), { recursive: true });
  mkdirSync(out); // Never overwrite a prior result, including a failed attempt.
  const scratch = join(out, "scratch");
  mkdirSync(scratch);
  const logs = join(out, "logs");
  mkdirSync(logs);
  const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  const protocol = [SCRIPT, runner, join(root, "scripts/wasm_vibe_host_runner.js")].map(p => readFileSync(p));
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("VIBE_") && !k.startsWith("NODE_")));
  Object.assign(env, {
    PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ""}`,
    VIBE_PREOPEN_DIR: root, VIBE_LIB: join(root, "lib"), VIBE_IMPORT_ABI: "raw",
    VIBE_FS_COMPILE: "1", VIBE_BACKEND: "wasi", VIBE_RC: "1",
    VIBE_CHECKED_MODULE_CACHE: "off", VIBE_EXPERIMENTAL_AST_CACHE: "0",
    VIBE_CODEGEN_BODY_CACHE: "off", VIBE_WASM_NAMES: "0", VIBE_WASM_MEMORY_STATS: "1",
  });
  const manifest = { schema: 1, created_at: new Date().toISOString(), protocol_sha256: hash(Buffer.concat(protocol)),
    checkout: checkoutIdentity(root), baseline: artifacts[0], candidate: artifacts[1],
    node: process.version, platform: process.platform, arch: process.arch,
    cpu: cpus()[0]?.model, host_memory_bytes: totalmem(), rounds, suite,
    output_equivalence: allowCodegenDiff ? "within-compiler; semantic parity requires separate execution tests" : "across-compilers",
    target: "linear-rc", selectors: Object.fromEntries(Object.entries(env).filter(([k]) => k.startsWith("VIBE_"))),
    cache: "new process per sample; empty cache for cold, same populated cache for warm; OS cache uncontrolled",
    compiler_memory_mode: "determined by supplied binaries, not inferred from names or VIBE_RC",
  };
  writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  const cases = [{ name: "closure", input: "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", entry: "__no_entry__" }];
  if (suite === "full") cases.push({ name: "cli", input: "lib/@vibe/cli/entry.vibe", entry: "cli_main" });
  const samples = [];
  const hashes = new Map();
  try {
    for (const [i, lane] of ["a", "b"].entries()) copyFileSync(artifacts[i].path, join(scratch, `${lane}.wasm`));
    for (let round = 0; round < rounds; round++) {
      for (const corpus of cases) {
        for (const lane of round % 2 ? ["b", "a"] : ["a", "b"]) {
          const cache = join(scratch, `cache-${String(round).padStart(3, "0")}-${corpus.name}-${lane}`);
          mkdirSync(cache);
          for (const temperature of ["cold", "warm"]) {
            if (temperature === "warm" && !hasCache(cache)) throw new Error("cold compile did not populate warm cache");
            const name = `${round}-${corpus.name}-${lane}-${temperature}`;
            const output = join(scratch, "out.wasm");
            rmSync(output, { force: true });
            rmSync(`${output}.diag`, { force: true });
            const rssFile = join(logs, `${name}.time`);
            const timeArgs = process.platform === "darwin" ? ["-l", "-o", rssFile] : ["-f", "peak_rss_kib=%M", "-o", rssFile];
            const args = [...timeArgs, "bash", runner, "--invoke", "cli_main", join(scratch, `${lane}.wasm`), corpus.input, output, corpus.entry];
            const start = performance.now();
            const result = run("/usr/bin/time", args, { cwd: root, env: { ...env, VIBE_BUILD_CACHE_DIR: cache }, encoding: "utf8", timeout: 180_000, maxBuffer: 8 * 1024 * 1024 });
            const wall_ms = performance.now() - start;
            const diagnostics = existsSync(`${output}.diag`) ? readFileSync(`${output}.diag`, "utf8") : "";
            writeFileSync(join(logs, `${name}.log`), `${result.stdout ?? ""}${result.stderr ?? ""}${diagnostics}`);
            if (result.error || result.status !== 0) throw new Error(`${name}: process failed: ${result.error ?? result.status}; see ${logs}`);
            if (!existsSync(output)) throw new Error(`${name}: missing output`);
            const bytes = readFileSync(output);
            if (!WebAssembly.validate(bytes)) throw new Error(`${name}: invalid Wasm output`);
            const wasm_sha256 = hash(bytes);
            const hashKey = allowCodegenDiff ? `${corpus.name}-${lane}` : corpus.name;
            if (hashes.has(hashKey) && hashes.get(hashKey) !== wasm_sha256) throw new Error(`${name}: output differs ${allowCodegenDiff ? "within one compiler across rounds or temperatures" : "across compilers, rounds or temperatures"}`);
            hashes.set(hashKey, wasm_sha256);
            const row = { round, corpus: corpus.name, lane, temperature, wall_ms,
              ...parseMemory(result.stderr), peak_rss_bytes: parsePeakRss(readFileSync(rssFile, "utf8"), process.platform),
              wasm_bytes: bytes.length, wasm_sha256 };
            samples.push(row);
            appendFileSync(join(out, "samples.jsonl"), JSON.stringify(row) + "\n");
          }
          rmSync(cache, { recursive: true });
        }
      }
    }
    const comparisons = cases.flatMap(corpus => ["cold", "warm"].map(temperature => {
      const select = lane => samples.filter(s => s.corpus === corpus.name && s.temperature === temperature && s.lane === lane);
      const a = select("a"), b = select("b");
      const fields = ["wall_ms", "heap_ptr_bytes", "linear_memory_bytes", "end_rss_bytes", "peak_rss_bytes"];
      const med = rows => Object.fromEntries(fields.map(k => [k, median(rows.map(r => r[k]))]));
      const baseline = med(a), candidate = med(b);
      return { corpus: corpus.name, temperature, baseline, candidate,
        wall_ratio: candidate.wall_ms / baseline.wall_ms,
        paired_wall_ratio: median(b.map((s, i) => s.wall_ms / a[i].wall_ms)),
        heap_ptr_ratio: candidate.heap_ptr_bytes / baseline.heap_ptr_bytes,
        peak_rss_ratio: candidate.peak_rss_bytes / baseline.peak_rss_bytes };
    }));
    const summary = { ...manifest, comparisons, samples };
    writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
    return summary;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === SCRIPT) {
  try {
    const [baseline, candidate, out, rounds = "4", suite = "closure", flag] = process.argv.slice(2);
    if (!baseline || !candidate || !out || process.argv.length > 8 || (flag !== undefined && flag !== "--allow-codegen-diff")) throw new Error("usage: compare_compiler_memory.mjs <baseline.wasm> <candidate.wasm> <new-output-directory> [rounds=4] [closure|full] [--allow-codegen-diff]");
    const result = collect({ baseline, candidate, out, rounds: Number(rounds), suite, allowCodegenDiff: flag === "--allow-codegen-diff" });
    console.log(JSON.stringify(result.comparisons, null, 2));
  } catch (error) {
    console.error(`[compare-compiler-memory] ${error.message}`);
    process.exitCode = 1;
  }
}
