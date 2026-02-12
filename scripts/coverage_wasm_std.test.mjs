import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

import {
  classifyFailureReason,
  buildAggregatedReport,
  buildMarkdown,
  readAttemptsTsv,
  evaluateKpi,
  loadBackendMatrix,
  expectedBackendForCase,
} from "./coverage_wasm_std.mjs";

test("classifyFailureReason: compile unsupported", () => {
  const result = classifyFailureReason(
    "PanicError\ncompile: Gen(Unsupported(\"call: to_double\"))\n",
  );
  assert.equal(result.reason, "compile_unsupported");
  assert.match(result.message, /call: to_double/);
});

test("classifyFailureReason: runtime trap", () => {
  const result = classifyFailureReason("[coverage_wasm_source] unreachable\n");
  assert.equal(result.reason, "runtime_trap");
  assert.match(result.message, /unreachable/);
});

test("readAttemptsTsv + buildAggregatedReport + buildMarkdown", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "xsh-cov-"));
  const reportAPath = path.join(dir, "xsh__std__a_test.report.json");
  const reportBPath = path.join(dir, "xsh__std__b_test.report.json");
  const logC1 = path.join(dir, "c.wasm.log");
  const logC2 = path.join(dir, "c.wasm_js_string.log");
  const attemptsPath = path.join(dir, "attempts.tsv");

  fs.writeFileSync(
    reportAPath,
    JSON.stringify({
      map_path: path.join(dir, "xsh__std__a_test.wasm.cov.json"),
      stats: {
        point_total: 10,
        point_hit: 8,
        line_total: 8,
        line_hit: 6,
        branch_total: 2,
        branch_hit: 2,
      },
      lines: [
        { line: 10, hit: true, count: 1 },
        { line: 11, hit: false, count: 0 },
      ],
      execution: { ok: true, error: null },
    }),
  );

  fs.writeFileSync(
    reportBPath,
    JSON.stringify({
      map_path: path.join(dir, "xsh__std__b_test.wasm.cov.json"),
      stats: {
        point_total: 6,
        point_hit: 6,
        line_total: 6,
        line_hit: 6,
        branch_total: 0,
        branch_hit: 0,
      },
      lines: [{ line: 20, hit: true, count: 1 }],
      execution: { ok: false, error: "unreachable" },
    }),
  );

  fs.writeFileSync(
    logC1,
    'PanicError\ncompile: Gen(Unsupported("call local: abs"))\n',
  );
  fs.writeFileSync(logC2, '[coverage_wasm_source] missing coverage map\n');

  fs.writeFileSync(
    attemptsPath,
    [
      `vibe/std/a_test.vibe\twasm\t0\t${reportAPath}.log\t${reportAPath}`,
      `vibe/std/b_test.vibe\twasm\t0\t${reportBPath}.log\t${reportBPath}`,
      `vibe/std/c_test.vibe\twasm\t1\t${logC1}\t-`,
      `vibe/std/c_test.vibe\twasm-js-string\t1\t${logC2}\t-`,
    ].join("\n") + "\n",
  );

  const attempts = readAttemptsTsv(attemptsPath);
  const matrix = {
    path: "inline",
    defaults: { expected_backend: "wasm" },
    cases: {
      "vibe/std/c_test.vibe": { expected_backend: "wasm-js-string" },
    },
  };

  const report = buildAggregatedReport({
    reportPaths: [reportAPath, reportBPath],
    failedCases: ["vibe/std/c_test.vibe"],
    attempts,
    totalCases: 3,
    backendMatrix: matrix,
  });

  assert.equal(report.case_count, 2);
  assert.equal(report.failed_case_count, 1);
  assert.equal(report.execution.trap_case_count, 1);
  assert.equal(report.failure_reason_counts.compile_unsupported, 1);
  assert.equal(report.spec.mismatch_case_count, 0);
  assert.equal(report.spec.expected_failure_count, 0);
  assert.equal(report.spec.unexpected_failure_count, 1);
  assert.equal(report.stats.point_total, 16);
  assert.equal(report.stats.point_hit, 14);
  assert.deepEqual(report.cases.map((item) => item.name), [
    "xsh__std__a_test",
    "xsh__std__b_test",
  ]);
  assert.deepEqual(
    report.failed_case_details[0].attempts.map((item) => item.mode),
    ["wasm", "wasm-js-string"],
  );
  assert.equal(report.failed_case_details[0].spec_status, "unexpected_failure");
  assert.equal(
    report.failed_case_details[0].backend.expected_backend,
    "wasm-js-string",
  );

  const markdown = buildMarkdown(report);
  assert.match(markdown, /^# xsh\/std wasm source coverage report/m);
  assert.match(markdown, /## Failure Reasons/m);
  assert.match(markdown, /compile_unsupported/);
  assert.match(markdown, /spec unexpected failures/m);
});

test("expectedBackendForCase: defaults and per-case override", () => {
  const matrix = {
    path: "inline",
    defaults: { expected_backend: "wasm" },
    cases: {
      "vibe/std/io_test.vibe": {
        expected_backend: "wasm-js-string",
        note: "requires js-string",
      },
    },
  };
  const a = expectedBackendForCase(matrix, "vibe/std/int_test.vibe");
  assert.equal(a.expected_backend, "wasm");
  assert.deepEqual(a.expected_modes, ["wasm"]);
  assert.equal(a.source, "default");

  const b = expectedBackendForCase(matrix, "vibe/std/io_test.vibe");
  assert.equal(b.expected_backend, "wasm-js-string");
  assert.deepEqual(b.expected_modes, ["wasm-js-string"]);
  assert.equal(b.source, "case");
  assert.equal(b.note, "requires js-string");
});

test("loadBackendMatrix: parses json file", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "xsh-cov-matrix-"));
  const matrixPath = path.join(dir, "backend_capabilities.json");
  fs.writeFileSync(
    matrixPath,
    JSON.stringify({
      format: "xsh-std-backend-capability-matrix-v1",
      defaults: { expected_backend: "wasm" },
      cases: {
        "vibe/std/io_test.vibe": { expected_backend: "wasm-js-string" },
      },
    }),
  );
  const matrix = loadBackendMatrix(matrixPath);
  assert.equal(matrix.path, matrixPath);
  assert.equal(matrix.defaults.expected_backend, "wasm");
  assert.equal(
    matrix.cases["vibe/std/io_test.vibe"].expected_backend,
    "wasm-js-string",
  );
});

test("buildAggregatedReport: classifies expected_failure when expected backend not attempted", () => {
  const attempts = [
    {
      case_path: "vibe/std/io_test.vibe",
      mode: "wasm",
      exit_code: 1,
      log_path: "",
      report_path: "-",
    },
  ];
  const matrix = {
    path: "inline",
    defaults: { expected_backend: "wasm" },
    cases: {
      "vibe/std/io_test.vibe": { expected_backend: "wasm-js-string" },
    },
  };
  const report = buildAggregatedReport({
    reportPaths: [],
    failedCases: ["vibe/std/io_test.vibe"],
    attempts,
    totalCases: 1,
    backendMatrix: matrix,
  });
  assert.equal(report.failed_case_count, 1);
  assert.equal(report.spec.mismatch_case_count, 0);
  assert.equal(report.spec.expected_failure_count, 1);
  assert.equal(report.spec.unexpected_failure_count, 0);
  assert.equal(report.failed_case_details[0].spec_status, "expected_failure");
});

test("buildAggregatedReport: detects measured mode mismatch", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "xsh-cov-mismatch-"));
  const reportPath = path.join(dir, "xsh__std__mismatch.report.json");
  const attempts = [
    {
      case_path: "vibe/std/mismatch_test.vibe",
      mode: "wasm-js-string",
      exit_code: 0,
      log_path: `${reportPath}.log`,
      report_path: reportPath,
    },
  ];
  fs.writeFileSync(
    reportPath,
    JSON.stringify({
      map_path: path.join(dir, "xsh__std__mismatch.wasm.cov.json"),
      stats: {
        point_total: 2,
        point_hit: 2,
        line_total: 2,
        line_hit: 2,
        branch_total: 0,
        branch_hit: 0,
      },
      lines: [{ line: 1, hit: true, count: 1 }],
      execution: { ok: true, error: null },
    }),
  );
  const matrix = {
    path: "inline",
    defaults: { expected_backend: "wasm" },
    cases: {},
  };
  const report = buildAggregatedReport({
    reportPaths: [reportPath],
    failedCases: [],
    attempts,
    totalCases: 1,
    backendMatrix: matrix,
  });
  assert.equal(report.spec.mismatch_case_count, 1);
  assert.equal(report.cases[0].spec_status, "mismatch");
});

test("buildAggregatedReport: ignores excluded lines in line totals", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "xsh-cov-excluded-lines-"));
  const reportPath = path.join(dir, "xsh__std__excluded.report.json");
  const attempts = [
    {
      case_path: "vibe/std/excluded_test.vibe",
      mode: "wasm",
      exit_code: 0,
      log_path: `${reportPath}.log`,
      report_path: reportPath,
    },
  ];
  fs.writeFileSync(
    reportPath,
    JSON.stringify({
      map_path: path.join(dir, "xsh__std__excluded.wasm.cov.json"),
      stats: {
        point_total: 3,
        point_hit: 2,
        line_total: 3,
        line_hit: 2,
        branch_total: 0,
        branch_hit: 0,
      },
      lines: [
        { line: 10, hit: true, count: 1, excluded: false },
        { line: 11, hit: false, count: 0, excluded: true },
        { line: 12, hit: true, count: 1, excluded: false },
      ],
      execution: { ok: true, error: null },
    }),
  );

  const report = buildAggregatedReport({
    reportPaths: [reportPath],
    failedCases: [],
    attempts,
    totalCases: 1,
    backendMatrix: null,
  });

  assert.equal(report.cases[0].stats.line_total, 2);
  assert.equal(report.cases[0].stats.line_hit, 2);
  assert.deepEqual(report.cases[0].missed_lines, []);
  assert.equal(report.stats.line_total, 2);
  assert.equal(report.stats.line_hit, 2);
});

test("evaluateKpi: passes and fails by thresholds", () => {
  const report = {
    total_case_count: 10,
    measured_case_count: 6,
    rates: { line: 61.5 },
  };
  const pass = evaluateKpi(report, 60, 60);
  assert.equal(pass.ok, true);
  assert.equal(pass.failures.length, 0);

  const fail = evaluateKpi(report, 70, 80);
  assert.equal(fail.ok, false);
  assert.match(fail.failures.join(" "), /measured_case_rate/);
  assert.match(fail.failures.join(" "), /line_coverage/);
});
