#!/usr/bin/env node
// #1379 focused cross-process oracle for the metadata-only ingestion stamp.
//
// Usage: node scripts/ingestion_stamp_oracle.mjs <stage2.wasm>
//
// The ordinary two-file edit-cycle fixture does not traverse fingerprint_file_fs
// on an unchanged `vibe check`. This bounded real-package fixture does: checking
// a copied production member under its index.vpkg exercises the shared-import
// prefix validation path without changing normal compiler semantics.

import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { parseIngestionFingerprintTelemetry } from "./edit_cycle_kpi.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");

function fail(message, result) {
  if (result?.stdout) message += `\nstdout: ${result.stdout}`;
  if (result?.stderr) message += `\nstderr: ${result.stderr}`;
  throw new Error(message);
}

function main() {
  const stageArg = process.argv[2];
  if (!stageArg) fail("usage: node scripts/ingestion_stamp_oracle.mjs <stage2.wasm>");
  const stage2 = isAbsolute(stageArg) ? stageArg : resolve(process.cwd(), stageArg);
  for (const path of [stage2, runner, join(root, "lib/@vibe/random/index.vpkg"), join(root, "lib/@vibe/random/random.vibe")]) {
    if (!existsSync(path)) fail(`ingestion-stamp-oracle: missing ${path}`);
  }

  const work = mkdtempSync(join(tmpdir(), "vibe-ingestion-stamp-"));
  try {
    const pkg = join(work, "pkg");
    const cache = join(work, "cache");
    mkdirSync(pkg);
    mkdirSync(cache);
    // Real package files (not a hand-written synthetic contract) ensure this
    // keeps following the production index.vpkg member path.
    cpSync(join(root, "lib/@vibe/random/index.vpkg"), join(pkg, "index.vpkg"));
    cpSync(join(root, "lib/@vibe/random/random.vibe"), join(pkg, "random.vibe"));
    const input = join(pkg, "random.vibe");

    function rejectedRequest(name, extraEnv) {
      const out = join(work, `${name}.out`);
      const sidecar = join(work, `${name}.json`);
      writeFileSync(sidecar, "stale observation");
      const result = spawnSync(runner, ["--invoke", "cli_main", stage2, input, out, ""], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_PREOPEN_DIR: root,
          VIBE_BUILD_CACHE_DIR: cache,
          VIBE_INGESTION_TELEMETRY_OUT: sidecar,
          ...extraEnv,
        },
      });
      assert.notEqual(result.status, 0, `${name} request must fail`);
      assert.ok(!existsSync(sidecar), `${name} request must remove stale sidecar before failing`);
    }

    function check(name, stampEnabled) {
      const out = join(work, `${name}.out`);
      const sidecar = join(work, `${name}.json`);
      const nonce = `ingestion-stamp-${name}`;
      const result = spawnSync(runner, ["--invoke", "cli_main", stage2, input, out, ""], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_PREOPEN_DIR: root,
          VIBE_CHECK_ONLY: "1",
          VIBE_BUILD_CACHE_DIR: cache,
          VIBE_INGESTION_TELEMETRY_OUT: sidecar,
          VIBE_INGESTION_TELEMETRY_NONCE: nonce,
          VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP: stampEnabled ? "1" : "",
        },
      });
      if (result.status !== 0) fail(`ingestion-stamp-oracle: ${name} check failed`, result);
      if (!existsSync(out) || !existsSync(sidecar)) fail(`ingestion-stamp-oracle: ${name} omitted output or sidecar`, result);
      return {
        output: readFileSync(out, "utf8"),
        telemetry: parseIngestionFingerprintTelemetry(readFileSync(sidecar, "utf8"), nonce, `${name} telemetry`),
      };
    }

    rejectedRequest("missing-nonce", { VIBE_CHECK_ONLY: "1" });
    rejectedRequest("control-nonce", {
      VIBE_CHECK_ONLY: "1",
      VIBE_INGESTION_TELEMETRY_NONCE: "bad\u0001nonce",
    });
    rejectedRequest("unsupported-mode", {
      VIBE_CHECK_ONLY: "",
      VIBE_INGESTION_TELEMETRY_NONCE: "unsupported-mode",
    });

    const baseline = check("baseline", false);
    const prime = check("prime", true);
    const warm = check("warm", true);
    assert.equal(baseline.output, "ok\n", "baseline checker result");
    assert.equal(prime.output, baseline.output, "stamp prime checker result");
    assert.equal(warm.output, baseline.output, "stamp warm checker result");
    assert.equal(baseline.telemetry.stamp_probes, 0, "gate-off baseline must not probe stamps");
    assert.equal(baseline.telemetry.source_read_calls, 1, "fixture baseline must read once at the fingerprint boundary");
    assert.equal(baseline.telemetry.hash_calls, 1, "fixture baseline must hash once at the fingerprint boundary");
    assert.ok(prime.telemetry.stamp_publications > 0, "stamp prime must publish");
    assert.ok(warm.telemetry.stamp_hits > 0, "unchanged fresh warm check must hit a stamp");
    assert.equal(warm.telemetry.source_read_calls, 0, "warm stamp must eliminate fingerprint-boundary source reads");
    assert.equal(warm.telemetry.hash_calls, 0, "warm stamp must eliminate fingerprint-boundary hashes");

    const stampName = readdirSync(cache).find((name) => name.startsWith("vibe_selfhost_ingestion_stamp_v1_"));
    assert.ok(stampName, "prime must create the dedicated ingestion stamp namespace entry");
    writeFileSync(join(cache, stampName), "v1\\t1\\t0not-a-fingerprint");
    const malformed = check("malformed", true);
    assert.ok(malformed.telemetry.stamp_malformed > 0, "malformed stamp must fail closed");
    assert.ok(malformed.telemetry.source_read_calls > 0 && malformed.telemetry.stamp_publications > 0, "malformed stamp must re-read/hash and republish");

    // A token change is also a miss even if the source edit is non-semantic.
    const contract = join(pkg, "index.vpkg");
    writeFileSync(contract, `${readFileSync(contract, "utf8")}\n// token-change oracle\n`);
    const tokenChanged = check("token-changed", true);
    assert.ok(tokenChanged.telemetry.stamp_misses > 0 && tokenChanged.telemetry.stamp_hits === 0, "changed stat token must not reuse a stamp");
    assert.ok(tokenChanged.telemetry.source_read_calls > 0, "changed token must read/hash source");
    console.log(JSON.stringify({ baseline: baseline.telemetry, prime: prime.telemetry, warm: warm.telemetry, malformed: malformed.telemetry, token_changed: tokenChanged.telemetry }));
  } finally {
    if (process.env.VIBE_INGESTION_STAMP_KEEP_TMP === "1") {
      console.error(`ingestion-stamp-oracle: kept ${work}`);
    } else {
      rmSync(work, { recursive: true, force: true });
    }
  }
}

main();
