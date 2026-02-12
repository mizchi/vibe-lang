///|
/// Minimal WASM (wasm-gc compatible) codegen for vibe
suberror WasmGenError {
  UnknownName(String)
  Unsupported(String)
} derive(Show, Eq)

///|
pub enum WasmCoveragePointKind {
  Line
  BranchIfThen
  BranchIfElse
  BranchMatchArm
} derive(Show, Eq)

///|
pub struct WasmCoveragePoint {
  id : Int
  kind : WasmCoveragePointKind
  span : @core.Span
} derive(Show, Eq)

///|
pub struct WasmCoverageArtifact {
  bytes : Bytes
  counter_base : Int
  counter_count : Int
  points : Array[WasmCoveragePoint]
} derive(Show, Eq)

///|
pub struct WasmEmitOptions {
  embed_error_strings : Bool
} derive(Show, Eq)

///|
pub fn wasm_emit_options(
  embed_error_strings? : Bool = false,
) -> WasmEmitOptions {
  { embed_error_strings, }
}

///|
priv struct StringSegment {
  offset : Int
  bytes : Array[Byte]
}

///|
priv struct StringTable {
  mut next_offset : Int
  map : Map[String, Int]
  segments : Array[StringSegment]
}

///|
fn StringTable::new() -> StringTable {
  { next_offset: 0, map: {}, segments: [] }
}

///|
fn align4(n : Int) -> Int {
  let rem = n % 4
  if rem == 0 {
    n
  } else {
    n + (4 - rem)
  }
}

///|
let tag_mask = 3

///|
let tag_int = 0

///|
let tag_obj = 1

///|
let tag_bool = 3

///|
let tag_fn = 2

///|
let obj_string = 1

///|
let obj_tuple = 3

///|
let obj_record = 4

///|
let obj_array = 5

///|
let obj_map = 6

///|
let obj_fn = 7

///|
let obj_float = 8

///|
let obj_double = 9

///|
let obj_enum = 10

///|
enum ValueKind {
  I32
  I64
  BoxedF32
  BoxedF64
  ExternRef
} derive(Show, Eq)

///|
fn valtype_byte(kind : ValueKind) -> Byte {
  match kind {
    ValueKind::I32 => (127).to_byte()
    ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
      (126).to_byte()
    ValueKind::ExternRef => (111).to_byte()
  }
}

///|
priv struct StringConstTable {
  map : Map[String, Int]
  names : Array[String]
}

///|
fn StringConstTable::new() -> StringConstTable {
  { map: {}, names: [] }
}

///|
fn StringConstTable::intern(self : StringConstTable, s : String) -> Int {
  match self.map.get(s) {
    Some(idx) => idx
    None => {
      let idx = self.names.length()
      self.map[s] = idx
      self.names.push(s)
      idx
    }
  }
}

///|
fn tag_ptr(ptr : Int, tag : Int) -> Int {
  ptr | (tag & tag_mask)
}

///|
fn tag_int_value64(n : Int64) -> Int64 {
  (n << 2) | tag_int.to_int64()
}

///|
fn tag_bool_value64(b : Bool) -> Int64 {
  let n : Int64 = if b { 1L } else { 0L }
  (n << 2) | tag_bool.to_int64()
}

///|
fn tag_fn_value64(idx : Int64) -> Int64 {
  (idx << 2) | tag_fn.to_int64()
}

///|
fn tag_ptr64(ptr : Int, tag : Int) -> Int64 {
  (ptr | (tag & tag_mask)).to_int64()
}

///|
fn StringTable::intern(self : StringTable, s : String) -> Int {
  match self.map.get(s) {
    Some(offset) => offset
    None => {
      let bytes = @utf8.encode(s)
      let content = bytes.to_array()
      let len = content.length()
      let data : Array[Byte] = []
      write_u32_le_bytes(data, obj_string)
      write_u32_le_bytes(data, len)
      for b in content {
        data.push(b)
      }
      let offset = self.next_offset
      self.map[s] = offset
      self.segments.push(StringSegment::{ offset, bytes: data })
      self.next_offset = align4(offset + data.length())
      offset
    }
  }
}

///|
fn u32_leb_len(n : Int) -> Int {
  let mut v = if n < 0 { 0 } else { n }
  let mut len = 1
  while v >= 128 {
    v = v >> 7
    len += 1
  }
  len
}

///|
fn data_segment_entry_len(offset : Int, len : Int) -> Int {
  1 + 1 + u32_leb_len(offset) + 1 + u32_leb_len(len) + len
}

///|
fn segmented_data_content_len(strings : StringTable) -> Int {
  let mut total = u32_leb_len(strings.segments.length())
  for seg in strings.segments {
    total += data_segment_entry_len(seg.offset, seg.bytes.length())
  }
  total
}

///|
fn packed_data_content_len(strings : StringTable) -> Int {
  let data_len = strings.next_offset
  u32_leb_len(1) + data_segment_entry_len(0, data_len)
}

///|
fn pack_string_segments(strings : StringTable) -> Array[Byte] {
  let total_len = strings.next_offset
  let data : Array[Byte] = Array::make(total_len, (0).to_byte())
  for seg in strings.segments {
    let seg_len = seg.bytes.length()
    for i in 0..<seg_len {
      data[seg.offset + i] = seg.bytes[i]
    }
  }
  data
}
