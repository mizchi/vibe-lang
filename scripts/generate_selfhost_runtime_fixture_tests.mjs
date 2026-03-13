#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const FIXTURE_DIR = path.join(ROOT, "fixtures");
const OUT_DIR = path.join(ROOT, "vibe/compiler/_generated_selfhost_runtime_fixtures");
const SHARD_SIZE = Number(process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_SHARD_SIZE || "20");
const LIMIT = Number(process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_LIMIT || "0");
const PATHS_RAW = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS || "";
const PATHS_FILE = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE || "";
const LIST_ONLY = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY === "1";

const emptySpec = () => ({
  last: undefined,
  effects: undefined,
  error_contains: undefined,
  todo: false,
  skip: false,
  version_refs: {},
  symbol_refs: {},
});

function splitFixture(source, filePath) {
  const marker = "\n__DATA__\n";
  const idx = source.indexOf(marker);
  if (idx < 0) {
    throw new Error(`[${filePath}] missing __DATA__ section`);
  }
  return {
    script: source.slice(0, idx + 1),
    data: source.slice(idx + marker.length),
  };
}

function stripFixtureDataIfPresent(source) {
  const marker = "\n__DATA__\n";
  const idx = source.indexOf(marker);
  return idx < 0 ? source : source.slice(0, idx + 1);
}

function parseSpec(data) {
  const raw = JSON.parse(data);
  return {
    last: raw.last,
    effects: raw.effects,
    error_contains: raw.error_contains ?? raw.compile_error,
    todo: Boolean(raw.todo || raw.TODO),
    skip: Boolean(raw.skip),
    version_refs: raw.version_refs || {},
    symbol_refs: raw.symbol_refs || {},
  };
}

function fileExists(relPath) {
  return fs.existsSync(path.join(ROOT, relPath));
}

function normalizeCandidate(relPath) {
  let normalized = relPath.replaceAll("\\", "/");
  if (normalized.startsWith("./")) normalized = normalized.slice(2);
  normalized = normalized.replaceAll("/./", "/");
  return normalized;
}

function resolveFsPath(currentPath, rawPath) {
  const currentDir = path.posix.dirname(currentPath);
  const candidates = [];
  const rawNormalized = normalizeCandidate(rawPath);
  candidates.push(rawNormalized);
  if (!rawNormalized.endsWith(".vibe")) {
    candidates.push(`${rawNormalized}.vibe`);
    candidates.push(`${rawNormalized}/index.vibe`);
  }
  const resolved = normalizeCandidate(path.posix.join(currentDir, rawPath));
  candidates.push(resolved);
  if (!resolved.endsWith(".vibe")) {
    candidates.push(`${resolved}.vibe`);
    candidates.push(`${resolved}/index.vibe`);
  }
  if (rawPath.startsWith("./")) {
    const rootRaw = normalizeCandidate(rawPath.slice(2));
    candidates.push(rootRaw);
    if (!rootRaw.endsWith(".vibe")) {
      candidates.push(`${rootRaw}.vibe`);
      candidates.push(`${rootRaw}/index.vibe`);
    }
  }
  for (const candidate of candidates) {
    if (fileExists(candidate)) return candidate;
  }
  throw new Error(`unresolved import target: ${rawPath} from ${currentPath}`);
}

function resolveImportPath(currentPath, rawPath, spec) {
  if (rawPath.startsWith("version@")) {
    const key = rawPath.slice("version@".length);
    const target = spec.version_refs[key];
    if (!target) throw new Error(`missing version ref: ${key}`);
    return resolveFsPath(currentPath, target);
  }
  if (rawPath.startsWith("symbol@")) {
    const key = rawPath.slice("symbol@".length);
    const target = spec.symbol_refs[key];
    if (!target) throw new Error(`missing symbol ref: ${key}`);
    return resolveFsPath(currentPath, target);
  }
  if (rawPath.startsWith("./fixtures/") || rawPath.startsWith("./vibe/")) {
    return normalizeCandidate(rawPath);
  }
  return resolveFsPath(currentPath, rawPath);
}

function rewriteSource(currentPath, source, spec) {
  return source
    .split("\n")
    .map((line) => {
      const match = line.match(/^(\s*import\s+)([^ \t{]+)(.*)$/);
      if (!match) return line;
      const [, prefix, rawPath, suffix] = match;
      const resolved = resolveImportPath(currentPath, rawPath, spec);
      return `${prefix}${resolved}${suffix}`;
    })
    .join("\n");
}

function collectImportPaths(source) {
  const paths = [];
  for (const line of source.split("\n")) {
    const match = line.match(/^\s*import\s+([^ \t{]+)(.*)$/);
    if (!match) continue;
    paths.push(match[1]);
  }
  return paths;
}

function loadSources(entryPath, spec) {
  const loaded = new Map();
  const visit = (currentPath, currentSpec) => {
    if (loaded.has(currentPath)) return;
    const source = fs.readFileSync(path.join(ROOT, currentPath), "utf8");
    const stripped = stripFixtureDataIfPresent(source);
    const rewritten = rewriteSource(currentPath, stripped, currentSpec);
    loaded.set(currentPath, rewritten);
    for (const rawImport of collectImportPaths(rewritten)) {
      const depPath = resolveImportPath(currentPath, rawImport, emptySpec());
      visit(depPath, emptySpec());
    }
  };
  visit(entryPath, spec);
  return [...loaded.entries()];
}

function escapeVibeString(value) {
  return JSON.stringify(value);
}

function selectedFixturePaths() {
  const values = [];
  for (const raw of PATHS_RAW.split(",")) {
    const trimmed = raw.trim();
    if (trimmed) values.push(trimmed);
  }
  if (PATHS_FILE) {
    for (const raw of fs.readFileSync(PATHS_FILE, "utf8").split("\n")) {
      const trimmed = raw.trim();
      if (trimmed) values.push(trimmed);
    }
  }
  if (values.length === 0) return null;
  return new Set(values);
}

function vibeEffectsLiteral(effects) {
  if (!effects) return "None";
  return `Some([\n${effects.map((item) => `    ${escapeVibeString(item)}`).join(",\n")}\n  ])`;
}

function generateShard(shardIndex, cases) {
  const lines = [];
  lines.push("// Generated by scripts/generate_selfhost_runtime_fixture_tests.mjs");
  lines.push("");
  lines.push("import ../fixture_preloaded_test_support.vibe {");
  lines.push("  assert_preloaded_fixture_success");
  lines.push("}");
  lines.push("");
  for (const item of cases) {
    lines.push(`test ${escapeVibeString(`generated fixture: ${item.path}`)} {`);
    lines.push(`  let path = ${escapeVibeString(item.path)}`);
    lines.push(`  let main_source = ${escapeVibeString(item.mainSource)}`);
    lines.push("  let sources = [");
    for (const [sourcePath, sourceText] of item.sources) {
      lines.push(`    (${escapeVibeString(sourcePath)}, ${escapeVibeString(sourceText)}),`);
    }
    lines.push("  ]");
    lines.push(
      `  assert_preloaded_fixture_success(path, main_source, sources, ${escapeVibeString(item.spec.last)}, ${vibeEffectsLiteral(item.spec.effects)})`,
    );
    lines.push("}");
    lines.push("");
  }
  const fileName = `runtime_fixture_success_${String(shardIndex + 1).padStart(2, "0")}_test.vibe`;
  const filePath = path.join(OUT_DIR, fileName);
  fs.writeFileSync(filePath, `${lines.join("\n")}\n`);
  return filePath;
}

function main() {
  const selected = selectedFixturePaths();
  let listed = 0;
  fs.mkdirSync(OUT_DIR, { recursive: true });
  for (const name of fs.readdirSync(OUT_DIR)) {
    if (name.endsWith("_test.vibe")) {
      fs.rmSync(path.join(OUT_DIR, name), { force: true });
    }
  }
  const fixtureNames = fs.readdirSync(FIXTURE_DIR).filter((name) => name.endsWith(".vibe")).sort();
  const cases = [];
  for (const name of fixtureNames) {
    const relPath = `fixtures/${name}`;
    if (selected && !selected.has(relPath)) continue;
    const source = fs.readFileSync(path.join(ROOT, relPath), "utf8");
    const { script, data } = splitFixture(source, relPath);
    const spec = parseSpec(data);
    if (spec.skip || spec.todo || name.includes("http_p3_")) continue;
    if (spec.last === undefined || spec.error_contains !== undefined) continue;
    if (LIST_ONLY) {
      console.log(relPath);
      listed += 1;
      if (LIMIT > 0 && listed >= LIMIT) break;
      continue;
    }
    const sources = loadSources(relPath, spec);
    const main = sources.find(([p]) => p === relPath);
    if (!main) throw new Error(`missing main source: ${relPath}`);
    cases.push({
      path: relPath,
      mainSource: main[1],
      sources,
      spec,
    });
    if (LIMIT > 0 && cases.length >= LIMIT) break;
  }
  const shards = [];
  for (let i = 0; i < cases.length; i += SHARD_SIZE) {
    shards.push(generateShard(shards.length, cases.slice(i, i + SHARD_SIZE)));
  }
  for (const shard of shards) {
    console.log(path.relative(ROOT, shard));
  }
}

main();
