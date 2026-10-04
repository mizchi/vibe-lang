// Experimental replay of successful CPU products. Fingerprints remain outputs
// of the real checker; this digest names identical prepared input snapshots.
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseModuleJobProduct } from "./parallel_selfhost_checker.mjs";

const outputs = ["outcome.txt", "env.out", "cache.out", "fingerprint.out"];
const observation = new Set([
  "VIBE_TASKGROUP_TRACE_OUT", "VIBE_INCREMENTAL_TELEMETRY_OUT",
  "VIBE_CHECKER_WORKER_TRACE", "VIBE_CHECKER_WORKER_MEM",
  "VIBE_TASKGROUP_KEEP_JOBS", "VIBE_TASKGROUP_JOB_CACHE",
  "VIBE_WASM_MEMORY_STATS", "VIBE_MEM", "VIBE_MEM_SAMPLE_MS",
]);
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const objectSha = (value) => sha(JSON.stringify(value));

export class TaskGroupJobCache {
  static async create(projectRoot, images) {
    const hashes = await Promise.all(images.map(async (path) => sha(await readFile(path))));
    const environment = Object.entries(process.env).filter(([name]) => !observation.has(name))
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
    const context = objectSha({ version: 1, projectRoot, images: hashes, environment });
    const root = join(resolve(projectRoot, process.env.VIBE_BUILD_CACHE_DIR || ".vibe/build/cache"), "taskgroup-jobs-v1");
    await mkdir(root, { recursive: true });
    return new TaskGroupJobCache(root, images, hashes, context);
  }

  constructor(root, images, hashes, context) {
    Object.assign(this, { root, images, hashes, context });
  }

  inputKey(inputs) {
    // Match the original prepared-file order: manifest, source, then lexical
    // dependency filenames. The numeric occurrence remains part of each name.
    const ordered = [...inputs.slice(0, 2), ...inputs.slice(2).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)];
    const hash = createHash("sha256");
    hash.update(this.context);
    for (const [name, contents] of ordered) {
      // Length framing distinguishes missing/empty files and field boundaries.
      hash.update(JSON.stringify([name, Buffer.byteLength(contents, "utf8")]));
      hash.update(contents, "utf8");
    }
    return hash.digest("hex");
  }

  async lookup(key, module) {
    try {
      const record = JSON.parse(await readFile(join(this.root, `${key}.json`), "utf8"));
      if (record.version !== 1 || record.input !== key || record.context !== this.context ||
          !Array.isArray(record.files) || record.files.length !== outputs.length ||
          record.digest !== objectSha(record.files) || record.files.some((value) => typeof value !== "string")) return null;
      const [outcome, env, cacheProduct, fingerprint] = record.files;
      const product = parseModuleJobProduct(module, { exit_code: 0 }, {
        outcome, env, cacheProduct, computedFingerprint: fingerprint.trim(),
        diagnostic: null, workerDiag: null,
      });
      return product.diagnostic || !product.cacheProduct ? null : product;
    } catch (error) {
      if (error.code === "EACCES" || error.code === "EPERM") throw error;
      // Torn or invalid optional entries require a fresh real check.
      return null;
    }
  }

  async verifyImages() {
    const hashes = await Promise.all(this.images.map(async (path) => sha(await readFile(path))));
    if (JSON.stringify(hashes) !== JSON.stringify(this.hashes)) throw new Error("TaskGroup producer image changed during the build");
  }

  async store(key, dir) {
    const files = await Promise.all(outputs.map((name) => readFile(join(dir, name), "utf8")));
    if (files[0].trim() !== "ok") throw new Error("only successful CPU products may be cached");
    const record = { version: 1, input: key, context: this.context, files, digest: objectSha(files) };
    const target = join(this.root, `${key}.json`);
    const temporary = `${target}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify(record));
      await rename(temporary, target);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
