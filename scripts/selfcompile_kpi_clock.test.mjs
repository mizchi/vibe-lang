import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import { join } from "node:path";
import test from "node:test";

const source = readFileSync(new URL("./selfcompile_kpi.sh", import.meta.url), "utf8");

// The actual KPI script owns clock selection. Only private fixture copies force
// the portable fallback; no production environment override can alter metrics.
function runKpi(backend, mode, gates = {}) {
  const root = mkdtempSync(join(os.tmpdir(), "vibe kpi clock-"));
  try {
    const scripts = join(root, "scripts");
    const bin = join(root, "bin");
    mkdirSync(scripts);
    mkdirSync(bin);
    let scriptSource = source;
    if (backend === "node") {
      scriptSource = scriptSource.replace("if [ -r /proc/uptime ]; then", "if false; then");
    }
    const script = join(scripts, "selfcompile_kpi.sh");
    writeFileSync(script, scriptSource);
    const stage = join(root, "stage2.wasm");
    writeFileSync(stage, Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]));
    const input = join(root, "input.vibe");
    writeFileSync(input, "let x = 1\n");
    const dateLog = join(root, "date-calls");
    writeFileSync(join(bin, "date"), `#!/usr/bin/env bash
set -euo pipefail
if [ "$#" != 1 ] || [ "$1" != '+%s%N' ]; then exit 98; fi
if [ ! -e "$KPI_CLOCK_TEST_DATE_LOG" ]; then
  printf 'start\\n' > "$KPI_CLOCK_TEST_DATE_LOG"
  printf '10000000000\\n'
else
  printf 'end\\n' >> "$KPI_CLOCK_TEST_DATE_LOG"
  printf '9000000000\\n'
fi
`, { mode: 0o755 });
    const runner = join(scripts, "mock-runner.sh");
    const runnerLog = join(root, "runner-calls");
    writeFileSync(runner, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$VIBE_PREOPEN_DIR" "$VIBE_FS_COMPILE" "$VIBE_IMPORT_ABI" \
  "$VIBE_WASM_MEMORY_STATS" "$VIBE_BUILD_CACHE_DIR" "$@" > "$KPI_CLOCK_TEST_RUNNER_LOG"
sleep 0.03
case "$KPI_CLOCK_TEST_MODE" in
  runner-failure) exit 23 ;;
  missing-output) ;;
  *) printf 'wasm output' > "$5" ;;
esac
if [ "$KPI_CLOCK_TEST_MODE" != missing-stats ]; then
  echo '[wasm-memory] heap_ptr=12345 pages=2' >&2
fi
`);
    const work = join(root, "_build", "work");
    const env = { ...process.env };
    for (const key of ["VIBE_KPI_MAX_HEAP_BYTES", "VIBE_KPI_MAX_WALL_MS",
      "VIBE_KPI_WORK_DIR", "VIBE_KPI_ALLOWED_WORK_ROOT"]) delete env[key];
    Object.assign(env, gates, {
      PATH: `${bin}:${env.PATH}`,
      VIBE_KPI_WORK_DIR: work,
      VIBE_KPI_RUNNER_SCRIPT: runner,
      KPI_CLOCK_TEST_MODE: mode,
      KPI_CLOCK_TEST_DATE_LOG: dateLog,
      KPI_CLOCK_TEST_RUNNER_LOG: runnerLog,
    });
    const result = spawnSync("bash", [script, stage, input], {
      env, encoding: "utf8", timeout: 30_000,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    const output = result.stdout + result.stderr;
    assert.equal(existsSync(work), false, "temporary KPI work must be removed on every exit");
    const invocation = readFileSync(runnerLog, "utf8").trimEnd().split("\n");
    assert.deepEqual(invocation, [root, "1", "raw", "1", join(work, "cache"),
      "--invoke", "cli_main", stage, input, join(work, "out.wasm"), "__no_entry__"]);
    return {
      status: result.status, output,
      usedRealtimeClock: existsSync(dateLog),
      metrics: /wall_ms=(-?\d+) heap_ptr_bytes=(\d+) mem_pages=(\d+)/.exec(output),
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

for (const backend of ["linux", "node"]) {
  const options = { skip: backend === "linux" && process.platform !== "linux" };
  test(`${backend}: a backwards realtime clock cannot bypass the advisory time gate`, options, () => {
    const result = runKpi(backend, "ok", { VIBE_KPI_MAX_WALL_MS: "1" });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /GATE FAIL: wall_ms/);
    assert.ok(result.metrics, result.output);
    assert.ok(Number(result.metrics[1]) >= 20, result.output);
    assert.equal(result.usedRealtimeClock, false);
    assert.deepEqual(result.metrics.slice(2), ["12345", "2"]);
  });

  test(`${backend}: positive metrics and heap gating survive clock changes`, options, () => {
    const plain = runKpi(backend, "ok");
    assert.equal(plain.status, 0, plain.output);
    assert.ok(plain.metrics, plain.output);
    assert.ok(Number(plain.metrics[1]) >= 20, plain.output);
    assert.deepEqual(plain.metrics.slice(2), ["12345", "2"]);
    assert.equal(plain.usedRealtimeClock, false);
    const gated = runKpi(backend, "ok", { VIBE_KPI_MAX_HEAP_BYTES: "12344" });
    assert.equal(gated.status, 1, gated.output);
    assert.match(gated.output, /GATE FAIL: heap_ptr_bytes 12345/);
    assert.ok(gated.metrics, gated.output);
    assert.deepEqual(gated.metrics.slice(2), ["12345", "2"]);
  });

  test(`${backend}: runner failure preserves its exit status and cleanup`, options, () => {
    const result = runKpi(backend, "runner-failure");
    assert.equal(result.status, 23, result.output);
    assert.equal(result.metrics, null);
  });

  test(`${backend}: missing output and missing heap statistics fail closed`, options, () => {
    const output = runKpi(backend, "missing-output");
    assert.equal(output.status, 1, output.output);
    assert.match(output.output, /compile produced no output wasm/);
    assert.equal(output.metrics, null);
    const stats = runKpi(backend, "missing-stats");
    assert.equal(stats.status, 1, stats.output);
    assert.match(stats.output, /no \[wasm-memory\] heap_ptr/);
    assert.equal(stats.metrics, null);
  });
}
