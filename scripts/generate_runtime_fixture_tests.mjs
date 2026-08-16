#!/usr/bin/env node

// Generates runtime fixture test files for the vibe compiler.
//
// Mode 1 – list candidates:
//   VIBE_RUNTIME_FIXTURE_LIST_ONLY=1 node scripts/generate_runtime_fixture_tests.mjs
//   Prints one fixture path per line to stdout.
//
// Mode 2 – generate test files:
//   VIBE_RUNTIME_FIXTURE_PATHS_FILE=paths.txt \
//   VIBE_RUNTIME_FIXTURE_SHARD_SIZE=10 \
//   node scripts/generate_runtime_fixture_tests.mjs
//   Creates .vibe test files in the generated directory and prints their paths
//   to stdout.

import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const ROOT = process.cwd();
const GENERATED_DIR = path.resolve(
  ROOT,
  process.env.VIBE_RUNTIME_FIXTURE_OUTPUT_DIR ||
    "lib/@vibe/compiler/_generated_runtime_fixtures",
);
const DEBT_FILE = path.join(ROOT, "scripts/runtime_fixture_debt.tsv");

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

/** Find an exact __DATA__ marker line, independently of parsing its payload. */
function fixtureDataMarker(content) {
  const match = /^__DATA__[ \t]*\r?$/m.exec(content);
  if (match === null) return null;
  return { start: match.index, end: match.index + match[0].length };
}

/** Parse the __DATA__ JSON from a fixture file. Malformed payloads are fatal. */
function parseFixtureData(content, filePath) {
  const marker = fixtureDataMarker(content);
  if (marker === null) return null;
  const dataStr = content.substring(marker.end).trim();
  try {
    return JSON.parse(dataStr);
  } catch (error) {
    throw new Error(
      `${filePath}: __DATA__ marker must be followed by valid JSON: ${error.message}`,
    );
  }
}

/** Return the source portion of a fixture (before __DATA__). */
function fixtureSource(content) {
  const marker = fixtureDataMarker(content);
  if (marker === null) return content;
  return content.substring(0, marker.start).trimEnd();
}

function splitTopLevelChunks(source) {
  const lines = source.split("\n");
  const chunks = [];
  let current = [];
  let depth = 0;
  let inString = false;
  let stringQuote = "";
  let escape = false;

  function pushCurrent() {
    const text = current.join("\n").trim();
    if (text) chunks.push(text);
    current = [];
  }

  function updateDepth(line) {
    for (let i = 0; i < line.length; i += 1) {
      const ch = line[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (inString) {
        if (ch === "\\") {
          escape = true;
        } else if (ch === stringQuote) {
          inString = false;
          stringQuote = "";
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        inString = true;
        stringQuote = ch;
        continue;
      }
      if (ch === "/" && i + 1 < line.length && line[i + 1] === "/") {
        break;
      }
      if (ch === "{" || ch === "(" || ch === "[") {
        depth += 1;
      } else if (ch === "}" || ch === ")" || ch === "]") {
        depth -= 1;
      }
    }
  }

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed && depth === 0 && current.length > 0) {
      pushCurrent();
    }
    current.push(line);
    updateDepth(line);
  }
  pushCurrent();
  return chunks;
}

// Chunks that must be HOISTED above the generated `test` block, because vibe
// only accepts them at the top level.
//
// `enum`, `struct`, `type`, `impl`, `trait` and `module` used to be classified
// as declaration chunks, i.e. left inside the block. They do not compile there:
// a block-local `enum` is rejected outright ("move `Color` to the top level",
// #1525) and `trait` does not even parse. `effect` was in neither list, so it
// fell to the expression wrapper and came out as `let _ = ( effect Console {`.
//
// The split is about WHERE a form is legal, so the test for it is the same
// question: can this appear inside a block? Only bindings can.
// A relative import is resolved against the directory of the file that WRITES
// it (measured: the compiler reports `cannot resolve import './lib/x' (resolved
// to <dir-of-importer>/lib/x)`). The generated file lives under
// lib/@vibe/compiler/_generated_runtime_fixtures/, not next to the fixture, so
// a path copied through verbatim points somewhere that does not exist.
//
// Rewriting needs to know what the path was relative TO, and the fixtures do
// not agree: some mean "next to me" and some mean "from the repo root" (every
// `./lib/...` and `./fixtures/...` in the corpus is the latter, and those do
// not resolve from fixtures/ either -- they are broken where they sit). So
// rather than pick one reading, try the fixture's own directory first, since
// that is what the language says, and fall back to the repo root. Whichever
// names a file that EXISTS is the one that was meant.
//
// If neither exists the line is left exactly as it was: the fixture is wrong in
// a way this script cannot repair, and rewriting it would only move the error
// somewhere less informative.
// `__DATA__`'s `last` is what the program PRINTED, and the printer used a debug
// rendering: a String value came out with surrounding quotes (`{"last":
// "\"ok\""}` for the value `ok`), while an Int came out bare (`{"last": "42"}`).
// `__to_string` is the display rendering, which does not quote -- measured:
// `__to_string("ok") == "ok"` holds and `== "\"ok\""` fails.
//
// The original printer cannot be re-run to settle this by experiment: it
// printed the value of a TOP-LEVEL expression, and ADR-0069 removed those, which
// is the same reason these fixtures no longer compile as written. So the two
// renderings are reconciled by reading the declaration instead. A `last` wrapped
// in quotes states unambiguously that the value is that String, which is what
// __to_string returns unquoted; anything else is already the display form.
//
// This is why the comparison is on __to_string and not on raw stdout: it is the
// renderer that still exists.
function displayForm(expectedLast) {
  if (
    expectedLast.length >= 2 &&
    expectedLast.startsWith('"') &&
    expectedLast.endsWith('"')
  ) {
    try {
      return JSON.parse(expectedLast);
    } catch {
      return expectedLast;
    }
  }
  return expectedLast;
}

/** Render a JS string as a vibe string literal. */
function vibeStringLiteral(s) {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

function rewriteRelativeImports(chunk, fixturePath) {
  const fixtureDir = path.dirname(path.join(ROOT, fixturePath));
  return chunk.replace(
    /^(\s*import\s+)(\.\.?\/[^\s{]+)/gm,
    (whole, head, spec) => {
      const candidates = [
        path.resolve(fixtureDir, spec),
        path.resolve(ROOT, spec),
      ];
      const target = candidates.find(
        (p) => fs.existsSync(p) || fs.existsSync(p + ".vibe"),
      );
      if (!target) {
        return whole;
      }
      let rel = path.relative(GENERATED_DIR, target);
      if (!rel.startsWith(".")) {
        rel = "./" + rel;
      }
      return head + rel;
    },
  );
}

function isPreludeChunk(chunk) {
  const trimmed = chunk.trimStart();
  return [
    "import ",
    "export ",
    "use ",
    "declare ",
    "enum ",
    "struct ",
    "type ",
    "impl ",
    "trait ",
    "effect ",
    "module ",
  ].some((kw) => trimmed.startsWith(kw));
}

// Chunks that are legal inside the block and are NOT expressions, so they are
// emitted as-is rather than wrapped in `let _ = ( ... )`.
function isDeclarationChunk(chunk) {
  const trimmed = chunk.trimStart();
  return trimmed.startsWith("let ") || trimmed.startsWith("let rec ");
}

// A fixture may end in a binding rather than a bare expression. The old
// top-level evaluator still reported the value of that binding, so preserving
// the declaration without reading it only proves that the fixture runs; it
// does not prove its `__DATA__.last` expectation. Keep this deliberately
// narrow: simple identifier bindings are safe to read after the declaration.
// Anything more involved must be classified as debt instead of being silently
// activated without an assertion.
function simpleBindingName(chunk) {
  const match = chunk
    .trimStart()
    .match(/^let\s+(?:rec\s+)?(?:mut\s+)?([a-z_][A-Za-z0-9_]*)\b/);
  return match?.[1] ?? null;
}

// A chunk with no code in it. Wrapping one as an expression produced
// `let _ = (\n// Basic effect declaration\n)`, which is a parse error -- the
// comment is the whole chunk, so there is nothing for the parens to hold.
function isCommentOnlyChunk(chunk) {
  return chunk
    .split("\n")
    .every((line) => line.trim() === "" || line.trim().startsWith("//"));
}

/**
 * A fixture is a runtime candidate when:
 *  - It has __DATA__ with a "last" key (expected runtime result)
 *  - It does NOT have "compile_error" or "error_contains"
 */
function isRuntimeCandidate(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, "utf8");
  } catch {
    return false;
  }
  const data = parseFixtureData(content, path.relative(ROOT, filePath));
  if (!data || typeof data !== "object") return false;
  if (!("last" in data)) return false;
  if (typeof data.last !== "string") {
    throw new Error(
      `${path.relative(ROOT, filePath)}: __DATA__.last must be a string`,
    );
  }
  if ("compile_error" in data || "error_contains" in data) return false;

  return true;
}

function discoverCandidates() {
  const fixturesDir = path.join(ROOT, "fixtures");
  const results = [];
  function visit(dir) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const absPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        visit(absPath);
      } else if (entry.isFile() && entry.name.endsWith(".vibe")) {
        // isRuntimeCandidate also audits any __DATA__ marker it encounters.
        // A malformed payload must fail discovery even when it would not have
        // contained a runtime `last` expectation.
        if (isRuntimeCandidate(absPath)) {
          results.push(path.relative(ROOT, absPath));
        }
      }
    }
  }
  if (fs.existsSync(fixturesDir)) visit(fixturesDir);
  results.sort();
  return results;
}

function readDebtPaths(allCandidates) {
  if (!fs.existsSync(DEBT_FILE)) return new Set();
  const candidates = new Set(allCandidates);
  const debts = new Set();
  const lines = fs.readFileSync(DEBT_FILE, "utf8").split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!line.trim() || line.trimStart().startsWith("#")) continue;
    const tab = line.indexOf("\t");
    if (tab < 0 || !line.substring(tab + 1).trim()) {
      throw new Error(
        `${path.relative(ROOT, DEBT_FILE)}:${i + 1}: expected <fixture>\\t<reason>`,
      );
    }
    const fixturePath = line.substring(0, tab).trim();
    if (debts.has(fixturePath)) {
      throw new Error(
        `${path.relative(ROOT, DEBT_FILE)}:${i + 1}: duplicate fixture ${fixturePath}`,
      );
    }
    if (!candidates.has(fixturePath)) {
      throw new Error(
        `${path.relative(ROOT, DEBT_FILE)}:${i + 1}: stale debt entry ${fixturePath}`,
      );
    }
    debts.add(fixturePath);
  }
  return debts;
}

// ---------------------------------------------------------------------------
// Test file generation
// ---------------------------------------------------------------------------

/**
 * Build a .vibe test file for a single fixture.
 *
 * The fixture source (everything before __DATA__) is placed at the top level
 * of the generated file, followed by a test block that verifies compilation
 * and execution succeeded.
 *
 * The selfhost `vibe test --backend compiled` command treats non-test
 * statements as prelude (included in each test case's compiled WASM module),
 * so the fixture code is compiled and evaluated as part of the test.
 */
function buildSingleFixtureTestContent(fixturePath) {
  const absPath = path.join(ROOT, fixturePath);
  let content;
  try {
    content = fs.readFileSync(absPath, "utf8");
  } catch {
    return `test "generated fixture: ${fixturePath}" {\n  assert(false)\n}\n`;
  }

  const source = fixtureSource(content);
  const data = parseFixtureData(content, fixturePath);
  const expectedLast = data?.last ?? null;
  const chunks = splitTopLevelChunks(source);
  const preludeChunks = [];
  const bodyChunks = [];
  for (const chunk of chunks) {
    if (isPreludeChunk(chunk)) {
      preludeChunks.push(chunk);
    } else if (isCommentOnlyChunk(chunk)) {
      preludeChunks.push(chunk);
    } else if (isDeclarationChunk(chunk)) {
      bodyChunks.push({ kind: "decl", text: chunk });
    } else {
      bodyChunks.push({ kind: "expr", text: chunk });
    }
  }

  // The fixture's `__DATA__` declares what the program PRINTS -- the rendered
  // value of its last expression (see the EXCLUDE_PATTERNS note in
  // scripts/unit_test_runner.sh: the gate "diffs the real program's stdout
  // against the JSON's last field"). Every expression chunk used to be wrapped
  // in `let _ = (...)`, including the final one, so the declared value was read
  // out of the JSON and then never compared to anything. A generated test
  // passed when the fixture COMPILED AND RAN, whatever it computed -- a fixture
  // declaring "ok" and returning "ng" was green.
  //
  // Only the last body chunk is the program's value; earlier expressions are
  // still evaluated for their effects and discarded. Searching backwards for
  // any expression is wrong when the fixture ends in a binding: it would
  // assert an earlier value and silently ignore the final binding.
  let lastExprIdx = -1;
  const finalBodyIdx = bodyChunks.length - 1;
  if (finalBodyIdx >= 0 && bodyChunks[finalBodyIdx].kind === "expr") {
    lastExprIdx = finalBodyIdx;
  }
  let finalBindingName = null;
  if (lastExprIdx < 0 && finalBodyIdx >= 0) {
    const finalChunk = bodyChunks[finalBodyIdx];
    if (finalChunk.kind === "decl") {
      finalBindingName = simpleBindingName(finalChunk.text);
    }
  }
  const renderedBody = bodyChunks.map((c, i) => {
    if (c.kind === "decl") return c.text;
    if (i === lastExprIdx && expectedLast !== null) {
      return `assert_true(__to_string(\n${c.text}\n) == ${vibeStringLiteral(displayForm(expectedLast))})`;
    }
    return `let _ = (\n${c.text}\n)`;
  });
  if (expectedLast !== null && lastExprIdx < 0) {
    if (finalBindingName === null) {
      throw new Error(
        `${fixturePath}: cannot assert __DATA__.last; end the fixture with an expression or a simple identifier binding, or add reasoned debt`,
      );
    }
    renderedBody.push(
      `assert_true(__to_string(${finalBindingName}) == ${vibeStringLiteral(displayForm(expectedLast))})`,
    );
  }

  const parts = [];
  if (preludeChunks.length > 0) {
    parts.push(
      preludeChunks.map((c) => rewriteRelativeImports(c, fixturePath)).join("\n\n"),
    );
    parts.push("");
  }

  const testBody = [];
  for (const chunk of renderedBody) {
    const indented = chunk
      .split("\n")
      .map((line) => (line.length > 0 ? `  ${line}` : ""))
      .join("\n");
    testBody.push(indented);
  }
  if (expectedLast !== null || bodyChunks.length === 0) {
    testBody.push("  ()");
  }
  parts.push(`test "generated fixture: ${fixturePath}" {\n${testBody.join("\n\n")}\n}\n`);

  return parts.join("\n");
}

/**
 * Build a .vibe test file containing tests for multiple fixtures in a shard.
 *
 * When shard size > 1, each fixture gets its own file to avoid name conflicts
 * between fixture preludes. This function returns an array of
 * { fileName, content } objects.
 */
function stableTestFileName(fixturePath) {
  const stem = path
    .basename(fixturePath, path.extname(fixturePath))
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 48) || "fixture";
  const pathHash = createHash("sha256").update(fixturePath).digest("hex").slice(0, 12);
  return `runtime_fixture_${stem}_${pathHash}_test.vibe`;
}

function buildShardTestFiles(fixturePaths) {
  // Each fixture needs its own file to avoid top-level name conflicts
  // between different fixture preludes.
  const files = [];
  const fileNames = new Set();
  for (const fixturePath of fixturePaths) {
    const fileName = stableTestFileName(fixturePath);
    if (fileNames.has(fileName)) {
      throw new Error(`generated runtime fixture filename collision: ${fileName}`);
    }
    fileNames.add(fileName);
    const content = buildSingleFixtureTestContent(fixturePath);
    files.push({ fileName, content });
  }
  return files;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const listOnly = process.env.VIBE_RUNTIME_FIXTURE_LIST_ONLY === "1";
  let limit = Number(
    process.env.VIBE_RUNTIME_FIXTURE_LIMIT || "0",
  );
  const inventoryMode = process.env.VIBE_RUNTIME_FIXTURE_INVENTORY || "";
  if (inventoryMode && inventoryMode !== "active" && inventoryMode !== "all") {
    throw new Error("VIBE_RUNTIME_FIXTURE_INVENTORY must be active or all");
  }

  if (listOnly) {
    let candidates = discoverCandidates();
    const includeDebt = inventoryMode
      ? inventoryMode === "all"
      : process.env.VIBE_RUNTIME_FIXTURE_INCLUDE_DEBT === "1";
    if (inventoryMode) limit = 0;
    if (!includeDebt) {
      const debtPaths = readDebtPaths(candidates);
      candidates = candidates.filter((candidate) => !debtPaths.has(candidate));
    } else {
      // Audit the manifest in all-candidate mode too. A removed or migrated
      // fixture must retire its debt row in the same change.
      readDebtPaths(candidates);
    }
    if (limit > 0) {
      candidates = candidates.slice(0, limit);
    }
    for (const c of candidates) {
      process.stdout.write(c + "\n");
    }
    return;
  }

  // Generate mode
  const pathsFile = process.env.VIBE_RUNTIME_FIXTURE_PATHS_FILE;
  if (!pathsFile) {
    process.stderr.write(
      "error: set VIBE_RUNTIME_FIXTURE_LIST_ONLY=1 or VIBE_RUNTIME_FIXTURE_PATHS_FILE\n",
    );
    process.exit(1);
  }

  const fixturePaths = fs
    .readFileSync(pathsFile, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  if (fixturePaths.length === 0) {
    return;
  }

  // Generate one file per fixture to avoid top-level name conflicts.
  fs.mkdirSync(GENERATED_DIR, { recursive: true });

  const files = buildShardTestFiles(fixturePaths);
  for (const { fileName, content } of files) {
    const filePath = path.join(GENERATED_DIR, fileName);
    fs.writeFileSync(filePath, content);
    const relPath = path.relative(ROOT, filePath);
    process.stdout.write(relPath + "\n");
  }
}

main();
