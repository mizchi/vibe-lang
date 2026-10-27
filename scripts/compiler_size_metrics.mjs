#!/usr/bin/env node
// Source-bound compiler geometry; names are an optional diagnostic companion.
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { dirname, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const scripts = dirname(fileURLToPath(import.meta.url));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const checksum = (value, label) => {
  if (!/^[0-9a-f]{64}$/.test(value || "")) throw new Error(`${label} checksum is missing; rebuild the generation`);
  return value;
};

export function withoutNames(bytes) {
  if (!bytes.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
    throw new Error("expected a core Wasm version-1 module");
  }
  let at = 8;
  const output = [bytes.subarray(0, 8)];
  const u32 = (limit) => {
    let value = 0, shift = 0, byte;
    do {
      if (at >= limit || shift >= 35) throw new Error("truncated or oversized section length");
      byte = bytes[at++]; value += (byte & 127) * 2 ** shift; shift += 7;
    } while (byte & 128);
    if (value > 0xffffffff) throw new Error("oversized section length");
    return value;
  };
  while (at < bytes.length) {
    const start = at;
    const kind = bytes[at++];
    const size = u32(bytes.length);
    const end = at + size;
    if (end > bytes.length) throw new Error("truncated Wasm section");
    let name = null;
    if (kind === 0) {
      const length = u32(end);
      if (at + length > end) throw new Error("truncated custom-section name");
      name = bytes.subarray(at, at + length).toString("utf8");
    }
    if (name !== "name") output.push(bytes.subarray(start, end));
    at = end;
  }
  return Buffer.concat(output);
}

function tool(name, bytes) {
  // Analyze the exact bytes whose hash was checked, even if a caller later
  // replaces its artifact path while another generation is being built.
  const directory = mkdtempSync(resolve(tmpdir(), "vibe-compiler-geometry-"));
  try {
    const snapshot = resolve(directory, "image.wasm");
    writeFileSync(snapshot, bytes);
    return JSON.parse(execFileSync(process.execPath, [resolve(scripts, name), "--json", snapshot], {
      encoding: "utf8", maxBuffer: 32 * 1024 * 1024, timeout: 30000,
    }));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function sourceGroups(functions, manifestPath, root) {
  const manifest = readFileSync(manifestPath);
  const paths = new Map();
  for (const line of manifest.toString("utf8").split(/\r?\n/)) {
    if (!line || line.startsWith("#")) continue;
    const fields = line.replaceAll("\\t", "\t").split("\t");
    if (fields.length !== 2 || !fields[1].endsWith(".vibe")) continue;
    const path = relative(root, resolve(dirname(manifestPath), fields[1])).replaceAll("\\", "/");
    if (path.startsWith("../") || path.startsWith("/")) continue;
    const tag = path.replace(/[^A-Za-z0-9_]/g, "_");
    const candidates = paths.get(tag) || new Set();
    candidates.add(path); paths.set(tag, candidates);
  }
  const groups = new Map();
  let attributed = 0;
  for (const fn of functions) {
    const match = /(?:_dep_|_exp_)(.+_vibe)(?:__.*)?$/.exec(fn.name);
    const candidates = match && paths.get(match[1]);
    const path = candidates?.size === 1 ? [...candidates][0] : null;
    if (path) attributed++;
    const key = path || (fn.name.startsWith("__rt_") ? "<runtime-generated>" : "<unmapped>");
    const group = groups.get(key) || { source: key, functions: 0, body_bytes: 0 };
    group.functions++; group.body_bytes += fn.size; groups.set(key, group);
  }
  return {
    source_manifest_sha256: hash(manifest), source_attributed_functions: attributed,
    // Ambiguous/absent paths retain their bytes in an explicit residual group.
    groups: [...groups.values()].sort((a, b) => b.body_bytes - a.body_bytes || (a.source < b.source ? -1 : a.source > b.source ? 1 : 0)),
  };
}

export function collectCompilerSize(options) {
  const root = resolve(options.root || resolve(scripts, ".."));
  const stage2 = resolve(options.stage2);
  const generation = resolve(options.generation || resolve(dirname(stage2), "generation.json"));
  const expectedSource = resolve(options.source || resolve(root, "lib/@vibe/compiler/_cli_adapter_module_source.vibe"));
  const receiptBytes = readFileSync(generation);
  const receipt = JSON.parse(receiptBytes);
  if (receipt.schema !== 1 || receipt.policy !== "rust-style-stage0-stage1-stage2") {
    throw new Error("unsupported generation receipt");
  }
  if (typeof receipt.source?.entry !== "string" || typeof receipt.source.commit !== "string"
      || typeof receipt.source.dirty !== "boolean") throw new Error("generation source identity is missing");
  const bytes = readFileSync(stage2);
  const artifactHash = hash(bytes);
  if (artifactHash !== checksum(receipt.stages?.stage2?.sha256, "stage2")
      || bytes.length !== receipt.stages.stage2.size) throw new Error("stage2 does not match its generation receipt");
  const sourceHash = checksum(receipt.source.entry_sha256, "generation input");
  const capturedSource = resolve(root, receipt.source.entry);
  if (hash(readFileSync(capturedSource)) !== sourceHash) throw new Error("captured generation input checksum mismatch");
  if (hash(readFileSync(expectedSource)) !== sourceHash) throw new Error("generation input does not match the requested source snapshot");
  const stripped = withoutNames(bytes);
  const sections = tool("wasm_section_sizes.mjs", bytes)[0];
  if (!sections.funcs || !sections.sections.code) throw new Error("stage2 contains no defined compiler functions");
  const result = {
    schema: 1,
    artifact_sha256: artifactHash, artifact_bytes: bytes.length,
    stripped_sha256: hash(stripped), stripped_bytes: stripped.length,
    generation_sha256: hash(receiptBytes),
    source: { commit: receipt.source.commit, build_tree_dirty: receipt.source.dirty,
      entry: receipt.source.entry, entry_sha256: sourceHash,
      seed_sha256: checksum(receipt.seed?.artifact?.sha256, "generation seed") },
    // Payload includes vector/body-length framing; body_bytes excludes it.
    code_section_bytes: sections.sections.code || 0,
    function_body_bytes: sections.codeBytes, defined_functions: sections.funcs,
    small_functions: sections.stubs,
    attribution: { status: "unavailable", reason: "no named companion supplied" },
  };
  if (options.named) {
    const named = resolve(options.named);
    const namedBytes = readFileSync(named);
    if (!withoutNames(namedBytes).equals(stripped)) throw new Error("named companion differs outside name sections");
    const data = tool("wasm_func_sizes.mjs", namedBytes);
    if (!data.namedFunctions || data.namedFunctions !== data.functions.length) {
      throw new Error("named companion must name every defined function");
    }
    if (data.functions.length !== result.defined_functions || data.codeBytes !== result.function_body_bytes
        || data.codeSectionBytes !== result.code_section_bytes) throw new Error("size tools disagree on compiler geometry");
    const rollup = sourceGroups(data.functions,
      resolve(options.sourceManifest || resolve(root, "lib/@vibe/compiler/compiler_sources_manifest.tsv")), root);
    result.attribution = { status: "available", artifact_sha256: hash(namedBytes),
      named_functions: data.namedFunctions, ...rollup,
      top_functions: data.functions.slice(0, 20).map((fn) => ({ index: fn.idx, body_bytes: fn.size, name: fn.name })) };
  }
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (!args[0] || args[0].startsWith("--")) throw new Error("usage: compiler_size_metrics.mjs <stage2.wasm> [--generation FILE] [--source FILE] [--named FILE] [--root DIR] [--source-manifest FILE]");
    const options = { stage2: args.shift() };
    const keys = { "--generation": "generation", "--source": "source", "--named": "named", "--root": "root", "--source-manifest": "sourceManifest" };
    while (args.length) {
      const flag = args.shift();
      if (!keys[flag] || !args.length || args[0].startsWith("--")) throw new Error(`invalid size-metric argument: ${flag}`);
      options[keys[flag]] = args.shift();
    }
    console.log(JSON.stringify(collectCompilerSize(options), null, 2));
  } catch (error) {
    console.error(`compiler-size: ${error.message}`);
    process.exitCode = 1;
  }
}
