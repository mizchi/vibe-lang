#!/usr/bin/env node

import fs from "node:fs";

function usage() {
  console.error(
    "usage: coverage_wasm_std.mjs <reports.txt> [--json <report.json>] [--summary <summary.txt>] [--failures <failures.txt>] [--total <count>]",
  );
}

function parseArgs(argv) {
  if (argv.length < 1) {
    usage();
    process.exit(1);
  }
  const listPath = argv[0];
  let reportJsonPath = "";
  let summaryPath = "";
  let failuresPath = "";
  let totalCases = -1;
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
    if (arg === "--failures") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --failures");
      }
      failuresPath = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg === "--total") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --total");
      }
      totalCases = Number(argv[i + 1]);
      i += 2;
      continue;
    }
    throw new Error(`unknown option: ${arg}`);
  }
  return { listPath, reportJsonPath, summaryPath, failuresPath, totalCases };
}

function percent(hit, total) {
  if (total <= 0) {
    return 0;
  }
  return (hit * 100.0) / total;
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

function buildSummary(report) {
  const lines = [];
  lines.push("xsh std wasm source coverage");
  lines.push(`cases(total/success): ${report.total_case_count}/${report.case_count}`);
  lines.push(`failed_cases: ${report.failed_cases.length}`);
  lines.push(
    `points: ${report.stats.point_hit}/${report.stats.point_total} (${percent(report.stats.point_hit, report.stats.point_total).toFixed(2)}%)`,
  );
  lines.push(
    `lines: ${report.stats.line_hit}/${report.stats.line_total} (${percent(report.stats.line_hit, report.stats.line_total).toFixed(2)}%)`,
  );
  lines.push(
    `branches: ${report.stats.branch_hit}/${report.stats.branch_total} (${percent(report.stats.branch_hit, report.stats.branch_total).toFixed(2)}%)`,
  );
  const lowest = report.cases
    .slice()
    .sort((a, b) => a.rates.point - b.rates.point)
    .slice(0, 5);
  if (lowest.length > 0) {
    lines.push("lowest_point_coverage:");
    for (const item of lowest) {
      lines.push(
        `  - ${item.name}: ${item.stats.point_hit}/${item.stats.point_total} (${item.rates.point.toFixed(2)}%)`,
      );
    }
  }
  if (report.failed_cases.length > 0) {
    lines.push("failed_case_list:");
    for (const path of report.failed_cases) {
      lines.push(`  - ${path}`);
    }
  }
  return lines.join("\n") + "\n";
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const reportPaths = readLineList(args.listPath);
  if (reportPaths.length === 0) {
    throw new Error("no report paths found");
  }
  const failedCases = readLineList(args.failuresPath);

  const cases = [];
  const totals = {
    point_total: 0,
    point_hit: 0,
    line_total: 0,
    line_hit: 0,
    branch_total: 0,
    branch_hit: 0,
  };

  for (const reportPath of reportPaths) {
    const raw = JSON.parse(fs.readFileSync(reportPath, "utf8"));
    const stats = raw.stats ?? {};
    const pointTotal = Number(stats.point_total ?? 0);
    const pointHit = Number(stats.point_hit ?? 0);
    const lineTotal = Number(stats.line_total ?? 0);
    const lineHit = Number(stats.line_hit ?? 0);
    const branchTotal = Number(stats.branch_total ?? 0);
    const branchHit = Number(stats.branch_hit ?? 0);

    totals.point_total += pointTotal;
    totals.point_hit += pointHit;
    totals.line_total += lineTotal;
    totals.line_hit += lineHit;
    totals.branch_total += branchTotal;
    totals.branch_hit += branchHit;

    const name = String(raw.map_path ?? reportPath)
      .replace(/^.*\/coverage\/wasm-std\/cases\//, "")
      .replace(/\.wasm\.cov\.json$/, "")
      .replace(/\.report\.json$/, "");

    cases.push({
      name,
      report_path: reportPath,
      stats: {
        point_total: pointTotal,
        point_hit: pointHit,
        line_total: lineTotal,
        line_hit: lineHit,
        branch_total: branchTotal,
        branch_hit: branchHit,
      },
      rates: {
        point: percent(pointHit, pointTotal),
        line: percent(lineHit, lineTotal),
        branch: percent(branchHit, branchTotal),
      },
    });
  }

  const report = {
    format: "xsh-std-wasm-source-coverage-v1",
    total_case_count: args.totalCases >= 0 ? args.totalCases : cases.length + failedCases.length,
    case_count: cases.length,
    failed_cases: failedCases,
    cases,
    stats: totals,
    rates: {
      point: percent(totals.point_hit, totals.point_total),
      line: percent(totals.line_hit, totals.line_total),
      branch: percent(totals.branch_hit, totals.branch_total),
    },
  };

  const summary = buildSummary(report);
  if (args.reportJsonPath.length > 0) {
    fs.writeFileSync(args.reportJsonPath, JSON.stringify(report, null, 2) + "\n");
  }
  if (args.summaryPath.length > 0) {
    fs.writeFileSync(args.summaryPath, summary);
  }
  process.stdout.write(summary);
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[coverage_wasm_std] ${message}`);
  process.exit(1);
}
