#!/usr/bin/env node
// #4043: does prelude reuse (#4042) produce exactly what the effect passes
// produce, on the edits where it replays?
//
// `VIBE_PRELUDE_REUSE=on` replays the suspend-CPS and evidence passes' output
// from the previous build's record when no edit can move what they read.
// `verify` replays the same way, runs the passes as well, produces their
// output, and fails the build when the replay differs in any statement,
// offsets included. This oracle replays a corpus of edits through both:
//
//   edits     a small program with a handler and a perform, edited step by
//             step: pure-helper bodies, a comment, an added helper (each
//             must REPLAY, or the comparison is vacuous), and an edit of the
//             performing function (must MISS). Three caches follow the
//             sequence: `on`, `verify`, and `off`. Every step's `on` module
//             must equal the `off` module in bytes and in the executed
//             result, which must also equal the value this oracle derives
//             from the fixture state; the `verify` build must succeed and
//             its trace must say `verified` wherever `on` replayed.
//   commits   the last N first-parent commits (default 3; the oldest first),
//             each tree's CLI closure built in verify mode through one
//             cache, so each build replays against the previous record where
//             it can. Every build must succeed (a verify failure fails the
//             build). A tree older than HEAD that does not build under this
//             compiler is skipped and said so; HEAD's must build, and at
//             least two trees must, or nothing was compared. Most real
//             commits miss, so HEAD's tree is then edited twice where a
//             replay is expected -- a comment above everything in
//             `core/hex.vibe`, a function appended to it, and a `let` inside
//             its `with Exception` function `hex_digit_value` -- and each
//             build must replay and verify, on the whole CLI closure.
//
// The body cache and the checked-module cache are off for the edits section,
// so a replayed body cannot make a comparison pass for another reason.
import { cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`prelude-reuse-oracle: ${message}`); };

// Every VIBE_* variable is DROPPED, not inherited (#2252): an inherited
// VIBE_PRELUDE_REUSE would decide the very thing this oracle measures.
const cleanEnv = Object.fromEntries(
  Object.entries(process.env).filter(([key]) => !key.startsWith("VIBE_")),
);

// Overridable ONLY so this oracle's self-test can drive it with scripted
// builds; unset on every real invocation.
const runnerScript = process.env.PRELUDE_REUSE_ORACLE_RUNNER
  || join(root, "scripts/run_wasm_vibe_host_runner.sh");
// Overridable ONLY so the self-test can fake the commits section against a
// scratch repository, without this checkout's history.
const gitRoot = process.env.PRELUDE_REUSE_ORACLE_GIT_ROOT || root;
// Overridable ONLY so the self-test can run one section.
const allSections = ["edits", "commits"];
const sections = (process.env.PRELUDE_REUSE_ORACLE_SECTIONS || allSections.join(","))
  .split(",").filter(Boolean);
for (const section of sections) {
  if (!allSections.includes(section)) fail(`unknown section ${section} (known: ${allSections.join(", ")})`);
}
const commitCount = Number(process.env.PRELUDE_REUSE_ORACLE_COMMITS || "3");
if (!Number.isInteger(commitCount) || commitCount < 2) fail("PRELUDE_REUSE_ORACLE_COMMITS must be an integer >= 2");

// ---- the fixture -----------------------------------------------------------
//
// `pr_run` handles the `Ask` effect `pr_ask` performs, so both are statements
// the passes rewrite or read; `main` reaches them. `pr_scale` and `pr_label`
// are pure and reach nothing the passes read, so an edit there may replay.
// `pr_guard` is `with Exception`, which the passes read only off its row.
// `pr_run` holds a string literal, `"qq"`: the self-test corrupts it inside a
// stored record (a well-formed record that replays a wrong statement) and
// requires this oracle to fail.
function libSource(state) {
  return [
    state.comment ? "// an edit that only moves offsets" : "",
    "effect Ask {",
    "  Get() -> Int",
    "}",
    "",
    state.scaleThrows
      ? `export fn pr_scale(_ n: Int) -> Int with Exception {\n  if n < 0 {\n    throw("negative")\n  } else {\n    n * ${state.scale}\n  }\n}`
      : `export fn pr_scale(_ n: Int) -> Int {\n  n * ${state.scale}\n}`,
    "",
    `export fn pr_guard(_ n: Int) -> Int with Exception {\n  if n < 0 {\n    throw("negative")\n  } else {\n    n + ${state.guard}\n  }\n}`,
    "",
    state.helper ? "fn pr_twice(_ s: String) -> String {\n  s + s\n}\n" : "",
    `export fn pr_label(_ n: Int) -> String {\n  ${state.helper ? 'pr_twice("ab")' : '"ab"'}\n}`,
    "",
    `fn pr_ask(_ n: Int) -> Int with Ask {\n  perform Ask::Get() + ${state.emit}\n}`,
    "",
    "export fn pr_run(_ n: Int) -> Int {",
    '  let tag = "qq"',
    "  let got = handle {",
    "    pr_ask(n)",
    "  } with {",
    "    Ask::Get() => resume(n * 2)",
    "  }",
    "  got + String::length(tag)",
    "}",
    "",
  ].join("\n");
}

const appSource = [
  "import ./lib.vibe { pr_scale, pr_label, pr_run, pr_guard }",
  "",
  "fn main() -> Int allows Exception {",
  "  pr_scale(3) + String::length(pr_label(2)) * 100 + pr_run(5) * 10000 + pr_guard(4) * 1000000",
  "}",
  "",
].join("\n");

// What the fixture computes in `state`, from its own definitions.
function expectedResult(state) {
  const label = state.helper ? 4 : 2;
  return 3 * state.scale + label * 100 + (5 * 2 + state.emit + 2) * 10000 + (4 + state.guard) * 1000000;
}

// Each step's state, and whether `on` must replay there. A step that must
// replay but misses fails the oracle: its comparison would prove nothing
// about replay.
const S0 = { scale: 2, comment: false, helper: false, emit: 1, guard: 1, scaleThrows: false };
const steps = [
  { name: "cold", state: S0, replay: false },
  { name: "pure-body", state: { ...S0, scale: 3 }, replay: true },
  { name: "comment", state: { ...S0, scale: 3, comment: true }, replay: true },
  { name: "added-helper", state: { ...S0, scale: 3, comment: true, helper: true }, replay: true },
  { name: "performing-body", state: { ...S0, scale: 3, comment: true, helper: true, emit: 4 }, replay: false },
  { name: "pure-body-after-miss", state: { ...S0, scale: 5, comment: true, helper: true, emit: 4 }, replay: true },
  // #4123: `Exception` in a row is not effect syntax, so an edit inside a
  // `with Exception` body replays; one that gives a function that row
  // changes the signature callers read, and must not.
  { name: "exception-body", state: { ...S0, scale: 5, comment: true, helper: true, emit: 4, guard: 2 }, replay: true },
  { name: "exception-row", state: { ...S0, scale: 6, comment: true, helper: true, emit: 4, guard: 2, scaleThrows: true }, replay: false },
];

// ---- builds ----------------------------------------------------------------

function lastTraceLine(path) {
  if (!existsSync(path)) return "";
  const lines = readFileSync(path, "utf8").split("\n").filter(Boolean);
  return lines.length === 0 ? "" : lines[lines.length - 1];
}

// One compile of `entry` in `project`, through `cache`, with `mode` as
// VIBE_PRELUDE_REUSE. Returns the module bytes (null when it failed), the
// trace line it appended (or ""), and its diagnostics.
function build({ project, stage2, entry, out, cache, mode, trace, extraEnv = {}, large = false }) {
  for (const stale of [out, `${out}.diag`]) rmSync(stale, { force: true });
  // A CLI-sized closure needs a deep stack: raise the soft limit where the
  // hard limit allows, and size node's stack to it.
  const prefix = large
    ? "if ulimit -s unlimited 2>/dev/null; then export VIBE_NODE_STACK_SIZE=500000; fi; "
    : "";
  // And the memory protocol scripts/build_cli_core.sh and
  // tests/gates/bootstrap/stage2_oracles.sh use for this import graph: on a
  // cold cache, retaining every parsed header while the bodies are prepared
  // traps the RC path out of bounds. Ask the loader for the closure first,
  // which fills the persistent header cache, and reserve the compile's
  // measured wasm32 space up front.
  if (large) warmHeaders({ project, stage2, entry, cache, extraEnv, prefix });
  const largeEnv = large ? { VIBE_WASM_PRE_GROW_PAGES: "65000" } : {};
  const before = existsSync(trace) ? readFileSync(trace, "utf8") : "";
  const result = spawnSync("bash", ["-c", `${prefix}exec bash "$0" "$@"`, runnerScript,
    "--invoke", "cli_main", stage2, entry, out, entry.endsWith("entry.vibe") ? "cli_main" : "main"], {
    cwd: project,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...cleanEnv,
      ...extraEnv,
      ...largeEnv,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_RC: "1",
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      VIBE_PRELUDE_REUSE: mode,
      VIBE_PRELUDE_REUSE_TRACE: trace,
    },
  });
  const after = existsSync(trace) ? readFileSync(trace, "utf8") : "";
  const appended = after.startsWith(before) ? after.slice(before.length).trim() : "<trace rewritten>";
  const diag = existsSync(`${out}.diag`) ? readFileSync(`${out}.diag`, "utf8").trim() : "";
  const ok = result.status === 0 && existsSync(out);
  return {
    bytes: ok ? readFileSync(out) : null,
    trace: appended,
    message: [result.stderr, result.stdout, diag].map((s) => (s || "").trim()).filter(Boolean).join("\n"),
  };
}

// The dependency-closure query, run only for what it caches: the persistent
// module headers the following compile of `entry` loads.
function warmHeaders({ project, stage2, entry, cache, extraEnv, prefix }) {
  const out = join(project, ".prelude-reuse-oracle-deps");
  const result = spawnSync("bash", ["-c", `${prefix}exec bash "$0" "$@"`, runnerScript,
    "--invoke", "cli_main", stage2, entry, out], {
    cwd: project,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...cleanEnv,
      ...extraEnv,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "0",
      VIBE_DEPS: "1",
      VIBE_DEPS_DIRECT: "0",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
    },
  });
  if (result.status !== 0) {
    const diag = existsSync(`${out}.diag`) ? readFileSync(`${out}.diag`, "utf8").trim() : "";
    fail(`warming the module-header cache for ${entry} failed: ${[result.stderr, result.stdout, diag].map((s) => (s || "").trim()).filter(Boolean).join("\n")}`);
  }
  for (const f of [out, `${out}.diag`]) rmSync(f, { force: true });
}

function execute(project, wasm) {
  const result = spawnSync("bash", [runnerScript, "--invoke", "main", wasm], {
    cwd: project,
    encoding: "utf8",
    env: { ...cleanEnv, VIBE_PREOPEN_DIR: project },
  });
  if (result.status !== 0) fail(`executing ${wasm} failed: ${(result.stderr || result.stdout || "").trim()}`);
  return (result.stdout || "").trim();
}

// ---- section: edits ---------------------------------------------------------

function runEdits(stage2, work) {
  const project = join(work, "edits");
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "app.vibe"), appSource);
  const caches = Object.fromEntries(["on", "verify", "off"].map((lane) => {
    const dir = join(work, `cache-${lane}`);
    mkdirSync(dir, { recursive: true });
    return [lane, dir];
  }));
  const fixtureEnv = { VIBE_CODEGEN_BODY_CACHE: "off", VIBE_CHECKED_MODULE_CACHE: "off" };
  let previous = null;
  for (const step of steps) {
    writeFileSync(join(project, "lib.vibe"), libSource(step.state));
    const lane = (mode) => build({
      project, stage2, entry: "app.vibe", out: join(project, `${step.name}-${mode}.wasm`),
      cache: caches[mode], mode, trace: join(work, `trace-${mode}.txt`), extraEnv: fixtureEnv,
    });
    const on = lane("on");
    const verify = lane("verify");
    const off = lane("off");
    for (const [mode, b] of [["on", on], ["verify", verify], ["off", off]]) {
      if (!b.bytes) fail(`${step.name}: the ${mode} build failed:\n${b.message}`);
    }
    const replayed = on.trace.includes("prelude-reuse: replayed");
    if (step.replay && !replayed) {
      fail(`${step.name}: reuse did not replay, so the comparison would be vacuous (trace: ${on.trace || "none"})`);
    }
    if (!step.replay && replayed) fail(`${step.name}: reuse replayed an edit it must miss (trace: ${on.trace})`);
    if (!on.bytes.equals(off.bytes)) {
      fail(`${step.name}: the reuse-on module differs from a reuse-off compile (${on.bytes.length} vs ${off.bytes.length} bytes; trace: ${on.trace})`);
    }
    if (step.replay) {
      if (!verify.trace.includes("prelude-reuse: replayed") || !verify.trace.endsWith("; verified")) {
        fail(`${step.name}: the verify build did not replay and verify (trace: ${verify.trace || "none"})`);
      }
    }
    if (!verify.bytes.equals(off.bytes)) fail(`${step.name}: the verify module differs from a reuse-off compile`);
    const result = execute(project, join(project, `${step.name}-on.wasm`));
    const want = String(expectedResult(step.state));
    if (result !== want) fail(`${step.name}: the program executed ${result}, but the fixture state computes ${want}`);
    if (previous !== null && step.name !== "comment" && result === previous) {
      fail(`${step.name}: the edit did not change the executed result, so it proved nothing`);
    }
    previous = result;
    console.log(`[prelude-reuse-oracle] edits ${step.name}: ${on.trace.replace(/^prelude-reuse: /, "")} -> ${result}`);
  }
}

// ---- section: commits -------------------------------------------------------

function git(args) {
  const result = spawnSync("git", args, { cwd: gitRoot, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.status !== 0) fail(`git ${args.join(" ")} failed: ${(result.stderr || "").trim()}`);
  return result.stdout;
}

function runCommits(stage2, work) {
  const listed = () => git(["rev-list", "--first-parent", "-n", String(commitCount), "HEAD"])
    .split("\n").filter(Boolean).reverse();
  let commits = listed();
  // CI checks out one commit. Deepen a shallow checkout by exactly what this
  // section reads, rather than asking every caller for a deeper clone.
  if (commits.length < commitCount && git(["rev-parse", "--is-shallow-repository"]).trim() === "true") {
    const head = git(["rev-parse", "HEAD"]).trim();
    git(["fetch", "--quiet", "--no-tags", `--deepen=${commitCount}`, "origin", head]);
    commits = listed();
  }
  if (commits.length < commitCount) {
    fail(`only ${commits.length} of ${commitCount} commits are in this checkout's history, and it could not be deepened`);
  }
  // The tree's own generated fingerprint is not tracked: take this checkout's.
  // Its value does not change what the passes see, and every build of a tree
  // reads the same one.
  const fingerprint = join(root, "lib/@vibe/compiler/cache/codegen_fingerprint.vibe");
  if (!existsSync(fingerprint)) fail(`${fingerprint} is missing: run scripts/ensure_generated.sh first`);
  const cache = join(work, "cache-commits");
  mkdirSync(cache, { recursive: true });
  const trace = join(work, "trace-commits.txt");
  let built = 0;
  for (const [i, commit] of commits.entries()) {
    const isHead = i === commits.length - 1;
    const tree = join(work, `tree-${i}`);
    mkdirSync(tree, { recursive: true });
    const archive = spawnSync("bash", ["-c", 'git -C "$0" archive "$1" lib | tar -x -C "$2"', gitRoot, commit, tree], { encoding: "utf8" });
    if (archive.status !== 0) fail(`extracting ${commit} failed: ${(archive.stderr || "").trim()}`);
    cpSync(fingerprint, join(tree, "lib/@vibe/compiler/cache/codegen_fingerprint.vibe"));
    const b = build({
      project: tree, stage2, entry: "lib/@vibe/cli/entry.vibe", out: join(tree, "cli.wasm"),
      cache, mode: "verify", trace, extraEnv: { VIBE_LIB: join(tree, "lib"), VIBE_BACKEND: "wasi" }, large: true,
    });
    const short = commit.slice(0, 9);
    if (!b.bytes) {
      if (b.message.includes("VIBE_PRELUDE_REUSE=verify") || b.trace.includes("VERIFY FAILED")) {
        fail(`${short}: ${b.trace}\n${b.message}`);
      }
      if (isHead) fail(`${short} (HEAD) did not build:\n${b.message}`);
      console.log(`[prelude-reuse-oracle] commits ${short}: skipped, the tree does not build under this compiler`);
    } else {
      built += 1;
      console.log(`[prelude-reuse-oracle] commits ${short}: ${b.trace.replace(/^prelude-reuse: /, "")}`);
    }
    if (!isHead) rmSync(tree, { recursive: true, force: true });
  }
  if (built < 2) fail(`only ${built} tree(s) built, so no replay was attempted`);
  const head = join(work, `tree-${commits.length - 1}`);
  const hex = join(head, "lib/@vibe/core/hex.vibe");
  if (!existsSync(hex)) fail(`${hex} is missing: pick another file for the HEAD edits`);
  const headEdits = [
    ["comment", (src) => `// an edit that only moves offsets\n${src}`],
    ["appended-function", (src) => `${src}\nfn prelude_reuse_oracle_probe(_ n: Int) -> Int {\n  n + 1\n}\n`],
    // #4123: inside a `with Exception` function's body.
    ["exception-body", (src) => {
      const head = "fn hex_digit_value(_ c: Int) -> Int with Exception {\n";
      if (!src.includes(head)) fail(`${hex} no longer declares ${head.trim()}: pick another \`with Exception\` function for the HEAD edits`);
      return src.replace(head, `${head}  let prelude_reuse_oracle_unused = c + 0\n`);
    }],
  ];
  for (const [name, change] of headEdits) {
    writeFileSync(hex, change(readFileSync(hex, "utf8")));
    const b = build({
      project: head, stage2, entry: "lib/@vibe/cli/entry.vibe", out: join(head, "cli.wasm"),
      cache, mode: "verify", trace, extraEnv: { VIBE_LIB: join(head, "lib"), VIBE_BACKEND: "wasi" }, large: true,
    });
    if (!b.bytes) fail(`HEAD + ${name}: the verify build failed: ${b.trace}\n${b.message}`);
    if (!b.trace.includes("prelude-reuse: replayed") || !b.trace.endsWith("; verified")) {
      fail(`HEAD + ${name}: the build did not replay and verify, so the CLI closure proved nothing (trace: ${b.trace || "none"})`);
    }
    console.log(`[prelude-reuse-oracle] commits HEAD + ${name}: ${b.trace.replace(/^prelude-reuse: /, "")}`);
  }
}

// ---- main -------------------------------------------------------------------

const stage2 = resolve(process.argv[2] || fail("usage: prelude_reuse_oracle.mjs <stage2.wasm>"));
if (!existsSync(stage2)) fail(`${stage2} does not exist`);
if (sections.length !== allSections.length) {
  console.error(`[prelude-reuse-oracle] NOTE: running only ${sections.join(", ")}`);
}
const work = mkdtempSync(join(tmpdir(), "prelude-reuse-oracle-"));
try {
  if (sections.includes("edits")) runEdits(stage2, work);
  if (sections.includes("commits")) runCommits(stage2, work);
  console.log("[prelude-reuse-oracle] ok");
} finally {
  if (!process.env.PRELUDE_REUSE_ORACLE_KEEP) rmSync(work, { recursive: true, force: true });
}
