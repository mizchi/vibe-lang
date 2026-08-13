#!/usr/bin/env node
// Import-graph affected test selection (#988).
//
// flaker.toml's `[affected] resolver = "simple"` selects the `*_test.vibe`
// files living in or under a changed file's DIRECTORY. That is wrong in both
// directions, and the wrong direction matters much more than the wasteful one:
//
//   - it OVER-selects siblings that never import the changed file, and
//   - it UNDER-selects every test that imports the changed file from another
//     directory -- which is most of them, since `lib/@vibe/compiler/**` is
//     imported by test files all over the tree.
//
// Under-selection is the failure mode to design against: a run that skips the
// one test that would have caught the change reports green and is believed.
// So this tool is built to FAIL OPEN. It answers "run these" only when it can
// prove the answer; anything it cannot reason about exits 2 ("run everything").
//
// The graph is not re-derived here. `vibe deps --direct` returns the loader's
// OWN resolved imports for a file -- the same call the build makes, through
// the same persistent header cache -- so this cannot drift from the resolution
// the compiler actually performs (`index.vibe` facades, `.vpkg` contracts and
// their sibling impls, `@scope/pkg` landing in `.vibe/store` vs `lib/`,
// directory-shared vpkg imports, re-exports). Riding the incremental build is
// also what makes the index cheap to maintain: a file's direct deps are a
// function of that file's own text, so an edit re-queries exactly that file.
//
// Usage:
//   node scripts/affected_tests.mjs [options]
//
//   --changed-from <ref>  diff against the merge-base with <ref> (default: origin/main)
//   --changed <path>      an explicit changed path (repeatable); suppresses git
//   --index-only          refresh the dependency index and print nothing
//   --explain             annotate each selected entry with its path to the change (stderr)
//   --json                emit a JSON object instead of lines
//   --jobs N              parallel `vibe deps` queries while building the index (default 4)
//
// Output: one repo-relative test entry path per line. EMPTY OUTPUT WITH EXIT 0
// MEANS "nothing is affected" -- a real answer, not a failure.
//
// Exit codes:
//   0  the printed selection is complete and trustworthy
//   2  cannot determine -- the caller must run the full suite (see fail-open above)
//   1  hard error (bad usage, unreadable index)
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const INDEX_PATH = join(ROOT, "_build", "affected", "dep_index.json");
// Bump when the index's meaning changes (not merely its contents), so a stale
// file from an older layout is discarded instead of misread.
const INDEX_VERSION = 1;

export function parseArgs(argv) {
  const args = {
    changedFrom: "origin/main",
    changed: null,
    indexOnly: false,
    explain: false,
    json: false,
    jobs: 4,
  };
  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--changed-from") {
      if (i + 1 >= argv.length) throw new Error("missing value after --changed-from");
      args.changedFrom = argv[i + 1];
      i += 2;
    } else if (arg === "--changed") {
      if (i + 1 >= argv.length) throw new Error("missing value after --changed");
      (args.changed ??= []).push(argv[i + 1]);
      i += 2;
    } else if (arg === "--jobs") {
      if (i + 1 >= argv.length) throw new Error("missing value after --jobs");
      const n = Number(argv[i + 1]);
      if (!Number.isInteger(n) || n < 1) throw new Error(`--jobs must be a positive integer, got: ${argv[i + 1]}`);
      args.jobs = n;
      i += 2;
    } else if (arg === "--index-only") {
      args.indexOnly = true;
      i += 1;
    } else if (arg === "--explain") {
      args.explain = true;
      i += 1;
    } else if (arg === "--json") {
      args.json = true;
      i += 1;
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return args;
}

// A change this tool cannot reason about through the import graph. Anything
// that is not vibe source under lib/ can affect any test at all: the runner
// scripts, the seed, the task definitions, a fixture read at run time. Rather
// than pretend the graph covers them, say so and let the caller run the suite.
export function isGraphReasonable(path) {
  if (!path.startsWith("lib/")) return false;
  return path.endsWith(".vibe") || path.endsWith(".vpkg");
}

export function classifyChanges(changed) {
  const known = [];
  const unknown = [];
  for (const path of changed) {
    (isGraphReasonable(path) ? known : unknown).push(path);
  }
  return { known, unknown };
}

// Invert file -> direct deps into dep -> importers, then walk UPWARD from the
// changed files. This is the cheap direction: it never materializes a closure
// per test entry, and it visits only the part of the graph above the change.
//
// `entries` is the set of selectable test files; a changed file that IS one is
// selected directly (it needs no importer).
export function affectedFrom(index, changed, entries) {
  const importers = new Map();
  for (const [path, record] of Object.entries(index)) {
    for (const dep of record.deps) {
      let list = importers.get(dep);
      if (!list) {
        list = [];
        importers.set(dep, list);
      }
      list.push(path);
    }
  }
  const entrySet = new Set(entries);
  const seen = new Set();
  // `via` records the first path found from a changed file up to each node --
  // that is what --explain prints, so a surprising selection can be checked
  // rather than taken on faith.
  const via = new Map();
  const queue = [];
  for (const path of changed) {
    if (seen.has(path)) continue;
    seen.add(path);
    via.set(path, [path]);
    queue.push(path);
  }
  const selected = [];
  while (queue.length > 0) {
    const path = queue.shift();
    if (entrySet.has(path)) selected.push(path);
    for (const importer of importers.get(path) ?? []) {
      if (seen.has(importer)) continue;
      seen.add(importer);
      via.set(importer, [...via.get(path), importer]);
      queue.push(importer);
    }
  }
  selected.sort();
  return { selected, via };
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function fileHash(absPath) {
  try {
    return sha256(readFileSync(absPath));
  } catch {
    return null;
  }
}

function listTestEntries() {
  const proc = spawnSync("bash", [join(ROOT, "scripts", "unit_test_runner.sh"), "--list"], {
    cwd: ROOT,
    encoding: "utf-8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (proc.status !== 0) {
    throw new Error(`unit_test_runner.sh --list failed (exit ${proc.status}): ${proc.stderr ?? ""}`);
  }
  return (proc.stdout ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("#"));
}

function changedFromGit(ref) {
  const base = spawnSync("git", ["merge-base", "HEAD", ref], { cwd: ROOT, encoding: "utf-8" });
  // No merge-base (shallow clone, unknown ref) is exactly the "cannot
  // determine" case -- do not silently fall back to comparing against HEAD,
  // which would report an empty change set and select nothing.
  if (base.status !== 0) return null;
  const range = base.stdout.trim();
  const out = spawnSync("git", ["diff", "--name-only", range], { cwd: ROOT, encoding: "utf-8" });
  if (out.status !== 0) return null;
  const untracked = spawnSync("git", ["ls-files", "--others", "--exclude-standard"], {
    cwd: ROOT,
    encoding: "utf-8",
  });
  const lines = (out.stdout ?? "").split("\n");
  if (untracked.status === 0) lines.push(...(untracked.stdout ?? "").split("\n"));
  return [...new Set(lines.map((l) => l.trim()).filter((l) => l !== ""))];
}

function resolveCli() {
  const explicit = process.env.VIBE_AFFECTED_CLI_WASM || process.env.VIBE_STAGE2_WASM;
  if (explicit) return existsSync(explicit) ? explicit : null;
  // Same rule as coverage_suite.sh: the generation built for THIS checkout,
  // never the newest by mtime (a worktree can hold another revision's stage2,
  // and a dep index built from the wrong compiler is quietly wrong).
  const rev = spawnSync("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT, encoding: "utf-8" });
  if (rev.status !== 0) return null;
  const dir = join(ROOT, "_build", "selfhost", "generations");
  if (!existsSync(dir)) return null;
  const suffix = `_${rev.stdout.trim()}`;
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(suffix)) continue;
    const candidate = join(dir, name, "stage2.wasm");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

// One `vibe deps --direct` query. Returns the resolved direct deps, or null
// when the query failed -- null is propagated all the way out as exit 2 rather
// than treated as "no deps", which would silently prune the graph.
//
// Each concurrent query needs its OWN output path: the adapter writes
// `<out>` and `<out>.diag`, so a shared name would let one query read
// another's bytes.
function queryDirectDeps(cli, path, outPath) {
  return new Promise((resolveQuery) => {
    rmSync(outPath, { force: true });
    rmSync(`${outPath}.diag`, { force: true });
    const child = spawn(
      "bash",
      [
        join(ROOT, "scripts", "run_wasm_vibe_host_runner.sh"),
        "--invoke",
        "cli_main",
        cli,
        path,
        outPath,
        "__no_entry__",
      ],
      {
        cwd: ROOT,
        stdio: "ignore",
        env: {
          ...process.env,
          VIBE_PREOPEN_DIR: ROOT,
          VIBE_IMPORT_ABI: "raw",
          VIBE_DEPS: "1",
          VIBE_DEPS_DIRECT: "1",
        },
      },
    );
    child.on("error", (err) => resolveQuery({ deps: null, error: String(err) }));
    child.on("close", (status) => {
      if (existsSync(`${outPath}.diag`)) {
        const diag = readFileSync(`${outPath}.diag`, "utf-8").trim();
        if (diag !== "") return resolveQuery({ deps: null, error: diag });
      }
      if (!existsSync(outPath)) {
        // No output file at all means the mode never ran -- an older compiler
        // without VIBE_DEPS falls through to the default compile path. That is
        // NOT "this file has no imports", and treating it as such would prune
        // the graph and under-select.
        return resolveQuery({ deps: null, error: `no output from vibe deps (exit ${status})` });
      }
      const deps = readFileSync(outPath, "utf-8")
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l !== "")
        .map((l) => (l.startsWith("/") ? relative(ROOT, l) : l));
      resolveQuery({ deps, error: null });
    });
  });
}

function loadIndex() {
  if (!existsSync(INDEX_PATH)) return {};
  try {
    const parsed = JSON.parse(readFileSync(INDEX_PATH, "utf-8"));
    if (parsed?.version !== INDEX_VERSION) return {};
    return parsed.entries ?? {};
  } catch {
    return {};
  }
}

function saveIndex(entries) {
  mkdirSync(dirname(INDEX_PATH), { recursive: true });
  writeFileSync(INDEX_PATH, `${JSON.stringify({ version: INDEX_VERSION, entries }, null, 0)}\n`);
}

// Breadth-first from the test entries over direct edges, re-querying only the
// files whose bytes changed since the index was written. Everything reachable
// gets an entry, so the inverted map below is complete.
async function refreshIndex(cli, roots, jobs) {
  const index = loadIndex();
  const tmpDir = join(ROOT, "_build", "affected", "tmp");
  mkdirSync(tmpDir, { recursive: true });
  const queue = [...roots];
  const visited = new Set(queue);
  let queried = 0;
  let reused = 0;
  while (queue.length > 0) {
    // Everything cached is settled without spawning anything; only the stale
    // files reach the (parallel) query batch. On a warm index with one edited
    // file, that batch has one element.
    const batch = [];
    while (batch.length < jobs && queue.length > 0) {
      const path = queue.shift();
      const hash = fileHash(join(ROOT, path));
      if (hash === null) {
        // A dep that no longer exists on disk: the graph moved under us, so
        // the index cannot be completed. Fail open rather than guess.
        return { index: null, error: `cannot read ${path}` };
      }
      const cached = index[path];
      if (cached && cached.hash === hash) {
        reused += 1;
        for (const dep of cached.deps) {
          if (!visited.has(dep)) {
            visited.add(dep);
            queue.push(dep);
          }
        }
      } else {
        batch.push({ path, hash });
      }
    }
    if (batch.length === 0) continue;
    const results = await Promise.all(
      batch.map((item, slot) => queryDirectDeps(cli, item.path, join(tmpDir, `deps${slot}.txt`))),
    );
    for (let i = 0; i < batch.length; i += 1) {
      const { path, hash } = batch[i];
      const { deps, error } = results[i];
      if (deps === null) return { index: null, error: `vibe deps ${path}: ${error}` };
      index[path] = { hash, deps };
      queried += 1;
      for (const dep of deps) {
        if (!visited.has(dep)) {
          visited.add(dep);
          queue.push(dep);
        }
      }
    }
  }
  saveIndex(index);
  return { index, error: null, queried, reused };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const entries = listTestEntries();

  const changed = args.changed ?? changedFromGit(args.changedFrom);
  if (changed === null) {
    process.stderr.write(`[affected] cannot compute a change set against ${args.changedFrom}\n`);
    process.exit(2);
  }
  const { known, unknown } = classifyChanges(changed);
  if (unknown.length > 0 && !args.indexOnly) {
    // Not a failure -- an honest "the import graph does not cover this".
    process.stderr.write(
      `[affected] ${unknown.length} change(s) outside the vibe import graph (e.g. ${unknown[0]}); run the full suite\n`,
    );
    process.exit(2);
  }

  const cli = resolveCli();
  if (cli === null) {
    process.stderr.write(
      "[affected] no stage2 for this checkout; run 'pkf run generation' or set VIBE_AFFECTED_CLI_WASM\n",
    );
    process.exit(2);
  }

  const { index, error, queried, reused } = await refreshIndex(cli, entries, args.jobs);
  if (index === null) {
    process.stderr.write(`[affected] dependency index incomplete: ${error}\n`);
    process.exit(2);
  }
  process.stderr.write(`[affected] index: ${queried} queried, ${reused} reused, ${Object.keys(index).length} files\n`);
  if (args.indexOnly) return;

  const { selected, via } = affectedFrom(index, known, entries);
  if (args.explain) {
    for (const entry of selected) {
      process.stderr.write(`[affected] ${entry} <- ${(via.get(entry) ?? [entry]).join(" <- ")}\n`);
    }
  }
  if (args.json) {
    process.stdout.write(`${JSON.stringify({ changed: known, selected, total_entries: entries.length }, null, 2)}\n`);
    return;
  }
  for (const entry of selected) process.stdout.write(`${entry}\n`);
}

const isCliEntry = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isCliEntry) {
  main().catch((error) => {
    process.stderr.write(`[affected] ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
}
