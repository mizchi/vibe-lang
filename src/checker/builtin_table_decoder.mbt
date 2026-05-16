///|
/// Builtin table binary decoder.
/// Decodes the compact binary format back to Array[BuiltinTableEntry].
///
/// Binary format:
///   Header: "VBLT" (4 bytes) + version u8 + count LEB128
///   Entry:  name_len LEB128 + name UTF-8 + param_count LEB128
///           + TypeTag bytes (each param) + ret TypeTag + flags u8

///|
/// Decoded builtin table entry.
struct BuiltinTableEntry {
  name : String
  params : Array[BuiltinTypeId]
  ret : BuiltinTypeId
  flags : Int
} derive(Eq, Debug)

///|
/// Type identifier decoded from binary.
enum BuiltinTypeId {
  BTUnit
  BTInt
  BTBool
  BTString
  BTDouble
  BTFloat
  BTBytes
  BTChar
  BTPath
  BTV128
  BTJson
  BTStringBuilder
  BTPromptText
  BTArray(BuiltinTypeId)
  BTMap(BuiltinTypeId, BuiltinTypeId)
  BTSet(BuiltinTypeId)
  BTOption(BuiltinTypeId)
  BTArrayBuilder(BuiltinTypeId)
  BTMapBuilder(BuiltinTypeId, BuiltinTypeId)
  BTFn(Array[BuiltinTypeId], BuiltinTypeId)
  BTTypeVar(Int) // 0=T, 1=U, 2=V
  BTUnknown
} derive(Eq, Debug)

///|
/// Read LEB128 unsigned integer from bytes at position.
/// Updates pos[0] to point past the decoded value.
fn read_leb128(data : Bytes, pos : Array[Int]) -> Int {
  let mut result = 0
  let mut shift = 0
  while true {
    let byte = data.unsafe_get(pos[0]).to_int()
    pos[0] = pos[0] + 1
    result = result.lor(byte.land(0x7F) << shift)
    if byte.land(0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  result
}

///|
/// Read a type tag from bytes at position.
/// Updates pos[0] past the decoded type.
fn read_type_tag(data : Bytes, pos : Array[Int]) -> BuiltinTypeId {
  let tag = data.unsafe_get(pos[0]).to_int()
  pos[0] = pos[0] + 1
  if tag == 0x00 {
    return BTUnit
  }
  if tag == 0x01 {
    return BTInt
  }
  if tag == 0x02 {
    return BTBool
  }
  if tag == 0x03 {
    return BTString
  }
  if tag == 0x04 {
    return BTDouble
  }
  if tag == 0x05 {
    return BTFloat
  }
  if tag == 0x06 {
    return BTBytes
  }
  if tag == 0x07 {
    return BTChar
  }
  if tag == 0x08 {
    return BTPath
  }
  if tag == 0x09 {
    return BTV128
  }
  if tag == 0x0A {
    return BTJson
  }
  if tag == 0x0B {
    return BTStringBuilder
  }
  if tag == 0x0C {
    return BTPromptText
  }
  if tag == 0x10 {
    let elem = read_type_tag(data, pos)
    return BTArray(elem)
  }
  if tag == 0x11 {
    let key = read_type_tag(data, pos)
    let val = read_type_tag(data, pos)
    return BTMap(key, val)
  }
  if tag == 0x12 {
    let elem = read_type_tag(data, pos)
    return BTSet(elem)
  }
  if tag == 0x13 {
    let elem = read_type_tag(data, pos)
    return BTOption(elem)
  }
  if tag == 0x14 {
    let elem = read_type_tag(data, pos)
    return BTArrayBuilder(elem)
  }
  if tag == 0x15 {
    let key = read_type_tag(data, pos)
    let val = read_type_tag(data, pos)
    return BTMapBuilder(key, val)
  }
  if tag == 0x20 {
    let param_count = read_leb128(data, pos)
    let params : Array[BuiltinTypeId] = []
    for i = 0; i < param_count; i = i + 1 {
      params.push(read_type_tag(data, pos))
      let _ = i
    }
    let ret = read_type_tag(data, pos)
    return BTFn(params, ret)
  }
  if tag >= 0xF0 && tag <= 0xF2 {
    return BTTypeVar(tag - 0xF0)
  }
  BTUnknown
}

///|
/// Decode builtin table from binary bytes.
/// Returns None if magic number doesn't match.
fn decode_builtin_table(data : Bytes) -> Array[BuiltinTableEntry]? {
  // Check magic: "VBLT"
  if data.length() < 5 {
    return None
  }
  if data.unsafe_get(0).to_int() != 0x56 ||
    data.unsafe_get(1).to_int() != 0x42 ||
    data.unsafe_get(2).to_int() != 0x4C ||
    data.unsafe_get(3).to_int() != 0x54 {
    return None
  }
  let pos : Array[Int] = [4]
  // Version
  let _version = data.unsafe_get(pos[0]).to_int()
  pos[0] = pos[0] + 1
  // Count
  let count = read_leb128(data, pos)
  let result : Array[BuiltinTableEntry] = []
  for i = 0; i < count; i = i + 1 {
    // Name (UTF-8 bytes -> String via Char array)
    let name_len = read_leb128(data, pos)
    let name_chars : Array[Char] = []
    for j = 0; j < name_len; j = j + 1 {
      name_chars.push(data.unsafe_get(pos[0] + j).to_int().unsafe_to_char())
    }
    pos[0] = pos[0] + name_len
    let name = String::from_iter(name_chars.iter())
    // Params
    let param_count = read_leb128(data, pos)
    let params : Array[BuiltinTypeId] = []
    for j = 0; j < param_count; j = j + 1 {
      params.push(read_type_tag(data, pos))
      let _ = j
    }
    // Return type
    let ret = read_type_tag(data, pos)
    // Flags
    let flags = data.unsafe_get(pos[0]).to_int()
    pos[0] = pos[0] + 1
    result.push(BuiltinTableEntry::{ name, params, ret, flags })
    let _ = i
  }
  Some(result)
}
