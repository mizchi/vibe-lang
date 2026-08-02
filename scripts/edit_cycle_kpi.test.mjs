import assert from "node:assert/strict";
import test from "node:test";

import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";

const validSidecar = JSON.stringify({
  schema: 1,
  modules_planned: 2,
  modules_rechecked: 1,
  modules_reused: 1,
  parse_operations: 3,
  modules_failed_or_blocked: 0,
});

test("edit-cycle KPI accepts a complete incremental typecheck sidecar", () => {
  assert.deepEqual(parseIncrementalTelemetry(validSidecar), JSON.parse(validSidecar));
});

test("edit-cycle KPI rejects malformed or internally inconsistent telemetry", () => {
  assert.throws(
    () => parseIncrementalTelemetry("not json"),
    /invalid JSON/,
  );
  assert.throws(
    () => parseIncrementalTelemetry(JSON.stringify({
      schema: 1,
      modules_planned: 2,
      modules_rechecked: 2,
      modules_reused: 1,
      parse_operations: 3,
      modules_failed_or_blocked: 0,
    })),
    /must equal modules_planned/,
  );
});
