import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const checker = new URL("./check_fixture_snapshots.mjs", import.meta.url);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-fixture-snapshots-"));

function write(name, source) {
  const target = path.join(root, name);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, source);
}

function run(status) {
  const result = spawnSync(process.execPath, [fileURLToPath(checker)], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, status, result.stderr || result.stdout);
  return result.stderr;
}

try {
  write("fixtures/value_test.vibe", 'test { inspect(42, "42") }\n');
  write("fixtures/marker_test.vibe", 'test { inspect("__DATA__", "__DATA__") }\n');
  write("fixtures/helper.vibe", '// __DATA__ is not a tail inside a comment.\n');
  run(0);

  for (const [name, source] of [
    ["runtime.vibe", '42\n__DATA__\n{"last":"42"}\n'],
    ["opcode.vibe", '42\n__DATA__\n{"opcode":"struct.new"}\n'],
    ["malformed.vibe", '42\r\n  __DATA__\t\r\nnot json\r\n'],
  ]) {
    const relative = `fixtures/nested/${name}`;
    write(relative, source);
    assert(fs.readFileSync(path.join(root, relative), "utf8").includes("__DATA__"));
    const diagnostic = run(1);
    assert(diagnostic.includes(relative), diagnostic);
    assert.match(diagnostic, /inspect/);
    fs.unlinkSync(path.join(root, relative));
    run(0);
  }

  write("fixtures/warnings/unused.diag", "warning: unused variable\n");
  assert.match(run(1), /fixtures\/warnings\/unused\.diag/);
  fs.unlinkSync(path.join(root, "fixtures/warnings/unused.diag"));
  // Empty expected output is still a separate expectation file.
  write("fixtures/warnings/clean.diag", "");
  assert.match(run(1), /fixtures\/warnings\/clean\.diag/);
  fs.unlinkSync(path.join(root, "fixtures/warnings/clean.diag"));
  run(0);
  console.log("fixture snapshot guard: ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
