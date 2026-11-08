#!/usr/bin/env node
// Exercise the oracle using real captured answers, not a scripted compiler.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { assertCurrentAnswers, compareSnapshots, scenarios } from "./probe.mjs";

const [phase, path] = process.argv.slice(2);
assert(["before", "after"].includes(phase) && path, "usage: verify_receipt.mjs before|after <receipt.json>");
const receipt = JSON.parse(readFileSync(path, "utf8"));
assert.equal(receipt.schema, 1);
assert(receipt.rounds >= 3);
assert.equal(receipt.records.length, 2 * receipt.rounds * scenarios.length);
const failed = [];
const seen = new Set();
for (const row of receipt.records) {
  const key = `${row.engine}/${row.round}/${row.name}`;
  assert(!seen.has(key), `duplicate ${key}`);
  seen.add(key);
  const scenario = scenarios.find((item) => item.name === row.name);
  assert(scenario, `unknown case ${key}`);
  assertCurrentAnswers(row.snapshot, scenario);
  assertCurrentAnswers(row.fresh_snapshot, scenario);
  if (!row.equivalent) {
    failed.push(key);
    assert.throws(() => compareSnapshots(row.snapshot, row.fresh_snapshot, key), /stale diagnostics/);
  } else compareSnapshots(row.snapshot, row.fresh_snapshot, key);
  for (const group of [row.wall_ms, row.fresh_wall_ms]) {
    for (const metric of ["hover", "repeat_hover", "references", "symbols"]) {
      assert(Number.isFinite(group[metric]) && group[metric] > 0, `missing timing ${key}/${metric}`);
    }
  }
}
assert.equal(receipt.passed, failed.length === 0);
if (phase === "before") {
  assert.deepEqual(failed.sort(), Array.from({ length: receipt.rounds }, (_, round) => `node/${round}/dependency_missing`).sort());
} else assert.deepEqual(failed, [], "candidate must match fresh state everywhere");

let refused = 0;
for (const engine of ["node", "selfhost"]) {
  const get = (name) => receipt.records.find((row) => row.engine === engine && row.round === 0 && row.name === name).snapshot;
  const cases = [
    ["diagnostics", "parse_error", "recovered"],
    ["hover", "initial", "unsaved_type_edit"],
    ["references", "initial", "moved_locations"],
    ["symbols", "initial", "moved_locations"],
    ["doc", "unsaved_type_edit", "doc_only_edit"],
  ];
  for (const [field, oldName, currentName] of cases) {
    const current = get(currentName), old = get(oldName);
    assert.notDeepEqual(old[field], current[field], `vacuous stale-${field} mutation`);
    const mutated = structuredClone(current);
    mutated[field] = structuredClone(old[field]);
    assert.throws(() => compareSnapshots(mutated, current, `${engine}/mutant`), new RegExp(`stale ${field}`));
    refused++;
  }
  for (const field of ["diagnostics", "hover", "references", "symbols", "doc"]) {
    const missing = structuredClone(get("initial"));
    delete missing[field];
    assert.throws(() => compareSnapshots(missing, get("initial"), `${engine}/missing-${field}`));
    refused++;
  }
}
console.log(JSON.stringify({ phase, comparisons: receipt.records.length, expected_failures: failed, captured_answer_mutations_refused: refused }));
