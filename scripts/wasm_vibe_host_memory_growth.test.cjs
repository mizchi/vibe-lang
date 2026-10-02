'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const {createHostRuntime} = require('./wasm_vibe_host_runtime.js');
const PAGE = 65536;
function fixture(initial=4, maximum=8, heap=initial*PAGE-8, type='i32') {
  const host=createHostRuntime(); host.HOST_IMPORT_ABI='raw';
  const memory=new WebAssembly.Memory({initial, maximum});
  const global=new WebAssembly.Global({value:type,mutable:true},type==='i64'?BigInt(heap):heap);
  const instance={exports:{memory,__heap_ptr:global}};
  return {host,instance,memory,global};
}
test('ordinary host growth is geometric and retains the raw string address', () => {
  const f=fixture(); const text='abc日本語';
  const before=Number(f.global.value);
  const result=f.host.encodeHostString(f.instance,text);
  assert.equal(Number(BigInt.asUintN(64,result)>>32n),before);
  assert.equal(f.host.decodeStringArg(f.instance,result),text);
  assert.equal(f.memory.buffer.byteLength,6*PAGE);
});
for (const type of ['i32','i64']) {
  test(`bounded memory retries exact growth and retains ${type} heap/string content`, () => {
    const f=fixture(4,5,4*PAGE-8,type);
    new Uint8Array(f.memory.buffer).set([19,255,70],0);
    const text='abc日本語'; const result=f.host.encodeHostString(f.instance,text);
    assert.equal(f.host.decodeStringArg(f.instance,result),text);
    assert.equal(f.memory.buffer.byteLength,5*PAGE);
    assert.equal(Number(f.global.value),4*PAGE+8);
    assert.deepEqual([...new Uint8Array(f.memory.buffer,0,3)],[19,255,70]);
  });
  test(`bounded memory preserves raw byte header and payload with ${type} heap`, () => {
    const f=fixture(4,5,4*PAGE-8,type);
    const payload=Buffer.from([0,255,9,31,128,20,8,2,5,6]);
    const pointer=f.host.encodeHostBytes(f.instance,payload);
    assert.deepEqual(Buffer.from(f.host.decodeHostBytes(f.instance,pointer)),payload);
    const view=new DataView(f.memory.buffer);
    assert.equal(view.getInt32(Number(pointer),true),-payload.length);
    assert.equal(view.getUint32(Number(pointer)+4,true),payload.length);
    assert.equal(view.getUint32(Number(pointer)+8,true),Number(pointer)+12);
    assert.equal(f.memory.buffer.byteLength,5*PAGE);
  });
}
test('an unsatisfiable host allocation fails without advancing the heap', () => {
  const f=fixture(4,4); const before=f.global.value;
  assert.throws(()=>f.host.encodeHostString(f.instance,'abc日本語'),RangeError);
  assert.equal(f.global.value,before);
  assert.equal(f.memory.buffer.byteLength,4*PAGE);
});
test('non-capacity errors are preserved without retry', () => {
  const f=fixture(); const error=new Error('growth denied');let calls=0;
  f.memory.grow=()=>{calls++;throw error;};
  assert.throws(()=>f.host.encodeHostString(f.instance,'abc日本語'),e=>e===error);
  assert.equal(calls,1);
});
test('exact deficit larger than half the current capacity is requested directly', () => {
  const f=fixture(2,12);const text='q'.repeat(6*PAGE);
  const result=f.host.encodeHostString(f.instance,text);
  assert.equal(f.host.decodeStringArg(f.instance,result),text);
  assert.equal(f.memory.buffer.byteLength,8*PAGE);
});
test('allocation fitting current capacity does not grow', () => {
  const f=fixture(4,8,8);const buffer=f.memory.buffer;
  f.host.encodeHostBytes(f.instance,Buffer.from([3,2,1]));
  assert.equal(f.memory.buffer,buffer);
});
for (const cabi of [false,true]) {
  test(`Preview2 stream read preserves bounded allocation, cabi=${cabi}`, () => {
    const old=process.env.VIBE_STDIN_BYTES;
    process.env.VIBE_STDIN_BYTES='a'.repeat(20);
    try {
      const f=fixture(4,5);
      f.host.instanceRefGlobal=f.instance;
      if(cabi)f.instance.exports.cabi_realloc=()=>BigInt(4*PAGE-8);
      const imports=f.host.createPreview2CliStreamsHost();
      const streams=imports['wasi:io/streams@0.2.0'];
      streams['[method]input-stream.blocking-read'](3n,20n,64n);
      const view=new DataView(f.memory.buffer);
      assert.equal(view.getUint8(64),0);
      const ptr=view.getUint32(68,true),len=view.getUint32(72,true);
      assert.equal(ptr,4*PAGE-8);
      assert.equal(len,20);
      assert.equal(Buffer.from(f.memory.buffer,ptr,len).toString(),'a'.repeat(20));
      assert.equal(f.memory.buffer.byteLength,5*PAGE);
      assert.equal(f.global.value,cabi ? 4*PAGE-8 : 4*PAGE+12);
    } finally {
      if(old===undefined)delete process.env.VIBE_STDIN_BYTES;else process.env.VIBE_STDIN_BYTES=old;
    }
  });
}
test('explicit pre-grow remains an exact target', () => {
  const old=process.env.VIBE_WASM_PRE_GROW_PAGES;
  process.env.VIBE_WASM_PRE_GROW_PAGES='5';
  try {const f=fixture();f.host.preGrowWasmMemory(f.instance);assert.equal(f.memory.buffer.byteLength,5*PAGE);}
  finally {if(old===undefined)delete process.env.VIBE_WASM_PRE_GROW_PAGES;else process.env.VIBE_WASM_PRE_GROW_PAGES=old;}
});
test('raw arena growth retains its separate allocation cursor', () => {
  const oldMode=process.env.VIBE_WASM_HOST_ALLOC_MODE;
  const oldGuard=process.env.VIBE_WASM_HOST_ARENA_GUARD_BYTES;
  process.env.VIBE_WASM_HOST_ALLOC_MODE='arena';
  process.env.VIBE_WASM_HOST_ARENA_GUARD_BYTES='0';
  try {
    const f=fixture(); const before=f.global.value;
    const result=f.host.encodeHostString(f.instance,'abc日本語');
    assert.equal(f.host.decodeStringArg(f.instance,result),'abc日本語');
    assert.equal(f.global.value,before);
    assert.equal(f.memory.buffer.byteLength,6*PAGE);
    assert.equal(f.host.hostAllocPtrGlobal,4*PAGE+8);
  } finally {
    for (const [key,value] of [['VIBE_WASM_HOST_ALLOC_MODE',oldMode],['VIBE_WASM_HOST_ARENA_GUARD_BYTES',oldGuard]]) {
      if(value===undefined)delete process.env[key];else process.env[key]=value;
    }
  }
});
test('zero-initial-capacity memory grows by its actual deficit', () => {
  const f=fixture(0,1,0);const result=f.host.encodeHostString(f.instance,'日本');
  assert.equal(f.host.decodeStringArg(f.instance,result),'日本');
  assert.equal(f.memory.buffer.byteLength,PAGE);
});
test('exact growth failure is reported once when deficit dominates geometric policy', () => {
  const f=fixture(2,2);const original=f.memory.grow.bind(f.memory);let calls=0;
  f.memory.grow=(delta)=>{calls++;return original(delta);};
  assert.throws(()=>f.host.encodeHostString(f.instance,'x'.repeat(4*PAGE)),RangeError);
  assert.equal(calls,1);
});
