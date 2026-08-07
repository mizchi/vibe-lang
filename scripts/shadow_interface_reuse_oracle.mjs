#!/usr/bin/env node
// #1548 isolated cross-process oracle for the shadow interface-reuse
// observation lane.
//
//   node scripts/shadow_interface_reuse_oracle.mjs <stage2.wasm>
//
// The lane is observation-only: it records, per module the check walk
// settles, what an exported-interface-keyed reuse policy WOULD have decided
// beside the actual production decision. This oracle proves the sidecar's
// strict request discipline (nonce, stale deletion, trace-lane rejection,
// publish-after-success), the decision rows across the bounded edit matrix —
// including the #1442 asymmetry where a dependency impl-bound edit misses
// TDRE4 but hits the interface-keyed shadow — and fail-closed observation of
// malformed shadow records. It asserts equal check outputs with the lane off
// and on, and never claims a production reuse change.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scopeNote = "shadow decisions derive from the exported-interface observation identity; they are recorded alongside, and never influence, the production reuse decision; missing or malformed shadow state observes as miss; leaf-fingerprint short-circuited modules are outside this observation";
const productionDecisions = new Set(["rechecked", "reused_conservative", "reused_dependency_transport_alias"]);
const shadowDecisions = new Set(["hit", "miss"]);

function fail(message) {
  throw new Error(`shadow-interface-reuse-oracle: ${message}`);
}

/// Strict parse of the successful-check shadow sidecar.
export function parseShadowInterfaceReuseTrace(text, expectedNonce) {
  let trace;
  try {
    trace = JSON.parse(text);
  } catch (error) {
    fail(`invalid JSON (${error.message})`);
  }
  if (!trace || typeof trace !== "object" || Array.isArray(trace)) fail("expected object");
  const keys = Object.keys(trace).sort();
  if (JSON.stringify(keys) !== JSON.stringify(["modules", "run_nonce", "schema", "scope_note", "version"])) fail("unexpected trace keys");
  if (trace.schema !== "shadow-interface-reuse-trace") fail(`unsupported schema ${JSON.stringify(trace.schema)}`);
  if (trace.version !== 1) fail(`unsupported version ${JSON.stringify(trace.version)}`);
  if (typeof trace.run_nonce !== "string" || trace.run_nonce.length === 0) fail("missing run_nonce");
  if (expectedNonce !== undefined && trace.run_nonce !== expectedNonce) fail("run_nonce mismatch (stale sidecar)");
  if (trace.scope_note !== scopeNote) fail("dishonest scope_note");
  if (!Array.isArray(trace.modules) || trace.modules.length === 0) fail("missing modules");
  const paths = new Set();
  for (const row of trace.modules) {
    if (!row || typeof row !== "object" || Array.isArray(row)) fail("invalid module row");
    const rowKeys = Object.keys(row).sort();
    if (JSON.stringify(rowKeys) !== JSON.stringify(["path", "production_decision", "shadow_decision", "shadow_input_fingerprint"])) fail("unexpected module row keys");
    if (typeof row.path !== "string" || row.path.length === 0 || paths.has(row.path)) fail("invalid or duplicate module path");
    paths.add(row.path);
    if (!productionDecisions.has(row.production_decision)) fail(`invalid production decision for ${row.path}`);
    if (!shadowDecisions.has(row.shadow_decision)) fail(`invalid shadow decision for ${row.path}`);
    if (typeof row.shadow_input_fingerprint !== "string" || row.shadow_input_fingerprint.length === 0) fail(`missing shadow input fingerprint for ${row.path}`);
  }
  return trace;
}

function decisionsByName(trace) {
  return Object.fromEntries(trace.modules.map((row) => [basename(row.path).replace(/\.vibe$/, ""), [row.production_decision, row.shadow_decision]]));
}

function assertDecisions(name, trace, expected) {
  const actual = decisionsByName(trace);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`${name} decision drift: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function listShadowRecords(cacheDir) {
  if (!existsSync(cacheDir)) return [];
  const out = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.includes("selfhost_shadow_interface_reuse_v1")) out.push(full);
    }
  };
  walk(cacheDir);
  return out;
}

function run(stage2) {
  const invoke = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  if (![stage2, invoke].every(existsSync)) fail("missing stage2 compiler or node host runner");
  const work = mkdtempSync(join(tmpdir(), "vibe-shadow-interface-reuse-"));
  const project = join(work, "project");
  const cache = join(work, "cache");
  try {
    mkdirSync(project, { recursive: true });
    // Three modules: base is import-less, so warm runs short-circuit it on
    // its persistent leaf fingerprint — the documented observation exclusion.
    // library imports base, so it stays inside finish_typecheck_fs_impl (and
    // this observation) on every run.
    const writeLibrary = (body) => writeFileSync(join(project, "library.vibe"), body);
    const baseLibrary = 'import ./base.vibe { base_value }\nexport trait Identity { identity[U: Eq](U) -> U }\nimpl [T: Eq] Eq for Option[T]\nexport fn library_value(x: Int) -> Int { base_value(x) + private_offset() }\nfn private_offset() -> Int { 1 }\n';
    writeFileSync(join(project, "base.vibe"), "export fn base_value(x: Int) -> Int { x + 1 }\n");
    writeLibrary(baseLibrary);
    writeFileSync(join(project, "app.vibe"), "import ./library.vibe { library_value }\nfn main() -> Int { library_value(41) }\n");

    const runCheck = (name, { nonce, out = `${name}.shadow.json`, extraEnv = {}, expectFailure = false, entry = "app.vibe", cacheDir } = {}) => {
      const checkOut = `${name}.check.out`;
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, entry, checkOut], {
        cwd: project,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_BUILD_CACHE_DIR: cacheDir ?? cache,
          VIBE_CHECK_ONLY: "1",
          VIBE_IMPORT_ABI: "raw",
          VIBE_HOME: join(work, "home"),
          VIBE_PREOPEN_DIR: project,
          ...(out === null ? {} : {
            VIBE_SHADOW_INTERFACE_REUSE_TRACE_OUT: out,
            ...(nonce === null ? {} : { VIBE_SHADOW_INTERFACE_REUSE_TRACE_NONCE: nonce ?? `nonce-${name}` }),
          }),
          ...extraEnv,
        },
      });
      const checkText = existsSync(join(project, checkOut)) ? readFileSync(join(project, checkOut), "utf8") : "";
      const succeeded = result.status === 0 && checkText === "ok\n";
      if (expectFailure) {
        if (succeeded) fail(`${name} unexpectedly succeeded`);
        if (out !== null && existsSync(join(project, out))) fail(`${name} published a sidecar for a failed check`);
        return { checkText };
      }
      if (!succeeded) fail(`${name} check failed: ${(result.stderr || result.stdout || checkText).trim()}`);
      if (out === null) return { checkText };
      const sidecarPath = join(project, out);
      if (!existsSync(sidecarPath)) fail(`${name} sidecar missing after successful check`);
      return { checkText, trace: parseShadowInterfaceReuseTrace(readFileSync(sidecarPath, "utf8"), nonce ?? `nonce-${name}`) };
    };

    // Baseline output parity: two cold runs over the same sources, lane off
    // (isolated control cache) and lane on, must produce identical check
    // output text.
    const offBaseline = runCheck("off_baseline", { out: null, cacheDir: join(work, "cache-off") });
    const cold = runCheck("cold");
    if (offBaseline.checkText !== cold.checkText) fail("lane-on check output diverged from lane-off");
    assertDecisions("cold", cold.trace, {
      base: ["rechecked", "miss"],
      library: ["rechecked", "miss"],
      app: ["rechecked", "miss"],
    });

    // Warm: base short-circuits on its leaf fingerprint and is absent from
    // the observation; library and app agree on reuse in both policies.
    const warm = runCheck("warm_no_op");
    assertDecisions("warm_no_op", warm.trace, {
      library: ["reused_conservative", "hit"],
      app: ["reused_conservative", "hit"],
    });

    // Private dependency body edit: production reuses the consumer through
    // the TDRE4 transport alias; the interface-keyed shadow agrees.
    writeLibrary(baseLibrary.replace("private_offset() -> Int { 1 }", "private_offset() -> Int { 2 }"));
    const privateEdit = runCheck("private_body_edit");
    assertDecisions("private_body_edit", privateEdit.trace, {
      library: ["rechecked", "miss"],
      app: ["reused_dependency_transport_alias", "hit"],
    });

    // The #1442 asymmetry this experiment exists to measure: an impl-bound
    // edit changes the dependency's TypeEnv-v3 transport (TDRE4 miss, consumer
    // rechecked) while preserving its exported-interface identity (shadow hit).
    writeLibrary(baseLibrary.replace("private_offset() -> Int { 1 }", "private_offset() -> Int { 2 }").replace("impl [T: Eq] Eq for Option[T]", "impl [T: Show] Eq for Option[T]"));
    const implBoundEdit = runCheck("impl_bound_edit");
    assertDecisions("impl_bound_edit", implBoundEdit.trace, {
      library: ["rechecked", "miss"],
      app: ["rechecked", "hit"],
    });

    // Public interface edit: the consumer's shadow key changes with the
    // dependency interface fingerprint — both policies agree on recheck.
    const publicEditLibrary = baseLibrary.replace("private_offset() -> Int { 1 }", "private_offset() -> Int { 2 }").replace("impl [T: Eq] Eq for Option[T]", "impl [T: Show] Eq for Option[T]").replace("library_value(x: Int) -> Int { base_value(x) + private_offset() }", 'library_value(x: Int) -> String { let _ = base_value(private_offset())\n"changed" }');
    if (publicEditLibrary === baseLibrary || !publicEditLibrary.includes("-> String")) fail("public interface edit fixture did not change the library source");
    writeLibrary(publicEditLibrary);
    writeFileSync(join(project, "app.vibe"), "import ./library.vibe { library_value }\nfn main() -> Int { let _ = library_value(41)\n0 }\n");
    const publicEdit = runCheck("public_interface_edit");
    assertDecisions("public_interface_edit", publicEdit.trace, {
      library: ["rechecked", "miss"],
      app: ["rechecked", "miss"],
    });

    // Settle a warm hit state, then corrupt every shadow record: fail-closed
    // observation means miss rows while production reuse stays untouched.
    const settled = runCheck("settled_warm");
    assertDecisions("settled_warm", settled.trace, {
      library: ["reused_conservative", "hit"],
      app: ["reused_conservative", "hit"],
    });
    const records = listShadowRecords(cache);
    if (records.length === 0) fail("no shadow records were published under the isolated cache");
    for (const record of records) writeFileSync(record, "SHIF1corrupted");
    const corrupted = runCheck("corrupted_records");
    assertDecisions("corrupted_records", corrupted.trace, {
      library: ["reused_conservative", "miss"],
      app: ["reused_conservative", "miss"],
    });
    // The corrupted run republished valid records: the next run hits again.
    const republished = runCheck("republished");
    assertDecisions("republished", republished.trace, {
      library: ["reused_conservative", "hit"],
      app: ["reused_conservative", "hit"],
    });

    // Request discipline: a missing nonce fails the check before any walk...
    runCheck("missing_nonce", { nonce: null, expectFailure: true });
    // ...combining with the invalidation trace lane is rejected...
    runCheck("trace_lane_combination", {
      extraEnv: {
        VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: "combined.trace.json",
        VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "combined-nonce",
      },
      expectFailure: true,
    });
    // ...and a failed check deletes a stale requested sidecar and publishes
    // nothing (the sidecar name matches an earlier successful run's).
    writeFileSync(join(project, "broken.vibe"), "fn main( -> Int { 0 }\n");
    runCheck("settled_warm", { entry: "broken.vibe", expectFailure: true });

    console.log(JSON.stringify({
      schema: 1,
      scenario: "shadow-interface-reuse-observation",
      cases: [
        "off_baseline", "cold", "warm_no_op", "private_body_edit", "impl_bound_edit",
        "public_interface_edit", "settled_warm", "corrupted_records", "republished",
        "missing_nonce", "trace_lane_combination", "failed_check_stale_removal",
      ],
      impl_bound_divergence: decisionsByName(implBoundEdit.trace),
      corrupted_record_count: records.length,
    }));
  } finally {
    if (process.env.VIBE_SHADOW_INTERFACE_ORACLE_KEEP_TMP === "1") console.error(`shadow-interface-reuse-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) fail("usage: shadow_interface_reuse_oracle.mjs <stage2.wasm>");
  const stage2 = isAbsolute(process.argv[2]) ? process.argv[2] : resolve(process.cwd(), process.argv[2]);
  run(stage2);
}
