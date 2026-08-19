#!/usr/bin/env node

import fs from "node:fs";
import { pathToFileURL } from "node:url";

function usage() {
  console.error(
    "usage: coverage_wasm_std.mjs <reports.txt> [--json <report.json>] [--summary <summary.txt>] [--markdown <report.md>] [--failures <failures.txt>] [--attempts <attempts.tsv>] [--matrix <backend-matrix.json>] [--total <count>] [--strict <0|1>] [--min-measured-rate <0-100>] [--min-line-rate <0-100>]",
  );
}

export function parseArgs(argv) {
  if (argv.length < 1) {
    usage();
    process.exit(1);
  }
  const listPath = argv[0];
  let reportJsonPath = "";
  let summaryPath = "";
  let markdownPath = "";
  let failuresPath = "";
  let attemptsPath = "";
  let matrixPath = "";
  let totalCases = -1;
  let strict = 0;
  let minMeasuredRate = null;
  let minLineRate = null;
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
    if (arg === "--markdown") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --markdown");
      }
      markdownPath = argv[i + 1];
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
    if (arg === "--attempts") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --attempts");
      }
      attemptsPath = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg === "--matrix") {
      if (i + 1 >= argv.length) {
        throw new Error("missing path after --matrix");
      }
      matrixPath = argv[i + 1];
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
    if (arg === "--strict") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --strict");
      }
      strict = Number(argv[i + 1]);
      i += 2;
      continue;
    }
    if (arg === "--min-measured-rate") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --min-measured-rate");
      }
      minMeasuredRate = Number(argv[i + 1]);
      i += 2;
      continue;
    }
    if (arg === "--min-line-rate") {
      if (i + 1 >= argv.length) {
        throw new Error("missing value after --min-line-rate");
      }
      minLineRate = Number(argv[i + 1]);
      i += 2;
      continue;
    }
    throw new Error(`unknown option: ${arg}`);
  }
  if (minMeasuredRate !== null && Number.isNaN(minMeasuredRate)) {
    throw new Error("invalid --min-measured-rate: expected number");
  }
  if (minLineRate !== null && Number.isNaN(minLineRate)) {
    throw new Error("invalid --min-line-rate: expected number");
  }
  if (
    minMeasuredRate !== null &&
    (minMeasuredRate < 0 || minMeasuredRate > 100)
  ) {
    throw new Error("invalid --min-measured-rate: expected 0..100");
  }
  if (minLineRate !== null && (minLineRate < 0 || minLineRate > 100)) {
    throw new Error("invalid --min-line-rate: expected 0..100");
  }
  if (!(strict === 0 || strict === 1)) {
    throw new Error("invalid --strict: expected 0|1");
  }
  return {
    listPath,
    reportJsonPath,
    summaryPath,
    markdownPath,
    failuresPath,
    attemptsPath,
    matrixPath,
    totalCases,
    strict,
    minMeasuredRate,
    minLineRate,
  };
}

function percent(hit, total) {
  if (total <= 0) {
    return 0;
  }
  return (hit * 100.0) / total;
}

function percentText(hit, total) {
  return percent(hit, total).toFixed(2);
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

function readFileSafe(path) {
  if (!path || !fs.existsSync(path)) {
    return "";
  }
  try {
    return fs.readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function isValidBackendName(name) {
  return name === "wasm" || name === "wasm-js-string" || name === "either";
}

export function loadBackendMatrix(path) {
  if (!path || !fs.existsSync(path)) {
    return null;
  }
  const raw = JSON.parse(fs.readFileSync(path, "utf8"));
  if (!raw || typeof raw !== "object") {
    throw new Error("invalid backend matrix: root must be object");
  }
  const defaults = raw.defaults ?? {};
  const cases = raw.cases ?? {};
  const defaultBackend = defaults.expected_backend ?? "wasm";
  if (!isValidBackendName(defaultBackend)) {
    throw new Error(
      `invalid backend matrix defaults.expected_backend: ${defaultBackend}`,
    );
  }
  if (!cases || typeof cases !== "object" || Array.isArray(cases)) {
    throw new Error("invalid backend matrix: cases must be object");
  }
  for (const [casePath, entry] of Object.entries(cases)) {
    if (!entry || typeof entry !== "object") {
      throw new Error(`invalid backend matrix case entry: ${casePath}`);
    }
    const expectedBackend = entry.expected_backend ?? defaultBackend;
    if (!isValidBackendName(expectedBackend)) {
      throw new Error(
        `invalid backend matrix case expected_backend for ${casePath}: ${expectedBackend}`,
      );
    }
  }
  return {
    path,
    defaults: {
      expected_backend: defaultBackend,
    },
    cases,
  };
}

function expectedModesFromBackend(expectedBackend) {
  if (expectedBackend === "either") {
    return ["wasm", "wasm-js-string"];
  }
  return [expectedBackend];
}

export function expectedBackendForCase(matrix, casePath) {
  if (!matrix) {
    return {
      expected_backend: "either",
      expected_modes: ["wasm", "wasm-js-string"],
      source: "default",
      note: "",
    };
  }
  const entry = matrix.cases?.[casePath];
  const expectedBackend =
    entry?.expected_backend ?? matrix.defaults.expected_backend;
  return {
    expected_backend: expectedBackend,
    expected_modes: expectedModesFromBackend(expectedBackend),
    source: entry ? "case" : "default",
    note: typeof entry?.note === "string" ? entry.note : "",
  };
}

export function readAttemptsTsv(path) {
  if (!path || !fs.existsSync(path)) {
    return [];
  }
  const raw = fs.readFileSync(path, "utf8");
  const out = [];
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) {
      continue;
    }
    const parts = line.split("\t");
    out.push({
      case_path: parts[0] ?? "",
      mode: parts[1] ?? "",
      exit_code: Number(parts[2] ?? "1"),
      log_path: parts[3] ?? "",
      report_path: parts[4] ?? "",
    });
  }
  return out;
}

export function classifyFailureReason(text) {
  const raw = text ?? "";
  const allLines = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const compileLines = allLines.filter((line) => /^compile:\s*/.test(line));
  const compileLine =
    compileLines.length > 0
      ? compileLines[compileLines.length - 1].replace(/^compile:\s*/, "")
      : null;
  const coverageLineMatch = raw.match(/\[coverage_wasm_source\]\s*([^\n]+)/);
  const fallbackMessage =
    compileLine ??
    coverageLineMatch?.[1] ??
    allLines.slice(-1)[0] ??
    "unknown failure";

  if (/does not support:/.test(raw) || /Unsupported\(/.test(raw)) {
    return {
      reason: "compile_unsupported",
      message: fallbackMessage,
    };
  }
  if (/UnknownName\(/.test(raw)) {
    return {
      reason: "compile_unknown_name",
      message: fallbackMessage,
    };
  }
  if (/missing coverage map/.test(raw)) {
    return {
      reason: "missing_coverage_map",
      message: fallbackMessage,
    };
  }
  if (/\bunreachable\b/.test(raw) || /run trapped/.test(raw)) {
    return {
      reason: "runtime_trap",
      message: fallbackMessage,
    };
  }
  if (/entry not found/.test(raw)) {
    return {
      reason: "entry_not_found",
      message: fallbackMessage,
    };
  }
  return {
    reason: "command_failed",
    message: fallbackMessage,
  };
}

function classifyFromLogPath(logPath) {
  return classifyFailureReason(readFileSafe(logPath));
}

function inferName(raw, reportPath) {
  const mapPath = raw?.map_path;
  if (typeof mapPath === "string" && mapPath.length > 0) {
    return mapPath
      .replace(/^.*[\\/]/, "")
      .replace(/\.wasm\.cov\.json$/, "")
      .replace(/\.report\.json$/, "");
  }
  return String(reportPath)
    .replace(/^.*[\\/]/, "")
    .replace(/\.wasm\.cov\.json$/, "")
    .replace(/\.report\.json$/, "");
}

function inferMissedLines(raw) {
  if (!Array.isArray(raw?.lines)) {
    return [];
  }
  return raw.lines
    .filter(
      (line) =>
        line.excluded !== true && !line.hit && typeof line.line === "number",
    )
    .map((line) => line.line)
    .sort((a, b) => a - b);
}

function buildAttemptIndex(attempts) {
  const byCase = new Map();
  const byReportPath = new Map();
  for (const attempt of attempts) {
    if (attempt.case_path) {
      if (!byCase.has(attempt.case_path)) {
        byCase.set(attempt.case_path, []);
      }
      byCase.get(attempt.case_path).push(attempt);
    }
    if (
      attempt.report_path &&
      attempt.report_path !== "-" &&
      Number(attempt.exit_code) === 0
    ) {
      byReportPath.set(attempt.report_path, attempt);
    }
  }
  return { byCase, byReportPath };
}

function reasonPriority(reason) {
  switch (reason) {
    case "compile_unsupported":
      return 0;
    case "compile_unknown_name":
      return 1;
    case "runtime_trap":
      return 2;
    case "missing_coverage_map":
      return 3;
    case "entry_not_found":
      return 4;
    case "command_failed":
      return 5;
    case "unknown":
      return 6;
    default:
      return 7;
  }
}

function chooseFailureSummary(attemptDetails) {
  if (!attemptDetails.length) {
    return {
      reason: "unknown",
      message: "no attempt log",
    };
  }
  const sorted = attemptDetails
    .slice()
    .sort((a, b) => reasonPriority(a.reason) - reasonPriority(b.reason));
  return {
    reason: sorted[0].reason,
    message: sorted[0].message,
  };
}

function uniqueModes(attempts) {
  const set = new Set();
  for (const attempt of attempts) {
    if (attempt.mode) {
      set.add(attempt.mode);
    }
  }
  return Array.from(set.values()).sort();
}

export function evaluateKpi(report, minMeasuredRate, minLineRate) {
  const measuredRate = percent(
    report.measured_case_count,
    report.total_case_count,
  );
  const lineRate = Number(report.rates?.line ?? 0);

  const measuredOk =
    minMeasuredRate === null || measuredRate >= Number(minMeasuredRate);
  const lineOk = minLineRate === null || lineRate >= Number(minLineRate);
  const ok = measuredOk && lineOk;

  const failures = [];
  if (!measuredOk) {
    failures.push(
      `measured_case_rate ${measuredRate.toFixed(2)}% < ${Number(minMeasuredRate).toFixed(2)}%`,
    );
  }
  if (!lineOk) {
    failures.push(
      `line_coverage ${lineRate.toFixed(2)}% < ${Number(minLineRate).toFixed(2)}%`,
    );
  }

  return {
    ok,
    measured_rate: measuredRate,
    line_rate: lineRate,
    thresholds: {
      min_measured_rate: minMeasuredRate,
      min_line_rate: minLineRate,
    },
    failures,
  };
}

function escapeMarkdownCell(text) {
  return String(text ?? "")
    .replaceAll("|", "\\|")
    .replaceAll("\n", "<br>");
}

export function buildAggregatedReport({
  reportPaths,
  failedCases,
  attempts,
  totalCases,
  backendMatrix,
}) {
  const { byCase, byReportPath } = buildAttemptIndex(attempts);

  const cases = [];
  const totals = {
    point_total: 0,
    point_hit: 0,
    line_total: 0,
    line_hit: 0,
    branch_total: 0,
    branch_hit: 0,
  };

  let trapCaseCount = 0;
  let mismatchCaseCount = 0;

  for (const reportPath of reportPaths) {
    const raw = JSON.parse(fs.readFileSync(reportPath, "utf8"));
    const stats = raw.stats ?? {};
    const pointTotal = Number(stats.point_total ?? 0);
    const pointHit = Number(stats.point_hit ?? 0);
    const reportedLineTotal = Number(stats.line_total ?? 0);
    const reportedLineHit = Number(stats.line_hit ?? 0);
    const uniqueLines = Array.isArray(raw.lines) ? raw.lines : [];
    const measuredLines = uniqueLines.filter(
      (line) => line && line.excluded !== true,
    );
    const lineTotal =
      uniqueLines.length > 0 ? measuredLines.length : reportedLineTotal;
    const lineHit =
      uniqueLines.length > 0
        ? measuredLines.filter((line) => line.hit === true).length
        : reportedLineHit;
    const branchTotal = Number(stats.branch_total ?? 0);
    const branchHit = Number(stats.branch_hit ?? 0);

    totals.point_total += pointTotal;
    totals.point_hit += pointHit;
    totals.line_total += lineTotal;
    totals.line_hit += lineHit;
    totals.branch_total += branchTotal;
    totals.branch_hit += branchHit;

    const reportKey = reportPath;
    const attempt = byReportPath.get(reportKey);
    const executionOk = raw?.execution?.ok !== false;
    const executionError =
      typeof raw?.execution?.error === "string" && raw.execution.error.length > 0
        ? raw.execution.error
        : null;
    if (!executionOk) {
      trapCaseCount += 1;
    }
    const backendSpec = expectedBackendForCase(
      backendMatrix ?? null,
      attempt?.case_path ?? "",
    );
    const modeStatus =
      backendSpec.expected_backend === "either" ||
      backendSpec.expected_backend === (attempt?.mode ?? "unknown")
        ? "matched"
        : "mismatch";
    if (modeStatus === "mismatch") {
      mismatchCaseCount += 1;
    }

    cases.push({
      name: inferName(raw, reportPath),
      case_path: attempt?.case_path ?? "",
      mode: attempt?.mode ?? "unknown",
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
      execution: {
        ok: executionOk,
        error: executionError,
      },
      missed_lines: inferMissedLines(raw),
      backend: backendSpec,
      spec_status: modeStatus,
    });
  }

  const failedCaseDetails = [];
  const failureReasonCounts = {};
  let expectedFailureCount = 0;
  let unexpectedFailureCount = 0;

  for (const casePath of failedCases) {
    const attemptsForCase = byCase.get(casePath) ?? [];
    const backendSpec = expectedBackendForCase(backendMatrix ?? null, casePath);
    const attemptDetails = attemptsForCase.map((attempt) => {
      const { reason, message } = classifyFromLogPath(attempt.log_path);
      return {
        mode: attempt.mode,
        exit_code: Number(attempt.exit_code),
        log_path: attempt.log_path,
        reason,
        message,
      };
    });

    const { reason, message } = chooseFailureSummary(attemptDetails);
    const attemptedExpectedModeCount = attemptDetails.filter((attempt) =>
      backendSpec.expected_modes.includes(attempt.mode),
    ).length;
    const specStatus =
      attemptedExpectedModeCount === 0
        ? "expected_failure"
        : "unexpected_failure";
    if (specStatus === "expected_failure") {
      expectedFailureCount += 1;
    } else {
      unexpectedFailureCount += 1;
    }
    failureReasonCounts[reason] = Number(failureReasonCounts[reason] ?? 0) + 1;

    failedCaseDetails.push({
      case_path: casePath,
      reason,
      message,
      attempts: attemptDetails,
      spec_status: specStatus,
      backend: backendSpec,
    });
  }

  failedCaseDetails.sort((a, b) => a.case_path.localeCompare(b.case_path));

  const report = {
    format: "vibe-std-wasm-source-coverage-v2",
    generated_at: new Date().toISOString(),
    total_case_count:
      totalCases >= 0 ? totalCases : cases.length + failedCaseDetails.length,
    case_count: cases.length,
    measured_case_count: cases.length,
    failed_case_count: failedCaseDetails.length,
    spec: {
      matrix_path: backendMatrix?.path ?? "",
      mismatch_case_count: mismatchCaseCount,
      expected_failure_count: expectedFailureCount,
      unexpected_failure_count: unexpectedFailureCount,
    },
    execution: {
      ok_case_count: cases.length - trapCaseCount,
      trap_case_count: trapCaseCount,
    },
    modes: uniqueModes(attempts),
    failed_cases: failedCases,
    failure_reason_counts: failureReasonCounts,
    failed_case_details: failedCaseDetails,
    cases,
    stats: totals,
    rates: {
      point: percent(totals.point_hit, totals.point_total),
      line: percent(totals.line_hit, totals.line_total),
      branch: percent(totals.branch_hit, totals.branch_total),
    },
  };

  return report;
}

export function buildSummary(report) {
  const lines = [];
  lines.push("vibe std wasm source coverage");
  if (report.modes.length > 0) {
    lines.push(`modes: ${report.modes.join(", ")}`);
  }
  lines.push(
    `cases(total/measured/failed): ${report.total_case_count}/${report.measured_case_count}/${report.failed_case_count}`,
  );
  lines.push(
    `execution(ok/trap): ${report.execution.ok_case_count}/${report.execution.trap_case_count}`,
  );
  if (report.kpi) {
    lines.push(
      `kpi(measured/line): ${report.kpi.measured_rate.toFixed(2)}% / ${report.kpi.line_rate.toFixed(2)}%`,
    );
  }
  lines.push(
    `spec(mismatch/expected/unexpected): ${report.spec.mismatch_case_count}/${report.spec.expected_failure_count}/${report.spec.unexpected_failure_count}`,
  );
  lines.push(
    `points: ${report.stats.point_hit}/${report.stats.point_total} (${percentText(report.stats.point_hit, report.stats.point_total)}%)`,
  );
  lines.push(
    `lines: ${report.stats.line_hit}/${report.stats.line_total} (${percentText(report.stats.line_hit, report.stats.line_total)}%)`,
  );
  lines.push(
    `branches: ${report.stats.branch_hit}/${report.stats.branch_total} (${percentText(report.stats.branch_hit, report.stats.branch_total)}%)`,
  );

  const lowest = report.cases
    .slice()
    .sort((a, b) => a.rates.line - b.rates.line)
    .slice(0, 5);
  if (lowest.length > 0) {
    lines.push("lowest_line_coverage:");
    for (const item of lowest) {
      const missed = item.missed_lines.length > 0 ? ` missed=${item.missed_lines.join(",")}` : "";
      const trap = item.execution.ok ? "" : " trap";
      lines.push(
        `  - ${item.name} [${item.mode}]: ${item.stats.line_hit}/${item.stats.line_total} (${item.rates.line.toFixed(2)}%)${trap}${missed}`,
      );
    }
  }

  const reasons = Object.entries(report.failure_reason_counts).sort(
    (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
  );
  if (reasons.length > 0) {
    lines.push("failure_reasons:");
    for (const [reason, count] of reasons) {
      lines.push(`  - ${reason}: ${count}`);
    }
  }

  if (report.failed_case_details.length > 0) {
    lines.push("failed_case_list:");
    for (const item of report.failed_case_details) {
      lines.push(
        `  - ${item.case_path}: ${item.reason}/${item.spec_status} expected=${item.backend.expected_backend} (${item.message})`,
      );
    }
  }

  return lines.join("\n") + "\n";
}

export function buildMarkdown(report) {
  const lines = [];
  lines.push("# @vibe/builtin wasm source coverage report");
  lines.push("");
  lines.push(`- Generated: ${report.generated_at}`);
  lines.push(
    `- Modes: ${report.modes.length > 0 ? report.modes.join(", ") : "(none)"}`,
  );
  lines.push("");

  lines.push("## Overview");
  lines.push("");
  lines.push("| Metric | Value |");
  lines.push("| --- | ---: |");
  lines.push(`| cases (total) | ${report.total_case_count} |`);
  lines.push(`| cases (measured) | ${report.measured_case_count} |`);
  lines.push(`| cases (failed) | ${report.failed_case_count} |`);
  lines.push(`| spec mismatch cases | ${report.spec.mismatch_case_count} |`);
  lines.push(
    `| spec expected failures | ${report.spec.expected_failure_count} |`,
  );
  lines.push(
    `| spec unexpected failures | ${report.spec.unexpected_failure_count} |`,
  );
  lines.push(`| execution trap cases | ${report.execution.trap_case_count} |`);
  lines.push(
    `| points | ${report.stats.point_hit}/${report.stats.point_total} (${percentText(report.stats.point_hit, report.stats.point_total)}%) |`,
  );
  lines.push(
    `| lines | ${report.stats.line_hit}/${report.stats.line_total} (${percentText(report.stats.line_hit, report.stats.line_total)}%) |`,
  );
  lines.push(
    `| branches | ${report.stats.branch_hit}/${report.stats.branch_total} (${percentText(report.stats.branch_hit, report.stats.branch_total)}%) |`,
  );
  lines.push("");

  const reasons = Object.entries(report.failure_reason_counts).sort(
    (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
  );
  if (reasons.length > 0) {
    lines.push("## Failure Reasons");
    lines.push("");
    lines.push("| Reason | Count |");
    lines.push("| --- | ---: |");
    for (const [reason, count] of reasons) {
      lines.push(`| ${escapeMarkdownCell(reason)} | ${count} |`);
    }
    lines.push("");
  }

  if (report.failed_case_details.length > 0) {
    lines.push("## Failed Cases");
    lines.push("");
    lines.push("| Case | Spec | Expected Backend | Reason | Message | Attempts |");
    lines.push("| --- | --- | --- | --- | --- | --- |");
    for (const item of report.failed_case_details) {
      const attemptModes = item.attempts.map((attempt) => attempt.mode).join(", ");
      lines.push(
        `| ${escapeMarkdownCell(item.case_path)} | ${escapeMarkdownCell(item.spec_status)} | ${escapeMarkdownCell(item.backend.expected_backend)} | ${escapeMarkdownCell(item.reason)} | ${escapeMarkdownCell(item.message)} | ${escapeMarkdownCell(attemptModes)} |`,
      );
    }
    lines.push("");
  }

  if (report.cases.length > 0) {
    const lowest = report.cases
      .slice()
      .sort((a, b) => a.rates.line - b.rates.line)
      .slice(0, 10);
    lines.push("## Lowest Coverage Cases");
    lines.push("");
    lines.push("| Case | Mode | Point% | Line% | Branch% | Trap | Missed Lines |");
    lines.push("| --- | --- | ---: | ---: | ---: | --- | --- |");
    for (const item of lowest) {
      const missed =
        item.missed_lines.length > 0
          ? item.missed_lines.slice(0, 20).join(",")
          : "";
      lines.push(
        `| ${escapeMarkdownCell(item.name)} | ${escapeMarkdownCell(item.mode)} | ${item.rates.point.toFixed(2)} | ${item.rates.line.toFixed(2)} | ${item.rates.branch.toFixed(2)} | ${item.execution.ok ? "no" : "yes"} | ${escapeMarkdownCell(missed)} |`,
      );
    }
    lines.push("");
  }

  return lines.join("\n") + "\n";
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const reportPaths = readLineList(args.listPath);
  const failedCases = readLineList(args.failuresPath);
  const attempts = readAttemptsTsv(args.attemptsPath);
  const backendMatrix = loadBackendMatrix(args.matrixPath);

  const report = buildAggregatedReport({
    reportPaths,
    failedCases,
    attempts,
    totalCases: args.totalCases,
    backendMatrix,
  });
  report.kpi = evaluateKpi(report, args.minMeasuredRate, args.minLineRate);

  const summary = buildSummary(report);
  const markdown = buildMarkdown(report);

  if (args.reportJsonPath.length > 0) {
    fs.writeFileSync(args.reportJsonPath, JSON.stringify(report, null, 2) + "\n");
  }
  if (args.summaryPath.length > 0) {
    fs.writeFileSync(args.summaryPath, summary);
  }
  if (args.markdownPath.length > 0) {
    fs.writeFileSync(args.markdownPath, markdown);
  }

  process.stdout.write(summary);

  if (!report.kpi.ok) {
    throw new Error(`kpi gate failed: ${report.kpi.failures.join("; ")}`);
  }
  if (
    args.strict === 1 &&
    (report.spec.unexpected_failure_count > 0 ||
      report.spec.mismatch_case_count > 0)
  ) {
    throw new Error(
      `strict gate failed: unexpected_failed=${report.spec.unexpected_failure_count}, mode_mismatch=${report.spec.mismatch_case_count}`,
    );
  }
}

const isCliEntry =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isCliEntry) {
  try {
    main();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[coverage_wasm_std] ${message}`);
    process.exit(1);
  }
}
