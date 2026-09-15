#!/usr/bin/env node
// Reading the persistent cache's artifact envelopes from OUTSIDE the compiler:
// which cache wrote this file, and for which module?
//
// The filename cannot answer. `persistent_artifact_cache_path` hashes
// (version_tag, kind, entry_name, fingerprint) into one opaque token, so two
// artifacts for the same module at different sources are two unrelated names,
// and two artifacts for different modules are equally unrelated. A harness that
// wants to pair artifacts BY MODULE has to read the module out of the bytes.
//
// It is written there. `checked_module_cache_input_identity` puts
// `normalize_path(path)` third, and `commit_checked_module_artifact` stores the
// identity verbatim at the head of the payload -- it is the same field the
// decoder validates before accepting a transport, so pairing on it pairs on
// exactly what acceptance turns on.
//
//   file    := "VART1" u32le(payload_len) payload          (@vibe/cache/cache.vibe)
//   payload := "vMOD" u8(1) u32le(sum1) u32le(sum2)
//              varint(len(identity)) identity ...          (artifacts/module)
//   identity:= str("checked-module-input-v1") str(context) str(path) str(source) ...
//   str     := varint(byte length) bytes                   (ast_binary_write_string)
//
// Every offset above is asserted rather than assumed: a layout change must
// surface as a thrown error here, not as a pairing that quietly degrades to
// "some other module's artifact".
import fs from "node:fs";
import path from "node:path";

export const ENVELOPE_MAGIC = Buffer.from("VART1");
/// Which cache wrote an artifact is readable from its payload magic, which is
/// how a harness can ask "did the cold run populate THIS cache" without
/// reconstructing a filename it cannot compute.
export const PAYLOAD_MAGICS = {
  checked_module: Buffer.from([118, 77, 79, 68, 1]), // "vMOD", version 1
  codegen_body_cache: Buffer.from("VBW2"),
};
export const PAYLOAD_MAGIC = PAYLOAD_MAGICS.checked_module;
export const IDENTITY_MAGIC = "checked-module-input-v1";

const PAYLOAD_AT = ENVELOPE_MAGIC.length + 4;
// "vMOD" + version, then the two 4-byte checksum slots encode_checked_module_artifact
// back-patches. The identity length varint follows them.
const IDENTITY_LEN_AT = PAYLOAD_AT + PAYLOAD_MAGIC.length + 8;

function readVarint(bytes, at) {
  let value = 0, shift = 0, i = at;
  for (;;) {
    if (i >= bytes.length) throw new Error(`checked-module artifact: varint runs past the end at ${at}`);
    const byte = bytes[i++];
    value += (byte & 0x7f) * 2 ** shift;
    if (!(byte & 0x80)) break;
    shift += 7;
    if (shift > 49) throw new Error(`checked-module artifact: varint too long at ${at}`);
  }
  if (!Number.isSafeInteger(value)) throw new Error(`checked-module artifact: varint out of range at ${at}`);
  return { value, next: i };
}

function readString(bytes, at) {
  const { value: length, next } = readVarint(bytes, at);
  const end = next + length;
  if (end > bytes.length) throw new Error(`checked-module artifact: string of ${length} bytes runs past the end at ${at}`);
  return { value: bytes.subarray(next, end), next: end };
}

/// Cheap enough to run over every file in a cache directory: the two magics and
/// nothing else. A file that passes this is an artifact envelope of `kind`;
/// whether its payload is INTACT is the compiler's question, not this one's.
export function isArtifact(bytes, kind = "checked_module") {
  const magic = PAYLOAD_MAGICS[kind];
  if (!magic) throw new Error(`unknown artifact kind: ${kind}`);
  return bytes.length >= PAYLOAD_AT + magic.length &&
    bytes.subarray(0, ENVELOPE_MAGIC.length).equals(ENVELOPE_MAGIC) &&
    bytes.subarray(PAYLOAD_AT, PAYLOAD_AT + magic.length).equals(magic);
}

export const isModuleArtifact = bytes => isArtifact(bytes, "checked_module");

/// The module path and the raw input identity this artifact was published for.
export function moduleArtifactIdentity(bytes) {
  if (!isModuleArtifact(bytes)) throw new Error("checked-module artifact: not a vMOD artifact envelope");
  const declared = bytes.readUInt32LE(ENVELOPE_MAGIC.length);
  if (declared !== bytes.length - PAYLOAD_AT) {
    throw new Error(`checked-module artifact: envelope declares ${declared} payload bytes, file carries ${bytes.length - PAYLOAD_AT}`);
  }
  const identity = readString(bytes, IDENTITY_LEN_AT);
  const magic = readString(identity.value, 0);
  if (magic.value.toString("latin1") !== IDENTITY_MAGIC) {
    throw new Error(`checked-module artifact: identity magic is ${JSON.stringify(magic.value.toString("latin1"))}, not ${IDENTITY_MAGIC}`);
  }
  const context = readString(identity.value, magic.next);
  const modulePath = readString(identity.value, context.next);
  return {
    path: modulePath.value.toString("latin1"),
    context: context.value.toString("latin1"),
    identity: identity.value,
  };
}

/// The artifacts in `dir` that are checked-module transports, as
/// `{ file, bytes, path }`. Anything else in the cache directory (type
/// environments, header lists, body caches) is skipped by magic, so this does
/// not depend on the filename convention it cannot read anyway.
export function readModuleArtifacts(dir) {
  return fs.readdirSync(dir).flatMap(name => {
    const file = path.join(dir, name);
    if (!fs.statSync(file).isFile()) return [];
    const bytes = fs.readFileSync(file);
    if (!isModuleArtifact(bytes)) return [];
    return [{ file, bytes, path: moduleArtifactIdentity(bytes).path }];
  });
}

/// How many artifacts of each kind a cache directory holds. "Did the cold run
/// populate the cache the warm run is supposed to consume?" is a question about
/// bytes on disk, and it is answerable before, and independently of, whatever
/// the warm run reports about itself.
export function countArtifacts(dir) {
  const counts = Object.fromEntries(Object.keys(PAYLOAD_MAGICS).map(kind => [kind, 0]));
  if (!fs.existsSync(dir)) return counts;
  for (const name of fs.readdirSync(dir)) {
    const file = path.join(dir, name);
    if (!fs.statSync(file).isFile()) continue;
    const bytes = fs.readFileSync(file);
    for (const kind of Object.keys(PAYLOAD_MAGICS)) if (isArtifact(bytes, kind)) counts[kind]++;
  }
  return counts;
}

/// The pre-edit artifact of the SAME module as `canonical`, or null when that
/// module's artifact did not move across the edit (an untouched module, which
/// is not a stale-transport case and must not be faked as one by reaching for
/// a different module's bytes: that artifact is rejected for its path, which
/// proves nothing about a decoder that accepts an earlier source).
export function pickStaleArtifact(canonical, pool) {
  const wanted = moduleArtifactIdentity(canonical).path;
  const sameModule = pool.filter(entry => entry.path === wanted);
  const stale = sameModule.find(entry => !entry.bytes.equals(canonical));
  if (!stale) return null;
  return { bytes: stale.bytes, path: wanted, candidates: sameModule.length };
}
