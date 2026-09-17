#!/usr/bin/env node
"use strict";
// Dump or strip named wasm custom sections. Used by the #2199 gate:
// dump-linemap matches `viberun --dump-linemap`; strip removes mapping
// data so a trap degrades to a wasm frame with no fabricated path:line.

const fs = require("node:fs");

function readUleb(buf, pos, end) {
  let result = 0;
  let shift = 0;
  while (pos < (end ?? buf.length)) {
    const byte = buf[pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return { value: result, next: pos };
    }
    shift += 7;
    if (shift > 35) {
      throw new Error("malformed uleb");
    }
  }
  throw new Error("truncated uleb");
}

function eachCustomSection(buf, fn) {
  if (buf.length < 8 || buf[0] !== 0x00 || buf[1] !== 0x61 || buf[2] !== 0x73 || buf[3] !== 0x6d) {
    throw new Error("not a wasm module");
  }
  let pos = 8;
  while (pos < buf.length) {
    const start = pos;
    const id = buf[pos++];
    const len = readUleb(buf, pos);
    pos = len.next;
    const bodyStart = pos;
    const bodyEnd = bodyStart + len.value;
    if (bodyEnd > buf.length) {
      throw new Error("truncated section");
    }
    if (id === 0) {
      const nameLen = readUleb(buf, bodyStart, bodyEnd);
      const nameStart = nameLen.next;
      const nameEnd = nameStart + nameLen.value;
      const name = buf.slice(nameStart, nameEnd).toString("utf8");
      fn({ start, end: bodyEnd, name, payload: buf.slice(nameEnd, bodyEnd) });
    }
    pos = bodyEnd;
  }
}

function dumpLinemap(wasmPath) {
  const buf = fs.readFileSync(wasmPath);
  let files = [];
  let payload = null;
  eachCustomSection(buf, (sec) => {
    if (sec.name === "vibe.dbgfiles") {
      files = sec.payload.toString("utf8").split("\n").filter((l) => l.length > 0);
    }
    if (sec.name === "vibe.linemap") {
      payload = sec.payload;
    }
  });
  if (!payload) {
    return;
  }
  const rows = [];
  for (let pos = 0; pos + 16 <= payload.length; pos += 16) {
    const funcIdx = payload.readUInt32LE(pos);
    const offset = payload.readUInt32LE(pos + 4);
    const fileId = payload.readUInt32LE(pos + 8);
    const line = payload.readUInt32LE(pos + 12);
    const file = fileId < files.length ? files[fileId] : String(fileId);
    rows.push({ funcIdx, offset, file, line });
  }
  rows.sort((a, b) => a.funcIdx - b.funcIdx || a.offset - b.offset);
  for (const r of rows) {
    process.stdout.write(`${r.funcIdx}\t${r.offset}\t${r.file}\t${r.line}\n`);
  }
}

function stripSections(wasmPath, outPath, names) {
  const want = new Set(names);
  const buf = fs.readFileSync(wasmPath);
  const chunks = [buf.slice(0, 8)];
  let pos = 8;
  while (pos < buf.length) {
    const start = pos;
    const id = buf[pos++];
    const len = readUleb(buf, pos);
    pos = len.next;
    const bodyEnd = pos + len.value;
    let drop = false;
    if (id === 0) {
      const nameLen = readUleb(buf, pos, bodyEnd);
      const nameEnd = nameLen.next + nameLen.value;
      const name = buf.slice(nameLen.next, nameEnd).toString("utf8");
      if (want.has(name)) {
        drop = true;
      }
    }
    if (!drop) {
      chunks.push(buf.slice(start, bodyEnd));
    }
    pos = bodyEnd;
  }
  fs.writeFileSync(outPath, Buffer.concat(chunks));
}

const cmd = process.argv[2];
if (cmd === "dump-linemap") {
  dumpLinemap(process.argv[3]);
} else if (cmd === "strip") {
  stripSections(process.argv[3], process.argv[4], process.argv.slice(5));
} else {
  console.error("usage: wasm_custom_section.js dump-linemap <wasm>");
  console.error("       wasm_custom_section.js strip <wasm> <out> <section>...");
  process.exit(2);
}
