#!/usr/bin/env node

import fs from "node:fs";
import { pathToFileURL } from "node:url";

function usage() {
  console.error(
    "usage: coverage_selfhost_suite.mjs <reports.txt> [--json <report.json>] [--summary <summary.txt>] [--min-point-rate <0-100>] [--min-line-rate <0-100>] [--min-branch-rate <0-100>]",
  );
}

function parseRateOption(rawValue, flagName) {
  const value = Number(rawValue);
  if (!Number.isFinite(value) || value < 0 || value > 100) {
    throw new Error(`invalid value for ${flagName}: ${rawValue} (expected 0-100)`);
  }
  return value;
}

export function parseArgs(argv) {
  if (argv.length < 1) {
    usage();
    process.exit(1);
  }
  const listPath = argv[0];
  let reportJsonPath = "";
  let summaryPath = "";
  let minPointRate = null;
  let minLineRate = null;
  let minBranchRate = null;
  let i = 1;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--json") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --json");
      }
      reportJsonPath = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg === "--summary") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --summary");
      }
      summaryPath = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg === "--min-point-rate") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --min-point-rate");
      }
      minPointRate = parseRateOption(argv[i + 1], "--min-point-rate");
      i += 2;
      continue;
    }
    if (arg === "--min-line-rate") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --min-line-rate");
      }
      minLineRate = parseRateOption(argv[i + 1], "--min-line-rate");
      i += 2;
      continue;
    }
    if (arg === "--min-branch-rate") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --min-branch-rate");
      }
      minBranchRate = parseRateOption(argv[i + 1], "--min-branch-rate");
      i += 2;
      continue;
    }
    throw new Error(`unknown option: ${arg}`);
  }
  return {
    listPath,
    reportJsonPath,
    summaryPath,
    minPointRate,
    minLineRate,
    minBranchRate,
  };
}

function readLineList(path) {
  if (!path || !fs.existsSync(path)) {
    return [];
  }
  const raw = fs.readFileSync(path, "utf8");
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function ratePercent(hit, total) {
  if (total <= 0) {
    return 0;
  }
  return (hit * 100.0) / total;
}

function percentText(hit, total) {
  return ratePercent(hit, total).toFixed(2);
}

function normalizeLineStats(raw, stats) {
  const uniqueLines = Array.isArray(raw?.lines) ? raw.lines : [];
  if (uniqueLines.length <= 0) {
    return {
      line_total: Number(stats.line_total ?? 0),
      line_hit: Number(stats.line_hit ?? 0),
    };
  }
  const measuredLines = uniqueLines.filter((line) => line?.excluded !== true);
  return {
    line_total: measuredLines.length,
    line_hit: measuredLines.filter((line) => line?.hit === true).length,
  };
}

export function buildSuiteReport(reportPaths) {
  const totals = {
    point_total: 0,
    point_hit: 0,
    line_total: 0,
    line_hit: 0,
    branch_total: 0,
    branch_hit: 0,
  };
  let trapCaseCount = 0;
  const cases = [];

  for (const reportPath of reportPaths) {
    const raw = JSON.parse(fs.readFileSync(reportPath, "utf8"));
    const stats = raw?.stats ?? {};
    const pointTotal = Number(stats.point_total ?? 0);
    const pointHit = Number(stats.point_hit ?? 0);
    const lineStats = normalizeLineStats(raw, stats);
    const branchTotal = Number(stats.branch_total ?? 0);
    const branchHit = Number(stats.branch_hit ?? 0);
    const executionOk = raw?.execution?.ok !== false;
    const executionError =
      typeof raw?.execution?.error === "string" && raw.execution.error.length > 0
        ? raw.execution.error
        : "";
    if (!executionOk) {
      trapCaseCount += 1;
    }

    totals.point_total += pointTotal;
    totals.point_hit += pointHit;
    totals.line_total += lineStats.line_total;
    totals.line_hit += lineStats.line_hit;
    totals.branch_total += branchTotal;
    totals.branch_hit += branchHit;

    cases.push({
      report_path: reportPath,
      entry_path: typeof raw?.entry_path === "string" ? raw.entry_path : "",
      execution_ok: executionOk,
      execution_error: executionError,
      stats: {
        point_total: pointTotal,
        point_hit: pointHit,
        line_total: lineStats.line_total,
        line_hit: lineStats.line_hit,
        branch_total: branchTotal,
        branch_hit: branchHit,
      },
      rates: {
        point: ratePercent(pointHit, pointTotal),
        line: ratePercent(lineStats.line_hit, lineStats.line_total),
        branch: ratePercent(branchHit, branchTotal),
      },
    });
  }

  return {
    format: "vibe-selfhost-suite-coverage-v1",
    case_count: cases.length,
    execution: {
      trap_case_count: trapCaseCount,
    },
    stats: totals,
    rates: {
      point: ratePercent(totals.point_hit, totals.point_total),
      line: ratePercent(totals.line_hit, totals.line_total),
      branch: ratePercent(totals.branch_hit, totals.branch_total),
    },
    cases,
  };
}

export function evaluateKpi(
  report,
  minPointRate,
  minLineRate,
  minBranchRate,
) {
  const pointRate = Number(report?.rates?.point ?? 0);
  const lineRate = Number(report?.rates?.line ?? 0);
  const branchRate = Number(report?.rates?.branch ?? 0);
  const pointOk = minPointRate === null || pointRate >= Number(minPointRate);
  const lineOk = minLineRate === null || lineRate >= Number(minLineRate);
  const branchOk = minBranchRate === null || branchRate >= Number(minBranchRate);
  const ok = pointOk && lineOk && branchOk;
  const failures = [];
  if (!pointOk) {
    failures.push(
      `point_coverage ${pointRate.toFixed(2)}% < ${Number(minPointRate).toFixed(2)}%`,
    );
  }
  if (!lineOk) {
    failures.push(
      `line_coverage ${lineRate.toFixed(2)}% < ${Number(minLineRate).toFixed(2)}%`,
    );
  }
  if (!branchOk) {
    failures.push(
      `branch_coverage ${branchRate.toFixed(2)}% < ${Number(minBranchRate).toFixed(2)}%`,
    );
  }
  return {
    ok,
    point_rate: pointRate,
    line_rate: lineRate,
    branch_rate: branchRate,
    thresholds: {
      min_point_rate: minPointRate,
      min_line_rate: minLineRate,
      min_branch_rate: minBranchRate,
    },
    has_thresholds:
      minPointRate !== null || minLineRate !== null || minBranchRate !== null,
    failures,
  };
}

function buildSummaryText(report) {
  const lines = [];
  lines.push("vibe selfhost suite coverage");
  lines.push(`cases: ${report.case_count}`);
  lines.push(
    `points: ${report.stats.point_hit}/${report.stats.point_total} (${percentText(report.stats.point_hit, report.stats.point_total)}%)`,
  );
  lines.push(
    `lines: ${report.stats.line_hit}/${report.stats.line_total} (${percentText(report.stats.line_hit, report.stats.line_total)}%)`,
  );
  lines.push(
    `branches: ${report.stats.branch_hit}/${report.stats.branch_total} (${percentText(report.stats.branch_hit, report.stats.branch_total)}%)`,
  );
  lines.push(`traps: ${report.execution.trap_case_count}`);
  if (report.kpi?.has_thresholds) {
    lines.push(`kpi: ${report.kpi.ok ? "ok" : "fail"}`);
    if (!report.kpi.ok && report.kpi.failures.length > 0) {
      lines.push(`kpi_failures: ${report.kpi.failures.join(" | ")}`);
    }
  }
  return lines.join("\n") + "\n";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const reportPaths = readLineList(args.listPath);
  if (reportPaths.length <= 0) {
    throw new Error(`no report paths in list: ${args.listPath}`);
  }
  const report = buildSuiteReport(reportPaths);
  report.kpi = evaluateKpi(
    report,
    args.minPointRate,
    args.minLineRate,
    args.minBranchRate,
  );
  const summary = buildSummaryText(report);
  if (args.reportJsonPath.length > 0) {
    fs.writeFileSync(args.reportJsonPath, JSON.stringify(report, null, 2) + "\n");
  }
  if (args.summaryPath.length > 0) {
    fs.writeFileSync(args.summaryPath, summary);
  }
  process.stdout.write(summary);
  if (!report.kpi.ok) {
    throw new Error(`coverage KPI failed: ${report.kpi.failures.join("; ")}`);
  }
}

const isCliEntry =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isCliEntry) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[coverage_selfhost_suite] ${message}`);
    process.exit(1);
  });
}
