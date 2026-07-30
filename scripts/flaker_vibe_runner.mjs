#!/usr/bin/env node
// flaker <-> selfhost unit-test bridge (#988).
//
// flaker.toml's runner/adapter used to point at the retired MoonBit host
// (`moon test --target js`, moontest adapter, moon resolver — #594), which
// made `flaker run --profile local` a silent no-op: listTests failed, the
// inventory was empty, and every run reported "Selected tests: 0 / 0" with
// exit 0. This script rewires flaker's `custom` runner/adapter protocol onto
// the selfhost unit-test battery (scripts/unit_test_runner.sh, #531/#535).
//
// Subcommands (see flaker's CustomRunner / CustomAdapter contracts):
//   list     print the test inventory as JSON [{suite, testName}] — one entry
//            per active *_test.vibe file (per-file granularity: the
//            selfhost battery compiles+runs whole files, so a file is the
//            selection unit). Sourced from `unit_test_runner.sh --list`
//            (#1233 removed the hand-maintained allowlist file this used to
//            read directly; --list now computes the same active set via
//            discover() + that script's small EXCLUDE_PATTERNS).
//   execute  read {tests, opts} JSON on stdin, run the selected files through
//            unit_test_runner.sh (via a temp VIBE_UNIT_TEST_ALLOWLIST, which
//            #1233 repurposed into an explicit-subset override rather than
//            the corpus definition), print an ExecuteResult JSON {exitCode,
//            results, durationMs, stdout, stderr} on stdout.
//   parse    read unit_test_runner.sh output on stdin, print TestCaseResult[]
//            JSON (flaker `import` / CI-artifact ingestion path).
//
// Stage2 selection: VIBE_STAGE2_WASM is passed through when set (CI reuses
// the gate's stage2; locally, point it at a fresh generation to skip the
// per-run seed->stage1->stage2 selfbuild that unit_test_runner.sh otherwise
// performs). Without it, expect the first run to spend minutes selfbuilding.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNNER_SH = join(ROOT, "scripts", "unit_test_runner.sh");

// A file is one test: suite = repo-relative path (what the path-based
// affected resolver matches against), testName = fixed marker.
const TEST_NAME = "file";

// #1233: the active-file inventory is computed by unit_test_runner.sh's
// discover() + EXCLUDE_PATTERNS, not read from a committed allowlist file
// anymore. `--list` is pure and fast (no stage2 build, no compiling) --
// asking the runner script keeps this bridge from re-deriving discovery
// rules that could drift from the actual runner's.
function listActiveFiles() {
  const proc = spawnSync("bash", [RUNNER_SH, "--list"], {
    cwd: ROOT,
    encoding: "utf-8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (proc.status !== 0) {
    throw new Error(
      `unit_test_runner.sh --list failed (exit ${proc.status}): ${proc.stderr ?? ""}`,
    );
  }
  return (proc.stdout ?? "")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "");
}

function readStdin() {
  return readFileSync(0, "utf-8");
}

// Parse unit_test_runner.sh per-file lines:
//   "ok:   <path>"                     -> passed
//   "FAIL: <path> -- <diag>"           -> failed
//   "skip: <path> (<reason>)"          -> skipped
function parseRunnerOutput(text) {
  const results = [];
  for (const line of text.split("\n")) {
    let m;
    if ((m = line.match(/^ok:\s+(\S+)\s*$/))) {
      results.push({
        suite: m[1],
        testName: TEST_NAME,
        status: "passed",
        durationMs: 0,
        retryCount: 0,
      });
    } else if ((m = line.match(/^FAIL:\s+(\S+)(?:\s+--\s+(.*))?$/))) {
      results.push({
        suite: m[1],
        testName: TEST_NAME,
        status: "failed",
        durationMs: 0,
        retryCount: 0,
        errorMessage: (m[2] ?? "").trim() || "unit_test_runner reported FAIL",
      });
    } else if ((m = line.match(/^skip:\s+(\S+)/))) {
      results.push({
        suite: m[1],
        testName: TEST_NAME,
        status: "skipped",
        durationMs: 0,
        retryCount: 0,
      });
    }
  }
  return results;
}

function cmdList() {
  const tests = listActiveFiles().map((suite) => ({ suite, testName: TEST_NAME }));
  process.stdout.write(JSON.stringify(tests));
}

function cmdExecute() {
  const started = Date.now();
  let payload = {};
  try {
    payload = JSON.parse(readStdin() || "{}");
  } catch {
    payload = {};
  }
  const suites = [...new Set((payload.tests ?? []).map((t) => t.suite))];
  if (suites.length === 0) {
    process.stdout.write(
      JSON.stringify({ exitCode: 0, results: [], durationMs: 0, stdout: "", stderr: "" }),
    );
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), "flaker-vibe-"));
  try {
    const subset = join(dir, "allowlist.txt");
    writeFileSync(subset, suites.join("\n") + "\n");
    const proc = spawnSync("bash", [join(ROOT, "scripts", "unit_test_runner.sh")], {
      cwd: ROOT,
      encoding: "utf-8",
      maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, VIBE_UNIT_TEST_ALLOWLIST: subset },
    });
    const stdout = proc.stdout ?? "";
    const stderr = proc.stderr ?? "";
    // Per-file verdicts: ok/skip on stdout, FAIL on stderr.
    const results = parseRunnerOutput(stdout + "\n" + stderr);
    // Selected-but-unreported files (runner crashed before reaching them):
    // surface them as failures instead of dropping them silently.
    const seen = new Set(results.map((r) => r.suite));
    for (const suite of suites) {
      if (!seen.has(suite)) {
        results.push({
          suite,
          testName: TEST_NAME,
          status: "failed",
          durationMs: 0,
          retryCount: 0,
          errorMessage: `no verdict from unit_test_runner.sh (exit ${proc.status ?? "?"})`,
        });
      }
    }
    process.stdout.write(
      JSON.stringify({
        exitCode: proc.status ?? 1,
        results,
        durationMs: Date.now() - started,
        stdout,
        stderr,
      }),
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function cmdParse() {
  process.stdout.write(JSON.stringify(parseRunnerOutput(readStdin())));
}

const sub = process.argv[2];
switch (sub) {
  case "list":
    cmdList();
    break;
  case "execute":
    cmdExecute();
    break;
  case "parse":
    cmdParse();
    break;
  default:
    process.stderr.write(
      "usage: node scripts/flaker_vibe_runner.mjs <list|execute|parse>\n",
    );
    process.exit(2);
}
