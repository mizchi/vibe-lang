///|
/// Builtin table binary encoder.
/// Parses declarations.vibe line-by-line and encodes to compact binary format.
///
/// Binary format:
///   Header: "VBLT" (4 bytes) + version u8 + count LEB128
///   Entry:  name_len LEB128 + name UTF-8 + param_count LEB128
///           + TypeTag bytes (each param) + ret TypeTag + flags u8

///|
/// TypeTag constants for binary encoding.
let type_tag_unit : Int = 0x00

///|
let type_tag_int : Int = 0x01

///|
let type_tag_bool : Int = 0x02

///|
let type_tag_string : Int = 0x03

///|
let type_tag_double : Int = 0x04

///|
let type_tag_float : Int = 0x05

///|
let type_tag_bytes : Int = 0x06

///|
let type_tag_char : Int = 0x07

///|
let type_tag_path : Int = 0x08

///|
let type_tag_v128 : Int = 0x09

///|
let type_tag_json : Int = 0x0A

///|
let type_tag_string_builder : Int = 0x0B

///|
let type_tag_prompt_text : Int = 0x0C

///|
let type_tag_array : Int = 0x10

///|
let type_tag_map : Int = 0x11

///|
let type_tag_set : Int = 0x12

///|
let type_tag_option : Int = 0x13

///|
let type_tag_array_builder : Int = 0x14

///|
let type_tag_map_builder : Int = 0x15

///|
let type_tag_fn : Int = 0x20

///|
let type_tag_t : Int = 0xF0

///|
let type_tag_unknown : Int = 0xFF

///|
/// Char codes for parsing.
let cc_open_bracket : Int = '['.to_int()

///|
let cc_close_bracket : Int = ']'.to_int()

///|
let cc_open_paren : Int = '('.to_int()

///|
let cc_close_paren : Int = ')'.to_int()

///|
let cc_comma : Int = ','.to_int()

///|
let cc_dash : Int = '-'.to_int()

///|
let cc_gt : Int = '>'.to_int()

///|
/// Parsed builtin declaration.
struct BuiltinDecl {
  name : String
  params : Array[BuiltinTypeTag]
  ret : BuiltinTypeTag
  flags : Int
} derive(Eq, Debug)

///|
impl Show for BuiltinDecl with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// Type tag for binary encoding. Supports nested container types.
enum BuiltinTypeTag {
  Unit
  Int_
  Bool_
  String_
  Double_
  Float_
  Bytes_
  Char_
  Path_
  V128_
  Json_
  StringBuilder_
  PromptText_
  Array_(BuiltinTypeTag)
  Map_(BuiltinTypeTag, BuiltinTypeTag)
  Set_(BuiltinTypeTag)
  Option_(BuiltinTypeTag)
  ArrayBuilder_(BuiltinTypeTag)
  MapBuilder_(BuiltinTypeTag, BuiltinTypeTag)
  Fn_(Array[BuiltinTypeTag], BuiltinTypeTag)
  TypeVar(Int) // 0=T, 1=U, 2=V
  Unknown
} derive(Eq, Debug)

///|
impl Show for BuiltinTypeTag with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// Write LEB128 unsigned integer to buffer.
fn write_leb128(buf : Array[Int], value : Int) -> Unit {
  let mut v = value
  while v >= 0x80 {
    buf.push(v.land(0x7F).lor(0x80))
    v = (v.reinterpret_as_uint() >> 7).reinterpret_as_int()
  }
  buf.push(v.land(0x7F))
}

///|
/// Write a type tag to the buffer (recursive for containers).
fn write_type_tag(buf : Array[Int], tag : BuiltinTypeTag) -> Unit {
  match tag {
    Unit => buf.push(type_tag_unit)
    Int_ => buf.push(type_tag_int)
    Bool_ => buf.push(type_tag_bool)
    String_ => buf.push(type_tag_string)
    Double_ => buf.push(type_tag_double)
    Float_ => buf.push(type_tag_float)
    Bytes_ => buf.push(type_tag_bytes)
    Char_ => buf.push(type_tag_char)
    Path_ => buf.push(type_tag_path)
    V128_ => buf.push(type_tag_v128)
    Json_ => buf.push(type_tag_json)
    StringBuilder_ => buf.push(type_tag_string_builder)
    PromptText_ => buf.push(type_tag_prompt_text)
    Array_(elem) => {
      buf.push(type_tag_array)
      write_type_tag(buf, elem)
    }
    Map_(key, val) => {
      buf.push(type_tag_map)
      write_type_tag(buf, key)
      write_type_tag(buf, val)
    }
    Set_(elem) => {
      buf.push(type_tag_set)
      write_type_tag(buf, elem)
    }
    Option_(elem) => {
      buf.push(type_tag_option)
      write_type_tag(buf, elem)
    }
    ArrayBuilder_(elem) => {
      buf.push(type_tag_array_builder)
      write_type_tag(buf, elem)
    }
    MapBuilder_(key, val) => {
      buf.push(type_tag_map_builder)
      write_type_tag(buf, key)
      write_type_tag(buf, val)
    }
    Fn_(params, ret) => {
      buf.push(type_tag_fn)
      write_leb128(buf, params.length())
      for p in params {
        write_type_tag(buf, p)
      }
      write_type_tag(buf, ret)
    }
    TypeVar(idx) => buf.push(type_tag_t + idx)
    Unknown => buf.push(type_tag_unknown)
  }
}

///|
/// Find the index of a char code in a string. Returns -1 if not found.
fn find_charcode(s : String, cc : Int) -> Int {
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == cc {
      return i
    }
  }
  -1
}

///|
/// Find the matching close paren for an open paren at position `start`.
fn find_matching_paren(s : String, start : Int) -> Int {
  let mut depth = 0
  for i = start; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if c == cc_open_paren {
      depth = depth + 1
    } else if c == cc_close_paren {
      depth = depth - 1
      if depth == 0 {
        return i
      }
    }
  }
  -1
}

///|
/// Find "->" arrow in a type string after the closing paren.
fn find_arrow(s : String) -> Int {
  let close = find_matching_paren(s, 0)
  if close < 0 {
    return -1
  }
  for i = close; i < s.length() - 1; i = i + 1 {
    if s[i].to_int() == cc_dash && s[i + 1].to_int() == cc_gt {
      return i
    }
  }
  -1
}

///|
/// Split a string by commas at the top level (not inside brackets/parens).
fn split_top_level_comma(s : String) -> Array[String] {
  let result : Array[String] = []
  let mut depth = 0
  let mut start = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if c == cc_open_bracket || c == cc_open_paren {
      depth = depth + 1
    } else if c == cc_close_bracket || c == cc_close_paren {
      depth = depth - 1
    } else if c == cc_comma && depth == 0 {
      result.push(s[start:i].trim().to_owned())
      start = i + 1
    }
  }
  result.push(s[start:s.length()].trim().to_owned())
  result
}

///|
/// Parse a type string (e.g. "Array[T]", "Int", "Map[String, Int]") into BuiltinTypeTag.
fn parse_type_tag(s : String) -> BuiltinTypeTag {
  let trimmed = s.trim().to_owned()
  if trimmed == "Unit" {
    return Unit
  }
  if trimmed == "Int" {
    return Int_
  }
  if trimmed == "Bool" {
    return Bool_
  }
  if trimmed == "String" {
    return String_
  }
  if trimmed == "Double" {
    return Double_
  }
  if trimmed == "Float" {
    return Float_
  }
  if trimmed == "Bytes" {
    return Bytes_
  }
  if trimmed == "Char" {
    return Char_
  }
  if trimmed == "Path" {
    return Path_
  }
  if trimmed == "V128" {
    return V128_
  }
  if trimmed == "Json" {
    return Json_
  }
  if trimmed == "StringBuilder" {
    return StringBuilder_
  }
  if trimmed == "PromptText" {
    return PromptText_
  }
  if trimmed == "T" {
    return TypeVar(0)
  }
  if trimmed == "U" {
    return TypeVar(1)
  }
  if trimmed == "V" {
    return TypeVar(2)
  }
  // Check for container types with brackets
  let bracket_start = find_charcode(trimmed, cc_open_bracket)
  if bracket_start >= 0 {
    let container_name = trimmed[0:bracket_start].to_owned()
    let inner = trimmed[bracket_start + 1:trimmed.length() - 1].to_owned()
    if container_name == "Array" {
      return Array_(parse_type_tag(inner))
    }
    if container_name == "Map" {
      let parts = split_top_level_comma(inner)
      if parts.length() == 2 {
        return Map_(parse_type_tag(parts[0]), parse_type_tag(parts[1]))
      }
    }
    if container_name == "Set" {
      return Set_(parse_type_tag(inner))
    }
    if container_name == "Option" {
      return Option_(parse_type_tag(inner))
    }
    if container_name == "ArrayBuilder" {
      return ArrayBuilder_(parse_type_tag(inner))
    }
    if container_name == "MapBuilder" {
      let parts = split_top_level_comma(inner)
      if parts.length() == 2 {
        return MapBuilder_(parse_type_tag(parts[0]), parse_type_tag(parts[1]))
      }
    }
  }
  // Check for Fn type: (T) -> U
  if trimmed.length() > 0 && trimmed[0].to_int() == cc_open_paren {
    let arrow_pos = find_arrow(trimmed)
    if arrow_pos >= 0 {
      let close_paren = find_matching_paren(trimmed, 0)
      let params_inner = trimmed[1:close_paren].trim().to_owned()
      let ret_str = trimmed[arrow_pos + 2:trimmed.length()].trim().to_owned()
      let params = if params_inner.length() == 0 {
        []
      } else {
        let parts = split_top_level_comma(params_inner)
        let result : Array[BuiltinTypeTag] = []
        for p in parts {
          result.push(parse_type_tag(p))
        }
        result
      }
      return Fn_(params, parse_type_tag(ret_str))
    }
  }
  Unknown
}

///|
/// Parse a single `declare` line into a BuiltinDecl.
/// Format: `declare Name::method(Type1, Type2) -> RetType`
fn parse_declare_line(line : String) -> BuiltinDecl? {
  let trimmed = line.trim().to_owned()
  if !trimmed.has_prefix("declare ") {
    return None
  }
  let rest = trimmed[8:trimmed.length()].to_owned()
  // Find the opening paren
  let paren_pos = find_charcode(rest, cc_open_paren)
  if paren_pos < 0 {
    return None
  }
  let name = rest[0:paren_pos].trim().to_owned()
  // Find matching close paren
  let close_paren = find_matching_paren(rest, paren_pos)
  if close_paren < 0 {
    return None
  }
  // Parse params
  let params_str = rest[paren_pos + 1:close_paren].trim().to_owned()
  let params : Array[BuiltinTypeTag] = if params_str.length() == 0 {
    []
  } else {
    let parts = split_top_level_comma(params_str)
    let result : Array[BuiltinTypeTag] = []
    for p in parts {
      result.push(parse_type_tag(p))
    }
    result
  }
  // Find "->" for return type
  let arrow_str = rest[close_paren + 1:rest.length()].trim().to_owned()
  let ret = if arrow_str.has_prefix("->") {
    parse_type_tag(arrow_str[2:arrow_str.length()].to_owned())
  } else {
    BuiltinTypeTag::Unit
  }
  Some(BuiltinDecl::{ name, params, ret, flags: 0 })
}

///|
/// Parse all declarations from source text.
fn parse_declarations(source : String) -> Array[BuiltinDecl] {
  let result : Array[BuiltinDecl] = []
  for line in source.split("\n") {
    match parse_declare_line(line.to_owned()) {
      Some(decl) => result.push(decl)
      None => ()
    }
  }
  result
}

///|
/// Encode declarations to binary format.
fn encode_builtin_table(decls : Array[BuiltinDecl]) -> Bytes {
  let buf : Array[Int] = []
  // Magic: "VBLT"
  buf.push(0x56) // V
  buf.push(0x42) // B
  buf.push(0x4C) // L
  buf.push(0x54) // T
  // Version
  buf.push(1)
  // Count
  write_leb128(buf, decls.length())
  // Entries
  for decl in decls {
    // Name - encode as UTF-8
    let name_bytes = @utf8.encode(decl.name[:])
    write_leb128(buf, name_bytes.length())
    for i = 0; i < name_bytes.length(); i = i + 1 {
      buf.push(name_bytes.unsafe_get(i).to_int())
    }
    // Param count
    write_leb128(buf, decl.params.length())
    // Param types
    for p in decl.params {
      write_type_tag(buf, p)
    }
    // Return type
    write_type_tag(buf, decl.ret)
    // Flags
    buf.push(decl.flags)
  }
  // Convert to Bytes
  let byte_arr : Array[Byte] = []
  for v in buf {
    byte_arr.push(v.to_byte())
  }
  Bytes::from_array(byte_arr[:])
}
