#!/usr/bin/env node

import fs from "node:fs";

function usage() {
  console.error(
    "usage: coverage_wasm_source.mjs <wasm-file> <map-json> [--json <report.json>] [--summary <summary.txt>]",
  );
}

function parseArgs(argv) {
  if (argv.length < 2) {
    usage();
    process.exit(1);
  }
  const wasmPath = argv[0];
  const mapPath = argv[1];
  let reportJsonPath = "";
  let summaryPath = "";
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
    throw new Error(`unknown option: ${arg}`);
  }
  return { wasmPath, mapPath, reportJsonPath, summaryPath };
}

function percent(hit, total) {
  if (total <= 0) {
    return "0.00";
  }
  return ((hit * 100.0) / total).toFixed(2);
}

function ensureExportNumber(globalExport, name) {
  if (!globalExport || typeof globalExport.value !== "number") {
    throw new Error(`missing numeric global export: ${name}`);
  }
  return globalExport.value;
}

function buildSummaryText(report) {
  const lines = [];
  lines.push("xsh wasm source coverage");
  lines.push(`wasm: ${report.wasm_path}`);
  lines.push(`map: ${report.map_path}`);
  lines.push(
    `points: ${report.stats.point_hit}/${report.stats.point_total} (${percent(report.stats.point_hit, report.stats.point_total)}%)`,
  );
  lines.push(
    `lines: ${report.stats.line_hit}/${report.stats.line_total} (${percent(report.stats.line_hit, report.stats.line_total)}%)`,
  );
  lines.push(
    `branches: ${report.stats.branch_hit}/${report.stats.branch_total} (${percent(report.stats.branch_hit, report.stats.branch_total)}%)`,
  );
  const missedLineList = report.lines
    .filter((line) => !line.hit)
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

function makeHostFunction(moduleName, importName) {
  if (moduleName === "xsh" && importName === "path") {
    return (value) => value;
  }
  if (moduleName === "xsh" && importName === "sh") {
    return (_value) => 0;
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

  const counterBase = ensureExportNumber(exports.__xsh_cov_base, "__xsh_cov_base");
  const counterCount = ensureExportNumber(
    exports.__xsh_cov_count,
    "__xsh_cov_count",
  );
  if (counterCount < 0) {
    throw new Error(`invalid counter count: ${counterCount}`);
  }

  exports.run();

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
  const lineHit = linePoints.filter((p) => p.hit).length;
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
  const lines = Array.from(lineMap.values()).sort((a, b) => a.line - b.line);

  const report = {
    format: "xsh-wasm-source-coverage-v1",
    wasm_path: args.wasmPath,
    map_path: args.mapPath,
    counter_base: counterBase,
    counter_count: counterCount,
    points,
    lines,
    stats: {
      point_total: points.length,
      point_hit: pointHit,
      line_total: linePoints.length,
      line_hit: lineHit,
      branch_total: branchPoints.length,
      branch_hit: branchHit,
    },
  };

  const summary = buildSummaryText(report);
  if (args.reportJsonPath.length > 0) {
    fs.writeFileSync(args.reportJsonPath, JSON.stringify(report, null, 2) + "\n");
  }
  if (args.summaryPath.length > 0) {
    fs.writeFileSync(args.summaryPath, summary);
  }
  process.stdout.write(summary);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[coverage_wasm_source] ${message}`);
  process.exit(1);
});
