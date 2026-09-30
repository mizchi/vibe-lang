import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));
const normalize = "lib/@vibe/compiler/normalize";
const sources = readdirSync(path.join(root, normalize), { recursive: true })
  .filter((name) => /\.(vibe|vpkg)$/.test(name))
  .map((name) => `${normalize}/${name}`);

test("normalizer source files stay within 3,000 lines", () => {
  const oversized = sources.flatMap((name) => {
    const text = readFileSync(path.join(root, name), "utf8");
    const lines = text.split("\n").length - Number(text.endsWith("\n"));
    return lines > 3000 ? [`${name}: ${lines} lines`] : [];
  });
  assert.deepEqual(oversized, [], oversized.join("\n"));
});

test("every desugar implementation and contract reaches the compiler bundle", () => {
  const manifest = readFileSync(path.join(root, "lib/@vibe/compiler/compiler_sources_manifest.tsv"), "utf8");
  const registered = new Set(manifest.split("\n").map((row) => row.split("\t")[1]));
  const missing = sources.filter((name) => name.includes("/desugar/") && !name.endsWith("_test.vibe"))
    .map((name) => name.replace("lib/@vibe/compiler/", ""))
    .filter((name) => !registered.has(name));
  assert.deepEqual(missing, [], `Unbundled desugar sources: ${missing.join(", ")}`);
});
