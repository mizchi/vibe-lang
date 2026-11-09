#!/usr/bin/env node
// The compile-only size budget (#2506), and the build receipt it is read from.
//
//   node scripts/compile_only_size_budget.mjs receipt --artifact W --compiler W
//        --module-source F --fingerprint FP [--names 0|1] [--root DIR]
//     writes <W>.receipt.json for an artifact scripts/build_compile_only.sh
//     just produced
//   node scripts/compile_only_size_budget.mjs check --stage2 W --artifact W
//        --fingerprint FP [--baseline F] [--print] [--root DIR]
//     checks provenance of both artifacts, then the budget (or, with --print,
//     prints the measurement as baseline lines)
//
// WHAT IS BUDGETED. The compile-only artifact may be at most
//     (stripped bytes of the full CLI stage2 built from the same source)
//     - separation_bytes * (100 - tolerance_pct) / 100
// i.e. what the compile-only entry leaves out of the CLI must not shrink.
// Compiler growth is in both artifacts and cancels; CLI-only growth only
// widens the separation. So neither can fail this, and the full CLI stays
// observation-only (#1109-4): it is read as the reference, never capped.
// What fails is code the CLI carries becoming reachable from
// `main_compile_only` -- the regression the compile-only artifact exists to
// prevent. The absolute compile-only bytes are reported, not capped: measured,
// the compiler grows ~2.8% between two seed bumps (~100 commits), so an
// absolute cap would fight ordinary development exactly as #1109-4 records.
//
// PROVENANCE. A size read from the wrong artifact is a number about something
// else, so every mismatch is a refusal, never a warning:
//   - the CLI stage2 must match its generation receipt, and that generation's
//     input must be this checkout's generated module source
//     (compiler_size_metrics.mjs, the series #3646 already records);
//   - the compile-only artifact must match its build receipt, be built BY that
//     same stage2, from generated sources with this checkout's
//     ensure_generated fingerprint, by this checkout's build_compile_only.sh.
// The name section is removed before measuring, so the named artifact the
// lanes gate builds and the plain one measure the same.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { collectCompilerSize, withoutNames, tool } from "./compiler_size_metrics.mjs";

const scripts = dirname(fileURLToPath(import.meta.url));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const KIND = "vibe-compile-only-artifact";
const BUILDER = "scripts/build_compile_only.sh";

export const receiptPath = (artifact) => `${artifact}.receipt.json`;

export function writeReceipt({ artifact, compiler, moduleSource, fingerprint, names, root }) {
  root = resolve(root || resolve(scripts, ".."));
  if (!/^[0-9a-f]{64}$/.test(fingerprint || "")) throw new Error("receipt needs the ensure_generated fingerprint");
  const bytes = readFileSync(artifact);
  const receipt = {
    schema: 1, kind: KIND,
    artifact_sha256: hash(bytes), artifact_bytes: bytes.length, names: names === "1",
    compiler_sha256: hash(readFileSync(compiler)),
    module_source_sha256: hash(readFileSync(moduleSource)),
    generated_fingerprint: fingerprint,
    builder_sha256: hash(readFileSync(resolve(root, BUILDER))),
  };
  writeFileSync(receiptPath(artifact), `${JSON.stringify(receipt, null, 2)}\n`);
  return receipt;
}

// Every way the artifact can fail to be the one this checkout and this CLI
// would produce, each with the edit that fixes it.
export function verifyReceipt({ artifact, bytes, compilerSha, fingerprint, root }) {
  root = resolve(root || resolve(scripts, ".."));
  const rebuild = `rebuild it: bash ${BUILDER} --names --out ${artifact} --compiler <the stage2 being compared>`;
  const path = receiptPath(artifact);
  if (!existsSync(path)) throw new Error(`${artifact} has no build receipt (${path}); ${rebuild}`);
  let receipt;
  try { receipt = JSON.parse(readFileSync(path, "utf8")); } catch { throw new Error(`${path} is not JSON; ${rebuild}`); }
  if (receipt.schema !== 1 || receipt.kind !== KIND) throw new Error(`${path} is not a compile-only build receipt; ${rebuild}`);
  if (receipt.artifact_sha256 !== hash(bytes) || receipt.artifact_bytes !== bytes.length) {
    throw new Error(`${artifact} does not match its build receipt (the file changed after the build); ${rebuild}`);
  }
  if (receipt.compiler_sha256 !== compilerSha) {
    throw new Error(`${artifact} was built by compiler ${receipt.compiler_sha256}, not by the stage2 it is compared with (${compilerSha}); ${rebuild}`);
  }
  if (receipt.generated_fingerprint !== fingerprint) {
    throw new Error(`${artifact} was built from generated sources ${receipt.generated_fingerprint}, but this checkout's are ${fingerprint}; ${rebuild}`);
  }
  if (receipt.builder_sha256 !== hash(readFileSync(resolve(root, BUILDER)))) {
    throw new Error(`${artifact} was built by another ${BUILDER}; ${rebuild}`);
  }
  return receipt;
}

export function measure({ stage2, artifact, fingerprint, root }) {
  const cli = collectCompilerSize({ stage2, root });
  const bytes = readFileSync(artifact);
  const receipt = verifyReceipt({ artifact, bytes, compilerSha: cli.artifact_sha256, fingerprint, root });
  const stripped = withoutNames(bytes);
  const sections = tool("wasm_section_sizes.mjs", stripped)[0];
  if (!sections.funcs || !sections.sections.code) throw new Error(`${artifact} defines no functions`);
  return {
    source_commit: cli.source.commit, build_tree_dirty: cli.source.build_tree_dirty,
    generated_fingerprint: fingerprint,
    cli_sha256: cli.artifact_sha256, compile_only_sha256: hash(stripped), compile_only_names: receipt.names,
    cli_bytes: cli.stripped_bytes, compile_only_bytes: stripped.length,
    separation_bytes: cli.stripped_bytes - stripped.length,
    cli_code_section_bytes: cli.code_section_bytes, compile_only_code_section_bytes: sections.sections.code,
    cli_functions: cli.defined_functions, compile_only_functions: sections.funcs,
  };
}

export function readBaseline(path) {
  const values = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const text = line.trim();
    if (!text || text.startsWith("#")) continue;
    const fields = text.split(/\s+/);
    if (fields.length !== 2 || !/^[0-9]+$/.test(fields[1])) throw new Error(`${path}: malformed line '${text}' (expected '<key> <integer>')`);
    if (fields[0] in values) throw new Error(`${path}: duplicate key ${fields[0]}`);
    values[fields[0]] = Number(fields[1]);
  }
  for (const key of ["separation_bytes", "tolerance_pct"]) {
    if (!(key in values)) throw new Error(`${path}: no ${key} entry`);
  }
  if (values.separation_bytes <= 0) throw new Error(`${path}: separation_bytes must be positive`);
  if (values.tolerance_pct >= 100) throw new Error(`${path}: tolerance_pct must be below 100`);
  return values;
}

// The verdict: { ok, floor, lines } -- lines are what the gate prints.
export function judge(measured, baseline) {
  const floor = Math.floor(baseline.separation_bytes * (100 - baseline.tolerance_pct) / 100);
  const cap = measured.cli_bytes - floor;
  const lines = [
    `compile-only ${measured.compile_only_bytes} B (${measured.compile_only_functions} functions), ` +
      `CLI ${measured.cli_bytes} B (${measured.cli_functions} functions), separation ${measured.separation_bytes} B`,
  ];
  if (measured.separation_bytes < floor) {
    lines.push(`FAIL: the compile-only artifact is ${measured.compile_only_bytes} B, over its budget of ${cap} B ` +
      `(CLI ${measured.cli_bytes} B - separation floor ${floor} B = baseline ${baseline.separation_bytes} B - ${baseline.tolerance_pct}%): ` +
      `${floor - measured.separation_bytes} B that only the full CLI carried are now reachable from main_compile_only. ` +
      `Find them by diffing 'node scripts/wasm_func_sizes.mjs <artifact> --top 1000000' of the named compile-only artifact ` +
      `against the previous one, and keep them out of main_compile_only; if the CLI itself shrank on purpose ` +
      `(code moved out of the CLI, #2499/#2504), rebaseline with --print.`);
    return { ok: false, floor, lines };
  }
  const ceiling = Math.floor(baseline.separation_bytes * (100 + baseline.tolerance_pct) / 100);
  if (measured.separation_bytes > ceiling) {
    lines.push(`NOTE: separation grew past baseline + ${baseline.tolerance_pct}% (${measured.separation_bytes} > ${ceiling} B); ` +
      `ratchet bench/perf/compile_only_size_baseline.txt up with --print so the gain is protected.`);
  }
  lines.push(`ok: compile-only within budget (${cap} B; floor ${floor} B, margin ${measured.separation_bytes - floor} B)`);
  return { ok: true, floor, lines };
}

function parse(args, allowed) {
  const options = {};
  while (args.length) {
    const flag = args.shift();
    if (flag === "--print") { options.print = true; continue; }
    if (!allowed[flag] || !args.length) throw new Error(`invalid argument: ${flag}`);
    options[allowed[flag]] = args.shift();
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [verb, ...rest] = process.argv.slice(2);
    const root = resolve(scripts, "..");
    if (verb === "receipt") {
      const o = parse(rest, { "--artifact": "artifact", "--compiler": "compiler", "--module-source": "moduleSource",
        "--fingerprint": "fingerprint", "--names": "names", "--root": "root" });
      for (const key of ["artifact", "compiler", "moduleSource"]) if (!o[key]) throw new Error(`receipt: --${key} is required`);
      writeReceipt({ root, ...o });
    } else if (verb === "check") {
      const o = parse(rest, { "--stage2": "stage2", "--artifact": "artifact", "--fingerprint": "fingerprint",
        "--baseline": "baseline", "--root": "root" });
      for (const key of ["stage2", "artifact", "fingerprint"]) if (!o[key]) throw new Error(`check: --${key} is required`);
      const measured = measure({ root, ...o });
      if (o.print) {
        for (const [key, value] of Object.entries(measured)) console.log(`# ${key} ${value}`);
        console.log(`separation_bytes ${measured.separation_bytes}`);
      } else {
        const verdict = judge(measured, readBaseline(o.baseline || resolve(root, "bench/perf/compile_only_size_baseline.txt")));
        for (const line of verdict.lines) (line.startsWith("FAIL") ? console.error : console.log)(`compile-only-size: ${line}`);
        if (!verdict.ok) process.exitCode = 1;
      }
    } else {
      throw new Error("usage: compile_only_size_budget.mjs receipt|check ... (see the header)");
    }
  } catch (error) {
    console.error(`compile-only-size: FAIL: ${error.message}`);
    process.exitCode = 1;
  }
}
