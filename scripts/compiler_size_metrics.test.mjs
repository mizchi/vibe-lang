import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import test from "node:test";
import { collectCompilerSize, withoutNames } from "./compiler_size_metrics.mjs";

const sha = (b) => createHash("sha256").update(b).digest("hex");
const u32 = (n) => {
  const out = [];
  do { const b = n & 127; n >>>= 7; out.push(b | (n ? 128 : 0)); } while (n);
  return out;
};
const str = (s) => [...u32(Buffer.byteLength(s)), ...Buffer.from(s)];
const section = (id, b) => [id, ...u32(b.length), ...b];
const custom = (name, b) => section(0, [...str(name), ...b]);
const names = (items) => custom("name", section(1, [...u32(items.length),
  ...items.flatMap(([index, name]) => [...u32(index), ...str(name)])]));
const ownNames = ["alpha_dep_lib__vibe_compiler_core_alpha_vibe", "beta_exp_lib__vibe_compiler_core_beta_vibe"];

function fixture(t, { imports = false, labels = ownNames } = {}) {
  const root = mkdtempSync(join(tmpdir(), "vibe-compiler-size-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = join(root, "gen"); mkdirSync(dir);
  const source = join(root, "flat.vibe"); writeFileSync(source, "fn cli_main() -> Int { 0 }\n");
  const captured = join(dir, "flat.vibe"); writeFileSync(captured, readFileSync(source));
  const manifest = join(root, "lib/@vibe/compiler/compiler_sources_manifest.tsv");
  mkdirSync(join(root, "lib/@vibe/compiler"), { recursive: true });
  writeFileSync(manifest, "core\tcore/alpha.vibe\ncore\tcore/beta.vibe\n");
  const bytes = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0,
    ...section(1, [1, 0x60, 0, 0]),
    // An imported tag before a function must not shift defined function names.
    ...(imports ? section(2, [2, ...str("m"), ...str("tag"), 4, 0, 0,
      ...str("m"), ...str("f"), 0, 0]) : []),
    ...section(3, [2, 0, 0]), ...custom("other", [7]),
    ...section(10, [2, 2, 0, 0x0b, 3, 0, 1, 0x0b]),
  ]);
  const stage2 = join(dir, "stage2.wasm"); writeFileSync(stage2, bytes);
  const named = join(dir, "named.wasm");
  writeFileSync(named, Buffer.concat([bytes, Buffer.from(names(labels.map((n, i) => [i + (imports ? 1 : 0), n])))]));
  const generation = join(dir, "generation.json");
  const receipt = { schema: 1, policy: "rust-style-stage0-stage1-stage2",
    source: { commit: "a".repeat(40), dirty: false, entry: relative(root, captured), entry_sha256: sha(readFileSync(source)) },
    stages: { stage2: { sha256: sha(bytes), size: bytes.length } },
    seed: { artifact: { sha256: "b".repeat(64) } } };
  writeFileSync(generation, JSON.stringify(receipt));
  return { root, dir, source, captured, stage2, named, generation, manifest, bytes, receipt,
    options: { root, source, stage2, generation } };
}

test("code payload and body bytes remain distinct; missing names are explicit", (t) => {
  const f = fixture(t); const r = collectCompilerSize(f.options);
  assert.equal(r.code_section_bytes, 8); assert.equal(r.function_body_bytes, 5);
  assert.equal(r.defined_functions, 2); assert.equal(r.artifact_sha256, sha(f.bytes));
  assert.equal(r.source.entry_sha256, sha(readFileSync(f.source)));
  assert.deepEqual(r.attribution, { status: "unavailable", reason: "no named companion supplied" });
});

test("a name-only companion binds source groups to the same executable", (t) => {
  const f = fixture(t, { imports: true });
  const r = collectCompilerSize({ ...f.options, named: f.named });
  assert.equal(r.attribution.named_functions, 2);
  assert.equal(r.attribution.source_attributed_functions, 2);
  assert.deepEqual(r.attribution.top_functions.map((x) => x.index).sort(), [1, 2]);
  assert.equal(r.attribution.groups.reduce((n, g) => n + g.body_bytes, 0), 5);
  assert(r.attribution.groups.every((g) => g.source.startsWith("lib/@vibe/compiler/core/")));
  assert(withoutNames(readFileSync(f.named)).equals(f.bytes));
});

test("an ambiguous source tag retains bytes without guessing a file", (t) => {
  const f = fixture(t, { labels: ["a_dep_lib__vibe_compiler_core_a_b_vibe", "b_dep_lib__vibe_compiler_core_a_b_vibe"] });
  writeFileSync(f.manifest, "core\\tcore/a-b.vibe\ncore\\tcore/a_b.vibe\n");
  const r = collectCompilerSize({ ...f.options, named: f.named });
  assert.equal(r.attribution.source_attributed_functions, 0);
  assert.deepEqual(r.attribution.groups, [{ source: "<unmapped>", functions: 2, body_bytes: 5 }]);
});

test("same-size artifact corruption cannot inherit a receipt", (t) => {
  const f = fixture(t); const changed = Buffer.from(f.bytes); changed[changed.length - 2] = 0;
  assert.equal(changed.length, f.bytes.length); assert(!changed.equals(f.bytes));
  writeFileSync(f.stage2, changed);
  assert.throws(() => collectCompilerSize(f.options), /stage2 does not match/);
});

test("an empty artifact cannot masquerade as a zero-size compiler", (t) => {
  const f = fixture(t); const empty = f.bytes.subarray(0, 8);
  writeFileSync(f.stage2, empty);
  f.receipt.stages.stage2 = { sha256: sha(empty), size: empty.length };
  writeFileSync(f.generation, JSON.stringify(f.receipt));
  assert.throws(() => collectCompilerSize(f.options), /no defined compiler functions/);
});

test("old receipts and a different requested source refuse instead of falling back", (t) => {
  const f = fixture(t);
  delete f.receipt.source.entry_sha256; writeFileSync(f.generation, JSON.stringify(f.receipt));
  assert.throws(() => collectCompilerSize(f.options), /input checksum is missing/);
  f.receipt.source.entry_sha256 = sha(readFileSync(f.source)); writeFileSync(f.generation, JSON.stringify(f.receipt));
  writeFileSync(f.source, "another source snapshot\n");
  assert.throws(() => collectCompilerSize(f.options), /requested source snapshot/);
});

test("a changed captured input and a missing receipt are detected", (t) => {
  const f = fixture(t); writeFileSync(f.captured, "changed\n");
  assert.throws(() => collectCompilerSize(f.options), /captured generation input/);
  assert.throws(() => collectCompilerSize({ ...f.options, generation: join(f.dir, "missing.json") }), /ENOENT/);
});

test("a companion must supply complete names and preserve every other section", (t) => {
  const f = fixture(t);
  assert.throws(() => collectCompilerSize({ ...f.options, named: f.stage2 }), /name every defined/);
  writeFileSync(f.named, Buffer.concat([f.bytes, Buffer.from(names([[0, ownNames[0]]]))]));
  assert.throws(() => collectCompilerSize({ ...f.options, named: f.named }), /name every defined/);
  writeFileSync(f.named, Buffer.concat([f.bytes, Buffer.from(names([[0, ownNames[0]], [1, ownNames[1]]])), Buffer.from(custom("extra", [1]))]));
  assert.throws(() => collectCompilerSize({ ...f.options, named: f.named }), /differs outside name sections/);
});

test("malformed section envelopes refuse boundedly", () => {
  const header = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]);
  assert.throws(() => withoutNames(Buffer.concat([header, Buffer.from([0, 5, 9])])), /truncated/);
  assert.throws(() => withoutNames(Buffer.concat([header, Buffer.from([1, 128, 128, 128, 128, 128, 0])])), /oversized/);
  assert.throws(() => withoutNames(Buffer.from("not Wasm")), /core Wasm/);
});

test("the JSON interface and prior text mode agree, including tag imports", (t) => {
  const f = fixture(t, { imports: true });
  const tool = new URL("./wasm_func_sizes.mjs", import.meta.url).pathname;
  const data = JSON.parse(execFileSync(process.execPath, [tool, f.named, "--json"], { encoding: "utf8", timeout: 5000 }));
  assert.equal(data.importedFunctions, 1); assert.equal(data.namedFunctions, 2);
  const text = execFileSync(process.execPath, [tool, f.named, "--top", "2"], { encoding: "utf8", timeout: 5000 });
  assert.match(text, /#\s+2/); assert.match(text, /5 B across 2 functions \(2 named\)/);
  const run = spawnSync(process.execPath, [new URL("./compiler_size_metrics.mjs", import.meta.url).pathname,
    f.stage2, "--root", f.root, "--source", f.source], { encoding: "utf8", timeout: 5000 });
  assert.equal(run.status, 0, run.stderr); assert.equal(JSON.parse(run.stdout).defined_functions, 2);
});

test("unhandled import forms cannot silently shift attribution", (t) => {
  const f = fixture(t);
  const bytes = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0,
    ...section(2, [1, ...str("m"), ...str("mem"), 2, 3, 0, 1]), ...section(10, [0])]);
  const path = join(f.dir, "shared.wasm"); writeFileSync(path, bytes);
  const run = spawnSync(process.execPath, [new URL("./wasm_func_sizes.mjs", import.meta.url).pathname, path, "--json"],
    { encoding: "utf8", timeout: 5000 });
  assert.notEqual(run.status, 0); assert.match(run.stderr, /unsupported import limits flags/);
});
