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
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { parseIngestionFingerprintTelemetry } from "./edit_cycle_kpi.mjs";
import {
  compareSuccessfulIncrementalInvalidationTraces,
  parseIncrementalInvalidationTrace,
} from "./incremental_invalidation_oracle.mjs";

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
    const gateOffCache = join(work, "gate-off-cache");
    const gateOnCache = join(work, "gate-on-cache");
    mkdirSync(pkg);
    mkdirSync(gateOffCache);
    mkdirSync(gateOnCache);
    // Real package files (not a hand-written synthetic contract) ensure this
    // keeps following the production index.vpkg member path. Everything below
    // mutates only this temporary copy, never a tracked fixture.
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
          VIBE_BUILD_CACHE_DIR: gateOffCache,
          VIBE_INGESTION_TELEMETRY_OUT: sidecar,
          ...extraEnv,
        },
      });
      assert.notEqual(result.status, 0, `${name} request must fail`);
      assert.ok(!existsSync(sidecar), `${name} request must remove stale sidecar before failing`);
    }

    function check(name, { stampEnabled, cacheDir }) {
      const out = join(work, `${name}.out`);
      const telemetryPath = join(work, `${name}.ingestion.json`);
      const tracePath = join(work, `${name}.invalidation.json`);
      const telemetryNonce = `ingestion-stamp-telemetry-${name}`;
      const traceNonce = `ingestion-stamp-trace-${name}`;
      // Both compiler-owned successful-only sidecars begin stale. Expected
      // nonces make an accidental prior observation unable to satisfy this run.
      writeFileSync(telemetryPath, "stale ingestion observation");
      writeFileSync(tracePath, "stale invalidation observation");
      const result = spawnSync(runner, ["--invoke", "cli_main", stage2, input, out, ""], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_PREOPEN_DIR: root,
          VIBE_CHECK_ONLY: "1",
          VIBE_BUILD_CACHE_DIR: cacheDir,
          VIBE_INGESTION_TELEMETRY_OUT: telemetryPath,
          VIBE_INGESTION_TELEMETRY_NONCE: telemetryNonce,
          VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: tracePath,
          VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: traceNonce,
          VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP: stampEnabled ? "1" : "",
        },
      });
      if (result.status !== 0) fail(`ingestion-stamp-oracle: ${name} check failed`, result);
      if (!existsSync(out) || !existsSync(telemetryPath) || !existsSync(tracePath)) {
        fail(`ingestion-stamp-oracle: ${name} omitted output or requested sidecar`, result);
      }
      return {
        outputBytes: readFileSync(out),
        outputText: readFileSync(out, "utf8"),
        telemetry: parseIngestionFingerprintTelemetry(readFileSync(telemetryPath, "utf8"), telemetryNonce, `${name} telemetry`),
        trace: parseIncrementalInvalidationTrace(readFileSync(tracePath, "utf8"), traceNonce),
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

    // The two cache directories start from the same copied package and each
    // sees exactly a prime followed by a warm check; only the opt-in differs.
    const gateOffPrime = check("gate-off-prime", { stampEnabled: false, cacheDir: gateOffCache });
    const gateOffWarm = check("gate-off-warm", { stampEnabled: false, cacheDir: gateOffCache });
    const gateOnPrime = check("gate-on-prime", { stampEnabled: true, cacheDir: gateOnCache });
    const gateOnWarm = check("gate-on-warm", { stampEnabled: true, cacheDir: gateOnCache });
    assert.equal(gateOffPrime.outputText, "ok\n", "gate-off prime checker result");
    assert.equal(gateOffWarm.outputText, gateOffPrime.outputText, "gate-off warm checker result");
    assert.equal(gateOnPrime.outputText, gateOffPrime.outputText, "gate-on prime checker result");
    assert.equal(gateOnWarm.outputText, gateOffPrime.outputText, "gate-on warm checker result");
    assert.equal(gateOffWarm.telemetry.stamp_probes, 0, "gate-off warm must not probe stamps");
    assert.equal(gateOffWarm.telemetry.source_read_calls, 1, "gate-off warm must read once at the fingerprint boundary");
    assert.equal(gateOffWarm.telemetry.hash_calls, 1, "gate-off warm must hash once at the fingerprint boundary");
    assert.ok(gateOnPrime.telemetry.stamp_publications > 0, "gate-on prime must publish");
    assert.ok(gateOnWarm.telemetry.stamp_hits >= 1, "gate-on warm must hit a stamp");
    assert.equal(gateOnWarm.telemetry.source_read_calls, 0, "gate-on warm must eliminate fingerprint-boundary source reads");
    assert.equal(gateOnWarm.telemetry.hash_calls, 0, "gate-on warm must eliminate fingerprint-boundary hashes");
    assert.deepEqual(gateOnWarm.outputBytes, gateOffWarm.outputBytes, "gate-off/on warm output bytes");
    assert.equal(gateOnWarm.outputText, gateOffWarm.outputText, "gate-off/on warm output text");
    compareSuccessfulIncrementalInvalidationTraces(gateOffWarm.trace, gateOnWarm.trace);

    // The package contract stays byte-for-byte identical, but its trusted stat
    // token changes. A stamp miss must fall back to source/hash work without
    // changing observed successful-check semantics from the prior warm run.
    const contract = join(pkg, "index.vpkg");
    const contractBytes = readFileSync(contract);
    const oldMtimeMs = statSync(contract).mtimeMs;
    utimesSync(contract, 2_000_000_000, 2_000_000_000);
    assert.deepEqual(readFileSync(contract), contractBytes, "metadata-only case must not change contract bytes");
    assert.notEqual(statSync(contract).mtimeMs, oldMtimeMs, "metadata-only case must change the stat token");
    const metadataChanged = check("metadata-changed", { stampEnabled: true, cacheDir: gateOnCache });
    assert.ok(metadataChanged.telemetry.stamp_misses > 0, "metadata-only token change must miss the stamp");
    assert.ok(metadataChanged.telemetry.source_read_calls > 0, "metadata-only token change must read source");
    assert.ok(metadataChanged.telemetry.hash_calls > 0, "metadata-only token change must hash source");
    assert.deepEqual(metadataChanged.outputBytes, gateOnWarm.outputBytes, "metadata-only output bytes");
    assert.equal(metadataChanged.outputText, gateOnWarm.outputText, "metadata-only output text");
    compareSuccessfulIncrementalInvalidationTraces(gateOnWarm.trace, metadataChanged.trace);

    const stampName = readdirSync(gateOnCache).find((name) => name.startsWith("vibe_selfhost_ingestion_stamp_v1_"));
    assert.ok(stampName, "gate-on prime must create the dedicated ingestion stamp namespace entry");
    writeFileSync(join(gateOnCache, stampName), "v1\\t1\\t0not-a-fingerprint");
    const malformed = check("malformed", { stampEnabled: true, cacheDir: gateOnCache });
    assert.ok(malformed.telemetry.stamp_malformed > 0, "malformed stamp must fail closed");
    assert.ok(malformed.telemetry.source_read_calls > 0 && malformed.telemetry.hash_calls > 0 && malformed.telemetry.stamp_publications > 0, "malformed stamp must re-read/hash and republish");

    // A content token change is also a miss even if the source edit is non-semantic.
    writeFileSync(contract, `${readFileSync(contract, "utf8")}\n// token-change oracle\n`);
    const tokenChanged = check("token-changed", { stampEnabled: true, cacheDir: gateOnCache });
    assert.ok(tokenChanged.telemetry.stamp_misses > 0 && tokenChanged.telemetry.stamp_hits === 0, "changed stat token must not reuse a stamp");
    assert.ok(tokenChanged.telemetry.source_read_calls > 0 && tokenChanged.telemetry.hash_calls > 0, "changed token must read/hash source");
    console.log(JSON.stringify({
      gate_off_prime: gateOffPrime.telemetry,
      gate_off_warm: gateOffWarm.telemetry,
      gate_on_prime: gateOnPrime.telemetry,
      gate_on_warm: gateOnWarm.telemetry,
      metadata_changed: metadataChanged.telemetry,
      malformed: malformed.telemetry,
      token_changed: tokenChanged.telemetry,
    }));
  } finally {
    if (process.env.VIBE_INGESTION_STAMP_KEEP_TMP === "1") {
      console.error(`ingestion-stamp-oracle: kept ${work}`);
    } else {
      rmSync(work, { recursive: true, force: true });
    }
  }
}

main();
