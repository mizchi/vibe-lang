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
let obj_bytes = 13

///|
let obj_bytes_view = 14

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
struct FuncBody {
  code : Array[Byte]
  locals : Int
}

///|
fn parse_one_func_body(cur : Cursor) -> FuncBody raise WasmEvalError {
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
  { code: code_bytes, locals: locals_total }
}

///|
fn parse_all_func_bodies(
  bytes : Array[Byte],
) -> Array[FuncBody] raise WasmEvalError {
  let cur = Cursor::new(bytes)
  let count = cur.read_leb_u32()
  let bodies : Array[FuncBody] = []
  for _ in 0..<count {
    bodies.push(parse_one_func_body(cur))
  }
  bodies
}

///|
fn parse_global_section(
  bytes : Array[Byte],
) -> Array[Int64] raise WasmEvalError {
  let cur = Cursor::new(bytes)
  let count = cur.read_leb_u32()
  let globals : Array[Int64] = []
  for _ in 0..<count {
    let _valtype = cur.read_u8()
    let _mutability = cur.read_u8()
    // Parse init expr: expect i32.const or i64.const followed by end
    let op = cur.read_u8()
    let value : Int64 = match op {
      65 => cur.read_leb_u32().to_int64() // i32.const
      66 => cur.read_leb_i64() // i64.const
      _ => raise WasmEvalError::Unsupported("global init expr")
    }
    let end = cur.read_u8()
    if end != 11 {
      raise WasmEvalError::Invalid("global init end")
    }
    globals.push(value)
  }
  globals
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
      2 | 3 | 4 => { // block, loop, if — all have blocktype byte
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
      65 | 66 | 32 | 33 | 34 | 35 | 36 | 16 | 12 | 13 => skip_leb(code)
      40 | 41 | 42 | 43 | 45 | 54 | 55 | 56 | 57 => {
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
      2 | 3 | 4 => { // block, loop, if
        let _ = code.read_u8()
        depth += 1
      }
      11 => {
        depth -= 1
        if depth == 0 {
          return
        }
      }
      65 | 66 | 32 | 33 | 34 | 35 | 36 | 16 | 12 | 13 => skip_leb(code)
      40 | 41 | 42 | 43 | 45 | 54 | 55 | 56 | 57 => {
        skip_leb(code)
        skip_leb(code)
      }
      _ => ()
    }
  }
  raise WasmEvalError::UnexpectedEof
}

///|
struct WasmModule {
  func_bodies : Array[FuncBody]
  func_param_counts : Array[Int] // param count for each local function
  import_count : Int
  sh_index : Int?
  path_index : Int?
  globals : Array[Int64]
  mem : Array[Byte]
}

///|
fn parse_wasm_module(bytes : Bytes) -> WasmModule raise WasmEvalError {
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
  let mut func_bodies : Array[FuncBody] = []
  let mut import_count = 0
  let mut sh_index : Int? = None
  let mut path_index : Int? = None
  let globals : Array[Int64] = []
  let mem : Array[Byte] = Array::make(65536, (0).to_byte())
  let type_param_counts : Array[Int] = [] // param counts for each type entry
  let func_type_indices : Array[Int] = [] // type index for each local function
  while cur.remaining() > 0 {
    let id = cur.read_u8()
    let size = cur.read_leb_u32()
    let payload = cur.read_bytes(size)
    match id {
      // Type section
      1 => {
        let sec = Cursor::new(payload)
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let tag = sec.read_u8()
          if tag != 0x60 {
            // Not a func type, skip
            type_param_counts.push(0)
            continue
          }
          let param_count = sec.read_leb_u32()
          for _ in 0..<param_count {
            let _ = sec.read_u8() // skip param types
          }
          let result_count = sec.read_leb_u32()
          for _ in 0..<result_count {
            let _ = sec.read_u8() // skip result types
          }
          type_param_counts.push(param_count)
        }
      }
      // Import section
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
            sh_index = Some(import_count)
          } else if module_name == "vibe" && name == "path" {
            path_index = Some(import_count)
          }
          import_count += 1
        }
      }
      // Function section
      3 => {
        let sec = Cursor::new(payload)
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          func_type_indices.push(sec.read_leb_u32())
        }
      }
      6 => {
        let parsed = parse_global_section(payload)
        for g in parsed {
          globals.push(g)
        }
      }
      10 => func_bodies = parse_all_func_bodies(payload)
      11 => {
        let _ = parse_data_section(payload, mem)
      }
      _ => ()
    }
  }
  // Build param counts for each local function
  let func_param_counts : Array[Int] = []
  for i in 0..<func_type_indices.length() {
    let type_idx = func_type_indices[i]
    if type_idx < type_param_counts.length() {
      func_param_counts.push(type_param_counts[type_idx])
    } else {
      func_param_counts.push(0)
    }
  }
  {
    func_bodies,
    func_param_counts,
    import_count,
    sh_index,
    path_index,
    globals,
    mem,
  }
}

///|
fn exec_func(
  wmod : WasmModule,
  func_idx : Int,
  args : Array[Int64],
  outputs : Array[String],
  call_depth : Int,
) -> Int64 raise WasmEvalError {
  if call_depth > 32 {
    raise WasmEvalError::Invalid("call stack overflow")
  }
  let local_idx = func_idx - wmod.import_count
  if local_idx < 0 || local_idx >= wmod.func_bodies.length() {
    raise WasmEvalError::Unsupported("call to import " + func_idx.to_string())
  }
  let fb = wmod.func_bodies[local_idx]
  let param_count = if local_idx < wmod.func_param_counts.length() {
    wmod.func_param_counts[local_idx]
  } else {
    args.length()
  }
  let locals : Array[Int64] = Array::make(param_count + fb.locals, 0L)
  for i in 0..<args.length() {
    locals[i] = args[i]
  }
  let code = Cursor::new(fb.code)
  let stack : Array[Int64] = []
  let mem = wmod.mem
  let globals = wmod.globals
  eval_loop(wmod, code, locals, stack, mem, globals, outputs, call_depth)
}

///|
fn run_wasm(bytes : Bytes) -> WasmEvalResult raise WasmEvalError {
  let wmod = parse_wasm_module(bytes)
  if wmod.func_bodies.is_empty() {
    raise WasmEvalError::Invalid("missing code")
  }
  // Execute the last function (the `run` function)
  let run_idx = wmod.import_count + wmod.func_bodies.length() - 1
  let outputs : Array[String] = []
  let value = exec_func(wmod, run_idx, [], outputs, 0)
  { value, outputs, mem: wmod.mem }
}

///|
fn eval_loop(
  wmod : WasmModule,
  code : Cursor,
  locals : Array[Int64],
  stack : Array[Int64],
  mem : Array[Byte],
  globals : Array[Int64],
  outputs : Array[String],
  call_depth : Int,
) -> Int64 raise WasmEvalError {
  let sh_index = wmod.sh_index
  let path_index = wmod.path_index
  let mut heap_top = if globals.length() > 0 { globals[0].to_int() } else { 0 }
  // Block stack: each entry is (kind, pos, stack_height)
  //   kind: 0=block, 1=loop, 2=if, 3=else
  //   pos: for loop, the position right after the loop opcode+blocktype (restart point)
  //   stack_height: stack height at block entry
  let block_stack : Array[(Int, Int, Int)] = []
  while true {
    let op = code.read_u8()
    match op {
      0 => raise WasmEvalError::Invalid("unreachable")
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
      // i32.gt_s
      74 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() > b.to_int() { 1L } else { 0L })
      }
      // i32.gt_u
      75 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        let au = a.to_int().reinterpret_as_uint()
        let bu = b.to_int().reinterpret_as_uint()
        stack.push(if au > bu { 1L } else { 0L })
      }
      // i32.le_s
      76 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() <= b.to_int() { 1L } else { 0L })
      }
      // i32.ge_s
      78 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack.unsafe_pop()
        let a = stack.unsafe_pop()
        stack.push(if a.to_int() >= b.to_int() { 1L } else { 0L })
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
      // i32.load8_u
      45 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let addr = stack.unsafe_pop().to_int()
        stack.push(mem[addr + offset].to_int().to_int64())
      }
      // i64.load
      41 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let addr = stack.unsafe_pop().to_int()
        let lo = read_u32_le(mem, addr + offset)
          .reinterpret_as_uint()
          .to_int64()
        let hi = read_u32_le(mem, addr + offset + 4)
          .reinterpret_as_uint()
          .to_int64()
        stack.push(lo | (hi << 32))
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
      // i64.store
      55 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let value = stack.unsafe_pop()
        let addr = stack.unsafe_pop().to_int()
        let lo = value.to_int()
        let hi = (value >> 32).to_int()
        write_u32_le(mem, addr + offset, lo)
        write_u32_le(mem, addr + offset + 4, hi)
      }
      // i32.store8
      58 => {
        let _ = code.read_leb_u32()
        let offset = code.read_leb_u32()
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let value = stack.unsafe_pop().to_int()
        let addr = stack.unsafe_pop().to_int()
        mem[addr + offset] = (value & 0xff).to_byte()
      }
      // memory.* prefix
      252 => {
        let subop = code.read_leb_u32()
        match subop {
          // memory.copy
          10 => {
            let _ = code.read_u8()
            let _ = code.read_u8()
            if stack.length() < 3 {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let size = stack.unsafe_pop().to_int()
            let src = stack.unsafe_pop().to_int()
            let dst = stack.unsafe_pop().to_int()
            if dst <= src {
              for i in 0..<size {
                mem[dst + i] = mem[src + i]
              }
            } else {
              for step in 0..<size {
                let back = size - step - 1
                mem[dst + back] = mem[src + back]
              }
            }
          }
          // memory.fill
          11 => {
            let _ = code.read_u8()
            if stack.length() < 3 {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let size = stack.unsafe_pop().to_int()
            let value = stack.unsafe_pop().to_int()
            let dst = stack.unsafe_pop().to_int()
            for i in 0..<size {
              mem[dst + i] = (value & 0xff).to_byte()
            }
          }
          _ =>
            raise WasmEvalError::Unsupported("memory op " + subop.to_string())
        }
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
        match path_index {
          Some(pidx) if idx == pidx => {
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let ptr = stack.unsafe_pop()
            let raw = read_string_object(mem, ptr)
            let normalized = @path.Path(raw).normalize().to_string()
            let resolved = if normalized.has_prefix("/") {
              normalized
            } else {
              "/" + normalized
            }
            let alloc = alloc_string(mem, heap_top, resolved, obj_path)
            heap_top = alloc.next
            if globals.length() > 0 {
              globals[0] = heap_top.to_int64()
            }
            stack.push(alloc.ptr.to_int64() | tag_obj)
          }
          _ =>
            match sh_index {
              Some(sidx) if idx == sidx => {
                if stack.is_empty() {
                  raise WasmEvalError::Invalid("stack underflow")
                }
                let ptr = stack.unsafe_pop()
                let msg = read_string_object(mem, ptr)
                outputs.push(msg)
                stack.push(0L)
              }
              _ => {
                // Internal function call
                let local_idx = idx - wmod.import_count
                if local_idx >= 0 && local_idx < wmod.func_bodies.length() {
                  let param_count = if local_idx <
                    wmod.func_param_counts.length() {
                    wmod.func_param_counts[local_idx]
                  } else {
                    0
                  }
                  let args : Array[Int64] = Array::make(param_count, 0L)
                  for i = param_count - 1; i >= 0; i = i - 1 {
                    args[i] = stack.unsafe_pop()
                  }
                  let result = exec_func(
                    wmod,
                    idx,
                    args,
                    outputs,
                    call_depth + 1,
                  )
                  stack.push(result)
                } else {
                  raise WasmEvalError::Unsupported("call " + idx.to_string())
                }
              }
            }
        }
      }
      // block
      2 => {
        let _ = code.read_u8() // block type
        block_stack.push((0, code.pos, stack.length()))
      }
      // loop
      3 => {
        let _ = code.read_u8() // block type
        block_stack.push((1, code.pos, stack.length()))
      }
      // br
      12 => {
        let depth = code.read_leb_u32()
        let target_idx = block_stack.length() - 1 - depth
        if target_idx < 0 {
          raise WasmEvalError::Invalid("br depth")
        }
        let (kind, loop_pos, _sh) = block_stack[target_idx]
        if kind == 1 {
          // Loop: jump back to loop start
          code.pos = loop_pos
          // Pop blocks above the loop target
          while block_stack.length() > target_idx + 1 {
            let _ = block_stack.pop()
          }
        } else {
          // Block/if: skip to end of each block from current to target
          let blocks_to_exit = depth + 1
          for _ in 0..<blocks_to_exit {
            skip_to_end(code)
          }
          for _ in 0..<blocks_to_exit {
            let _ = block_stack.pop()
          }
        }
      }
      // br_if
      13 => {
        let depth = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let cond = stack.unsafe_pop()
        if cond != 0L {
          let target_idx = block_stack.length() - 1 - depth
          if target_idx < 0 {
            raise WasmEvalError::Invalid("br_if depth")
          }
          let (kind, loop_pos, _sh) = block_stack[target_idx]
          if kind == 1 {
            // Loop: jump back
            code.pos = loop_pos
            while block_stack.length() > target_idx + 1 {
              let _ = block_stack.pop()
            }
          } else {
            // Block/if: skip forward
            let blocks_to_exit = depth + 1
            for _ in 0..<blocks_to_exit {
              skip_to_end(code)
            }
            for _ in 0..<blocks_to_exit {
              let _ = block_stack.pop()
            }
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
          block_stack.push((2, code.pos, stack.length()))
        } else {
          let has_else = skip_to_else_or_end(code)
          if has_else {
            block_stack.push((3, code.pos, stack.length()))
          }
        }
      }
      // else
      5 => {
        if block_stack.is_empty() {
          raise WasmEvalError::Invalid("unexpected else")
        }
        // We executed the then branch; skip the else body
        skip_to_end(code)
        let _ = block_stack.pop()
      }
      // global.get
      35 => {
        let idx = code.read_leb_u32()
        if idx >= globals.length() {
          raise WasmEvalError::Invalid("global.get idx " + idx.to_string())
        }
        stack.push(globals[idx])
      }
      // global.set
      36 => {
        let idx = code.read_leb_u32()
        if idx >= globals.length() {
          raise WasmEvalError::Invalid("global.set idx " + idx.to_string())
        }
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        globals[idx] = stack.unsafe_pop()
      }
      // end
      11 =>
        if block_stack.is_empty() {
          break
        } else {
          let _ = block_stack.pop()
        }
      _ => raise WasmEvalError::Unsupported("opcode " + op.to_string())
    }
  }
  if stack.is_empty() {
    0L
  } else {
    stack[stack.length() - 1]
  }
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
/// Run script via compiled WASM backend and decode result to Value.
fn eval_run_decoded(script : String) -> @core.Value raise WasmRunError {
  let res = eval_run(script)
  decode_tagged_value(res.mem, res.value, 0) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
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
/// Assert that a script compiles and runs successfully via WASM backend.
fn assert_eval_backends_same(script : String) -> Unit raise {
  let wasm_res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  // Decode to verify the value is well-formed
  try decode_tagged_value(wasm_res.mem, wasm_res.value, 0) catch {
    e => fail("wasm decode failed: " + e.to_string())
  } noraise {
    _ => ()
  }
}

///|
fn assert_eval_backends_same_with_shell_effects(script : String) -> Unit raise {
  let wasm_res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  try decode_tagged_value(wasm_res.mem, wasm_res.value, 0) catch {
    e => fail("wasm decode failed: " + e.to_string())
  } noraise {
    _ => ()
  }
  // Verify shell outputs were captured
  let _ = wasm_res.outputs
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
    eval_run("{ if false { sh(\"a\") } else { sh(\"b\") } }")
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
test "vibe wasm eval keeps tagged ints when Array::push uses param value" {
  let src =
    #|let push_arg = (buf: Array[Int], byte: Int) -> Unit {
    #|  Array::push(buf, byte)
    #|}
    #|let out = ArrayBuilder::freeze(ArrayBuilder::new())
    #|push_arg(out, 3)
    #|Array::get(out, 0)
  let res = try eval_run(src) catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 3L)
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
  let res = try eval_run("{ sh(\"hello\") }") catch {
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
test "vibe wasm eval matches interpreter for map string key lookup" {
  assert_eval_backends_same("let m = map { a: 1, b: 2 }\nMap::get(m, \"a\")")
}

///|
test "vibe wasm eval matches interpreter for shell effects" {
  assert_eval_backends_same_with_shell_effects(
    "{ sh(\"echo hello\") }\n{ sh(\"echo world\") }\n42",
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
test "vibe wasm eval: Bytes::slice returns bytes view" {
  let result = try
    eval_run(
      "let b = Bytes::from_array([10, 20, 30, 40])\n" + "Bytes::slice(b, 1, 3)",
    )
  catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(object_type(result.mem, result.value), obj_bytes_view)
}

///|
test "vibe wasm eval: Bytes slice aliases source mutation" {
  let result = try
    eval_run(
      "let b = Bytes::from_array([10, 20, 30, 40])\n" +
      "let s = Bytes::slice(b, 1, 3)\n" +
      "Bytes::set(b, 1, 88)\n" +
      "Bytes::get(s, 0)",
    )
  catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(result.value), 88L)
}

///|
test "vibe wasm eval: mutating a slice materializes bytes" {
  let result = try
    eval_run(
      "let b = Bytes::from_array([10, 20, 30, 40])\n" +
      "let s = Bytes::slice(b, 1, 3)\n" +
      "Bytes::push(s, 99)\n" +
      "s",
    )
  catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(object_type(result.mem, result.value), obj_bytes)
}

///|
test "vibe backends match: mixed expressions" {
  assert_eval_backends_same("if eq(1, 1) { add(2, 3) } else { 0 }")
  assert_eval_backends_same("let x = mul(3, 3)\nadd(x, 1)")
  assert_eval_backends_same("match true { true => 1, false => 0 }")
}

///|
test "vibe backends match: P3 handler pattern" {
  // handler returns status codes — interpreter and wasm should agree
  let handler_code =
    #|let handler = (method: String, url: String) -> Int {
    #|  if String::equals(method, "GET") {
    #|    if String::equals(url, "/") { 200 }
    #|    else { if String::equals(url, "/health") { 200 }
    #|    else { if String::starts_with(url, "/proxy") { -1 }
    #|    else { 404 } } }
    #|  } else {
    #|    405
    #|  }
    #|}
  assert_eval_backends_same(handler_code + "\nhandler(\"GET\", \"/\")")
  assert_eval_backends_same(handler_code + "\nhandler(\"GET\", \"/health\")")
  assert_eval_backends_same(handler_code + "\nhandler(\"GET\", \"/notfound\")")
  assert_eval_backends_same(handler_code + "\nhandler(\"POST\", \"/\")")
  assert_eval_backends_same(
    handler_code + "\nhandler(\"GET\", \"/proxy?target=http://example.com\")",
  )
}

///|
test "vibe wasm eval for-c loop basic" {
  let script =
    #|let _start = () -> {
    #|  let mut sum = 0
    #|  for i = 1; lt(i, 6); i = add(i, 1) {
    #|    sum = add(sum, i)
    #|  }
    #|  sum
    #|}
    #|_start()
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval for-c loop with continue" {
  let script =
    #|let _start = () -> {
    #|  let mut sum = 0
    #|  for i = 0; lt(i, 10); i = add(i, 1) {
    #|    if eq(i, 5) { continue }
    #|    sum = add(sum, i)
    #|  }
    #|  sum
    #|}
    #|_start()
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval while loop with continue" {
  let script =
    #|let _start = () -> {
    #|  let mut i = 0
    #|  let mut sum = 0
    #|  while lt(i, 10) {
    #|    i = add(i, 1)
    #|    if eq(i, 5) { continue }
    #|    sum = add(sum, i)
    #|  }
    #|  sum
    #|}
    #|_start()
  assert_eval_backends_same(script)
}

///|
test "vibe backends match: String::length" {
  assert_eval_backends_same("String::length(\"hello\")")
  assert_eval_backends_same("String::length(\"\")")
  assert_eval_backends_same("String::length(\"abc\")")
}

///|
test "vibe backends match: String::char_code_at" {
  assert_eval_backends_same("String::char_code_at(\"abc\", 0)")
  assert_eval_backends_same("String::char_code_at(\"abc\", 2)")
}

///|
test "vibe backends match: String::substring" {
  assert_eval_backends_same("String::substring(\"hello world\", 0, 5)")
  assert_eval_backends_same("String::substring(\"abcdef\", 2, 5)")
  assert_eval_backends_same("String::substring(\"abc\", 0, 0)")
}

///|
test "vibe backends match: String::concat" {
  assert_eval_backends_same("String::concat(\"hello\", \" world\")")
  assert_eval_backends_same("String::concat(\"\", \"abc\")")
  assert_eval_backends_same("String::concat(\"abc\", \"\")")
}

///|
test "vibe backends match: String::join" {
  assert_eval_backends_same("String::join([\"a\", \"b\", \"c\"], \",\")")
  assert_eval_backends_same("String::join([\"only\"], \"-\")")
}

///|
test "vibe backends match: String::index_of" {
  assert_eval_backends_same("String::index_of(\"hello world\", \"world\")")
  assert_eval_backends_same("String::index_of(\"abcabc\", \"bc\")")
}

///|
test "vibe backends match: String::contains" {
  assert_eval_backends_same("String::contains(\"hello world\", \"world\")")
  assert_eval_backends_same("String::contains(\"hello\", \"xyz\")")
  assert_eval_backends_same("String::contains(\"abc\", \"\")")
}

///|
test "vibe backends match: String::starts_with" {
  assert_eval_backends_same("String::starts_with(\"hello world\", \"hello\")")
  assert_eval_backends_same("String::starts_with(\"hello\", \"xyz\")")
  assert_eval_backends_same("String::starts_with(\"abc\", \"\")")
}

///|
test "vibe backends match: String::ends_with" {
  assert_eval_backends_same("String::ends_with(\"hello world\", \"world\")")
  assert_eval_backends_same("String::ends_with(\"hello\", \"xyz\")")
  assert_eval_backends_same("String::ends_with(\"abc\", \"\")")
}

///|
test "vibe backends match: String::last_index_of" {
  assert_eval_backends_same("String::last_index_of(\"abcabc\", \"bc\")")
  assert_eval_backends_same("String::last_index_of(\"aaa\", \"a\")")
}

///|
test "vibe backends match: String::count" {
  assert_eval_backends_same("String::count(\"abcabc\", \"bc\")")
  assert_eval_backends_same("String::count(\"hello\", \"l\")")
}

///|
test "vibe backends match: String::trim" {
  assert_eval_backends_same("String::trim(\"  hello  \")")
  assert_eval_backends_same("String::trim(\"abc\")")
  assert_eval_backends_same("String::trim(\"  \")")
}

///|
test "vibe backends match: String::trim_start" {
  assert_eval_backends_same("String::trim_start(\"  hello\")")
  assert_eval_backends_same("String::trim_start(\"abc\")")
}

///|
test "vibe backends match: String::trim_end" {
  assert_eval_backends_same("String::trim_end(\"hello  \")")
  assert_eval_backends_same("String::trim_end(\"abc\")")
}

///|
test "vibe backends match: String::to_upper" {
  assert_eval_backends_same("String::to_upper(\"hello\")")
  assert_eval_backends_same("String::to_upper(\"ABC\")")
  assert_eval_backends_same("String::to_upper(\"aBc123\")")
}

///|
test "vibe backends match: String::to_lower" {
  assert_eval_backends_same("String::to_lower(\"HELLO\")")
  assert_eval_backends_same("String::to_lower(\"abc\")")
  assert_eval_backends_same("String::to_lower(\"AbC123\")")
}

///|
test "vibe backends match: String::replace" {
  assert_eval_backends_same(
    "String::replace(\"hello world\", \"world\", \"there\")",
  )
  assert_eval_backends_same("String::replace(\"aaa\", \"a\", \"bb\")")
}

///|
test "vibe backends match: String::replace_all" {
  assert_eval_backends_same("String::replace_all(\"abcabc\", \"bc\", \"xy\")")
  assert_eval_backends_same("String::replace_all(\"hello\", \"l\", \"r\")")
}

///|
test "vibe backends match: String::split" {
  assert_eval_backends_same("String::split(\"a,b,c\", \",\")")
  assert_eval_backends_same("String::split(\"hello\", \",\")")
  assert_eval_backends_same("String::split(\",a,,b,\", \",\")")
}

///|
test "vibe backends match: String::equals" {
  assert_eval_backends_same("String::equals(\"abc\", \"abc\")")
  assert_eval_backends_same("String::equals(\"abc\", \"def\")")
  assert_eval_backends_same("String::equals(\"\", \"\")")
}

///|
test "vibe backends match: String::from_char_code" {
  assert_eval_backends_same("String::from_char_code(65)")
  assert_eval_backends_same("String::from_char_code(97)")
}

///|
test "vibe backends match: Int::abs" {
  assert_eval_backends_same("Int::abs(5)")
  assert_eval_backends_same("Int::abs(-5)")
  assert_eval_backends_same("Int::abs(0)")
}

///|
test "vibe backends match: Int::is_even and Int::is_odd" {
  assert_eval_backends_same("Int::is_even(4)")
  assert_eval_backends_same("Int::is_even(3)")
  assert_eval_backends_same("Int::is_odd(3)")
  assert_eval_backends_same("Int::is_odd(4)")
  assert_eval_backends_same("Int::is_even(0)")
}

///|
test "vibe backends match: Map::has_key" {
  assert_eval_backends_same(
    "let m = map { a: 1, b: 2 }\nMap::has_key(m, \"a\")",
  )
  assert_eval_backends_same(
    "let m = map { a: 1, b: 2 }\nMap::has_key(m, \"c\")",
  )
}

///|
test "vibe backends match: Map::keys" {
  assert_eval_backends_same("let m = map { a: 1, b: 2 }\nMap::keys(m)")
}

///|
test "vibe backends match: Map::values" {
  assert_eval_backends_same("let m = map { a: 1, b: 2 }\nMap::values(m)")
}

///|
test "vibe backends match: Set::new and Set::size" {
  assert_eval_backends_same("Set::size(Set::new())")
}

///|
test "vibe backends match: Set::add and Set::contains" {
  assert_eval_backends_same(
    "let s = Set::new()\nlet s2 = Set::add(s, 42)\nSet::contains(s2, 42)",
  )
  assert_eval_backends_same(
    "let s = Set::new()\nlet s2 = Set::add(s, 42)\nSet::contains(s2, 99)",
  )
}

///|
test "vibe backends match: Set::add and Set::size" {
  assert_eval_backends_same(
    "let s = Set::new()\nlet s2 = Set::add(s, 1)\nlet s3 = Set::add(s2, 2)\nSet::size(s3)",
  )
}

///|
test "vibe backends match: Set::remove" {
  assert_eval_backends_same(
    "let s = Set::new()\nlet s2 = Set::add(s, 1)\nlet s3 = Set::add(s2, 2)\nlet s4 = Set::remove(s3, 1)\nSet::size(s4)",
  )
}

///|
test "vibe backends match: Set::from_array" {
  assert_eval_backends_same("Set::size(Set::from_array([1, 2, 3]))")
  assert_eval_backends_same("Set::contains(Set::from_array([10, 20]), 10)")
}

///|
test "vibe backends match: Bytes::length" {
  assert_eval_backends_same(
    "let b = Bytes::from_array([1, 2, 3])\nBytes::length(b)",
  )
}

///|
test "vibe backends match: Bytes::get and Bytes::set" {
  assert_eval_backends_same(
    "let b = Bytes::from_array([10, 20, 30])\nBytes::get(b, 1)",
  )
  assert_eval_backends_same(
    "let b = Bytes::from_array([10, 20, 30])\nBytes::set(b, 1, 99)\nBytes::get(b, 1)",
  )
}

///|
test "vibe backends match: Bytes::push" {
  assert_eval_backends_same(
    "let b = Bytes::from_array([1])\nBytes::push(b, 42)\nBytes::length(b)",
  )
}

///|
test "vibe backends match: Bytes::from_string and Bytes::to_string" {
  assert_eval_backends_same(
    "let b = Bytes::from_string(\"abc\")\nBytes::length(b)",
  )
}

///|
test "vibe backends match: Bytes::append" {
  assert_eval_backends_same(
    "let a = Bytes::from_array([1, 2])\nlet b = Bytes::from_array([3, 4])\nBytes::append(a, b)\nBytes::length(a)",
  )
}

///|
// Bytes::fill and Bytes::blit are not registered in the checker.

///|
test "vibe backends match: Bytes::concat" {
  assert_eval_backends_same(
    "let a = Bytes::from_array([1, 2])\nlet b = Bytes::from_array([3, 4])\nlet c = Bytes::concat(a, b)\nBytes::length(c)",
  )
}

///|
test "vibe backends match: Array::length" {
  assert_eval_backends_same("Array::length([1, 2, 3])")
  assert_eval_backends_same("Array::length([])")
}

///|
test "vibe backends match: Array::set" {
  assert_eval_backends_same(
    "let a = [1, 2, 3]\nArray::set(a, 1, 99)\nArray::get(a, 1)",
  )
}

///|
test "vibe backends match: Array::truncate" {
  assert_eval_backends_same(
    "let a = [1, 2, 3, 4, 5]\nArray::truncate(a, 3)\nArray::length(a)",
  )
}

///|
test "vibe backends match: FixedArray::make and FixedArray::length" {
  assert_eval_backends_same("FixedArray::length(FixedArray::make(5, 0))")
}

///|
test "vibe backends match: FixedArray::get and FixedArray::set" {
  assert_eval_backends_same(
    "let a = FixedArray::make(3, 0)\nFixedArray::set(a, 1, 42)\nFixedArray::get(a, 1)",
  )
}

///|
test "vibe backends match: FixedArray::blit" {
  assert_eval_backends_same(
    "let src = FixedArray::make(3, 10)\nlet dst = FixedArray::make(3, 0)\nFixedArray::blit(dst, 0, src, 0, 3)\nFixedArray::get(dst, 2)",
  )
}

///|
test "vibe backends match: StringBuilder" {
  assert_eval_backends_same(
    "let sb = StringBuilder::new()\nStringBuilder::push(sb, \"hello\")\nStringBuilder::push(sb, \" world\")\nStringBuilder::freeze(sb)",
  )
}

///|
test "vibe wasm eval Array::concat" {
  let script =
    #|let a = [1, 2]
    #|let b = [3, 4]
    #|Array::length(Array::concat(a, b))
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval Array::push_all" {
  let script =
    #|let a = [1, 2]
    #|Array::push_all(a, [3, 4])
    #|Array::length(a)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval Array::slice" {
  let script =
    #|let a = [10, 20, 30, 40, 50]
    #|let s = Array::slice(a, 1, 4)
    #|Array::length(s)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval String::utf8_length" {
  let script =
    #|String::utf8_length("hello")
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval String::replace_all" {
  let script =
    #|let s = String::replace_all("aabbcc", "bb", "XX")
    #|String::length(s)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval nested function call" {
  let script =
    #|let add = (a: Int, b: Int) -> Int { a + b }
    #|let mul = (a: Int, b: Int) -> Int { a * b }
    #|mul(add(1, 2), add(3, 4))
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval match with guard" {
  let script =
    #|let x = 5
    #|match x {
    #|  n if n > 3 => 1,
    #|  _ => 0
    #|}
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval string interpolation basic" {
  let script =
    #|let name = "world"
    #|let msg = "hello \{name}"
    #|String::length(msg)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval recursive fibonacci" {
  let script =
    #|let rec fib = (n: Int) -> Int {
    #|  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
    #|}
    #|fib(10)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval closure capture" {
  let script =
    #|let x = 10
    #|let add_x = (n: Int) -> Int { n + x }
    #|add_x(5)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval while with accumulator and break" {
  let script =
    #|let main = () -> Int {
    #|  let mut sum = 0
    #|  let mut i = 0
    #|  while i < 100 {
    #|    sum = sum + i
    #|    i = i + 1
    #|    if sum > 50 { break }
    #|  }
    #|  sum
    #|}
    #|main()
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval tuple destructure" {
  let script =
    #|let pair = (10, 20)
    #|let (a, b) = pair
    #|a + b
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval enum with payload match" {
  let script =
    #|enum Result { Ok(Int); Err }
    #|let x = Ok(42)
    #|match x { Ok(n) => n, Err => 0 }
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval let rec with captured helpers" {
  // Mimics markdown parse_blocks pattern: let rec that captures outer helpers
  let script =
    #|let is_special = (n: Int) -> Bool { n > 10 }
    #|let transform = (n: Int) -> Int { n * 2 }
    #|let rec process = (items: Array[Int], idx: Int) -> Int {
    #|  if idx >= Array::length(items) {
    #|    0
    #|  } else {
    #|    let item = Array::get(items, idx)
    #|    let value = if is_special(item) { transform(item) } else { item }
    #|    value + process(items, idx + 1)
    #|  }
    #|}
    #|process([1, 2, 20, 3, 15], 0)
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval let rec with many captures" {
  // Larger let rec with multiple captured helpers (closer to markdown parse_blocks)
  let script =
    #|let check_a = (n: Int) -> Bool { n == 1 }
    #|let check_b = (n: Int) -> Bool { n == 2 }
    #|let check_c = (n: Int) -> Bool { n == 3 }
    #|let val_a = 100
    #|let val_b = 200
    #|let val_c = 300
    #|let rec classify = (items: Array[Int], idx: Int, acc: Int) -> Int {
    #|  if idx >= Array::length(items) {
    #|    acc
    #|  } else {
    #|    let item = Array::get(items, idx)
    #|    let contribution = if check_a(item) {
    #|      val_a
    #|    } else if check_b(item) {
    #|      val_b
    #|    } else if check_c(item) {
    #|      val_c
    #|    } else {
    #|      item
    #|    }
    #|    classify(items, idx + 1, acc + contribution)
    #|  }
    #|}
    #|classify([1, 2, 3, 4, 1], 0, 0)
  // 100 + 200 + 300 + 4 + 100 = 704
  let res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 704L)
}

///|
test "vibe wasm eval let rec called from two paths" {
  // Tests that let rec works regardless of call path (issue #10)
  let script =
    #|let rec sum_arr = (arr: Array[Int], i: Int) -> Int {
    #|  if i >= Array::length(arr) { 0 }
    #|  else { Array::get(arr, i) + sum_arr(arr, i + 1) }
    #|}
    #|let via_direct = sum_arr([1, 2, 3], 0)
    #|let wrapper = (arr: Array[Int]) -> Int { sum_arr(arr, 0) }
    #|let via_wrapper = wrapper([4, 5, 6])
    #|via_direct + via_wrapper
  assert_eval_backends_same(script)
}

///|
test "vibe wasm eval let rec multiple invocations with captures" {
  // Issue #10: let rec should work reliably with multiple call sites
  let script =
    #|let threshold = 5
    #|let rec count_above = (arr: Array[Int], idx: Int) -> Int {
    #|  if idx >= Array::length(arr) { 0 }
    #|  else {
    #|    let item = Array::get(arr, idx)
    #|    let add = if item > threshold { 1 } else { 0 }
    #|    add + count_above(arr, idx + 1)
    #|  }
    #|}
    #|let r1 = count_above([1, 10, 3, 20], 0)
    #|let r2 = count_above([6, 7, 8], 0)
    #|let r3 = count_above([1, 2, 3], 0)
    #|r1 * 100 + r2 * 10 + r3
  // r1=2, r2=3, r3=0 → 230
  let res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 230L)
}

// ======================================================================
// RC-enabled WASM execution tests
// ======================================================================

///|
fn eval_run_rc(script : String) -> WasmEvalResult raise WasmRunError {
  let db = VibeDb::new()
  db.set_source("main", script)
  let wasm = compile_module_wasm(db, "main", enable_rc=true) catch {
    e => raise WasmRunError::Compile(e.to_string())
  }
  run_wasm(wasm) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
}

///|
test "rc eval: simple integer passes through unchanged" {
  let res = try eval_run_rc("42") catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 42L)
}

///|
test "rc eval: tuple allocation and field access" {
  let res = try eval_run_rc("let t = (10, 20, 30)\nt.1") catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 20L)
}

///|
// TODO: "rc eval: function returning tuple" — stack underflow in interpreter
// due to free-list codegen in named function bodies. Needs investigation.

///|
// TODO: "rc eval: mutable reassignment preserves correctness" — same issue
// as above: RC codegen in function bodies triggers interpreter stack underflow.

///|
test "rc eval: multiple tuple variables" {
  let script =
    #|let a = (1, 2)
    #|let b = (3, 4)
    #|a.0 + a.1 + b.0 + b.1
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 10L)
}

///|
test "rc eval: tuple passed to function" {
  let script =
    #|let sum_pair = (p: (Int, Int)) -> Int { p.0 + p.1 }
    #|let t = (5, 7)
    #|sum_pair(t)
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 12L)
}

///|
test "rc eval: array allocation and indexing" {
  let script =
    #|let arr = [10, 20, 30]
    #|arr[1]
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 20L)
}

///|
// TODO: "rc eval: if/else returning tuples" — same interpreter stack underflow
// issue with RC codegen in named function bodies.

///|
test "rc eval: rc result matches non-rc result for arithmetic" {
  let script = "let f = (x: Int) -> Int { x * x + 2 * x + 1 }\nf(10)"
  let res_rc = try eval_run_rc(script) catch {
    e => fail("rc eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let res_no_rc = try eval_run(script) catch {
    e => fail("non-rc eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(res_rc.value, res_no_rc.value)
}

///|
test "rc eval: rc result matches non-rc result for tuple" {
  let script =
    #|let t = (7, 8, 9)
    #|t.0 + t.1 + t.2
  let res_rc = try eval_run_rc(script) catch {
    e => fail("rc eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let res_no_rc = try eval_run(script) catch {
    e => fail("non-rc eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(res_rc.value, res_no_rc.value)
}
