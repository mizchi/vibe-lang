#!/usr/bin/env node
// wasm_section_sizes.mjs — wasm モジュールをセクション単位・関数単位に分解して
// バイト数を出す。「どちらが大きいか」ではなく「どこが大きいか」に答えるための
// もので、docs/wasm/code-size-linear-vs-gc.md の内訳表はこれで取っている。
//
//   node scripts/wasm_section_sizes.mjs [--json] <file.wasm> [more.wasm ...]
//
// 出力 (既定、1 ファイル 1 行 + セクション行):
//
//   <name> total=<bytes> funcs=<n> stubs=<n> bodied=<n>
//     code 4577  type 76  import 35  ...
//
// `stubs` は本体が 4 バイト以下の関数の数。linear レーンはランタイムヘルパの
// スロットを常に確保しつつ、使われた本体だけを埋めるので、この 2 つの数の比が
// 「そのモジュールが実際に何を使ったか」を表す。wasm-gc レーンは使用に関係なく
// 本体を吐くので、プログラムを変えてもこの比が動かない — 内訳を見る目的は
// まさにその差を出すことにある。
//
// 依存なし。wasm binary format の section header と code section の関数本体長
// (どちらも LEB128) だけを読む。命令レベルの解析はしない。
import fs from 'node:fs';

const SECTION_NAMES = {
  0: 'custom', 1: 'type', 2: 'import', 3: 'func', 4: 'table', 5: 'mem',
  6: 'global', 7: 'export', 8: 'start', 9: 'elem', 10: 'code', 11: 'data',
  12: 'datacount', 13: 'tag',
};

// 本体がこのバイト数以下なら「埋められていないスロット」と見なす。空関数は
// ローカル宣言 0 + `end` で 2 バイト、定数を 1 つ返すだけで 4 バイト程度。
const STUB_MAX_BYTES = 4;

function readU32(buf, offset) {
  let value = 0;
  let shift = 0;
  let byte;
  do {
    if (offset >= buf.length) throw new Error('truncated LEB128');
    byte = buf[offset++];
    value += (byte & 0x7f) * 2 ** shift;
    shift += 7;
  } while (byte & 0x80);
  return [value, offset];
}

function analyze(path) {
  const buf = fs.readFileSync(path);
  if (buf.length < 8 || buf.readUInt32LE(0) !== 0x6d736100) {
    throw new Error(`${path}: not a wasm module`);
  }
  const sections = {};
  const funcSizes = [];
  let offset = 8;
  while (offset < buf.length) {
    const id = buf[offset++];
    let size;
    [size, offset] = readU32(buf, offset);
    let name = SECTION_NAMES[id] ?? `id${id}`;
    if (id === 0) {
      // custom セクションは名前で区別しないと全部 "custom" に潰れる。
      let nameLen;
      let cursor;
      [nameLen, cursor] = readU32(buf, offset);
      name = `custom:${buf.subarray(cursor, cursor + nameLen).toString('utf8')}`;
    }
    if (id === 10) {
      let count;
      let cursor;
      [count, cursor] = readU32(buf, offset);
      for (let i = 0; i < count; i++) {
        let bodySize;
        [bodySize, cursor] = readU32(buf, cursor);
        funcSizes.push(bodySize);
        cursor += bodySize;
      }
    }
    sections[name] = (sections[name] ?? 0) + size;
    offset += size;
  }
  const stubs = funcSizes.filter((s) => s <= STUB_MAX_BYTES).length;
  return {
    file: path,
    total: buf.length,
    sections,
    funcs: funcSizes.length,
    stubs,
    bodied: funcSizes.length - stubs,
    codeBytes: funcSizes.reduce((a, b) => a + b, 0),
    largest: [...funcSizes].sort((a, b) => b - a).slice(0, 8),
  };
}

const args = process.argv.slice(2);
const asJson = args[0] === '--json';
const files = asJson ? args.slice(1) : args;
if (files.length === 0) {
  console.error('usage: node scripts/wasm_section_sizes.mjs [--json] <file.wasm> ...');
  process.exit(2);
}

const results = files.map(analyze);
if (asJson) {
  console.log(JSON.stringify(results, null, 2));
} else {
  for (const r of results) {
    console.log(
      `${r.file} total=${r.total} funcs=${r.funcs} stubs=${r.stubs} bodied=${r.bodied} codeBytes=${r.codeBytes}`,
    );
    const ordered = Object.entries(r.sections).sort((a, b) => b[1] - a[1]);
    console.log('  ' + ordered.map(([k, v]) => `${k} ${v}`).join('  '));
    console.log('  largest funcs: ' + r.largest.join(', '));
  }
}
