///|
/// Minimal wasm-to-wat printer for xsh codegen tests.
suberror WasmWatError {
  UnexpectedEof
  InvalidMagic
  InvalidSection(String)
  UnsupportedOpcode(Int)
} derive(Show, Eq)

///|
priv struct Cursor {
  bytes : Bytes
  mut pos : Int
}

///|
fn Cursor::new(bytes : Bytes) -> Cursor {
  { bytes, pos: 0 }
}

///|
fn Cursor::remaining(self : Cursor) -> Int {
  self.bytes.length() - self.pos
}

///|
fn Cursor::read_u8(self : Cursor) -> Int raise WasmWatError {
  if self.pos >= self.bytes.length() {
    raise WasmWatError::UnexpectedEof
  }
  let b = self.bytes[self.pos]
  self.pos += 1
  b.to_int()
}

///|
fn Cursor::read_bytes(self : Cursor, n : Int) -> Bytes raise WasmWatError {
  if self.pos + n > self.bytes.length() {
    raise WasmWatError::UnexpectedEof
  }
  let view = self.bytes[self.pos:self.pos + n]
  self.pos += n
  view.to_bytes()
}

///|
fn Cursor::read_leb_u32(self : Cursor) -> Int raise WasmWatError {
  let mut result = 0
  let mut shift = 0
  while true {
    let b = self.read_u8()
    result = result | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 {
      return result
    }
    shift += 7
    if shift > 35 {
      raise WasmWatError::InvalidSection("leb overflow")
    }
  }
  result
}

///|
fn Cursor::read_name(self : Cursor) -> String raise WasmWatError {
  let len = self.read_leb_u32()
  let bytes = self.read_bytes(len)
  @utf8.decode_lossy(bytes[:])
}

///|
priv struct FuncType {
  params : Array[Int]
  results : Array[Int]
}

///|
priv struct ImportEntry {
  module_name : String
  name : String
  kind : Int
  type_index : Int
}

///|
priv struct ExportEntry {
  name : String
  kind : Int
  index : Int
}

///|
priv struct FuncBody {
  locals : Array[Int]
  instrs : Array[Instr]
}

///|
priv struct MemoryType {
  min : Int
  max : Int?
}

///|
priv struct DataSegment {
  offset : Int
  bytes : Bytes
}

///|
priv enum Instr {
  Simple(String)
  If(String?)
  Else
  End
}

///|
fn val_type_name(code : Int) -> String {
  match code {
    0x7f => "i32"
    0x7e => "i64"
    0x7d => "f32"
    0x7c => "f64"
    _ => "unknown"
  }
}

///|
fn block_type_name(code : Int) -> String? {
  if code == 0x40 {
    None
  } else {
    Some(val_type_name(code))
  }
}

///|
fn bytes_to_u32_le(bytes : Bytes) -> Int {
  let arr = bytes.to_array()
  let mut out = 0
  for i in 0..<arr.length() {
    out = out | (arr[i].to_int() << (8 * i))
  }
  out
}

///|
fn bytes_to_u64_le(bytes : Bytes) -> UInt64 {
  let arr = bytes.to_array()
  let mut out : UInt64 = 0
  for i in 0..<arr.length() {
    let part = arr[i].to_uint64() << (8 * i)
    out = out | part
  }
  out
}

///|
fn parse_instrs(cursor : Cursor) -> Array[Instr] raise WasmWatError {
  let instrs : Array[Instr] = []
  while cursor.remaining() > 0 {
    let op = cursor.read_u8()
    match op {
      0x41 => {
        let value = cursor.read_leb_u32()
        instrs.push(Instr::Simple("i32.const " + value.to_string()))
      }
      0x43 => {
        let bytes = cursor.read_bytes(4)
        let bits = bytes_to_u32_le(bytes)
        let value = Float::reinterpret_from_int(bits)
        instrs.push(Instr::Simple("f32.const " + value.to_string()))
      }
      0x44 => {
        let bytes = cursor.read_bytes(8)
        let bits = bytes_to_u64_le(bytes)
        let value = UInt64::reinterpret_as_double(bits)
        instrs.push(Instr::Simple("f64.const " + value.to_string()))
      }
      0x20 => {
        let idx = cursor.read_leb_u32()
        instrs.push(Instr::Simple("local.get " + idx.to_string()))
      }
      0x21 => {
        let idx = cursor.read_leb_u32()
        instrs.push(Instr::Simple("local.set " + idx.to_string()))
      }
      0x22 => {
        let idx = cursor.read_leb_u32()
        instrs.push(Instr::Simple("local.tee " + idx.to_string()))
      }
      0x10 => {
        let idx = cursor.read_leb_u32()
        instrs.push(Instr::Simple("call " + idx.to_string()))
      }
      0x1a => instrs.push(Instr::Simple("drop"))
      0x6a => instrs.push(Instr::Simple("i32.add"))
      0x6b => instrs.push(Instr::Simple("i32.sub"))
      0x6c => instrs.push(Instr::Simple("i32.mul"))
      0x6d => instrs.push(Instr::Simple("i32.div_s"))
      0x6f => instrs.push(Instr::Simple("i32.rem_s"))
      0x92 => instrs.push(Instr::Simple("f32.add"))
      0x93 => instrs.push(Instr::Simple("f32.sub"))
      0x94 => instrs.push(Instr::Simple("f32.mul"))
      0x95 => instrs.push(Instr::Simple("f32.div"))
      0xa0 => instrs.push(Instr::Simple("f64.add"))
      0xa1 => instrs.push(Instr::Simple("f64.sub"))
      0xa2 => instrs.push(Instr::Simple("f64.mul"))
      0xa3 => instrs.push(Instr::Simple("f64.div"))
      0x45 => instrs.push(Instr::Simple("i32.eqz"))
      0x46 => instrs.push(Instr::Simple("i32.eq"))
      0x47 => instrs.push(Instr::Simple("i32.ne"))
      0x48 => instrs.push(Instr::Simple("i32.lt_s"))
      0x5b => instrs.push(Instr::Simple("f32.eq"))
      0x5d => instrs.push(Instr::Simple("f32.lt"))
      0x61 => instrs.push(Instr::Simple("f64.eq"))
      0x63 => instrs.push(Instr::Simple("f64.lt"))
      0x4a => instrs.push(Instr::Simple("i32.gt_s"))
      0x4c => instrs.push(Instr::Simple("i32.le_s"))
      0x4e => instrs.push(Instr::Simple("i32.ge_s"))
      0x74 => instrs.push(Instr::Simple("i32.shl"))
      0x76 => instrs.push(Instr::Simple("i32.shr_u"))
      0x72 => instrs.push(Instr::Simple("i32.or"))
      0x71 => instrs.push(Instr::Simple("i32.and"))
      0x73 => instrs.push(Instr::Simple("i32.xor"))
      0x8c => instrs.push(Instr::Simple("f32.neg"))
      0x99 => instrs.push(Instr::Simple("f64.neg"))
      0x28 => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "i32.load align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x2a => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "f32.load align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x2b => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "f64.load align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x36 => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "i32.store align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x38 => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "f32.store align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x39 => {
        let align = cursor.read_leb_u32()
        let offset = cursor.read_leb_u32()
        instrs.push(
          Instr::Simple(
            "f64.store align=" +
            align.to_string() +
            " offset=" +
            offset.to_string(),
          ),
        )
      }
      0x04 => {
        let block_type = cursor.read_u8()
        instrs.push(Instr::If(block_type_name(block_type)))
      }
      0x05 => instrs.push(Instr::Else)
      0x0b => instrs.push(Instr::End)
      _ => raise WasmWatError::UnsupportedOpcode(op)
    }
  }
  instrs
}

///|
fn escape_hex_digit(n : Int) -> Char {
  if n < 10 {
    ('0'.to_int() + n).unsafe_to_char()
  } else {
    ('a'.to_int() + (n - 10)).unsafe_to_char()
  }
}

///|
fn escape_bytes(bytes : Bytes) -> String {
  let sb = StringBuilder::new()
  for b in bytes {
    let code = b.to_int()
    if code >= 0x20 && code <= 0x7e && code != 0x22 && code != 0x5c {
      sb.write_char(code.unsafe_to_char())
    } else {
      sb.write_char('\\')
      sb.write_char(escape_hex_digit(code / 16))
      sb.write_char(escape_hex_digit(code % 16))
    }
  }
  sb.to_string()
}

///|
fn escape_wat_string(s : String) -> String {
  escape_bytes(@utf8.encode(s))
}

///|
fn write_indent(sb : StringBuilder, level : Int) -> Unit {
  for _ in 0..<level {
    sb.write_char(' ')
  }
}

///|
fn write_instrs(
  sb : StringBuilder,
  instrs : Array[Instr],
  indent : Int,
) -> Unit {
  let mut level = indent
  let mut block_depth = 0
  for instr in instrs {
    match instr {
      Instr::If(result) => {
        write_indent(sb, level)
        match result {
          Some(ty) => sb.write_string("if (result " + ty + ")")
          None => sb.write_string("if")
        }
        sb.write_char('\n')
        level += 2
        block_depth += 1
      }
      Instr::Else => {
        level -= 2
        write_indent(sb, level)
        sb.write_string("else")
        sb.write_char('\n')
        level += 2
      }
      Instr::End => {
        if block_depth > 0 {
          level -= 2
          block_depth -= 1
        }
        write_indent(sb, level)
        sb.write_string("end")
        sb.write_char('\n')
      }
      Instr::Simple(text) => {
        write_indent(sb, level)
        sb.write_string(text)
        sb.write_char('\n')
      }
    }
  }
}

///|
pub fn wasm_to_wat(bytes : Bytes) -> String raise WasmWatError {
  let cursor = Cursor::new(bytes)
  if cursor.read_u8() != 0x00 ||
    cursor.read_u8() != 0x61 ||
    cursor.read_u8() != 0x73 ||
    cursor.read_u8() != 0x6d {
    raise WasmWatError::InvalidMagic
  }
  // version
  let _ = cursor.read_u8()
  let _ = cursor.read_u8()
  let _ = cursor.read_u8()
  let _ = cursor.read_u8()
  let types : Array[FuncType] = []
  let imports : Array[ImportEntry] = []
  let func_types : Array[Int] = []
  let memories : Array[MemoryType] = []
  let exports : Array[ExportEntry] = []
  let funcs : Array[FuncBody] = []
  let data : Array[DataSegment] = []
  while cursor.remaining() > 0 {
    let id = cursor.read_u8()
    let size = cursor.read_leb_u32()
    let section_bytes = cursor.read_bytes(size)
    let sec = Cursor::new(section_bytes)
    match id {
      1 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let form = sec.read_u8()
          if form != 0x60 {
            raise WasmWatError::InvalidSection("type form")
          }
          let param_count = sec.read_leb_u32()
          let params : Array[Int] = []
          for _ in 0..<param_count {
            params.push(sec.read_u8())
          }
          let result_count = sec.read_leb_u32()
          let results : Array[Int] = []
          for _ in 0..<result_count {
            results.push(sec.read_u8())
          }
          types.push(FuncType::{ params, results })
        }
      }
      2 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let module_name = sec.read_name()
          let name = sec.read_name()
          let kind = sec.read_u8()
          if kind != 0 {
            raise WasmWatError::InvalidSection("import kind")
          }
          let type_index = sec.read_leb_u32()
          imports.push(ImportEntry::{ module_name, name, kind, type_index })
        }
      }
      3 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          func_types.push(sec.read_leb_u32())
        }
      }
      5 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let flags = sec.read_leb_u32()
          let min = sec.read_leb_u32()
          let max = if (flags & 1) == 1 {
            Some(sec.read_leb_u32())
          } else {
            None
          }
          memories.push(MemoryType::{ min, max })
        }
      }
      7 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let name = sec.read_name()
          let kind = sec.read_u8()
          let index = sec.read_leb_u32()
          exports.push(ExportEntry::{ name, kind, index })
        }
      }
      10 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let body_size = sec.read_leb_u32()
          let body_bytes = sec.read_bytes(body_size)
          let body = Cursor::new(body_bytes)
          let local_group_count = body.read_leb_u32()
          let locals : Array[Int] = []
          for _ in 0..<local_group_count {
            let n = body.read_leb_u32()
            let ty = body.read_u8()
            for _ in 0..<n {
              locals.push(ty)
            }
          }
          let instrs = parse_instrs(body)
          funcs.push(FuncBody::{ locals, instrs })
        }
      }
      11 => {
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let kind = sec.read_u8()
          if kind != 0 {
            raise WasmWatError::InvalidSection("data kind")
          }
          let op = sec.read_u8()
          if op != 0x41 {
            raise WasmWatError::InvalidSection("data offset op")
          }
          let offset = sec.read_leb_u32()
          let end = sec.read_u8()
          if end != 0x0b {
            raise WasmWatError::InvalidSection("data offset end")
          }
          let data_len = sec.read_leb_u32()
          let bytes = sec.read_bytes(data_len)
          data.push(DataSegment::{ offset, bytes })
        }
      }
      _ => ()
    }
  }
  let sb = StringBuilder::new()
  sb.write_string("(module\n")
  for i in 0..<types.length() {
    let ty = types[i]
    write_indent(sb, 2)
    sb.write_string("(type (;")
    sb.write_string(i.to_string())
    sb.write_string(";) (func")
    if ty.params.length() > 0 {
      sb.write_string(" (param")
      for p in ty.params {
        sb.write_string(" " + val_type_name(p))
      }
      sb.write_string(")")
    }
    if ty.results.length() > 0 {
      sb.write_string(" (result")
      for r in ty.results {
        sb.write_string(" " + val_type_name(r))
      }
      sb.write_string(")")
    }
    sb.write_string("))\n")
  }
  let mut import_func_count = 0
  for i in 0..<imports.length() {
    let imp = imports[i]
    if imp.kind == 0 {
      write_indent(sb, 2)
      sb.write_string("(import \"")
      sb.write_string(escape_wat_string(imp.module_name))
      sb.write_string("\" \"")
      sb.write_string(escape_wat_string(imp.name))
      sb.write_string("\" (func (;")
      sb.write_string(import_func_count.to_string())
      sb.write_string(";) (type ")
      sb.write_string(imp.type_index.to_string())
      sb.write_string(")))\n")
      import_func_count += 1
    }
  }
  for i in 0..<funcs.length() {
    let func_index = import_func_count + i
    let type_index = func_types[i]
    let func = funcs[i]
    write_indent(sb, 2)
    sb.write_string("(func (;")
    sb.write_string(func_index.to_string())
    sb.write_string(";) (type ")
    sb.write_string(type_index.to_string())
    sb.write_string(")")
    if func.locals.length() > 0 {
      sb.write_string(" (local")
      for ty in func.locals {
        sb.write_string(" " + val_type_name(ty))
      }
      sb.write_string(")")
    }
    sb.write_char('\n')
    write_instrs(sb, func.instrs, 4)
    write_indent(sb, 2)
    sb.write_string(")\n")
  }
  for i in 0..<memories.length() {
    let mem = memories[i]
    write_indent(sb, 2)
    sb.write_string("(memory (;")
    sb.write_string(i.to_string())
    sb.write_string(";) ")
    sb.write_string(mem.min.to_string())
    match mem.max {
      Some(max) => sb.write_string(" " + max.to_string())
      None => ()
    }
    sb.write_string(")\n")
  }
  for exp in exports {
    write_indent(sb, 2)
    sb.write_string("(export \"")
    sb.write_string(escape_wat_string(exp.name))
    sb.write_string("\" (")
    let kind = match exp.kind {
      0 => "func"
      2 => "memory"
      _ => "unknown"
    }
    sb.write_string(kind)
    sb.write_string(" ")
    sb.write_string(exp.index.to_string())
    sb.write_string("))\n")
  }
  for seg in data {
    write_indent(sb, 2)
    sb.write_string("(data (i32.const ")
    sb.write_string(seg.offset.to_string())
    sb.write_string(") \"")
    sb.write_string(escape_bytes(seg.bytes))
    sb.write_string("\")\n")
  }
  sb.write_string(")")
  sb.to_string()
}
