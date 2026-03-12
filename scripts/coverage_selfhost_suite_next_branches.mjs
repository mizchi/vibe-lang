#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const branchFocusedExtraEntries = [
  "vibe/compiler/eval_e2e_test.vibe",
  "vibe/compiler/fixture_test.vibe",
  "vibe/compiler/eval_selfhost_test.vibe",
  "vibe/compiler/eval_selfhost2_test.vibe",
  "vibe/compiler/eval_selfhost3_test.vibe",
  "vibe/compiler/lexer_test.vibe",
  "vibe/compiler/printer_test.vibe",
  "vibe/compiler/eval_builtins_test.vibe",
  "vibe/compiler/checker_test.vibe",
];

function usage() {
  console.error(
    "usage: coverage_selfhost_suite_next_branches.mjs [report.json] [--format text|env|json] [--preset branch]",
  );
}

export function parseArgs(argv) {
  let reportPath = "_build/coverage/selfhost-suite/selfhost_suite.report.json";
  let format = "text";
  let preset = null;
  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--preset") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --preset");
      }
      preset = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg === "--format") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --format");
      }
      format = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg.startsWith("--")) {
      throw new Error(`unknown option: ${arg}`);
    }
    reportPath = arg;
    i += 1;
  }
  if (!["text", "env", "json"].includes(format)) {
    throw new Error(`invalid format: ${format} (expected text|env|json)`);
  }
  if (preset !== null && preset !== "branch") {
    throw new Error(`invalid preset: ${preset} (expected branch)`);
  }
  return { reportPath, format, preset };
}

export function presetExtraEntries(preset) {
  if (preset === "branch") {
    return [...branchFocusedExtraEntries];
  }
  if (preset === null || preset === undefined || preset === "") {
    return [];
  }
  throw new Error(`invalid preset: ${preset}`);
}

export function computeNextBranchEntries(report) {
  const caseSet = new Set(
    Array.isArray(report?.cases)
      ? report.cases
          .map((item) => item?.entry_path)
          .filter((value) => typeof value === "string" && value.length > 0)
      : [],
  );
  return branchFocusedExtraEntries.filter((entryPath) => !caseSet.has(entryPath));
}

export function topBranchGaps(report) {
  if (!Array.isArray(report?.top_branch_gaps)) {
    return [];
  }
  return report.top_branch_gaps.filter(
    (item) =>
      item &&
      typeof item.entry_path === "string" &&
      typeof item.branch_miss === "number" &&
      typeof item.branch_total === "number" &&
      typeof item.branch_hit === "number",
  );
}

export function topNonAggregateBranchGaps(report) {
  if (!Array.isArray(report?.top_non_aggregate_branch_gaps)) {
    return [];
  }
  return report.top_non_aggregate_branch_gaps.filter(
    (item) =>
      item &&
      typeof item.entry_path === "string" &&
      typeof item.branch_miss === "number" &&
      typeof item.branch_total === "number" &&
      typeof item.branch_hit === "number",
  );
}

export function buildTextReport(report, reportPath) {
  const nextEntries = computeNextBranchEntries(report);
  const gaps = topBranchGaps(report);
  const nonAggregateGaps = topNonAggregateBranchGaps(report);
  const lines = [];
  lines.push("selfhost suite next branch targets");
  lines.push(`report: ${reportPath}`);
  if (gaps.length > 0) {
    lines.push("top_branch_gaps:");
    for (const gap of gaps) {
      lines.push(
        `- ${gap.entry_path} ${gap.branch_miss} missed (${gap.branch_hit}/${gap.branch_total})`,
      );
    }
  }
  if (nonAggregateGaps.length > 0) {
    lines.push("top_non_aggregate_branch_gaps:");
    for (const gap of nonAggregateGaps) {
      lines.push(
        `- ${gap.entry_path} ${gap.branch_miss} missed (${gap.branch_hit}/${gap.branch_total})`,
      );
    }
  }
  lines.push(
    `suggested_extra_entries: ${nextEntries.length > 0 ? nextEntries.join(",") : "(none)"}`,
  );
  if (nextEntries.length > 0) {
    lines.push(
      `run_env: VIBE_SELFHOST_SUITE_EXTRA_ENTRIES='${nextEntries.join(",")}'`,
    );
  }
  return lines.join("\n") + "\n";
}

export function buildJsonReport(report, reportPath) {
  return JSON.stringify(
    {
      report_path: reportPath,
      top_branch_gaps: topBranchGaps(report),
      top_non_aggregate_branch_gaps: topNonAggregateBranchGaps(report),
      suggested_extra_entries: computeNextBranchEntries(report),
    },
    null,
    2,
  );
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.preset !== null) {
    const entries = presetExtraEntries(args.preset);
    if (args.format === "env") {
      process.stdout.write(entries.join(","));
      return;
    }
    if (args.format === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            preset: args.preset,
            extra_entries: entries,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }
    process.stdout.write(
      `preset: ${args.preset}\nextra_entries: ${entries.join(",")}\n`,
    );
    return;
  }
  const reportPath = path.resolve(args.reportPath);
  if (!fs.existsSync(reportPath)) {
    throw new Error(`report not found: ${reportPath}`);
  }
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  if (args.format === "env") {
    process.stdout.write(computeNextBranchEntries(report).join(","));
    return;
  }
  if (args.format === "json") {
    process.stdout.write(buildJsonReport(report, reportPath) + "\n");
    return;
  }
  process.stdout.write(buildTextReport(report, reportPath));
}

const isCliEntry =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isCliEntry) {
  try {
    main();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    usage();
    console.error(`[coverage_selfhost_suite_next_branches] ${message}`);
    process.exit(1);
  }
}
