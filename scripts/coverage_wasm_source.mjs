#!/usr/bin/env node

import fs from "node:fs";
import { pathToFileURL } from "node:url";

function usage() {
  console.error(
    "usage: coverage_wasm_source.mjs <wasm-file> <map-json> [--json <report.json>] [--summary <summary.txt>] [--allow-trap] [--invoke <export-name> ...] [--min-point-rate <0-100>] [--min-line-rate <0-100>] [--min-branch-rate <0-100>]",
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
  if (argv.length < 2) {
    usage();
    process.exit(1);
  }
  const wasmPath = argv[0];
  const mapPath = argv[1];
  let reportJsonPath = "";
  let summaryPath = "";
  let allowTrap = false;
  const invokeNames = [];
  let minPointRate = null;
  let minLineRate = null;
  let minBranchRate = null;
  let i = 2;
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
    if (arg === "--allow-trap") {
      allowTrap = true;
      i += 1;
      continue;
    }
    if (arg === "--invoke") {
      if (i + 1 >= argv.length) {
        throw new Error("missing export name after --invoke");
      }
      invokeNames.push(argv[i + 1]);
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
    wasmPath,
    mapPath,
    reportJsonPath,
    summaryPath,
    allowTrap,
    invokeNames,
    minPointRate,
    minLineRate,
    minBranchRate,
  };
}

function ratePercent(hit, total) {
  if (total <= 0) {
    return 0;
  }
  return (hit * 100.0) / total;
}

function percent(hit, total) {
  return ratePercent(hit, total).toFixed(2);
}

function ensureExportNumber(globalExport, name) {
  if (!globalExport || typeof globalExport.value !== "number") {
    throw new Error(`missing numeric global export: ${name}`);
  }
  return globalExport.value;
}

function buildSummaryText(report) {
  const lines = [];
  lines.push("vibe wasm source coverage");
  lines.push(`wasm: ${report.wasm_path}`);
  lines.push(`map: ${report.map_path}`);
  if (Array.isArray(report.execution.invoked) && report.execution.invoked.length > 0) {
    lines.push(`invoked: ${report.execution.invoked.join(",")}`);
  }
  lines.push(`execution: ${report.execution.ok ? "ok" : `trap (${report.execution.error})`}`);
  lines.push(
    `points: ${report.stats.point_hit}/${report.stats.point_total} (${percent(report.stats.point_hit, report.stats.point_total)}%)`,
  );
  lines.push(
    `lines: ${report.stats.line_hit}/${report.stats.line_total} (${percent(report.stats.line_hit, report.stats.line_total)}%)`,
  );
  if (Number(report.stats.line_excluded_total ?? 0) > 0) {
    lines.push(`lines_excluded: ${report.stats.line_excluded_total}`);
  }
  lines.push(
    `branches: ${report.stats.branch_hit}/${report.stats.branch_total} (${percent(report.stats.branch_hit, report.stats.branch_total)}%)`,
  );
  if (report.kpi && report.kpi.has_thresholds) {
    lines.push(`kpi: ${report.kpi.ok ? "ok" : "fail"}`);
    if (!report.kpi.ok && Array.isArray(report.kpi.failures) && report.kpi.failures.length > 0) {
      lines.push(`kpi_failures: ${report.kpi.failures.join(" | ")}`);
    }
  }
  const missedLineList = report.lines
    .filter((line) => !line.hit && line.excluded !== true)
    .map((line) => line.line)
    .sort((a, b) => a - b);
  if (missedLineList.length > 0) {
    lines.push(`missed_lines: ${missedLineList.join(",")}`);
  }
  return lines.join("\n") + "\n";
}

function normalizeLine(point) {
  if (
    !point ||
    typeof point !== "object" ||
    typeof point.range !== "object" ||
    point.range === null ||
    typeof point.range.start !== "object" ||
    point.range.start === null ||
    typeof point.range.start.line !== "number"
  ) {
    return -1;
  }
  return point.range.start.line + 1;
}

function pointKind(point) {
  if (!point || typeof point !== "object" || typeof point.kind !== "string") {
    return "unknown";
  }
  return point.kind;
}

function readSourceLines(entryPath) {
  if (!entryPath || typeof entryPath !== "string") {
    return [];
  }
  if (!fs.existsSync(entryPath)) {
    return [];
  }
  const raw = fs.readFileSync(entryPath, "utf8");
  return raw.split(/\r?\n/);
}

function isListIdentifierLine(sourceLine) {
  return /^[A-Za-z_][A-Za-z0-9_]*(\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*,?$/.test(
    sourceLine,
  );
}

function isLineInsideListBlock(sourceLines, lineIndex, blockStartPattern) {
  if (lineIndex < 0 || lineIndex >= sourceLines.length) {
    return false;
  }
  if (!isListIdentifierLine(sourceLines[lineIndex].trim())) {
    return false;
  }
  for (let i = lineIndex - 1; i >= 0; i -= 1) {
    const prev = sourceLines[i].trim();
    if (prev.length === 0) {
      continue;
    }
    if (blockStartPattern.test(prev)) {
      return true;
    }
    if (/^\}/.test(prev)) {
      return false;
    }
  }
  return false;
}

function isImportListIdentifierLine(sourceLines, lineIndex) {
  return isLineInsideListBlock(sourceLines, lineIndex, /^import\s*\{/);
}

function isExportListHeaderLine(trimmed) {
  return /^export(?:\s+\.[^\s{]+)?\s*\{$/.test(trimmed);
}

function isExportListIdentifierLine(sourceLines, lineIndex) {
  return isLineInsideListBlock(
    sourceLines,
    lineIndex,
    /^export(?:\s+\.[^\s{]+)?\s*\{/,
  );
}

export function isCoverageNoiseLine(sourceLines, lineNumber) {
  if (!Array.isArray(sourceLines)) {
    return false;
  }
  if (typeof lineNumber !== "number" || lineNumber <= 0) {
    return false;
  }
  const lineIndex = lineNumber - 1;
  if (lineIndex < 0 || lineIndex >= sourceLines.length) {
    return false;
  }
  const trimmed = sourceLines[lineIndex].trim();
  if (trimmed.length === 0) {
    return true;
  }
  if (/^\/\//.test(trimmed)) {
    return true;
  }
  if (
    trimmed === "}" ||
    trimmed === "};" ||
    trimmed === "})" ||
    trimmed === "});" ||
    /^\}\s+from\b/.test(trimmed)
  ) {
    return true;
  }
  if (isExportListHeaderLine(trimmed)) {
    return true;
  }
  if (isImportListIdentifierLine(sourceLines, lineIndex)) {
    return true;
  }
  if (isExportListIdentifierLine(sourceLines, lineIndex)) {
    return true;
  }
  return false;
}

export function applySourceNoiseExclusion(lines, sourceLines) {
  const annotated = lines.map((line) => ({
    ...line,
    excluded: isCoverageNoiseLine(sourceLines, line.line),
  }));
  const measuredLines = annotated.filter((line) => line.excluded !== true);
  const lineHit = measuredLines.filter((line) => line.hit === true).length;
  return {
    lines: annotated,
    line_total: measuredLines.length,
    line_hit: lineHit,
    line_excluded_total: annotated.length - measuredLines.length,
  };
}

export function evaluateKpi(
  report,
  minPointRate,
  minLineRate,
  minBranchRate,
) {
  const pointRate = ratePercent(
    Number(report?.stats?.point_hit ?? 0),
    Number(report?.stats?.point_total ?? 0),
  );
  const lineRate = ratePercent(
    Number(report?.stats?.line_hit ?? 0),
    Number(report?.stats?.line_total ?? 0),
  );
  const branchRate = ratePercent(
    Number(report?.stats?.branch_hit ?? 0),
    Number(report?.stats?.branch_total ?? 0),
  );

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

function makeHostFunction(moduleName, importName) {
  if (moduleName === "vibe" && importName === "path") {
    return (value) => value;
  }
  if (moduleName === "vibe" && importName === "sh") {
    return (_value) => 0n;
  }
  return (..._args) => 0;
}

function buildImportObject(module) {
  const importObject = {};
  const imports = WebAssembly.Module.imports(module);
  for (const item of imports) {
    if (!importObject[item.module]) {
      importObject[item.module] = {};
    }
    if (item.kind === "function") {
      importObject[item.module][item.name] = makeHostFunction(
        item.module,
        item.name,
      );
      continue;
    }
    throw new Error(
      `unsupported wasm import kind for coverage runner: ${item.module}.${item.name} (${item.kind})`,
    );
  }
  return importObject;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const wasmBytes = fs.readFileSync(args.wasmPath);
  const map = JSON.parse(fs.readFileSync(args.mapPath, "utf8"));
  if (!map || typeof map !== "object" || !Array.isArray(map.points)) {
    throw new Error("coverage map must include points[]");
  }

  let module;
  try {
    module = await WebAssembly.compile(wasmBytes, {
      builtins: ["js-string"],
      importedStringConstants: "string_constants",
    });
  } catch {
    module = await WebAssembly.compile(wasmBytes);
  }
  const importObject = buildImportObject(module);
  const instance = await WebAssembly.instantiate(module, importObject);
  const exports = instance.exports;
  if (!exports || typeof exports !== "object") {
    throw new Error("missing wasm exports");
  }
  if (typeof exports.run !== "function") {
    throw new Error('missing export "run"');
  }
  if (!(exports.memory instanceof WebAssembly.Memory)) {
    throw new Error('missing export "memory"');
  }

  const counterBaseExport = exports.__vibe_cov_base;
  const counterCountExport = exports.__vibe_cov_count;
  const counterBaseName = "__vibe_cov_base";
  const counterCountName = "__vibe_cov_count";
  const counterBase = ensureExportNumber(counterBaseExport, counterBaseName);
  const counterCount = ensureExportNumber(counterCountExport, counterCountName);
  if (counterCount < 0) {
    throw new Error(`invalid counter count: ${counterCount}`);
  }

  let runError = null;
  try {
    for (const invokeName of args.invokeNames) {
      const invokeTarget = exports[invokeName];
      if (typeof invokeTarget !== "function") {
        throw new Error(`missing export "${invokeName}"`);
      }
      invokeTarget();
    }
    exports.run();
  } catch (error) {
    runError = error instanceof Error ? error.message : String(error);
  }

  const memory = exports.memory;
  const counters = Array.from(
    new Uint32Array(memory.buffer, counterBase, counterCount),
  );
  const pointLen = Math.min(counters.length, map.points.length);
  const points = [];
  for (let i = 0; i < pointLen; i += 1) {
    const rawPoint = map.points[i];
    const count = counters[i] ?? 0;
    points.push({
      id: typeof rawPoint.id === "number" ? rawPoint.id : i,
      kind: pointKind(rawPoint),
      line: normalizeLine(rawPoint),
      count,
      hit: count > 0,
      span: rawPoint.span ?? null,
      range: rawPoint.range ?? null,
    });
  }

  const linePoints = points.filter((p) => p.kind === "line");
  const branchPoints = points.filter((p) => p.kind !== "line");
  const pointHit = points.filter((p) => p.hit).length;
  const linePointHit = linePoints.filter((p) => p.hit).length;
  const branchHit = branchPoints.filter((p) => p.hit).length;

  const lineMap = new Map();
  for (const point of linePoints) {
    if (point.line <= 0) {
      continue;
    }
    const prev = lineMap.get(point.line);
    if (!prev) {
      lineMap.set(point.line, {
        line: point.line,
        hit: point.hit,
        count: point.count,
      });
      continue;
    }
    lineMap.set(point.line, {
      line: point.line,
      hit: prev.hit || point.hit,
      count: prev.count + point.count,
    });
  }
  const rawLines = Array.from(lineMap.values()).sort((a, b) => a.line - b.line);
  const sourceLines = readSourceLines(map.entry_path);
  const lineCoverage = applySourceNoiseExclusion(rawLines, sourceLines);
  const lines = lineCoverage.lines;
  const lineHit = lineCoverage.line_hit;

  const report = {
    format: "vibe-wasm-source-coverage-v2",
    wasm_path: args.wasmPath,
    map_path: args.mapPath,
    counter_base: counterBase,
    counter_count: counterCount,
    entry_path: typeof map.entry_path === "string" ? map.entry_path : "",
    execution: {
      ok: runError === null,
      error: runError,
      invoked: args.invokeNames,
    },
    points,
    lines,
    stats: {
      point_total: points.length,
      point_hit: pointHit,
      line_total: lineCoverage.line_total,
      line_hit: lineHit,
      line_excluded_total: lineCoverage.line_excluded_total,
      line_point_total: linePoints.length,
      line_point_hit: linePointHit,
      branch_total: branchPoints.length,
      branch_hit: branchHit,
    },
  };
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

  if (runError !== null && !args.allowTrap) {
    throw new Error(`run trapped: ${runError}`);
  }
  if (!report.kpi.ok) {
    throw new Error(`coverage KPI failed: ${report.kpi.failures.join("; ")}`);
  }
}

const isCliEntry =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isCliEntry) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[coverage_wasm_source] ${message}`);
    process.exit(1);
  });
}
