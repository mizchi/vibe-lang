///|
/// Tests for executing vibe-generated WASM
suberror WasmEvalError {
  UnexpectedEof
  Invalid(String)
  Unsupported(String)
} derive(Show, Eq)

///|
suberror WasmRunError {
  Compile(String)
  Eval(String)
} derive(Show, Eq)

///|
struct WasmEvalResult {
  value : Int64
  outputs : Array[String]
  mem : Array[Byte]
} derive(Show, Eq)

///|
struct Cursor {
  bytes : Array[Byte]
  mut pos : Int
}

///|
fn Cursor::new(bytes : Array[Byte]) -> Cursor {
  { bytes, pos: 0 }
}

///|
fn Cursor::remaining(self : Cursor) -> Int {
  self.bytes.length() - self.pos
}

///|
fn Cursor::read_u8(self : Cursor) -> Int raise WasmEvalError {
  if self.pos >= self.bytes.length() {
    raise WasmEvalError::UnexpectedEof
  }
  let b = self.bytes[self.pos]
  self.pos += 1
  b.to_int()
}

///|
fn Cursor::read_bytes(
  self : Cursor,
  n : Int,
) -> Array[Byte] raise WasmEvalError {
  if self.pos + n > self.bytes.length() {
    raise WasmEvalError::UnexpectedEof
  }
  let out : Array[Byte] = []
  for i in 0..<n {
    out.push(self.bytes[self.pos + i])
  }
  self.pos += n
  out
}

///|
fn Cursor::read_leb_u32(self : Cursor) -> Int raise WasmEvalError {
  let mut result = 0
  let mut shift = 0
  while true {
    let byte = self.read_u8()
    result = result | ((byte & 0x7f) << shift)
    if (byte & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 35 {
      raise WasmEvalError::Invalid("leb overflow")
    }
  }
  result
}

///|
fn Cursor::read_leb_i64(self : Cursor) -> Int64 raise WasmEvalError {
  let mut result : Int64 = 0L
  let mut shift = 0
  let mut last_byte = 0
  while true {
    let byte = self.read_u8()
    last_byte = byte
    result = result | ((byte & 0x7f).to_int64() << shift)
    if (byte & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 63 {
      raise WasmEvalError::Invalid("i64 leb overflow")
    }
  }
  // Sign extend if the sign bit of the last byte is set
  if shift < 64 && (last_byte & 0x40) != 0 {
    result = result | (-1L << (shift + 7))
  }
  result
}

///|
fn Cursor::read_name(self : Cursor) -> String raise WasmEvalError {
  let len = self.read_leb_u32()
  let bytes = self.read_bytes(len)
  bytes_to_string(bytes)
}

///|
fn bytes_to_string(bytes : Array[Byte]) -> String {
  let buf = StringBuilder::new()
  for b in bytes {
    buf.write_char(b.to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
fn read_u32_le(bytes : Array[Byte], pos : Int) -> Int raise WasmEvalError {
  if pos + 4 > bytes.length() {
    raise WasmEvalError::UnexpectedEof
  }
  let b0 = bytes[pos].to_int()
  let b1 = bytes[pos + 1].to_int()
  let b2 = bytes[pos + 2].to_int()
  let b3 = bytes[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn write_u32_le(
  bytes : Array[Byte],
  pos : Int,
  value : Int,
) -> Unit raise WasmEvalError {
  if pos + 4 > bytes.length() {
    raise WasmEvalError::UnexpectedEof
  }
  bytes[pos] = (value & 0xff).to_byte()
  bytes[pos + 1] = ((value >> 8) & 0xff).to_byte()
  bytes[pos + 2] = ((value >> 16) & 0xff).to_byte()
  bytes[pos + 3] = ((value >> 24) & 0xff).to_byte()
}

///|
fn read_string_object(
  mem : Array[Byte],
  ptr : Int64,
) -> String raise WasmEvalError {
  let base = untag_ptr(ptr)
  let ty = read_u32_le(mem, base)
  if ty != obj_string && ty != obj_path {
    raise WasmEvalError::Invalid("not string object")
  }
  let len = read_u32_le(mem, base + 4)
  let start = base + 8
  if start + len > mem.length() {
    raise WasmEvalError::UnexpectedEof
  }
  let buf = StringBuilder::new()
  for i in 0..<len {
    let b = mem[start + i]
    buf.write_char(b.to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
let tag_mask : Int64 = 3L

///|
let tag_obj : Int64 = 1L

///|
let tag_int : Int64 = 0L

///|
let tag_bool : Int64 = 3L

///|
let obj_string = 1

///|
let obj_path = 2

///|
let obj_array = 5

///|
let obj_map = 6

///|
fn untag_ptr(ptr : Int64) -> Int {
  (ptr - (ptr & tag_mask)).to_int()
}

///|
fn tag_of(ptr : Int64) -> Int64 {
  ptr & tag_mask
}

///|
fn is_tagged_obj(ptr : Int64) -> Bool {
  tag_of(ptr) == tag_obj
}

///|
fn is_tagged_int(ptr : Int64) -> Bool {
  tag_of(ptr) == tag_int
}

///|
fn decode_int(ptr : Int64) -> Int64 {
  ptr >> 2
}

///|
fn is_tagged_bool(ptr : Int64) -> Bool {
  tag_of(ptr) == tag_bool
}

///|
fn decode_bool(ptr : Int64) -> Bool {
  ptr >> 2 != 0L
}

///|
fn object_type(mem : Array[Byte], ptr : Int64) -> Int raise WasmEvalError {
  read_u32_le(mem, untag_ptr(ptr))
}

///|
fn object_len(mem : Array[Byte], ptr : Int64) -> Int raise WasmEvalError {
  read_u32_le(mem, untag_ptr(ptr) + 4)
}

///|
fn is_tagged_string(mem : Array[Byte], ptr : Int64) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_string
}

///|
fn is_tagged_path(mem : Array[Byte], ptr : Int64) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_path
}

///|
fn is_tagged_array(mem : Array[Byte], ptr : Int64) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_array
}

///|
fn is_tagged_map(mem : Array[Byte], ptr : Int64) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_map
}

///|
fn parse_code_section(
  bytes : Array[Byte],
) -> (Array[Byte], Int) raise WasmEvalError {
  let cur = Cursor::new(bytes)
  let count = cur.read_leb_u32()
  if count != 1 {
    raise WasmEvalError::Unsupported("expected one function")
  }
  let body_size = cur.read_leb_u32()
  let body = cur.read_bytes(body_size)
  let body_cur = Cursor::new(body)
  let local_decl_count = body_cur.read_leb_u32()
  let mut locals_total = 0
  for _ in 0..<local_decl_count {
    let n = body_cur.read_leb_u32()
    let ty = body_cur.read_u8()
    if ty != 127 && ty != 126 {
      raise WasmEvalError::Unsupported("local type")
    }
    locals_total += n
  }
  let code_bytes = body_cur.read_bytes(body_cur.remaining())
  (code_bytes, locals_total)
}

///|
fn parse_data_section(
  bytes : Array[Byte],
  mem : Array[Byte],
) -> Int raise WasmEvalError {
  let cur = Cursor::new(bytes)
  let count = cur.read_leb_u32()
  let mut max_end = 0
  for _ in 0..<count {
    let mode = cur.read_u8()
    if mode != 0 {
      raise WasmEvalError::Unsupported("data mode")
    }
    let op = cur.read_u8()
    if op != 65 {
      raise WasmEvalError::Unsupported("data offset expr")
    }
    let offset = cur.read_leb_u32()
    let end = cur.read_u8()
    if end != 11 {
      raise WasmEvalError::Invalid("data offset end")
    }
    let size = cur.read_leb_u32()
    let data = cur.read_bytes(size)
    for i in 0..<data.length() {
      let idx = offset + i
      if idx >= mem.length() {
        raise WasmEvalError::UnexpectedEof
      }
      mem[idx] = data[i]
    }
    let end = offset + data.length()
    if end > max_end {
      max_end = end
    }
  }
  max_end
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
struct AllocResult {
  ptr : Int
  next : Int
} derive(Show, Eq)

///|
fn alloc_string(
  mem : Array[Byte],
  heap_top : Int,
  s : String,
  ty : Int,
) -> AllocResult raise WasmEvalError {
  let bytes = @utf8.encode(s)
  let arr = bytes.to_array()
  let size = 8 + arr.length()
  let end = heap_top + size
  if end > mem.length() {
    raise WasmEvalError::UnexpectedEof
  }
  let len = arr.length()
  mem[heap_top] = (ty & 0xff).to_byte()
  mem[heap_top + 1] = ((ty >> 8) & 0xff).to_byte()
  mem[heap_top + 2] = ((ty >> 16) & 0xff).to_byte()
  mem[heap_top + 3] = ((ty >> 24) & 0xff).to_byte()
  mem[heap_top + 4] = (len & 0xff).to_byte()
  mem[heap_top + 5] = ((len >> 8) & 0xff).to_byte()
  mem[heap_top + 6] = ((len >> 16) & 0xff).to_byte()
  mem[heap_top + 7] = ((len >> 24) & 0xff).to_byte()
  for i in 0..<arr.length() {
    mem[heap_top + 8 + i] = arr[i]
  }
  { ptr: heap_top, next: align4(end) }
}

///|
fn skip_leb(code : Cursor) -> Unit raise WasmEvalError {
  while true {
    let byte = code.read_u8()
    if (byte & 0x80) == 0 {
      break
    }
  }
}

///|
fn skip_to_else_or_end(code : Cursor) -> Bool raise WasmEvalError {
  let mut depth = 1
  while code.remaining() > 0 {
    let op = code.read_u8()
    match op {
      4 => { // if
        let _ = code.read_u8()
        depth += 1
      }
      5 => if depth == 1 { return true }
      11 => {
        depth -= 1
        if depth == 0 {
          return false
        }
      }
      65 | 66 | 32 | 33 | 34 | 16 => skip_leb(code)
      40 | 42 | 43 | 54 => {
        skip_leb(code)
        skip_leb(code)
      }
      _ => ()
    }
  }
  raise WasmEvalError::UnexpectedEof
}

///|
fn skip_to_end(code : Cursor) -> Unit raise WasmEvalError {
  let mut depth = 1
  while code.remaining() > 0 {
    let op = code.read_u8()
    match op {
      4 => { // if
        let _ = code.read_u8()
        depth += 1
      }
      11 => {
        depth -= 1
        if depth == 0 {
          return
        }
      }
      65 | 66 | 32 | 33 | 34 | 16 => skip_leb(code)
      40 | 42 | 43 | 54 => {
        skip_leb(code)
        skip_leb(code)
      }
      _ => ()
    }
  }
  raise WasmEvalError::UnexpectedEof
}

///|
fn run_wasm(bytes : Bytes) -> WasmEvalResult raise WasmEvalError {
  let arr = bytes.to_array()
  if arr.length() < 8 {
    raise WasmEvalError::Invalid("short header")
  }
  if arr[0].to_int() != 0 ||
    arr[1].to_int() != 97 ||
    arr[2].to_int() != 115 ||
    arr[3].to_int() != 109 {
    raise WasmEvalError::Invalid("bad magic")
  }
  let cur = Cursor::new(arr)
  let _ = cur.read_bytes(8)
  let mut code_bytes : Array[Byte] = []
  let mut locals_total = 0
  let mut import_index = 0
  let mut sh_index : Int? = None
  let mut path_index : Int? = None
  let mem : Array[Byte] = Array::make(65536, (0).to_byte())
  let mut heap_top = 0
  while cur.remaining() > 0 {
    let id = cur.read_u8()
    let size = cur.read_leb_u32()
    let payload = cur.read_bytes(size)
    match id {
      2 => {
        let sec = Cursor::new(payload)
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let module_name = sec.read_name()
          let name = sec.read_name()
          let kind = sec.read_u8()
          if kind != 0 {
            raise WasmEvalError::Unsupported("import kind")
          }
          let _ = sec.read_leb_u32()
          if module_name == "vibe" && name == "sh" {
            sh_index = Some(import_index)
          } else if module_name == "vibe" && name == "path" {
            path_index = Some(import_index)
          }
          import_index += 1
        }
      }
      10 => {
        let (body, locals) = parse_code_section(payload)
        code_bytes = body
        locals_total = locals
      }
      11 => {
        let max_end = parse_data_section(payload, mem)
        heap_top = align4(max_end)
      }
      _ => ()
    }
  }
  if code_bytes.is_empty() {
    raise WasmEvalError::Invalid("missing code")
  }
  let code = Cursor::new(code_bytes)
  let locals : Array[Int64] = Array::make(locals_total, 0L)
  let stack : Array[Int64] = []
  let outputs : Array[String] = []
  let mut if_depth = 0
  while true {
    let op = code.read_u8()
    match op {
      // i32.const
      65 => {
        let v = code.read_leb_u32()
        stack.push(v.to_int64())
      }
      // i64.const
      66 => {
        let v = code.read_leb_i64()
        stack.push(v)
      }
      // i32.add
      106 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() + b.to_int()).to_int64())
      }
      // i32.sub
      107 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() - b.to_int()).to_int64())
      }
      // i32.mul
      108 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() * b.to_int()).to_int64())
      }
      // i32.eq
      70 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() == b.to_int() { 1L } else { 0L })
      }
      // i32.ne
      71 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() != b.to_int() { 1L } else { 0L })
      }
      // i32.lt_s
      72 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() < b.to_int() { 1L } else { 0L })
      }
      // i32.eqz
      69 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() == 0 { 1L } else { 0L })
      }
      // i32.or
      114 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() | b.to_int()).to_int64())
      }
      // i32.and
      113 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() & b.to_int()).to_int64())
      }
      // i32.xor
      115 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push((a.to_int() ^ b.to_int()).to_int64())
      }
      // i32.shl
      116 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack.unsafe_pop()
        let value = stack.unsafe_pop()
        stack.push((value.to_int() << shift.to_int()).to_int64())
      }
      // i32.shr_u
      118 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack.unsafe_pop()
        let value = stack.unsafe_pop()
        stack.push((value.to_int() >> shift.to_int()).to_int64())
      }
      // i64.add
      124 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a + b)
      }
      // i64.sub
      125 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a - b)
      }
      // i64.mul
      126 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a * b)
      }
      // i64.div_s
      127 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a / b)
      }
      // i64.rem_s
      129 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a % b)
      }
      // i64.and
      131 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a & b)
      }
      // i64.or
      132 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a | b)
      }
      // i64.xor
      133 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(a ^ b)
      }
      // i64.shl
      134 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack.unsafe_pop()
        let value = stack.unsafe_pop()
        stack.push(value << shift.to_int())
      }
      // i64.shr_s
      135 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack.unsafe_pop()
        let value = stack.unsafe_pop()
        stack.push(value >> shift.to_int())
      }
      // i64.shr_u
      136 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack.unsafe_pop()
        let value = stack.unsafe_pop()
        stack.push(
          (value.reinterpret_as_uint64() >> shift.to_int()).reinterpret_as_int64(),
        )
      }
      // i64.eqz
      80 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let a = stack.unsafe_pop()
        stack.push(if a == 0L { 1L } else { 0L })
      }
      // i64.eq
      81 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a == b { 1L } else { 0L })
      }
      // i64.ne
      82 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a != b { 1L } else { 0L })
      }
      // i64.lt_s
      83 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a < b { 1L } else { 0L })
      }
      // i64.gt_s
      84 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a > b { 1L } else { 0L })
      }
      // i64.le_s
      85 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a <= b { 1L } else { 0L })
      }
      // i64.ge_s
      86 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a >= b { 1L } else { 0L })
      }
      // i32.wrap_i64
      167 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack.unsafe_pop()
        stack.push(v.to_int().to_int64())
      }
      // i64.extend_i32_s
      172 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack.unsafe_pop()
        stack.push(v.to_int().to_int64())
      }
      // i64.extend_i32_u
      173 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack.unsafe_pop()
        let unsigned = v.to_int().reinterpret_as_uint().to_int64()
        stack.push(unsigned)
      }
      // memory.size
      63 => {
        let _ = code.read_u8()
        stack.push((mem.length() / 65536).to_int64())
      }
      // memory.grow
      64 => {
        let _ = code.read_u8()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let delta_pages = stack.unsafe_pop().to_int()
        let old_pages = mem.length() / 65536
        if delta_pages < 0 {
          stack.push(-1L)
        } else {
          let grow_bytes = delta_pages * 65536
          for _ in 0..<grow_bytes {
            mem.push((0).to_byte())
          }
          stack.push(old_pages.to_int64())
        }
      }
      // i32.load
      40 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let addr = stack.unsafe_pop().to_int()
        let value = read_u32_le(mem, addr + offset)
        stack.push(value.to_int64())
      }
      // i32.store
      54 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let value = stack.unsafe_pop().to_int()
        let addr = stack.unsafe_pop().to_int()
        write_u32_le(mem, addr + offset, value)
      }
      // local.get
      32 => {
        let idx = code.read_leb_u32()
        if idx >= locals.length() {
          raise WasmEvalError::Invalid("local.get")
        }
        stack.push(locals[idx])
      }
      // local.set
      33 => {
        let idx = code.read_leb_u32()
        if idx >= locals.length() {
          raise WasmEvalError::Invalid("local.set")
        }
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack.unsafe_pop()
        locals[idx] = v
      }
      // local.tee
      34 => {
        let idx = code.read_leb_u32()
        if idx >= locals.length() {
          raise WasmEvalError::Invalid("local.tee")
        }
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack[stack.length() - 1]
        locals[idx] = v
      }
      // call
      16 => {
        let idx = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let ptr = stack.unsafe_pop()
        match path_index {
          Some(pidx) if idx == pidx => {
            let raw = read_string_object(mem, ptr)
            let normalized = @path.Path(raw).normalize().to_string()
            let resolved = if normalized.has_prefix("/") {
              normalized
            } else {
              "/" + normalized
            }
            let alloc = alloc_string(mem, heap_top, resolved, obj_path)
            heap_top = alloc.next
            stack.push(alloc.ptr.to_int64() | tag_obj)
          }
          _ =>
            match sh_index {
              Some(sidx) if idx == sidx => {
                let msg = read_string_object(mem, ptr)
                outputs.push(msg)
                stack.push(0L)
              }
              _ => raise WasmEvalError::Unsupported("call")
            }
        }
      }
      // drop
      26 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let _ = stack.pop()
      }
      // if
      4 => {
        let _ = code.read_u8()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let cond = stack.unsafe_pop()
        if cond != 0L {
          if_depth += 1
        } else {
          let has_else = skip_to_else_or_end(code)
          if has_else {
            if_depth += 1
          }
        }
      }
      // else
      5 => {
        if if_depth == 0 {
          raise WasmEvalError::Invalid("unexpected else")
        }
        skip_to_end(code)
        if_depth -= 1
      }
      // end
      11 => if if_depth > 0 { if_depth -= 1 } else { break }
      _ => raise WasmEvalError::Unsupported("opcode " + op.to_string())
    }
  }
  let value = if stack.is_empty() { 0L } else { stack[stack.length() - 1] }
  { value, outputs, mem }
}

///|
fn eval_run(script : String) -> WasmEvalResult raise WasmRunError {
  let db = VibeDb::new()
  db.set_source("main", script)
  let wasm = compile_module_wasm(db, "main") catch {
    e => raise WasmRunError::Compile(e.to_string())
  }
  run_wasm(wasm) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
}

///|
struct InterpreterEvalResult {
  value : @core.Value
  effects : Array[@runtime.Effect]
}

///|
fn eval_run_interpreter_with_caps(
  script : String,
  caps : @capability.CapabilitySet,
) -> InterpreterEvalResult raise WasmRunError {
  let db = VibeDb::new()
  db.set_source("main", script)
  let compiled = compile_module(db, "main") catch {
    e => raise WasmRunError::Compile(e.to_string())
  }
  let rt = Runtime::new(caps)
  let result = @runtime_compile.run_compiled(rt, compiled) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
  let value = match result.last {
    Some(value) => value
    None => @core.Value::Unit
  }
  { value, effects: result.effects }
}

///|
fn eval_run_interpreter(script : String) -> @core.Value raise WasmRunError {
  let result = eval_run_interpreter_with_caps(
    script,
    @capability.CapabilitySet::new(),
  )
  result.value
}

///|
fn collect_shell_exec_effects(
  effects : Array[@runtime.Effect],
) -> Array[String] {
  let out : Array[String] = []
  for effect in effects {
    match effect {
      @runtime.Effect::ShellExec(cmd) => out.push(cmd)
      _ => ()
    }
  }
  out
}

///|
fn decode_tagged_value(
  mem : Array[Byte],
  tagged : Int64,
  depth : Int,
) -> @core.Value raise WasmEvalError {
  if depth > 64 {
    raise WasmEvalError::Unsupported("decode depth overflow")
  }
  if is_tagged_int(tagged) {
    return @core.Value::Int(decode_int(tagged))
  }
  if is_tagged_bool(tagged) {
    return @core.Value::Bool(decode_bool(tagged))
  }
  if !is_tagged_obj(tagged) {
    if tagged == 0L {
      return @core.Value::Unit
    }
    raise WasmEvalError::Unsupported(
      "decode unsupported tagged value: " + tagged.to_string(),
    )
  }
  let ty = object_type(mem, tagged)
  if ty == obj_string {
    return @core.Value::String(read_string_object(mem, tagged))
  }
  if ty == obj_path {
    return @core.Value::Path(@core.Path::new(read_string_object(mem, tagged)))
  }
  if ty == obj_array {
    let len = object_len(mem, tagged)
    let base = untag_ptr(tagged)
    let out : Array[@core.Value] = []
    for i in 0..<len {
      let item = read_u32_le(mem, base + 8 + i * 4).to_int64()
      out.push(decode_tagged_value(mem, item, depth + 1))
    }
    return @core.Value::Array(out)
  }
  if ty == obj_map {
    let len = object_len(mem, tagged)
    let base = untag_ptr(tagged)
    let out : Map[String, @core.Value] = {}
    for i in 0..<len {
      let key_ptr = read_u32_le(mem, base + 8 + i * 8).to_int64()
      let value = read_u32_le(mem, base + 12 + i * 8).to_int64()
      let key = read_string_object(mem, key_ptr)
      out[key] = decode_tagged_value(mem, value, depth + 1)
    }
    return @core.Value::Map(out)
  }
  raise WasmEvalError::Unsupported("decode unsupported object type")
}

///|
fn assert_eval_backends_same(script : String) -> Unit raise {
  let wasm_res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let wasm_value = try
    decode_tagged_value(wasm_res.mem, wasm_res.value, 0)
  catch {
    e => fail("wasm decode failed: " + e.to_string())
  } noraise {
    v => v
  }
  let interpreter_value = try eval_run_interpreter(script) catch {
    e => fail("interpreter eval failed: " + e.to_string())
  } noraise {
    v => v
  }
  assert_eq(wasm_value, interpreter_value)
}

///|
fn assert_eval_backends_same_with_shell_effects(script : String) -> Unit raise {
  let wasm_res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let wasm_value = try
    decode_tagged_value(wasm_res.mem, wasm_res.value, 0)
  catch {
    e => fail("wasm decode failed: " + e.to_string())
  } noraise {
    v => v
  }
  let interpreter = try
    eval_run_interpreter_with_caps(
      script,
      @capability.CapabilitySet::developer(),
    )
  catch {
    e => fail("interpreter eval failed: " + e.to_string())
  } noraise {
    v => v
  }
  let shell_effects = collect_shell_exec_effects(interpreter.effects)
  assert_eq(wasm_value, interpreter.value)
  assert_eq(wasm_res.outputs, shell_effects)
}

///|
test "vibe wasm eval returns value" {
  let res = try eval_run("let x = 1\nx") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 1L)
}

///|
test "vibe wasm eval handles locals" {
  let res = try eval_run("let x = 1\nlet y = 2\ny") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 2L)
}

///|
test "vibe wasm eval add/sub/eq/lt" {
  let add_res = try eval_run("add(1, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(add_res.value))
  assert_eq(decode_int(add_res.value), 3L)
  let sub_res = try eval_run("sub(5, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(sub_res.value), 3L)
  let eq_true = try eval_run("eq(2, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(eq_true.value))
  assert_true(decode_bool(eq_true.value))
  let eq_false = try eval_run("eq(2, 3)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(eq_false.value))
  assert_false(decode_bool(eq_false.value))
  let lt_true = try eval_run("lt(1, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(lt_true.value))
  assert_true(decode_bool(lt_true.value))
  let lt_false = try eval_run("lt(2, 1)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(lt_false.value))
  assert_false(decode_bool(lt_false.value))
}

///|
test "vibe wasm eval returns tagged string" {
  let res = try eval_run("\"hi\"") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  let is_str = try is_tagged_string(res.mem, res.value) catch {
    e => fail(e.to_string())
  } noraise {
    v => v
  }
  assert_true(is_str)
  let s = read_string_object(res.mem, res.value)
  assert_eq(s, "hi")
}

///|
test "vibe wasm eval returns tagged bool" {
  let res = try eval_run("true") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(res.value))
  assert_true(decode_bool(res.value))
}

///|
test "vibe wasm eval if expression" {
  let res_true = try eval_run("if true { 1 } else { 2 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res_true.value))
  assert_eq(decode_int(res_true.value), 1L)
  let res_false = try eval_run("if false { 1 } else { 2 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res_false.value))
  assert_eq(decode_int(res_false.value), 2L)
}

///|
test "vibe wasm eval if branches effects" {
  let res = try
    eval_run("do { if false { sh(\"a\") } else { sh(\"b\") } }")
  catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(res.outputs.length(), 1)
  assert_eq(res.outputs[0], "b")
}

///|
test "vibe wasm eval block expression" {
  let res = try eval_run("{ let x = 4\n x }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 4L)
}

///|
test "vibe wasm eval match expression" {
  let res = try eval_run("match 2 { 1 => 10, 2 => 20, _ => 0 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 20L)
}

///|
test "vibe wasm eval match bind" {
  let res = try eval_run("match 3 { v => add(v, 1) }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 4L)
}

///|
test "vibe wasm eval match tuple" {
  let res = try eval_run("match (1, 2) { (a, b) => add(a, b), _ => 0 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 3L)
}

///|
test "vibe wasm eval match nested tuple" {
  let res = try
    eval_run("match (1, (2, 3)) { (a, (b, c)) => add(add(a, b), c), _ => 0 }")
  catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 6L)
}

///|
test "vibe wasm eval match record" {
  let res = try
    eval_run(
      "match record { b: 2, a: 1 } { record { a: x, b: y } => add(x, y), _ => 0 }",
    )
  catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 3L)
}

///|
test "vibe wasm eval match nested record" {
  let res = try
    eval_run(
      "match record { a: record { b: 2 }, c: 3 } { record { a: record { b: x }, c: y } => add(x, y), _ => 0 }",
    )
  catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 5L)
}

///|
test "vibe wasm eval array literal" {
  let res = try eval_run("[1, 2]") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  let is_arr = try is_tagged_array(res.mem, res.value) catch {
    e => fail(e.to_string())
  } noraise {
    v => v
  }
  assert_true(is_arr)
  let len = object_len(res.mem, res.value)
  assert_eq(len, 2)
  let base = untag_ptr(res.value)
  let v0 = read_u32_le(res.mem, base + 8).to_int64()
  let v1 = read_u32_le(res.mem, base + 12).to_int64()
  assert_true(is_tagged_int(v0))
  assert_true(is_tagged_int(v1))
  assert_eq(decode_int(v0), 1L)
  assert_eq(decode_int(v1), 2L)
}

///|
test "vibe wasm eval map literal" {
  let res = try eval_run("map { a: 1 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  let is_map = try is_tagged_map(res.mem, res.value) catch {
    e => fail(e.to_string())
  } noraise {
    v => v
  }
  assert_true(is_map)
  let len = object_len(res.mem, res.value)
  assert_eq(len, 1)
  let base = untag_ptr(res.value)
  let key_ptr = read_u32_le(res.mem, base + 8).to_int64()
  let val = read_u32_le(res.mem, base + 12).to_int64()
  let key = read_string_object(res.mem, key_ptr)
  assert_eq(key, "a")
  assert_true(is_tagged_int(val))
  assert_eq(decode_int(val), 1L)
}

///|
test "vibe wasm eval match guard" {
  let res_false = try eval_run("match 2 { v if lt(v, 2) => 1, _ => 9 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(res_false.value), 9L)
  let res_true = try eval_run("match 1 { v if lt(v, 2) => 1, _ => 9 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(res_true.value), 1L)
}

///|
test "vibe wasm eval bool ops" {
  let not_res = try eval_run("not(true)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(not_res.value))
  assert_false(decode_bool(not_res.value))
  let and_res = try eval_run("and(true, false)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_false(decode_bool(and_res.value))
  let or_res = try eval_run("or(true, false)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(decode_bool(or_res.value))
}

///|
test "vibe wasm eval captures sh output" {
  let res = try eval_run("do { sh(\"hello\") }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 0L)
  assert_eq(res.outputs.length(), 1)
  assert_eq(res.outputs[0], "hello")
}

///|
test "vibe wasm eval normalizes path" {
  let res = try eval_run("let p = path(\"a/../b\")\np") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  let is_path = try is_tagged_path(res.mem, res.value) catch {
    e => fail(e.to_string())
  } noraise {
    v => v
  }
  assert_true(is_path)
  let normalized = read_string_object(res.mem, res.value)
  assert_eq(normalized, "/b")
}

///|
test "vibe wasm eval matches interpreter for scalar outputs" {
  assert_eval_backends_same("let x = 1\nadd(x, 2)")
  assert_eval_backends_same("if lt(1, 2) { \"ok\" } else { \"ng\" }")
  assert_eval_backends_same("not(and(true, false))")
  assert_eval_backends_same("let p = path(\"a/../b\")\np")
}

///|
test "vibe wasm eval matches interpreter for collection outputs" {
  assert_eval_backends_same("[1, add(1, 2), 5]")
  assert_eval_backends_same("map { a: 1, b: add(1, 2) }")
}

///|
test "vibe wasm eval matches interpreter for shell effects" {
  assert_eval_backends_same_with_shell_effects(
    "do { sh(\"echo hello\") }\ndo { sh(\"echo world\") }\n42",
  )
}

///|
test "vibe backends match: arithmetic operators" {
  assert_eval_backends_same("1 + 2")
  assert_eval_backends_same("10 - 3")
  assert_eval_backends_same("3 * 4")
  assert_eval_backends_same("10 / 3")
  assert_eval_backends_same("10 % 3")
  assert_eval_backends_same("-5")
  assert_eval_backends_same("-(3 + 2)")
  assert_eval_backends_same("1 + 2 * 3")
  assert_eval_backends_same("(1 + 2) * 3")
}

///|
test "vibe backends match: comparison operators" {
  assert_eval_backends_same("1 == 1")
  assert_eval_backends_same("1 != 2")
  assert_eval_backends_same("1 < 2")
  assert_eval_backends_same("2 > 1")
  assert_eval_backends_same("1 <= 1")
  assert_eval_backends_same("2 >= 1")
  assert_eval_backends_same("1 > 2")
  assert_eval_backends_same("1 >= 2")
  assert_eval_backends_same("3 <= 2")
  assert_eval_backends_same("0 == 0")
}

///|
test "vibe backends match: bitwise operators" {
  assert_eval_backends_same("5 & 3")
  assert_eval_backends_same("5 | 3")
  assert_eval_backends_same("5 ^ 3")
  assert_eval_backends_same("1 << 3")
  assert_eval_backends_same("8 >> 2")
  assert_eval_backends_same("0 & 0")
  assert_eval_backends_same("255 & 15")
}

///|
test "vibe backends match: boolean expressions" {
  assert_eval_backends_same("true")
  assert_eval_backends_same("false")
  assert_eval_backends_same("not(false)")
  assert_eval_backends_same("and(true, true)")
  assert_eval_backends_same("or(false, true)")
  assert_eval_backends_same("and(true, false)")
  assert_eval_backends_same("not(or(false, false))")
  assert_eval_backends_same("and(not(false), true)")
}

///|
test "vibe backends match: block expressions" {
  assert_eval_backends_same("{ let x = 10\n x }")
  assert_eval_backends_same("{ let a = 1\n let b = 2\n a + b }")
  assert_eval_backends_same("{ let x = { let y = 3\n y * 2 }\n x + 1 }")
}

///|
test "vibe backends match: nested conditionals" {
  assert_eval_backends_same("if true { if false { 1 } else { 2 } } else { 3 }")
  assert_eval_backends_same("if false { 1 } else { if true { 2 } else { 3 } }")
  assert_eval_backends_same(
    "if 1 < 2 { if 3 > 4 { 10 } else { 20 } } else { 30 }",
  )
}

///|
test "vibe backends match: match expressions" {
  assert_eval_backends_same("match 2 { 1 => 10, 2 => 20, _ => 0 }")
  assert_eval_backends_same("match 5 { v => v + 1 }")
  assert_eval_backends_same("match 3 { v if v < 5 => 1, _ => 0 }")
  assert_eval_backends_same("match 10 { v if v < 5 => 1, _ => 0 }")
  assert_eval_backends_same("match (1, 2) { (a, b) => a + b, _ => 0 }")
  assert_eval_backends_same(
    "match (1, (2, 3)) { (a, (b, c)) => a + b + c, _ => 0 }",
  )
  assert_eval_backends_same(
    "match record { a: 1, b: 2 } { record { a: x, b: y } => x + y, _ => 0 }",
  )
}

///|
test "vibe backends match: let binding chains" {
  assert_eval_backends_same("let a = 1\nlet b = a + 2\nlet c = b * 3\nc")
  assert_eval_backends_same("let x = 10\nlet y = x - 3\ny")
  assert_eval_backends_same("let a = 5\nlet b = a\nlet c = b\nc")
}

///|
test "vibe backends match: edge cases" {
  assert_eval_backends_same("0")
  assert_eval_backends_same("add(0, 0)")
  assert_eval_backends_same("1000 * 1000")
  assert_eval_backends_same("sub(0, 1)")
  assert_eval_backends_same("\"\"")
  assert_eval_backends_same("\"hello world\"")
}

///|
test "vibe backends match: nested collections" {
  assert_eval_backends_same("[1, 2, 3]")
  assert_eval_backends_same("[[1, 2], [3, 4]]")
  assert_eval_backends_same("map { a: 1, b: 2, c: 3 }")
  assert_eval_backends_same("[map { x: 1 }, map { x: 2 }]")
}

///|
test "vibe backends match: mixed expressions" {
  assert_eval_backends_same("if eq(1, 1) { add(2, 3) } else { 0 }")
  assert_eval_backends_same("let x = mul(3, 3)\nadd(x, 1)")
  assert_eval_backends_same("match true { true => 1, false => 0 }")
}
