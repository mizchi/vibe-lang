#!/usr/bin/env node
// Batch precompile phase for scripts/unit_test_runner.sh.
//
// Compiles every out-cache-missing test file of a battery through a small
// pool of RESIDENT stage2 compiler daemons (wasm_vibe_host_runner.js
// --daemon) instead of one node+instantiate+tier-up process per file, then
// stores each result into the compiled-test-wasm out-cache (same layout and
// keying as unit_out_store in unit_test_runner.sh). The fan-out that follows
// runs almost entirely on cache hits.
//
// Why resident: a one-shot compile pays ~0.4-0.5s of fixed process overhead
// (node boot, stage2 instantiate, V8 tier-up from scratch) per file; a warm
// daemon compiles a light test in ~10-70ms and a full-compiler-closure test
// in the compile's inherent time. The guest bump allocator never frees, so a
// daemon is recycled once its reported heap high-water passes
// VIBE_BATCH_HEAP_LIMIT (default 1.5GB; the wasm32 memory ceiling is 4GB and
// the heaviest single compile allocates ~1GB from a fresh heap).
//
// Failure policy: a file that fails here for ANY reason (compile error,
// daemon crash, timeout, plan failure) is simply not stored -- the runner's
// per-file fallback recompiles it one-shot and reports the real diagnostic
// with retries. This script never decides a test's fate; a non-zero exit
// means the batch phase itself is broken (the runner treats that as a
// warning and falls back wholesale).
//
// usage: node unit_batch_compile.mjs <stage2.wasm> <list-file>
// env (required, exported by unit_test_runner.sh):
//   ROOT_DIR OUT_CACHE_ROOT STAGE2_SHA CONTRACT_SALT
// env (optional):
//   VIBE_UNIT_BATCH_JOBS   compile daemons (default 4)
//   VIBE_BATCH_HEAP_LIMIT  recycle threshold in bytes (default 1500000000)
//   VIBE_UNIT_TEST_WEIGHTS weights tsv for heaviest-first ordering
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

const [s2Path, listFile] = process.argv.slice(2);
if (!s2Path || !listFile) {
  console.error("usage: unit_batch_compile.mjs <stage2.wasm> <list-file>");
  process.exit(2);
}
const ROOT = process.env.ROOT_DIR || process.cwd();
const OUT = path.join(process.env.OUT_CACHE_ROOT || "", process.env.STAGE2_SHA || "");
const SALT = process.env.CONTRACT_SALT || "";
if (!process.env.OUT_CACHE_ROOT || !process.env.STAGE2_SHA || !fs.existsSync(OUT)) {
  console.error("[unit-batch] OUT_CACHE_ROOT/STAGE2_SHA not set or cache dir missing");
  process.exit(2);
}
const JOBS = Math.max(1, Number(process.env.VIBE_UNIT_BATCH_JOBS || 4) | 0);
const HEAP_LIMIT = Number(process.env.VIBE_BATCH_HEAP_LIMIT || 1_500_000_000);
const RUNNER = path.join(ROOT, "scripts", "run_wasm_vibe_host_runner.sh");
const COMPILE_TIMEOUT_MS = 300_000; // matches the runner's one-shot bound
const PLAN_TIMEOUT_MS = 60_000;

const pathKey = (f) => f.replace(/\//g, "_");

// Content hashes are memoized per path: within one battery the tree is fixed,
// and the compiler-test closures share hundreds of modules, so the memo turns
// ~490 closure hashings into one pass over the distinct files.
const hashMemo = new Map();
function sha256File(p) {
  let h = hashMemo.get(p);
  if (h === undefined) {
    try {
      h = createHash("sha256").update(fs.readFileSync(p)).digest("hex");
    } catch {
      h = null;
    }
    hashMemo.set(p, h);
  }
  return h;
}

// Replicates unit_out_key exactly: sha256 over ("salt\t<salt>\n" followed by
// sha256sum-format lines, hash + two spaces + path, in .deps order), first 32
// hex chars. A mismatch is safe in both directions (it just misses), but a
// match is what makes the fan-out's hit path find these entries.
function keyFromDeps(depLines) {
  let text = `salt\t${SALT}\n`;
  for (const d of depLines) {
    const h = sha256File(d);
    if (h === null) return null;
    text += `${h}  ${d}\n`;
  }
  return createHash("sha256").update(text).digest("hex").slice(0, 32);
}

function existingHit(f) {
  const depf = path.join(OUT, `${pathKey(f)}.deps`);
  let lines;
  try {
    lines = fs.readFileSync(depf, "utf8").split("\n").filter(Boolean);
  } catch {
    return false;
  }
  if (lines.length === 0) return false;
  const key = keyFromDeps(lines);
  if (key === null) return false;
  try {
    return fs.statSync(path.join(OUT, `${pathKey(f)}.${key}.wasm`)).size > 0;
  } catch {
    return false;
  }
}

class Daemon {
  constructor(name, extraEnv) {
    this.name = name;
    this.extraEnv = extraEnv;
    this.proc = null;
    this.rl = null;
    this.heap = 0;
    this.chain = Promise.resolve();
  }
  start() {
    this.proc = spawn("bash", [RUNNER, "--daemon", "--invoke", "cli_main", s2Path], {
      cwd: ROOT,
      env: { ...process.env, VIBE_PREOPEN_DIR: ROOT, VIBE_IMPORT_ABI: "raw", ...this.extraEnv },
      stdio: ["pipe", "pipe", "ignore"],
    });
    this.rl = readline.createInterface({ input: this.proc.stdout, crlfDelay: Infinity });
    this.heap = 0;
  }
  kill() {
    if (this.proc) {
      try {
        this.proc.kill("SIGKILL");
      } catch {}
    }
    if (this.rl) this.rl.close();
    this.proc = null;
    this.rl = null;
    this.heap = 0;
  }
  // Serialized: one request in flight per daemon (the protocol is one JSON
  // line in, one out). Returns the parsed response or null (crash/timeout,
  // after which the process has been killed and will restart lazily).
  request(args, timeoutMs) {
    const p = this.chain.then(() => this.#requestNow(args, timeoutMs));
    this.chain = p.then(
      () => {},
      () => {},
    );
    return p;
  }
  #requestNow(args, timeoutMs) {
    if (!this.proc || this.proc.exitCode !== null || this.heap > HEAP_LIMIT) {
      this.kill();
      this.start();
    }
    return new Promise((resolve) => {
      const rl = this.rl;
      const proc = this.proc;
      let done = false;
      const finish = (value, killed) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        rl.off("line", onLine);
        proc.off("close", onClose);
        if (killed) this.kill();
        resolve(value);
      };
      const timer = setTimeout(() => finish(null, true), timeoutMs);
      const onLine = (line) => {
        let resp = null;
        try {
          resp = JSON.parse(line);
        } catch {}
        if (resp && typeof resp.heap_ptr === "number") this.heap = resp.heap_ptr;
        finish(resp, false);
      };
      const onClose = () => finish(null, true);
      rl.once("line", onLine);
      proc.once("close", onClose);
      try {
        proc.stdin.write(`${JSON.stringify({ args })}\n`);
      } catch {
        finish(null, true);
      }
    });
  }
}

async function compileAndStore(daemon, planDaemon, f) {
  const pk = pathKey(f);
  const outTmp = path.join(OUT, `${pk}.batch.${process.pid}.tmp.wasm`);
  const planTmp = `${outTmp}.plan`;
  const cleanup = () => {
    for (const p of [outTmp, `${outTmp}.diag`, planTmp, `${planTmp}.diag`]) {
      fs.rmSync(p, { force: true });
    }
  };
  // A failed request poisons its daemon for everything after it: a trap
  // leaves the instance's never-freed heap wherever the failure happened, so
  // the NEXT heavy compile's memory.grow fails too and a single failure
  // cascades down the whole remaining queue (observed as 187 instant
  // failures on the first full-battery run). Kill on failure; the next
  // request restarts the daemon lazily from a fresh heap.
  const fail = (stage, detail) => {
    cleanup();
    if (stage.startsWith("plan")) planDaemon.kill();
    else daemon.kill();
    console.error(`[unit-batch] fail(${stage}) ${f}${detail ? `: ${detail}` : ""}`);
    return { ok: false };
  };
  cleanup();
  try {
    const resp = await daemon.request([f, outTmp, "__no_entry__"], COMPILE_TIMEOUT_MS);
    let outOk = false;
    try {
      outOk = fs.statSync(outTmp).size > 0;
    } catch {}
    if (!resp) return fail("compile-crash", "");
    if (resp.exit_code !== 0 || !outOk) {
      return fail("compile", (resp.error || "").slice(0, 120));
    }
    const planResp = await planDaemon.request([f, planTmp, "__no_entry__"], PLAN_TIMEOUT_MS);
    let planText = null;
    try {
      planText = fs.readFileSync(planTmp, "utf8");
    } catch {}
    if (!planResp || planResp.exit_code !== 0 || planText === null) {
      return fail("plan", planResp ? (planResp.error || "").slice(0, 120) : "crash");
    }
    const deps = new Set([f]);
    for (const line of planText.split("\n")) {
      const cols = line.split("\t");
      if (cols[0] === "module" && cols.length >= 4 && cols[3]) deps.add(cols[3]);
    }
    const depLines = [...deps].sort(); // ASCII paths: JS sort == LC_ALL=C sort
    const key = keyFromDeps(depLines);
    if (key === null) return fail("key", "dep unreadable");
    const depf = path.join(OUT, `${pk}.deps`);
    fs.writeFileSync(`${depf}.tmp.${process.pid}`, `${depLines.join("\n")}\n`);
    fs.renameSync(`${depf}.tmp.${process.pid}`, depf);
    const keyedRe = new RegExp(`^${pk.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\..*\\.wasm$`);
    for (const e of fs.readdirSync(OUT)) {
      if (keyedRe.test(e) && !e.includes(".batch.")) fs.rmSync(path.join(OUT, e), { force: true });
    }
    fs.renameSync(outTmp, path.join(OUT, `${pk}.${key}.wasm`));
    fs.rmSync(`${outTmp}.diag`, { force: true });
    fs.rmSync(planTmp, { force: true });
    return { ok: true, ms: Math.round(resp.elapsed_us / 1000) };
  } catch (err) {
    return fail("store", String(err && err.message ? err.message : err).slice(0, 120));
  }
}

async function main() {
  // Leftover temps from a previous killed run must not rot in the (CI-
  // persisted) cache dir.
  for (const e of fs.readdirSync(OUT)) {
    if (e.includes(".batch.")) fs.rmSync(path.join(OUT, e), { force: true });
  }

  const listed = fs
    .readFileSync(listFile, "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#") && fs.existsSync(path.join(ROOT, l)));

  const weightsPath =
    process.env.VIBE_UNIT_TEST_WEIGHTS || path.join(ROOT, "scripts", "unit_test_weights.tsv");
  const weights = new Map();
  try {
    for (const line of fs.readFileSync(weightsPath, "utf8").split("\n")) {
      if (!line || line.startsWith("#")) continue;
      const [wf, wms] = line.split("\t");
      if (wf) weights.set(wf, Number(wms) || 0);
    }
  } catch {}
  const weightOf = (f) => weights.get(f) ?? 1500;

  const t0 = Date.now();
  const misses = listed.filter((f) => !existingHit(f)).sort((a, b) => weightOf(b) - weightOf(a));
  const nHits = listed.length - misses.length;
  if (misses.length === 0) {
    console.error(`[unit-batch] all ${listed.length} files already cached (${Date.now() - t0}ms)`);
    return;
  }
  console.error(
    `[unit-batch] ${misses.length} of ${listed.length} files to compile (${nHits} cached) with ${JOBS} daemons`,
  );

  const daemons = Array.from({ length: JOBS }, (_, i) => new Daemon(`c${i}`, { VIBE_FS_COMPILE: "1" }));
  const planDaemon = new Daemon("plan", { VIBE_MODULE_PLAN: "1" });

  // Weight >= HEAVY_MS marks the compiler-closure class: their compiles
  // allocate ~1GB of never-freed heap on top of whatever the instance
  // already holds. Two rules keep peak memory bounded (4 daemons at ~2.5GB
  // of wasm memory each starved the whole pool on the first full run):
  //  - recycle a daemon BEFORE a heavy compile unless its heap is low, so a
  //    heavy job always starts near a fresh heap (grow tops out ~1GB, like
  //    a one-shot);
  //  - warmup gate: one MEDIUM heavy file (the lightest of the class, so
  //    the gate is short) compiles alone to populate the shared on-disk
  //    module cache; the other daemons drain the light tail meanwhile and
  //    WAIT rather than start a heavy file cold -- otherwise every daemon
  //    duplicates the closure's cold module compilation at once.
  const HEAVY_MS = 4000;
  const HEAVY_HEAP_FLOOR = 400_000_000;
  let head = 0;
  let tail = misses.length - 1;
  let nOk = 0;
  let nFail = 0;

  let warmupFile = null;
  for (let i = misses.length - 1; i >= 0; i--) {
    if (weightOf(misses[i]) >= HEAVY_MS) {
      warmupFile = misses[i];
      misses.splice(i, 1);
      tail--;
      break;
    }
  }
  let warmupDone = warmupFile === null;
  let warmupResolve = () => {};
  const warmupGate = new Promise((r) => {
    warmupResolve = r;
  });
  if (warmupDone) warmupResolve();

  const runOne = async (daemon, f) => {
    if (weightOf(f) >= HEAVY_MS && daemon.heap > HEAVY_HEAP_FLOOR) daemon.kill();
    const r = await compileAndStore(daemon, planDaemon, f);
    if (r.ok) nOk++;
    else nFail++;
    const done = nOk + nFail;
    if (done % 50 === 0) {
      console.error(`[unit-batch] ${done}/${misses.length + (warmupFile ? 1 : 0)} (${Date.now() - t0}ms)`);
    }
  };

  const worker = async (daemon, isWarmupOwner) => {
    if (isWarmupOwner && warmupFile !== null) {
      await runOne(daemon, warmupFile);
      warmupDone = true;
      warmupResolve();
    }
    for (;;) {
      let f = null;
      if (warmupDone) {
        if (head <= tail) f = misses[head++];
      } else if (head <= tail && weightOf(misses[tail]) < HEAVY_MS) {
        f = misses[tail--];
      } else {
        await warmupGate;
        continue;
      }
      if (f === null) break;
      await runOne(daemon, f);
    }
  };

  await Promise.all(daemons.map((d, i) => worker(d, i === 0)));
  for (const d of daemons) d.kill();
  planDaemon.kill();
  console.error(
    `[unit-batch] compiled ${nOk}/${misses.length} (${nFail} left to the one-shot fallback) in ${Date.now() - t0}ms`,
  );
}

main().catch((err) => {
  console.error(`[unit-batch] fatal: ${err && err.stack ? err.stack : err}`);
  process.exit(1);
});
