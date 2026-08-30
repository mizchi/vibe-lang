// Parse every corpus case with a tree-sitter wasm grammar and compare the
// result against the tree the corpus records.
//
// This is what ties a wasm artifact to the grammar it claims to implement.
// Hashes cannot: a stamp is rewritable, so a contributor who regenerates only
// src/parser.c and then restamps produces a manifest where everything agrees
// and the wasm is still stale (#2422 review). Behaviour is not rewritable --
// a wasm built before a grammar change parses the new corpus case wrongly, and
// that is exactly the #2409 failure (`~5` yielding `(ERROR)`).
//
// Usage: node wasm_corpus_check.mjs <corpus-dir> <wasm> [<wasm> ...]
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

const [corpusDir, ...wasmPaths] = process.argv.slice(2);
if (!corpusDir || wasmPaths.length === 0) {
  console.error("usage: wasm_corpus_check.mjs <corpus-dir> <wasm> [<wasm> ...]");
  process.exit(2);
}

// Resolved from wherever the caller staged web-tree-sitter, so this file makes
// no assumption about node_modules layout.
const require = createRequire(process.env.VIBE_WTS_REQUIRE_BASE ?? import.meta.url);
const { Parser, Language } = require("web-tree-sitter");

// Corpus format: a `===` fence around the case name, the source, a `---` rule,
// then the expected s-expression.
function parseCorpus(text) {
  const cases = [];
  const lines = text.split("\n");
  const isFence = (l) => /^={3,}$/.test(l.trim());
  const isRule = (l) => /^-{3,}$/.test(l.trim());
  let i = 0;
  while (i < lines.length) {
    if (!isFence(lines[i])) { i++; continue; }
    const name = (lines[i + 1] ?? "").trim();
    if (!isFence(lines[i + 2] ?? "")) { i++; continue; }
    i += 3;
    const src = [];
    while (i < lines.length && !isRule(lines[i])) { src.push(lines[i]); i++; }
    i++; // the rule
    const want = [];
    while (i < lines.length && !isFence(lines[i])) { want.push(lines[i]); i++; }
    cases.push({ name, source: src.join("\n").replace(/^\n+|\n+$/g, "") + "\n", expected: want.join("\n") });
  }
  return cases;
}

// The corpus pretty-prints its trees across lines; toString() emits one line.
// Collapsing whitespace is the only normalization -- node names, field labels
// and nesting all still have to match exactly.
const normalize = (s) => s.replace(/\s+/g, " ").replace(/\( /g, "(").replace(/ \)/g, ")").trim();

const files = readdirSync(corpusDir).filter((f) => f.endsWith(".txt")).sort();
if (files.length === 0) {
  console.error(`[wasm-corpus] FAIL: no corpus files in ${corpusDir}`);
  process.exit(1);
}

let failures = 0;
let checked = 0;

await Parser.init();

for (const wasmPath of wasmPaths) {
  let lang;
  try {
    lang = await Language.load(readFileSync(wasmPath));
  } catch (e) {
    // A wasm that will not load is the sharpest form of "stale": the committed
    // Zed artifact wanted a `libc.so` side module and failed exactly here.
    console.error(`[wasm-corpus] FAIL: ${wasmPath} does not load: ${e.message}`);
    failures++;
    continue;
  }
  const parser = new Parser();
  parser.setLanguage(lang);

  for (const file of files) {
    for (const c of parseCorpus(readFileSync(join(corpusDir, file), "utf8"))) {
      const got = normalize(parser.parse(c.source).rootNode.toString());
      const want = normalize(c.expected);
      checked++;
      if (got !== want) {
        failures++;
        console.error(`[wasm-corpus] FAIL: ${wasmPath} :: ${file} :: ${c.name}`);
        console.error(`  expected: ${want}`);
        console.error(`  actual:   ${got}`);
      }
    }
  }
}

// A run that compared nothing passes every comparison it makes. Silence is
// "unchecked", not "safe" (#2248).
if (checked === 0) {
  console.error("[wasm-corpus] FAIL: no cases were compared");
  process.exit(1);
}
if (failures > 0) {
  console.error(`[wasm-corpus] FAIL: ${failures} mismatch(es) over ${checked} comparison(s)`);
  process.exit(1);
}
console.log(`[wasm-corpus] ok: ${checked} comparisons across ${wasmPaths.length} wasm artifact(s)`);
