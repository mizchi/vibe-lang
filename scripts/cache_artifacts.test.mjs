// The offsets in cache_artifacts.mjs are a second copy of a layout the
// compiler owns, so they are the kind of thing that rots silently: a reader
// that drifts still returns A string, and pairing on the wrong string degrades
// to the "any differing artifact" behaviour #2836 §3 exists to remove.
//
// So this file encodes artifacts the way the compiler does (varint-prefixed
// strings, "VART1" envelope, "vMOD" payload) and requires the reader to answer
// from them -- including at lengths that need a multi-byte varint, which is
// every real source. The paired check against artifacts a REAL compiler
// published is the parity script's own green run: it reads every artifact in
// two cache directories and throws if any offset here is wrong.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  ENVELOPE_MAGIC, IDENTITY_MAGIC, PAYLOAD_MAGIC,
  countArtifacts, isArtifact, isModuleArtifact, moduleArtifactIdentity, pickStaleArtifact,
} from "./cache_artifacts.mjs";

function varint(value) {
  const out = [];
  let x = value;
  do { const byte = x & 0x7f; x = Math.floor(x / 128); out.push(x ? byte | 0x80 : byte); } while (x);
  return Buffer.from(out);
}
const str = text => Buffer.concat([varint(Buffer.byteLength(text, "latin1")), Buffer.from(text, "latin1")]);

function artifact({ magic = IDENTITY_MAGIC, context = "ctx", path = "lib/leaf.vibe", source = "fn main() -> Int { 1 }",
  payloadMagic = PAYLOAD_MAGIC, envelopeMagic = ENVELOPE_MAGIC, declaredLength = null } = {}) {
  const identity = Buffer.concat([str(magic), str(context), str(path), str(source), str("strict"), varint(0)]);
  const payload = Buffer.concat([payloadMagic, Buffer.alloc(8), varint(identity.length), identity, Buffer.from([7, 7])]);
  const header = Buffer.alloc(4);
  header.writeUInt32LE(declaredLength ?? payload.length);
  return Buffer.concat([envelopeMagic, header, payload]);
}

test("reads the module path out of a well-formed artifact", () => {
  assert.equal(moduleArtifactIdentity(artifact()).path, "lib/leaf.vibe");
  assert.equal(moduleArtifactIdentity(artifact()).context, "ctx");
});

test("reads past the one-byte varint boundary", () => {
  // A real module source is thousands of bytes, so every field before the path
  // is length-prefixed with a multi-byte varint. A reader that assumed one byte
  // would pass every short synthetic case and fail on every real artifact.
  for (const length of [126, 127, 128, 129, 16383, 16384]) {
    const long = "x".repeat(length);
    assert.equal(moduleArtifactIdentity(artifact({ context: long })).path, "lib/leaf.vibe");
    assert.equal(moduleArtifactIdentity(artifact({ path: long, source: long })).path, long);
  }
});

test("rejects an envelope that is not a checked-module artifact", () => {
  for (const bytes of [artifact({ envelopeMagic: Buffer.from("VART2") }),
    artifact({ payloadMagic: Buffer.from([118, 77, 79, 68, 2]) }), Buffer.alloc(0), Buffer.from("VART1")]) {
    assert.equal(isModuleArtifact(bytes), false);
    assert.throws(() => moduleArtifactIdentity(bytes), /not a vMOD artifact envelope/);
  }
});

test("rejects an envelope whose declared payload length disagrees", () => {
  assert.throws(() => moduleArtifactIdentity(artifact({ declaredLength: 3 })), /envelope declares 3 payload bytes/);
});

test("rejects an identity that does not start with the expected magic", () => {
  assert.throws(() => moduleArtifactIdentity(artifact({ magic: "checked-module-input-v2" })),
    /identity magic is "checked-module-input-v2"/);
});

test("rejects a truncated artifact rather than inventing a path", () => {
  const bytes = artifact();
  assert.throws(() => moduleArtifactIdentity(bytes.subarray(0, bytes.length - 40)),
    /runs past the end|envelope declares/);
});

const entry = bytes => ({ bytes, path: moduleArtifactIdentity(bytes).path });

test("pairs the stale artifact by module, not by 'some bytes that differ'", () => {
  const canonical = artifact({ path: "lib/leaf.vibe", source: "after" });
  const pool = [
    entry(artifact({ path: "lib/mid.vibe", source: "unrelated" })),
    entry(artifact({ path: "lib/entry.vibe", source: "unrelated" })),
    entry(artifact({ path: "lib/leaf.vibe", source: "before" })),
  ];
  const picked = pickStaleArtifact(canonical, pool);
  assert.equal(picked.path, "lib/leaf.vibe");
  assert.equal(moduleArtifactIdentity(picked.bytes).path, "lib/leaf.vibe");
  assert.ok(picked.bytes.equals(artifact({ path: "lib/leaf.vibe", source: "before" })));
});

test("declines rather than reaching for another module when this one did not move", () => {
  const canonical = artifact({ path: "lib/leaf.vibe", source: "same" });
  const pool = [entry(canonical), entry(artifact({ path: "lib/mid.vibe", source: "differs" }))];
  assert.equal(pickStaleArtifact(canonical, pool), null);
});

test("declines when the module is absent from the pool entirely", () => {
  assert.equal(pickStaleArtifact(artifact({ path: "lib/new.vibe" }),
    [entry(artifact({ path: "lib/leaf.vibe" }))]), null);
});

test("tells the two cache kinds apart by payload magic", () => {
  const module = artifact();
  const body = artifact({ payloadMagic: Buffer.from("VBW2") });
  assert.equal(isArtifact(module, "checked_module"), true);
  assert.equal(isArtifact(module, "codegen_body_cache"), false);
  assert.equal(isArtifact(body, "codegen_body_cache"), true);
  assert.equal(isArtifact(body, "checked_module"), false);
  assert.throws(() => isArtifact(module, "nonesuch"), /unknown artifact kind: nonesuch/);
});

test("counts what a cache directory holds, and ignores what it does not own", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-cache-artifacts-"));
  try {
    fs.writeFileSync(path.join(dir, "a.bin"), artifact({ path: "lib/leaf.vibe" }));
    fs.writeFileSync(path.join(dir, "b.bin"), artifact({ path: "lib/mid.vibe" }));
    fs.writeFileSync(path.join(dir, "c.bin"), artifact({ payloadMagic: Buffer.from("VBW2") }));
    // A type-environment entry, a header list, a stray directory: the cache
    // root holds many things, and a count that included them would report a
    // populated cache for a cache that published nothing.
    fs.writeFileSync(path.join(dir, "d.txt"), "not an artifact envelope at all");
    fs.writeFileSync(path.join(dir, "e.bin"), artifact({ envelopeMagic: Buffer.from("VART2") }));
    fs.mkdirSync(path.join(dir, "sub"));
    assert.deepEqual(countArtifacts(dir), { checked_module: 2, codegen_body_cache: 1 });
    assert.deepEqual(countArtifacts(path.join(dir, "sub")), { checked_module: 0, codegen_body_cache: 0 });
    assert.deepEqual(countArtifacts(path.join(dir, "absent")), { checked_module: 0, codegen_body_cache: 0 });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
