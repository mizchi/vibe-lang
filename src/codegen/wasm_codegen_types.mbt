///|
/// Minimal WASM (wasm-gc compatible) codegen for vibe
suberror WasmGenError {
  UnknownName(String)
  Unsupported(String)
  BackendLimit(backend~ : String, feature~ : String)
} derive(Debug, Eq)

///|
pub impl Show for WasmGenError with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub fn WasmGenError::is_backend_limit(self : WasmGenError) -> Bool {
  match self {
    BackendLimit(_) => true
    _ => false
  }
}

///|
pub fn WasmGenError::format_message(self : WasmGenError) -> String {
  match self {
    BackendLimit(backend~, feature~) =>
      "backend '" + backend + "' does not support: " + feature
    Unsupported(msg) => "codegen: unsupported: " + msg
    UnknownName(name) => "codegen: unknown name: " + name
  }
}

///|
pub enum WasmCoveragePointKind {
  Line
  BranchIfThen
  BranchIfElse
  BranchMatchArm
} derive(Debug, Eq)

///|
pub impl Show for WasmCoveragePointKind with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub struct WasmCoveragePoint {
  id : Int
  kind : WasmCoveragePointKind
  span : @core.Span
} derive(Debug, Eq)

///|
pub impl Show for WasmCoveragePoint with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub struct WasmCoverageArtifact {
  bytes : Bytes
  counter_base : Int
  counter_count : Int
  points : Array[WasmCoveragePoint]
} derive(Debug, Eq)

///|
pub impl Show for WasmCoverageArtifact with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub struct WasmEmitOptions {
  embed_error_strings : Bool
  http_host_imports : Bool
  http_component_wasi_shim : Bool
  fs_host_imports : Bool
  force_cabi_realloc : Bool
  /// Library mode: skip _start generation, export all functions.
  /// Produces a .wasm suitable for `wasmtime --preload`.
  library_mode : Bool
  /// Linked imports: (wasm_module_name, func_name, param_count, return_count) tuples.
  /// These become wasm function imports instead of inlined definitions.
  linked_imports : Array[(String, String, Int, Int)]
  /// Enable Perceus RC codegen (experimental).
  enable_rc : Bool
  /// Enable RC debug mode: track alloc/free counts for leak detection.
  rc_debug : Bool
  /// Perceus actions for top-level (_start): (site, is_dup, name) tuples.
  rc_actions : Array[(String, Bool, String)]
  /// Per-function Perceus actions: func_name → (site, is_dup, name) tuples.
  rc_func_actions : Map[String, Array[(String, Bool, String)]]
  /// Original source — used only to render `<line>:<col>` (instead of
  /// `<offset>`) in lambda labels of the wasm `name` custom section.
  /// Empty disables the upgrade.
  source : String
} derive(Debug, Eq)

///|
pub impl Show for WasmEmitOptions with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub fn wasm_emit_options(
  embed_error_strings? : Bool = false,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
  fs_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
  linked_imports? : Array[(String, String, Int, Int)] = [],
  enable_rc? : Bool = false,
  rc_debug? : Bool = false,
  rc_actions? : Array[(String, Bool, String)] = [],
  rc_func_actions? : Map[String, Array[(String, Bool, String)]] = {},
  source? : String = "",
) -> WasmEmitOptions {
  {
    embed_error_strings,
    http_host_imports,
    http_component_wasi_shim,
    fs_host_imports,
    force_cabi_realloc,
    library_mode,
    linked_imports,
    enable_rc,
    rc_debug,
    rc_actions,
    rc_func_actions,
    source,
  }
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
let obj_string_view = 11

///|
let obj_array_view = 12

///|
let obj_bytes = 13

///|
let obj_bytes_view = 14

///|
/// Int64Array: i64-cell buffer storing tagged vibe Ints without truncation.
/// Header [tag, len, cap, data_ptr]; data is len * 8 bytes (one i64 per elem).
let obj_int64array = 15

///|
let obj_v128 = 15

///|
enum ValueKind {
  I32
  I64
  BoxedF32
  BoxedF64
  ExternRef
  V128
} derive(Debug, Eq)

///|
impl Show for ValueKind with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
fn valtype_byte(kind : ValueKind) -> Byte {
  match kind {
    ValueKind::I32 => (127).to_byte()
    ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
      (126).to_byte()
    ValueKind::ExternRef => (111).to_byte()
    ValueKind::V128 => (123).to_byte() // 0x7B
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
fn _tag_ptr(ptr : Int, tag : Int) -> Int {
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
/// Allocate a nullary enum constructor singleton in the data section.
/// Returns the offset where the 8-byte object [obj_type, ctor_tag] is placed.
fn StringTable::intern_enum_singleton(
  self : StringTable,
  ctor_name : String,
  ctor_tag : Int,
) -> Int {
  let key = "__enum__" + ctor_name
  match self.map.get(key) {
    Some(offset) => offset
    None => {
      let data : Array[Byte] = []
      write_u32_le_bytes(data, obj_enum) // offset 0: obj_type
      write_u32_le_bytes(data, 0) // offset 4: arity = 0
      write_u32_le_bytes(data, ctor_tag) // offset 8: ctor_tag
      let offset = self.next_offset
      self.map[key] = offset
      self.segments.push(StringSegment::{ offset, bytes: data })
      self.next_offset = align4(offset + data.length())
      offset
    }
  }
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
