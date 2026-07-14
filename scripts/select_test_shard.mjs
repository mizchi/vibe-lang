#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_WEIGHT = 1000;

export function normalizeRepoPath(file, root) {
  const rel = path.isAbsolute(file) ? path.relative(root, file) : file;
  return rel.split(path.sep).join("/");
}

export function loadWeights(weightsPath) {
  if (!weightsPath || !fs.existsSync(weightsPath)) {
    return {};
  }
  const parsed = JSON.parse(fs.readFileSync(weightsPath, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`weights file must be a JSON object: ${weightsPath}`);
  }
  const weights = {};
  for (const [key, value] of Object.entries(parsed)) {
    const weight = Number(value);
    if (Number.isFinite(weight) && weight >= 0) {
      weights[key.replaceAll("\\", "/")] = weight;
    }
  }
  return weights;
}

export function selectWeightedShard(files, options) {
  const index = Number(options.index);
  const total = Number(options.total);
  if (!Number.isInteger(index) || index < 0) {
    throw new Error(`invalid shard index: ${options.index}`);
  }
  if (!Number.isInteger(total) || total <= 0) {
    throw new Error(`invalid shard total: ${options.total}`);
  }
  if (index >= total) {
    throw new Error(`shard index must be less than total: ${index}/${total}`);
  }

  const root = options.root || process.cwd();
  const weights = options.weights || {};
  const items = files.map((file, originalIndex) => {
    const key = normalizeRepoPath(file, root);
    const weight = Number(weights[key] ?? weights[file] ?? DEFAULT_WEIGHT);
    return {
      file,
      key,
      originalIndex,
      weight: Number.isFinite(weight) && weight >= 0 ? weight : DEFAULT_WEIGHT,
    };
  });

  const bins = Array.from({ length: total }, (_, shardIndex) => ({
    shardIndex,
    weight: 0,
    items: [],
  }));

  for (const item of [...items].sort(
    (a, b) => b.weight - a.weight || a.key.localeCompare(b.key) || a.originalIndex - b.originalIndex,
  )) {
    let target = bins[0];
    for (const bin of bins.slice(1)) {
      if (bin.weight < target.weight || (bin.weight === target.weight && bin.shardIndex < target.shardIndex)) {
        target = bin;
      }
    }
    target.weight += item.weight;
    target.items.push(item);
  }

  return bins[index].items
    .sort((a, b) => a.originalIndex - b.originalIndex)
    .map((item) => item.file);
}

export function parseArgs(argv) {
  const options = {
    index: null,
    total: null,
    root: process.cwd(),
    weightsPath: "",
    files: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--") {
      options.files = argv.slice(i + 1);
      break;
    }
    if (arg === "--index") {
      options.index = argv[++i];
    } else if (arg === "--total") {
      options.total = argv[++i];
    } else if (arg === "--root") {
      options.root = argv[++i];
    } else if (arg === "--weights") {
      options.weightsPath = argv[++i];
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (options.index === null) {
    throw new Error("missing --index");
  }
  if (options.total === null) {
    throw new Error("missing --total");
  }
  return options;
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const selected = selectWeightedShard(options.files, {
    index: options.index,
    total: options.total,
    root: options.root,
    weights: loadWeights(options.weightsPath),
  });
  process.stdout.write(selected.join("\n"));
  if (selected.length > 0) {
    process.stdout.write("\n");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
