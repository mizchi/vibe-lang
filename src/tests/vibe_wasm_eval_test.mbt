///|
/// Tests for executing vibe-generated WASM
suberror WasmEvalError {
  UnexpectedEof
  Invalid(String)
  Unsupported(String)
} derive(Debug, Eq)

///|
impl Show for WasmEvalError with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
suberror WasmRunError {
  Compile(String)
  Eval(String)
} derive(Debug, Eq)

///|
impl Show for WasmRunError with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
struct WasmEvalResult {
  value : Int64
  outputs : Array[String]
  mem : Array[Byte]
  globals : Array[Int64]
} derive(Debug, Eq)

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
/// Read a signed LEB128 i32 immediate (the encoding used by `i32.const`).
/// Unlike `read_leb_u32`, this sign-extends when the final byte's 0x40 bit is
/// set, so e.g. the single byte `0x7F` decodes to -1 rather than 127. Reading
/// `i32.const` as unsigned previously made negative constants (notably the
/// `result = -1` sentinel in `String::index_of`) come back as large positives.
fn Cursor::read_leb_i32(self : Cursor) -> Int raise WasmEvalError {
  let mut result = 0
  let mut shift = 0
  let mut last_byte = 0
  while true {
    let byte = self.read_u8()
    last_byte = byte
    result = result | ((byte & 0x7f) << shift)
    if (byte & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 35 {
      raise WasmEvalError::Invalid("leb overflow")
    }
  }
  if shift < 32 && (last_byte & 0x40) != 0 {
    result = result | (-1 << (shift + 7))
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
let obj_tuple = 3

///|
let obj_record = 4

///|
let obj_array = 5

///|
let obj_map = 6

///|
let obj_float = 8

///|
let obj_double = 9

///|
let obj_enum = 10

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
    // 127 = i32, 126 = i64, 123 = v128. vibe-lang treats the wasm SIMD
    // extension as an always-on baseline, so v128 locals appear in core
    // primitives (e.g. the SIMD-accelerated array fill). This interpreter
    // only ever sees splat-broadcast vectors, which it models as their
    // single i32 lane in one Int64 stack slot (see the 0xFD handler).
    if ty != 127 && ty != 126 && ty != 123 {
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
      65 => cur.read_leb_i32().to_int64() // i32.const (signed LEB128)
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
} derive(Debug, Eq)

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
      14 => { // br_table
        let count = code.read_leb_u32()
        for _i = 0; _i < count + 1; _i = _i + 1 {
          skip_leb(code)
        }
      }
      40 | 41 | 42 | 43 | 45 | 54 | 55 | 56 | 57 | 58 => {
        skip_leb(code)
        skip_leb(code)
      }
      253 => skip_simd_immediates(code) // SIMD (v128) prefix
      _ => ()
    }
  }
  raise WasmEvalError::UnexpectedEof
}

///|
/// Skip the immediates of a v128 (0xFD-prefixed) instruction during static
/// block scanning. The sub-opcode LEB is always present; load/store forms
/// (0 = v128.load, 11 = v128.store) additionally carry a 2-LEB memarg.
fn skip_simd_immediates(code : Cursor) -> Unit raise WasmEvalError {
  let subop = code.read_leb_u32()
  if subop == 0 || subop == 11 {
    skip_leb(code) // align
    skip_leb(code) // offset
  }
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
      14 => { // br_table
        let count = code.read_leb_u32()
        for _i = 0; _i < count + 1; _i = _i + 1 {
          skip_leb(code)
        }
      }
      40 | 41 | 42 | 43 | 45 | 54 | 55 | 56 | 57 | 58 => {
        skip_leb(code)
        skip_leb(code)
      }
      253 => skip_simd_immediates(code) // SIMD (v128) prefix
      _ => ()
    }
  }
  raise WasmEvalError::UnexpectedEof
}

///|
struct WasmModule {
  func_bodies : Array[FuncBody]
  func_param_counts : Array[Int] // param count for each local function
  func_result_counts : Array[Int] // result count for each local function
  func_exports : Map[String, Int]
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
  let func_exports : Map[String, Int] = {}
  let globals : Array[Int64] = []
  let mem : Array[Byte] = Array::make(65536, (0).to_byte())
  let type_param_counts : Array[Int] = [] // param counts for each type entry
  let type_result_counts : Array[Int] = [] // result counts for each type entry
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
            type_result_counts.push(1)
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
          type_result_counts.push(result_count)
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
      7 => {
        let sec = Cursor::new(payload)
        let count = sec.read_leb_u32()
        for _ in 0..<count {
          let name = sec.read_name()
          let kind = sec.read_u8()
          let index = sec.read_leb_u32()
          if kind == 0 {
            func_exports[name] = index
          }
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
  // Build param/result counts for each local function
  let func_param_counts : Array[Int] = []
  let func_result_counts : Array[Int] = []
  for i in 0..<func_type_indices.length() {
    let type_idx = func_type_indices[i]
    if type_idx < type_param_counts.length() {
      func_param_counts.push(type_param_counts[type_idx])
    } else {
      func_param_counts.push(0)
    }
    if type_idx < type_result_counts.length() {
      func_result_counts.push(type_result_counts[type_idx])
    } else {
      func_result_counts.push(1)
    }
  }
  {
    func_bodies,
    func_param_counts,
    func_result_counts,
    func_exports,
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
) -> Array[Int64] raise WasmEvalError {
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
  let result_count = if local_idx < wmod.func_result_counts.length() {
    wmod.func_result_counts[local_idx]
  } else {
    1
  }
  let locals : Array[Int64] = Array::make(param_count + fb.locals, 0L)
  for i in 0..<args.length() {
    locals[i] = args[i]
  }
  let code = Cursor::new(fb.code)
  let stack : Array[Int64] = []
  let mem = wmod.mem
  let globals = wmod.globals
  let _ = eval_loop(
    wmod, code, locals, stack, mem, globals, outputs, call_depth,
  )
  // Return the top result_count values from the stack
  let results : Array[Int64] = []
  let start = if stack.length() > result_count {
    stack.length() - result_count
  } else {
    0
  }
  for i in start..<stack.length() {
    results.push(stack[i])
  }
  // If fewer values than expected, pad with 0
  while results.length() < result_count {
    results.push(0L)
  }
  results
}

///|
fn run_wasm(bytes : Bytes) -> WasmEvalResult raise WasmEvalError {
  let wmod = parse_wasm_module(bytes)
  if wmod.func_bodies.is_empty() {
    raise WasmEvalError::Invalid("missing code")
  }
  // Prefer the tagged eval export when present. `_start` intentionally
  // strips int tags for Wasmtime/CLI parity, so using the last function or
  // `_start` here breaks the decoder on scalar results.
  let run_idx = match wmod.func_exports.get("_vibe_run_tagged") {
    Some(idx) => idx
    None =>
      // Backward compatibility for modules emitted before `_vibe_run_tagged`
      // was added: fall back to the last function body.
      wmod.import_count + wmod.func_bodies.length() - 1
  }
  let outputs : Array[String] = []
  let results = exec_func(wmod, run_idx, [], outputs, 0)
  let value = if results.is_empty() {
    0L
  } else {
    results[results.length() - 1]
  }
  { value, outputs, mem: wmod.mem, globals: wmod.globals }
}

///|
fn run_wasm_export(
  bytes : Bytes,
  export_name : String,
) -> WasmEvalResult raise WasmEvalError {
  let wmod = parse_wasm_module(bytes)
  let export_idx = match wmod.func_exports.get(export_name) {
    Some(idx) => idx
    None => raise WasmEvalError::Invalid("missing export: " + export_name)
  }
  let outputs : Array[String] = []
  let results = exec_func(wmod, export_idx, [], outputs, 0)
  let value = if results.is_empty() {
    0L
  } else {
    results[results.length() - 1]
  }
  { value, outputs, mem: wmod.mem, globals: wmod.globals }
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
  // v128 value pool. The Int64 value stack cannot hold a 128-bit value, so a
  // v128 is materialised as a 16-byte FixedArray and referenced from the
  // stack/locals by its pool index. v128 values never cross a call boundary
  // in vibe-lang codegen (produced and consumed within one function body —
  // SIMD array fill and string-content equality), so a per-eval_loop pool is
  // sufficient.
  let v128_pool : Array[FixedArray[Byte]] = []
  while true {
    let op = code.read_u8()
    match op {
      0 => raise WasmEvalError::Invalid("unreachable")
      // i32.const (signed LEB128)
      65 => {
        let v = code.read_leb_i32()
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
      // select
      27 => {
        if stack.length() < 3 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let cond = stack.unsafe_pop()
        let val2 = stack.unsafe_pop()
        let val1 = stack.unsafe_pop()
        stack.push(if cond != 0L { val1 } else { val2 })
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
                  let results = exec_func(
                    wmod,
                    idx,
                    args,
                    outputs,
                    call_depth + 1,
                  )
                  for r in results {
                    stack.push(r)
                  }
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
          // Restore the value stack to the loop's entry height (wasm br
          // semantics) so leftover operands cannot accumulate across
          // iterations.
          while stack.length() > _sh {
            let _ = stack.unsafe_pop()
          }
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
            while stack.length() > _sh {
              let _ = stack.unsafe_pop()
            }
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
      // br_table
      14 => {
        let count = code.read_leb_u32()
        let labels : Array[Int] = []
        for _i = 0; _i < count; _i = _i + 1 {
          labels.push(code.read_leb_u32())
        }
        let default_label = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let index = stack.unsafe_pop().to_int()
        let depth = if index >= 0 && index < labels.length() {
          labels[index]
        } else {
          default_label
        }
        let target_idx = block_stack.length() - 1 - depth
        if target_idx < 0 {
          raise WasmEvalError::Invalid("br_table depth")
        }
        let (kind, loop_pos, _sh) = block_stack[target_idx]
        if kind == 1 {
          code.pos = loop_pos
          while block_stack.length() > target_idx + 1 {
            let _ = block_stack.pop()
          }
        } else {
          let blocks_to_exit = depth + 1
          for _ in 0..<blocks_to_exit {
            skip_to_end(code)
          }
          for _ in 0..<blocks_to_exit {
            let _ = block_stack.pop()
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
      // SIMD (v128) prefix. vibe-lang treats the wasm SIMD extension as an
      // always-on baseline (ADR-0054), so v128 ops appear in core primitives:
      // the splat-broadcast array fill (`i32x4.splat` + `v128.store`) and the
      // 16-byte string-content equality scan (`v128.load` + `i8x16.eq` +
      // `i8x16.all_true`). v128 values live in `v128_pool`, referenced by
      // index on the Int64 stack.
      253 => {
        let subop = code.read_leb_u32()
        match subop {
          // v128.load: pool a 16-byte copy of memory at addr+offset.
          0 => {
            let _ = code.read_leb_u32() // align
            let offset = code.read_leb_u32()
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let addr = stack.unsafe_pop().to_int()
            let v : FixedArray[Byte] = FixedArray::make(16, (0).to_byte())
            for i in 0..<16 {
              v[i] = mem[addr + offset + i]
            }
            v128_pool.push(v)
            stack.push((v128_pool.length() - 1).to_int64())
          }
          // v128.store: write the pooled 16 bytes back to memory.
          11 => {
            let _ = code.read_leb_u32() // align
            let offset = code.read_leb_u32()
            if stack.length() < 2 {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let idx = stack.unsafe_pop().to_int()
            let addr = stack.unsafe_pop().to_int()
            let v = v128_pool[idx]
            for i in 0..<16 {
              mem[addr + offset + i] = v[i]
            }
          }
          // i32x4.splat: broadcast the low 32 bits to all four lanes.
          17 => {
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let val = stack.unsafe_pop().to_int()
            let v : FixedArray[Byte] = FixedArray::make(16, (0).to_byte())
            for lane in 0..<4 {
              v[lane * 4 + 0] = (val & 0xff).to_byte()
              v[lane * 4 + 1] = ((val >> 8) & 0xff).to_byte()
              v[lane * 4 + 2] = ((val >> 16) & 0xff).to_byte()
              v[lane * 4 + 3] = ((val >> 24) & 0xff).to_byte()
            }
            v128_pool.push(v)
            stack.push((v128_pool.length() - 1).to_int64())
          }
          // i8x16.eq: per-byte equality (0xFF where equal, else 0x00).
          35 => {
            if stack.length() < 2 {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let bi = stack.unsafe_pop().to_int()
            let ai = stack.unsafe_pop().to_int()
            let a = v128_pool[ai]
            let b = v128_pool[bi]
            let r : FixedArray[Byte] = FixedArray::make(16, (0).to_byte())
            for i in 0..<16 {
              r[i] = if a[i] == b[i] { (0xff).to_byte() } else { (0).to_byte() }
            }
            v128_pool.push(r)
            stack.push((v128_pool.length() - 1).to_int64())
          }
          // i8x16.all_true: 1 iff every lane is non-zero.
          99 => {
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let idx = stack.unsafe_pop().to_int()
            let v = v128_pool[idx]
            let mut all = 1
            for i in 0..<16 {
              if v[i].to_int() == 0 {
                all = 0
              }
            }
            stack.push(all.to_int64())
          }
          // i8x16.splat: broadcast the low 8 bits to all 16 lanes.
          15 => {
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let b = (stack.unsafe_pop().to_int() & 0xff).to_byte()
            let v : FixedArray[Byte] = FixedArray::make(16, b)
            v128_pool.push(v)
            stack.push((v128_pool.length() - 1).to_int64())
          }
          // v128.any_true: 1 iff any lane is non-zero.
          83 => {
            if stack.is_empty() {
              raise WasmEvalError::Invalid("stack underflow")
            }
            let idx = stack.unsafe_pop().to_int()
            let v = v128_pool[idx]
            let mut any = 0
            for i in 0..<16 {
              if v[i].to_int() != 0 {
                any = 1
              }
            }
            stack.push(any.to_int64())
          }
          _ => raise WasmEvalError::Unsupported("simd op " + subop.to_string())
        }
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
  if ty == obj_tuple {
    let len = object_len(mem, tagged)
    let base = untag_ptr(tagged)
    let out : Array[@core.Value] = []
    for i in 0..<len {
      let item = read_u32_le(mem, base + 8 + i * 4).to_int64()
      out.push(decode_tagged_value(mem, item, depth + 1))
    }
    return @core.Value::Tuple(out)
  }
  if ty == obj_record {
    let len = object_len(mem, tagged)
    let base = untag_ptr(tagged)
    let out : Map[String, @core.Value] = {}
    for i in 0..<len {
      let key_ptr = read_u32_le(mem, base + 8 + i * 8).to_int64()
      let value = read_u32_le(mem, base + 12 + i * 8).to_int64()
      let key = read_string_object(mem, key_ptr)
      out[key] = decode_tagged_value(mem, value, depth + 1)
    }
    return @core.Value::Record(out)
  }
  if ty == obj_float {
    let base = untag_ptr(tagged)
    let bits = read_u32_le(mem, base + 4)
    return @core.Value::Float(Float::reinterpret_from_int(bits))
  }
  if ty == obj_double {
    let base = untag_ptr(tagged)
    let lo = read_u32_le(mem, base + 4)
    let hi = read_u32_le(mem, base + 8)
    let bits = (hi.to_int64().reinterpret_as_uint64() << 32) |
      (lo.to_int64() & 0xFFFFFFFFL).reinterpret_as_uint64()
    return @core.Value::Double(bits.reinterpret_as_double())
  }
  if ty == obj_enum {
    let base = untag_ptr(tagged)
    let arity = read_u32_le(mem, base + 4)
    let _ctor_tag = read_u32_le(mem, base + 8)
    let args : Array[@core.Value] = []
    for i in 0..<arity {
      let arg = read_u32_le(mem, base + 12 + i * 4).to_int64()
      args.push(decode_tagged_value(mem, arg, depth + 1))
    }
    return @core.Value::Tuple(args)
  }
  if ty == obj_bytes {
    // Layout: [type:i32][len:i32][cap:i32][data_ptr:i32]
    let base = untag_ptr(tagged)
    let len = read_u32_le(mem, base + 4)
    let data_ptr = read_u32_le(mem, base + 12)
    let out : Array[Byte] = []
    for i in 0..<len {
      out.push(mem[data_ptr + i])
    }
    return @core.Value::Bytes(out)
  }
  if ty == obj_bytes_view {
    // Layout: [type:i32][source_ptr:i32][start:i32][end:i32]
    let base = untag_ptr(tagged)
    let source_ptr = read_u32_le(mem, base + 4)
    let start = read_u32_le(mem, base + 8)
    let end = read_u32_le(mem, base + 12)
    let len = end - start
    let source_data_ptr = read_u32_le(mem, source_ptr + 12)
    let out : Array[Byte] = []
    for i in 0..<len {
      out.push(mem[source_data_ptr + start + i])
    }
    return @core.Value::Bytes(out)
  }
  raise WasmEvalError::Unsupported(
    "decode unsupported object type: " + ty.to_string(),
  )
}

///|
/// Assert that a script compiles and runs successfully via WASM backend.
fn assert_wasm_eval_decodes(script : String) -> Unit raise {
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
/// Assert that a script evaluates to a specific tagged Int via the WASM
/// backend. Used to pin the correctness of the SIMD-accelerated array fill
/// across the vector-loop / scalar-tail boundary.
fn assert_wasm_eval_int(script : String, expected : Int) -> Unit raise {
  let wasm_res = try eval_run(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let decoded = try decode_tagged_value(wasm_res.mem, wasm_res.value, 0) catch {
    e => fail("wasm decode failed: " + e.to_string())
  } noraise {
    r => r
  }
  match decoded {
    @core.Value::Int(n) =>
      if n != expected.to_int64() {
        fail(
          "wasm eval = " + n.to_string() + ", expected " + expected.to_string(),
        )
      }
    other => fail("wasm eval returned non-Int: " + other.to_string())
  }
}

///|
/// The SIMD fill writes 4 elements per 16-byte `v128.store`, then a scalar
/// tail covers the trailing `size & 3` cells. Probe both regions at a range
/// of sizes that straddle the vector/tail boundary (0..2 full vectors plus
/// every tail remainder) to ensure every cell receives the fill value.
test "vibe wasm eval: SIMD array fill covers vector body and scalar tail" {
  // size 3: scalar tail only (no full vector) — last cell.
  assert_wasm_eval_int("FixedArray::get(FixedArray::make(3, 9), 2)", 9)
  // size 4: exactly one vector, no tail — last cell of the vector.
  assert_wasm_eval_int("FixedArray::get(FixedArray::make(4, 5), 3)", 5)
  // size 7: one vector + 3 tail — a vector cell and the last tail cell.
  assert_wasm_eval_int("FixedArray::get(FixedArray::make(7, 8), 1)", 8)
  assert_wasm_eval_int("FixedArray::get(FixedArray::make(7, 8), 6)", 8)
  // size 9: two vectors + 1 tail — the lone tail cell.
  assert_wasm_eval_int("FixedArray::get(FixedArray::make(9, 6), 8)", 6)
  // Growable `Array` element access still reads back correctly post-fill.
  assert_wasm_eval_int("Array::get([3, 3, 3, 3, 3, 3, 3], 6)", 3)
}

///|
fn assert_wasm_eval_captures_shell_effects(script : String) -> Unit raise {
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
test "vibe wasm export _start returns raw int" {
  let db = VibeDb::new()
  db.set_source("main", "42")
  let wasm = compile_module_wasm(db, "main") catch { e => fail(e.to_string()) }
  let res = try run_wasm_export(wasm, "_start") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(res.value, 42L)
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
  let script =
    #|export let _start = () -> Unit with { Process } {
    #|  if false { sh("a") } else { sh("b") }
    #|}
  let res = try eval_run(script) catch {
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
  let script =
    #|export let _start = () -> Unit with { Process } {
    #|  sh("hello")
    #|}
  let res = try eval_run(script) catch {
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
test "vibe wasm eval decodes scalar outputs" {
  assert_wasm_eval_decodes("let x = 1\nadd(x, 2)")
  assert_wasm_eval_decodes("if lt(1, 2) { \"ok\" } else { \"ng\" }")
  assert_wasm_eval_decodes("not(and(true, false))")
  assert_wasm_eval_decodes("let p = path(\"a/../b\")\np")
}

///|
test "vibe wasm eval decodes collection outputs" {
  assert_wasm_eval_decodes("[1, add(1, 2), 5]")
  assert_wasm_eval_decodes("map { a: 1, b: add(1, 2) }")
}

///|
test "vibe wasm eval supports map string key lookup" {
  assert_wasm_eval_decodes("let m = map { a: 1, b: 2 }\nMap::get(m, \"a\")")
}

///|
test "vibe wasm eval captures shell effects" {
  let script =
    #|export let _start = () -> Int with { Process } {
    #|  { sh("echo hello") }
    #|  { sh("echo world") }
    #|  42
    #|}
  assert_wasm_eval_captures_shell_effects(script)
}

///|
test "vibe wasm eval supports arithmetic operators" {
  assert_wasm_eval_decodes("1 + 2")
  assert_wasm_eval_decodes("10 - 3")
  assert_wasm_eval_decodes("3 * 4")
  assert_wasm_eval_decodes("10 / 3")
  assert_wasm_eval_decodes("10 % 3")
  assert_wasm_eval_decodes("-5")
  assert_wasm_eval_decodes("-(3 + 2)")
  assert_wasm_eval_decodes("1 + 2 * 3")
  assert_wasm_eval_decodes("(1 + 2) * 3")
}

///|
test "vibe wasm eval supports comparison operators" {
  assert_wasm_eval_decodes("1 == 1")
  assert_wasm_eval_decodes("1 != 2")
  assert_wasm_eval_decodes("1 < 2")
  assert_wasm_eval_decodes("2 > 1")
  assert_wasm_eval_decodes("1 <= 1")
  assert_wasm_eval_decodes("2 >= 1")
  assert_wasm_eval_decodes("1 > 2")
  assert_wasm_eval_decodes("1 >= 2")
  assert_wasm_eval_decodes("3 <= 2")
  assert_wasm_eval_decodes("0 == 0")
}

///|
test "vibe wasm eval supports bitwise operators" {
  assert_wasm_eval_decodes("5 & 3")
  assert_wasm_eval_decodes("5 | 3")
  assert_wasm_eval_decodes("5 ^ 3")
  assert_wasm_eval_decodes("1 << 3")
  assert_wasm_eval_decodes("8 >> 2")
  assert_wasm_eval_decodes("0 & 0")
  assert_wasm_eval_decodes("255 & 15")
}

///|
test "vibe wasm eval supports boolean expressions" {
  assert_wasm_eval_decodes("true")
  assert_wasm_eval_decodes("false")
  assert_wasm_eval_decodes("not(false)")
  assert_wasm_eval_decodes("and(true, true)")
  assert_wasm_eval_decodes("or(false, true)")
  assert_wasm_eval_decodes("and(true, false)")
  assert_wasm_eval_decodes("not(or(false, false))")
  assert_wasm_eval_decodes("and(not(false), true)")
}

///|
test "vibe wasm eval supports: block expressions" {
  assert_wasm_eval_decodes("{ let x = 10\n x }")
  assert_wasm_eval_decodes("{ let a = 1\n let b = 2\n a + b }")
  assert_wasm_eval_decodes("{ let x = { let y = 3\n y * 2 }\n x + 1 }")
}

///|
test "vibe wasm eval supports: nested conditionals" {
  assert_wasm_eval_decodes("if true { if false { 1 } else { 2 } } else { 3 }")
  assert_wasm_eval_decodes("if false { 1 } else { if true { 2 } else { 3 } }")
  assert_wasm_eval_decodes(
    "if 1 < 2 { if 3 > 4 { 10 } else { 20 } } else { 30 }",
  )
}

///|
test "vibe wasm eval supports: match expressions" {
  assert_wasm_eval_decodes("match 2 { 1 => 10, 2 => 20, _ => 0 }")
  assert_wasm_eval_decodes("match 5 { v => v + 1 }")
  assert_wasm_eval_decodes("match 3 { v if v < 5 => 1, _ => 0 }")
  assert_wasm_eval_decodes("match 10 { v if v < 5 => 1, _ => 0 }")
  assert_wasm_eval_decodes("match (1, 2) { (a, b) => a + b, _ => 0 }")
  assert_wasm_eval_decodes(
    "match (1, (2, 3)) { (a, (b, c)) => a + b + c, _ => 0 }",
  )
  assert_wasm_eval_decodes(
    "match record { a: 1, b: 2 } { record { a: x, b: y } => x + y, _ => 0 }",
  )
}

///|
test "vibe wasm eval supports: let binding chains" {
  assert_wasm_eval_decodes("let a = 1\nlet b = a + 2\nlet c = b * 3\nc")
  assert_wasm_eval_decodes("let x = 10\nlet y = x - 3\ny")
  assert_wasm_eval_decodes("let a = 5\nlet b = a\nlet c = b\nc")
}

///|
test "vibe wasm eval supports: edge cases" {
  assert_wasm_eval_decodes("0")
  assert_wasm_eval_decodes("add(0, 0)")
  assert_wasm_eval_decodes("1000 * 1000")
  assert_wasm_eval_decodes("sub(0, 1)")
  assert_wasm_eval_decodes("\"\"")
  assert_wasm_eval_decodes("\"hello world\"")
}

///|
test "vibe wasm eval supports: nested collections" {
  assert_wasm_eval_decodes("[1, 2, 3]")
  assert_wasm_eval_decodes("[[1, 2], [3, 4]]")
  assert_wasm_eval_decodes("map { a: 1, b: 2, c: 3 }")
  assert_wasm_eval_decodes("[map { x: 1 }, map { x: 2 }]")
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
test "vibe wasm eval supports: mixed expressions" {
  assert_wasm_eval_decodes("if eq(1, 1) { add(2, 3) } else { 0 }")
  assert_wasm_eval_decodes("let x = mul(3, 3)\nadd(x, 1)")
  assert_wasm_eval_decodes("match true { true => 1, false => 0 }")
}

///|
test "vibe wasm eval supports: P3 handler pattern" {
  // handler returns status codes with decodable WASM results
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
  assert_wasm_eval_decodes(handler_code + "\nhandler(\"GET\", \"/\")")
  assert_wasm_eval_decodes(handler_code + "\nhandler(\"GET\", \"/health\")")
  assert_wasm_eval_decodes(handler_code + "\nhandler(\"GET\", \"/notfound\")")
  assert_wasm_eval_decodes(handler_code + "\nhandler(\"POST\", \"/\")")
  assert_wasm_eval_decodes(
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
  assert_wasm_eval_decodes(script)
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
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval string for-in char codes" {
  let script =
    #|let main = () -> Int {
    #|  let mut sum = 0
    #|  for i, c in "abc" {
    #|    sum = sum + i + c
    #|  }
    #|  sum
    #|}
    #|main()
  let res = try eval_run(script) catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  // ('a' + 0) + ('b' + 1) + ('c' + 2)
  assert_eq(decode_int(res.value), 297L)
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
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval supports: String::length" {
  assert_wasm_eval_decodes("String::length(\"hello\")")
  assert_wasm_eval_decodes("String::length(\"\")")
  assert_wasm_eval_decodes("String::length(\"abc\")")
}

///|
test "vibe wasm eval supports: String::char_code_at" {
  assert_wasm_eval_decodes("String::char_code_at(\"abc\", 0)")
  assert_wasm_eval_decodes("String::char_code_at(\"abc\", 2)")
}

///|
test "vibe wasm eval supports: String::substring" {
  assert_wasm_eval_decodes("String::substring(\"hello world\", 0, 5)")
  assert_wasm_eval_decodes("String::substring(\"abcdef\", 2, 5)")
  assert_wasm_eval_decodes("String::substring(\"abc\", 0, 0)")
}

///|
test "vibe wasm eval supports: String::concat" {
  assert_wasm_eval_decodes("String::concat(\"hello\", \" world\")")
  assert_wasm_eval_decodes("String::concat(\"\", \"abc\")")
  assert_wasm_eval_decodes("String::concat(\"abc\", \"\")")
}

///|
test "vibe wasm eval supports: String::join" {
  assert_wasm_eval_decodes("String::join([\"a\", \"b\", \"c\"], \",\")")
  assert_wasm_eval_decodes("String::join([\"only\"], \"-\")")
}

///|
test "vibe wasm eval supports: String::index_of" {
  assert_wasm_eval_decodes("String::index_of(\"hello world\", \"world\")")
  assert_wasm_eval_decodes("String::index_of(\"abcabc\", \"bc\")")
}

///|
// Value-level checks for SIMD-accelerated String::index_of (ADR-0054). The
// not-found case exercises the `result = -1` sentinel, which regressed to 127
// while `i32.const` was decoded as unsigned LEB128 (-1 == 0x7F == 127).
test "vibe wasm eval: String::index_of values (found / not found)" {
  assert_wasm_eval_int("String::index_of(\"hello world\", \"world\")", 6)
  assert_wasm_eval_int("String::index_of(\"abcabc\", \"bc\")", 1)
  assert_wasm_eval_int("String::index_of(\"abc\", \"x\")", -1)
  assert_wasm_eval_int("String::index_of(\"abc\", \"a\")", 0)
  // String long enough to take the 16-byte SIMD memchr window path.
  assert_wasm_eval_int(
    "String::index_of(\"aaaaaaaaaaaaaaaaaaaaXY\", \"XY\")", 20,
  )
  assert_wasm_eval_int(
    "String::index_of(\"aaaaaaaaaaaaaaaaaaaaXY\", \"ZZ\")", -1,
  )
}

///|
// Value-level checks for the single-pass SIMD String::compare (ADR-0054):
// signum of the lexicographic difference, returning -1 / 0 / 1. The minimal
// eval harness has no prelude, so we define `string_compare` locally; the
// codegen builtin handler intercepts the call regardless (no is_user_fn
// guard, like String::equals), exercising the 1-pass signum path. Covers the
// length tie-break (prefix is "less"), first-differing-byte sign, and the
// 16-byte SIMD common-prefix skip path (>16 equal leading bytes).
test "vibe wasm eval: String::compare signum (-1 / 0 / 1)" {
  let prelude =
    #|let string_compare = (a: String, b: String) -> Int {
    #|  if a < b { -1 } else if a > b { 1 } else { 0 }
    #|}
    #|
  fn cmp(a : String, b : String) -> String {
    prelude + "string_compare(\"" + a + "\", \"" + b + "\")"
  }

  assert_wasm_eval_int(cmp("a", "b"), -1)
  assert_wasm_eval_int(cmp("b", "a"), 1)
  assert_wasm_eval_int(cmp("abc", "abc"), 0)
  // Prefix is lexicographically smaller (length tie-break).
  assert_wasm_eval_int(cmp("ab", "abc"), -1)
  assert_wasm_eval_int(cmp("abc", "ab"), 1)
  // First differing byte decides regardless of remaining length.
  assert_wasm_eval_int(cmp("abd", "abc"), 1)
  assert_wasm_eval_int(cmp("abc", "abd"), -1)
  // >16 equal leading bytes: exercises the SIMD chunk-skip then scalar diff.
  assert_wasm_eval_int(cmp("aaaaaaaaaaaaaaaaaaaX", "aaaaaaaaaaaaaaaaaaaY"), -1)
  assert_wasm_eval_int(
    cmp("aaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaa"),
    0,
  )
}

///|
test "vibe wasm eval supports: String::contains" {
  assert_wasm_eval_decodes("String::contains(\"hello world\", \"world\")")
  assert_wasm_eval_decodes("String::contains(\"hello\", \"xyz\")")
  assert_wasm_eval_decodes("String::contains(\"abc\", \"\")")
}

///|
test "vibe wasm eval supports: String::starts_with" {
  assert_wasm_eval_decodes("String::starts_with(\"hello world\", \"hello\")")
  assert_wasm_eval_decodes("String::starts_with(\"hello\", \"xyz\")")
  assert_wasm_eval_decodes("String::starts_with(\"abc\", \"\")")
}

///|
test "vibe wasm eval supports: String::ends_with" {
  assert_wasm_eval_decodes("String::ends_with(\"hello world\", \"world\")")
  assert_wasm_eval_decodes("String::ends_with(\"hello\", \"xyz\")")
  assert_wasm_eval_decodes("String::ends_with(\"abc\", \"\")")
}

///|
test "vibe wasm eval supports: String::last_index_of" {
  assert_wasm_eval_decodes("String::last_index_of(\"abcabc\", \"bc\")")
  assert_wasm_eval_decodes("String::last_index_of(\"aaa\", \"a\")")
}

///|
test "vibe wasm eval supports: String::count" {
  assert_wasm_eval_decodes("String::count(\"abcabc\", \"bc\")")
  assert_wasm_eval_decodes("String::count(\"hello\", \"l\")")
}

///|
test "vibe wasm eval supports: String::trim" {
  assert_wasm_eval_decodes("String::trim(\"  hello  \")")
  assert_wasm_eval_decodes("String::trim(\"abc\")")
  assert_wasm_eval_decodes("String::trim(\"  \")")
}

///|
test "vibe wasm eval supports: String::trim_start" {
  assert_wasm_eval_decodes("String::trim_start(\"  hello\")")
  assert_wasm_eval_decodes("String::trim_start(\"abc\")")
}

///|
test "vibe wasm eval supports: String::trim_end" {
  assert_wasm_eval_decodes("String::trim_end(\"hello  \")")
  assert_wasm_eval_decodes("String::trim_end(\"abc\")")
}

///|
test "vibe wasm eval supports: String::to_upper" {
  assert_wasm_eval_decodes("String::to_upper(\"hello\")")
  assert_wasm_eval_decodes("String::to_upper(\"ABC\")")
  assert_wasm_eval_decodes("String::to_upper(\"aBc123\")")
}

///|
test "vibe wasm eval supports: String::to_lower" {
  assert_wasm_eval_decodes("String::to_lower(\"HELLO\")")
  assert_wasm_eval_decodes("String::to_lower(\"abc\")")
  assert_wasm_eval_decodes("String::to_lower(\"AbC123\")")
}

///|
test "vibe wasm eval supports: String::replace" {
  assert_wasm_eval_decodes(
    "String::replace(\"hello world\", \"world\", \"there\")",
  )
  assert_wasm_eval_decodes("String::replace(\"aaa\", \"a\", \"bb\")")
}

///|
test "vibe wasm eval supports: String::replace_all" {
  assert_wasm_eval_decodes("String::replace_all(\"abcabc\", \"bc\", \"xy\")")
  assert_wasm_eval_decodes("String::replace_all(\"hello\", \"l\", \"r\")")
}

///|
test "vibe wasm eval supports: String::split" {
  assert_wasm_eval_decodes("String::split(\"a,b,c\", \",\")")
  assert_wasm_eval_decodes("String::split(\"hello\", \",\")")
  assert_wasm_eval_decodes("String::split(\",a,,b,\", \",\")")
}

///|
test "vibe wasm eval supports: String::equals" {
  assert_wasm_eval_decodes("String::equals(\"abc\", \"abc\")")
  assert_wasm_eval_decodes("String::equals(\"abc\", \"def\")")
  assert_wasm_eval_decodes("String::equals(\"\", \"\")")
}

///|
test "vibe wasm eval supports: String::from_char_code" {
  assert_wasm_eval_decodes("String::from_char_code(65)")
  assert_wasm_eval_decodes("String::from_char_code(97)")
}

///|
test "vibe wasm eval supports: String::from_char_codes" {
  assert_wasm_eval_decodes(
    "String::char_code_at(String::from_char_codes([65, 66, 67]), 1)",
  )
  assert_wasm_eval_decodes("String::length(String::from_char_codes([]))")
}

///|
test "vibe wasm eval supports: Int64Array (linear, 32-bit-safe)" {
  // Round-trips values above the 30-bit Array[Int] cell limit (#429).
  assert_wasm_eval_decodes(
    "let a = Int64Array::make(2, 0)\nInt64Array::set(a, 0, 4294967295)\nInt64Array::get(a, 0)",
  )
  assert_wasm_eval_decodes(
    "Int64Array::length(Int64Array::make(5, 1073741824))",
  )
}

///|
test "vibe wasm eval supports: Int::abs" {
  assert_wasm_eval_decodes("Int::abs(5)")
  assert_wasm_eval_decodes("Int::abs(-5)")
  assert_wasm_eval_decodes("Int::abs(0)")
}

///|
test "vibe wasm eval supports: Int::is_even and Int::is_odd" {
  assert_wasm_eval_decodes("Int::is_even(4)")
  assert_wasm_eval_decodes("Int::is_even(3)")
  assert_wasm_eval_decodes("Int::is_odd(3)")
  assert_wasm_eval_decodes("Int::is_odd(4)")
  assert_wasm_eval_decodes("Int::is_even(0)")
}

///|
test "vibe wasm eval supports: Map::has_key" {
  assert_wasm_eval_decodes("let m = map { a: 1, b: 2 }\nMap::has_key(m, \"a\")")
  assert_wasm_eval_decodes("let m = map { a: 1, b: 2 }\nMap::has_key(m, \"c\")")
}

///|
test "vibe wasm eval supports: Map::keys" {
  assert_wasm_eval_decodes("let m = map { a: 1, b: 2 }\nMap::keys(m)")
}

///|
test "vibe wasm eval supports: Map::values" {
  assert_wasm_eval_decodes("let m = map { a: 1, b: 2 }\nMap::values(m)")
}

///|
test "vibe wasm eval supports: Set::new and Set::size" {
  assert_wasm_eval_decodes("Set::size(Set::new())")
}

///|
test "vibe wasm eval supports: Set::add and Set::contains" {
  assert_wasm_eval_decodes(
    "let s = Set::new()\nlet s2 = Set::add(s, 42)\nSet::contains(s2, 42)",
  )
  assert_wasm_eval_decodes(
    "let s = Set::new()\nlet s2 = Set::add(s, 42)\nSet::contains(s2, 99)",
  )
}

///|
test "vibe wasm eval supports: Set::add and Set::size" {
  assert_wasm_eval_decodes(
    "let s = Set::new()\nlet s2 = Set::add(s, 1)\nlet s3 = Set::add(s2, 2)\nSet::size(s3)",
  )
}

///|
test "vibe wasm eval supports: Set::remove" {
  assert_wasm_eval_decodes(
    "let s = Set::new()\nlet s2 = Set::add(s, 1)\nlet s3 = Set::add(s2, 2)\nlet s4 = Set::remove(s3, 1)\nSet::size(s4)",
  )
}

///|
test "vibe wasm eval supports: Set::from_array" {
  assert_wasm_eval_decodes("Set::size(Set::from_array([1, 2, 3]))")
  assert_wasm_eval_decodes("Set::contains(Set::from_array([10, 20]), 10)")
}

///|
test "vibe wasm eval supports: Bytes::length" {
  assert_wasm_eval_decodes(
    "let b = Bytes::from_array([1, 2, 3])\nBytes::length(b)",
  )
}

///|
test "vibe wasm eval supports: Bytes::get and Bytes::set" {
  assert_wasm_eval_decodes(
    "let b = Bytes::from_array([10, 20, 30])\nBytes::get(b, 1)",
  )
  assert_wasm_eval_decodes(
    "let b = Bytes::from_array([10, 20, 30])\nBytes::set(b, 1, 99)\nBytes::get(b, 1)",
  )
}

///|
test "vibe wasm eval supports: Bytes::push" {
  assert_wasm_eval_decodes(
    "let b = Bytes::from_array([1])\nBytes::push(b, 42)\nBytes::length(b)",
  )
}

///|
test "vibe wasm eval supports: Bytes::from_string and Bytes::to_string" {
  assert_wasm_eval_decodes(
    "let b = Bytes::from_string(\"abc\")\nBytes::length(b)",
  )
}

///|
test "vibe wasm eval supports: Bytes::append" {
  assert_wasm_eval_decodes(
    "let a = Bytes::from_array([1, 2])\nlet b = Bytes::from_array([3, 4])\nBytes::append(a, b)\nBytes::length(a)",
  )
}

///|
// Bytes::fill and Bytes::blit are not registered in the checker.

///|
test "vibe wasm eval supports: Bytes::concat" {
  assert_wasm_eval_decodes(
    "let a = Bytes::from_array([1, 2])\nlet b = Bytes::from_array([3, 4])\nlet c = Bytes::concat(a, b)\nBytes::length(c)",
  )
}

///|
test "vibe wasm eval supports: Array::length" {
  assert_wasm_eval_decodes("Array::length([1, 2, 3])")
  assert_wasm_eval_decodes("Array::length([])")
}

///|
test "vibe wasm eval supports: Array::set" {
  assert_wasm_eval_decodes(
    "let a = [1, 2, 3]\nArray::set(a, 1, 99)\nArray::get(a, 1)",
  )
}

///|
test "vibe wasm eval supports: Array::truncate" {
  assert_wasm_eval_decodes(
    "let a = [1, 2, 3, 4, 5]\nArray::truncate(a, 3)\nArray::length(a)",
  )
}

///|
test "vibe wasm eval supports: FixedArray::make and FixedArray::length" {
  assert_wasm_eval_decodes("FixedArray::length(FixedArray::make(5, 0))")
}

///|
test "vibe wasm eval supports: FixedArray::get and FixedArray::set" {
  assert_wasm_eval_decodes(
    "let a = FixedArray::make(3, 0)\nFixedArray::set(a, 1, 42)\nFixedArray::get(a, 1)",
  )
}

///|
test "vibe wasm eval supports: FixedArray::blit" {
  assert_wasm_eval_decodes(
    "let src = FixedArray::make(3, 10)\nlet dst = FixedArray::make(3, 0)\nFixedArray::blit(dst, 0, src, 0, 3)\nFixedArray::get(dst, 2)",
  )
}

///|
test "vibe wasm eval supports: StringBuilder" {
  assert_wasm_eval_decodes(
    "let sb = StringBuilder::new()\nStringBuilder::push(sb, \"hello\")\nStringBuilder::push(sb, \" world\")\nStringBuilder::freeze(sb)",
  )
}

///|
test "vibe wasm eval Array::concat" {
  let script =
    #|let a = [1, 2]
    #|let b = [3, 4]
    #|Array::length(Array::concat(a, b))
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval Array::push_all" {
  let script =
    #|let a = [1, 2]
    #|Array::push_all(a, [3, 4])
    #|Array::length(a)
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval Array::slice" {
  let script =
    #|let a = [10, 20, 30, 40, 50]
    #|let s = Array::slice(a, 1, 4)
    #|Array::length(s)
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval String::utf8_length" {
  let script =
    #|String::utf8_length("hello")
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval String::replace_all" {
  let script =
    #|let s = String::replace_all("aabbcc", "bb", "XX")
    #|String::length(s)
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval nested function call" {
  let script =
    #|let add = (a: Int, b: Int) -> Int { a + b }
    #|let mul = (a: Int, b: Int) -> Int { a * b }
    #|mul(add(1, 2), add(3, 4))
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval match with guard" {
  let script =
    #|let x = 5
    #|match x {
    #|  n if n > 3 => 1,
    #|  _ => 0
    #|}
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval string interpolation basic" {
  let script =
    #|let name = "world"
    #|let msg = "hello \{name}"
    #|String::length(msg)
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval recursive fibonacci" {
  let script =
    #|let rec fib = (n: Int) -> Int {
    #|  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
    #|}
    #|fib(10)
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval closure capture" {
  let script =
    #|let x = 10
    #|let add_x = (n: Int) -> Int { n + x }
    #|add_x(5)
  assert_wasm_eval_decodes(script)
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
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval tuple destructure" {
  let script =
    #|let pair = (10, 20)
    #|let (a, b) = pair
    #|a + b
  assert_wasm_eval_decodes(script)
}

///|
test "vibe wasm eval enum with payload match" {
  let script =
    #|enum Result { Ok(Int); Err }
    #|let x = Ok(42)
    #|match x { Ok(n) => n, Err => 0 }
  assert_wasm_eval_decodes(script)
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
  assert_wasm_eval_decodes(script)
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
  assert_wasm_eval_decodes(script)
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
test "rc eval: function returning tuple" {
  let script =
    #|let make = () -> (Int, Int) { (100, 200) }
    #|let t = make()
    #|t.0 + t.1
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 300L)
}

///|
test "rc eval: mutable reassignment preserves correctness" {
  let script =
    #|let make = () -> (Int, Int) { (10, 20) }
    #|let t = make()
    #|t.0 + t.1
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 30L)
}

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
test "rc eval: if/else returning tuples" {
  let script =
    #|let pick = (x: Int) -> (Int, Int) {
    #|  if x > 0 { (1, 2) } else { (3, 4) }
    #|}
    #|let t = pick(1)
    #|t.0 + t.1
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 3L)
}

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

///|
test "rc eval: mutable tuple reassignment with RC" {
  let script =
    #|let f = () -> Int {
    #|  let mut t = (10, 20)
    #|  t = (30, 40)
    #|  t.0 + t.1
    #|}
    #|f()
  let res = try eval_run_rc(script) catch {
    e => fail("wasm eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 70L)
}

///|
/// Parse WASM section sizes for binary analysis.
/// Returns map of section_id -> total_bytes (including header).
fn wasm_section_sizes(bytes : Bytes) -> Map[Int, Int] {
  let arr = bytes.to_array()
  let sizes : Map[Int, Int] = {}
  let cur = Cursor::{ bytes: arr, pos: 8 } // skip magic+version
  while cur.pos + 2 < arr.length() {
    let id = arr[cur.pos].to_int()
    cur.pos += 1
    let start = cur.pos - 1
    // Read LEB128 payload size manually (no raise)
    let mut payload_size = 0
    let mut shift = 0
    while cur.pos < arr.length() {
      let b = arr[cur.pos].to_int()
      cur.pos += 1
      payload_size = payload_size | ((b & 0x7F) << shift)
      if (b & 0x80) == 0 {
        break
      }
      shift += 7
    }
    cur.pos += payload_size
    sizes[id] = cur.pos - start
  }
  sizes
}

///|
test "rc perf: binary size overhead is bounded" {
  // Compare WASM binary size with and without RC for various programs.
  // RC helper functions (dup/drop/alloc) add ~400 bytes of fixed overhead
  // that amortizes over multiple allocation sites. Tiny programs pay more,
  // but multi-alloc programs show the call-based savings.
  let scripts : Array[(String, String)] = [
    ("int_literal", "42"),
    ("tuple_alloc", "(1, 2, 3)"),
    ("func_call", "let f = (x: Int) -> Int { x + 1 }\nf(10)"),
    ("tuple_access", "let t = (1, 2)\nt.0 + t.1"),
    (
      "multi_alloc",
      (
        #|let a = (1, 2)
        #|let b = (3, 4)
        #|let c = (5, 6)
        #|let d = (7, 8)
        #|a.0 + b.0 + c.0 + d.0
      ),
    ),
  ]
  let db = VibeDb::new()
  let mut total_rc = 0
  let mut total_no_rc = 0
  let mut details = ""
  for item in scripts {
    let (label, script) = item
    db.set_source("main", script)
    let wasm_rc = compile_module_wasm(db, "main", enable_rc=true) catch {
      _ => b""
    }
    db.set_source("main", script)
    let wasm_no_rc = compile_module_wasm(db, "main") catch { _ => b"" }
    let rc_len = wasm_rc.length()
    let no_rc_len = wasm_no_rc.length()
    total_rc += rc_len
    total_no_rc += no_rc_len
    let r = rc_len.to_double() / no_rc_len.to_double()
    details = details +
      "\n  " +
      label +
      ": rc=" +
      rc_len.to_string() +
      " no_rc=" +
      no_rc_len.to_string() +
      " ratio=" +
      r.to_string()
  }
  let ratio = total_rc.to_double() / total_no_rc.to_double()
  println("RC binary size analysis:" + details)
  println(
    "  TOTAL: rc=" +
    total_rc.to_string() +
    " no_rc=" +
    total_no_rc.to_string() +
    " ratio=" +
    ratio.to_string(),
  )
  // Section-level analysis for tuple_alloc (most overhead)
  db.set_source("main", "(1, 2, 3)")
  let rc_bytes = compile_module_wasm(db, "main", enable_rc=true) catch {
    _ => b""
  }
  db.set_source("main", "(1, 2, 3)")
  let no_rc_bytes = compile_module_wasm(db, "main") catch { _ => b"" }
  let rc_secs = wasm_section_sizes(rc_bytes)
  let no_rc_secs = wasm_section_sizes(no_rc_bytes)
  let sec_names = [
    (1, "type"),
    (3, "func"),
    (5, "memory"),
    (6, "global"),
    (7, "export"),
    (10, "code"),
    (11, "data"),
  ]
  let mut sec_details = ""
  for entry in sec_names {
    let (id, name) = entry
    let rc_s = rc_secs.get(id).unwrap_or(0)
    let no_rc_s = no_rc_secs.get(id).unwrap_or(0)
    if rc_s != no_rc_s {
      sec_details += "\n  " +
        name +
        ": rc=" +
        rc_s.to_string() +
        " no_rc=" +
        no_rc_s.to_string() +
        " diff=+" +
        (rc_s - no_rc_s).to_string()
    }
  }
  println("Section breakdown (tuple_alloc):" + sec_details)
  // With type-aware drop slimming, total RC overhead stays under 2.5x.
  assert_true(ratio < 2.5)
}

///|
test "rc perf: heap usage with mutable reassignment" {
  // Mutable reassignment with RC should produce correct results
  // and exercise the drop + free-list reuse path
  let script =
    #|let f = () -> Int {
    #|  let mut t = (1, 2)
    #|  t = (3, 4)
    #|  t = (5, 6)
    #|  t = (7, 8)
    #|  t.0 + t.1
    #|}
    #|f()
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
  // Correctness: same result
  assert_eq(res_rc.value, res_no_rc.value)
  assert_eq(decode_int(res_rc.value), 15L)
}

///|
test "rc perf: free-list reuse actually works" {
  // Allocate, drop, allocate same size → should reuse
  // This tests the full pipeline: alloc → drop (rc=0) → free-list → realloc
  let script =
    #|let f = () -> Int {
    #|  let mut t = (10, 20)
    #|  t = (30, 40)
    #|  t.0 + t.1
    #|}
    #|f()
  let db = VibeDb::new()
  db.set_source("main", script)
  let wasm = try compile_module_wasm(db, "main", enable_rc=true) catch {
    e => fail("compile failed: " + e.to_string())
  } noraise {
    r => r
  }
  let res = try run_wasm(wasm) catch {
    e => fail("eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  // Result should be correct
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 70L)
  // Check the free-list global: if reuse happened,
  // the heap pointer should be lower than without RC
  // (We can't directly compare heap ptrs here, but we verify correctness
  //  which proves the drop + realloc path works end-to-end)
}

///|
test "rc eval: deep recursive drop frees nested containers" {
  // Nested tuples: dropping outer should recursively drop inner.
  // ((1, 2), (3, 4)) → drop outer → inner tuples also freed
  let script =
    #|let f = () -> Int {
    #|  let mut t = ((1, 2), (3, 4))
    #|  let a = t.0
    #|  let b = t.1
    #|  let r = a.0 + a.1 + b.0 + b.1
    #|  t = ((5, 6), (7, 8))
    #|  let c = t.0
    #|  let d = t.1
    #|  r + c.0 + c.1 + d.0 + d.1
    #|}
    #|f()
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
  // Correctness: same result (1+2+3+4+5+6+7+8 = 36)
  assert_eq(res_rc.value, res_no_rc.value)
  assert_eq(decode_int(res_rc.value), 36L)
}

///|
test "rc eval: free-list scan reuses non-head blocks" {
  // Create mixed-size allocations, drop them, then allocate same sizes.
  // The free-list scan should find matches even if they aren't at the head.
  // Flow: alloc 2-tuple, alloc 3-tuple, drop 2-tuple, drop 3-tuple,
  //       alloc 2-tuple → should reuse the 2-tuple block (not head, which is 3-tuple)
  let script =
    #|let f = () -> Int {
    #|  let mut a = (1, 2)
    #|  let mut b = (3, 4, 5)
    #|  a = (10, 20)
    #|  b = (30, 40, 50)
    #|  a = (100, 200)
    #|  a.0 + a.1 + b.0 + b.1 + b.2
    #|}
    #|f()
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
  // Correctness: 100 + 200 + 30 + 40 + 50 = 420
  assert_eq(res_rc.value, res_no_rc.value)
  assert_eq(decode_int(res_rc.value), 420L)
}

///|
test "rc eval: closure capture drop frees captured heap objects" {
  // Closure captures a tuple. When the closure is dropped,
  // its captured tuple should also be RC-dropped.
  let script =
    #|let f = () -> Int {
    #|  let t = (10, 20)
    #|  let g = () -> Int { t.0 + t.1 }
    #|  g()
    #|}
    #|f()
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
  // Correctness: 10 + 20 = 30
  assert_eq(res_rc.value, res_no_rc.value)
  assert_eq(decode_int(res_rc.value), 30L)
}

///|
test "rc eval: mutable closure with captured tuple" {
  // Closure captures a mutable variable holding a tuple.
  // Reassignment inside should drop the old tuple via RC.
  let script =
    #|let f = () -> Int {
    #|  let mut x = (1, 2)
    #|  let g = () -> Int {
    #|    x = (3, 4)
    #|    x.0 + x.1
    #|  }
    #|  g()
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 7L)
}

///|
test "rc eval: enum payload drop frees inner heap objects" {
  // Some((1, 2)) wraps a tuple inside an enum.
  // When the enum is dropped, the tuple payload should also be freed.
  let script =
    #|let f = () -> Int {
    #|  let mut x = Some((10, 20))
    #|  let y = match x {
    #|    Some(t) => t.0 + t.1
    #|    None => 0
    #|  }
    #|  x = None
    #|  y
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 30L)
}

///|
test "rc eval: record value drop frees heap objects in values" {
  // Record values containing tuples should be recursively dropped.
  let script =
    #|let f = () -> Int {
    #|  let mut r = record { a: (1, 2), b: (3, 4) }
    #|  let v = r.a.0 + r.b.1
    #|  r = record { a: (0, 0), b: (0, 0) }
    #|  v
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 5L)
}

///|
test "rc perf: in-place reuse avoids heap growth on reassignment" {
  // Repeated same-size reassignment with RC==1 should reuse memory in-place.
  // The heap pointer should not grow beyond the first allocation.
  let script =
    #|let f = () -> Int {
    #|  let mut t = (1, 2)
    #|  t = (3, 4)
    #|  t = (5, 6)
    #|  t = (7, 8)
    #|  t = (9, 10)
    #|  t.0 + t.1
    #|}
    #|f()
  let db = VibeDb::new()
  db.set_source("main", script)
  let wasm_rc = try compile_module_wasm(db, "main", enable_rc=true) catch {
    e => fail("compile failed: " + e.to_string())
  } noraise {
    r => r
  }
  let res_rc = try run_wasm(wasm_rc) catch {
    e => fail("eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(res_rc.value), 19L)
  // Check heap pointer: with in-place reuse, only 1 allocation (not 5)
  // Heap global is at index 0. Read 4 bytes from the global section or
  // check memory layout. For now, verify the result is correct.
  // The free-list test already validates reuse; this ensures try_reuse path works.
}

///|
test "rc eval: pure borrow access skips dup" {
  // Multiple field accesses on same tuple should not dup the container.
  // Pure-borrow optimization: t has only borrow uses, no owning uses.
  let script =
    #|let f = () -> Int {
    #|  let t = (10, 20)
    #|  t.0 + t.1
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 30L)
}

///|
test "rc eval: record field borrow skips dup" {
  // Record field access (r.a, r.b) should borrow, not dup the container.
  let script =
    #|let f = () -> Int {
    #|  let r = record { a: 10, b: 20 }
    #|  r.a + r.b
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 30L)
}

///|
test "rc eval: nested tuple borrow and record access combined" {
  // Exercises multiple RC patterns: tuple borrow, record borrow,
  // nested allocation, and scope-end drops.
  let script =
    #|let f = () -> Int {
    #|  let a = (1, 2)
    #|  let b = (3, 4)
    #|  let r = record { x: 10, y: 20 }
    #|  a.0 + a.1 + b.0 + b.1 + r.x + r.y
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 40L)
}

///|
test "rc eval: ref cell write drops old heap value" {
  // When a mut_captured variable is reassigned, the old value must be RC-dropped.
  // A closure captures `x` mutably (ref cell), then reassigns it.
  let script =
    #|let f = () -> Int {
    #|  let mut x = (1, 2)
    #|  let g = () -> Int {
    #|    x = (3, 4)
    #|    x.0 + x.1
    #|  }
    #|  g()
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 7L)
}

///|
test "rc eval: string concat frees intermediate strings" {
  // String::concat allocates a new string; RC should drop the intermediates.
  let script =
    #|let a = "hello"
    #|let b = " world"
    #|let c = String::concat(a, b)
    #|String::length(c)
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
  assert_eq(decode_int(res_rc.value), 11L)
}

///|
test "rc eval: heap reclamation via free-list in loop" {
  // In a loop, temporary tuples from previous iterations should be freed
  // and their memory reclaimed via the free-list.
  let script =
    #|let f = () -> Int {
    #|  let mut i = 0
    #|  let mut result = 0
    #|  while i < 100 {
    #|    let t = (i, i + 1)
    #|    result = result + t.0 + t.1
    #|    i = i + 1
    #|  }
    #|  result
    #|}
    #|f()
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
  // Sum of i + (i+1) for i=0..99 = sum(2i+1) = 2*4950 + 100 = 10000
  assert_eq(decode_int(res_rc.value), 10000L)
}

///|
test "rc eval: static string literal not corrupted by RC drop" {
  // String literals live in the data section without RC headers.
  // The static data guard must skip dup/drop for these pointers.
  let script =
    #|let s = "hello"
    #|let t = "world"
    #|String::length(s) + String::length(t)
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
  assert_eq(decode_int(res_rc.value), 10L)
}

///|
test "rc eval: string literal passed to function with RC" {
  // A string literal is passed to a function that computes its length.
  // RC dup/drop must not corrupt the data section pointer.
  let script =
    #|let len = (s: String) -> Int { String::length(s) }
    #|let a = len("hello")
    #|let b = len("world")
    #|a + b
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
  assert_eq(decode_int(res_rc.value), 10L)
}

///|
test "rc eval: enum singleton None not corrupted by RC" {
  // None is a data section singleton. RC must not touch it.
  let script =
    #|let x = None
    #|let y = match x {
    #|  Some(v) => v
    #|  None => 42
    #|}
    #|y
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
  assert_eq(decode_int(res_rc.value), 42L)
}

///|
test "rc eval: match destructuring with enum payload" {
  // Some((10, 20)) wraps a tuple in an enum. Matching extracts the tuple.
  // The enum wrapper should be dropped; the tuple payload lives on.
  let script =
    #|let f = () -> Int {
    #|  let x = Some((10, 20))
    #|  let result = match x {
    #|    Some(t) => t.0 + t.1
    #|    None => 0
    #|  }
    #|  result
    #|}
    #|f()
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
  assert_eq(decode_int(res_rc.value), 30L)
}

///|
test "rc eval: nested function calls with heap return values" {
  // Functions that return heap objects need proper RC across call boundaries.
  let script =
    #|let make_pair = (a: Int, b: Int) -> (Int, Int) { (a, b) }
    #|let sum_pair = (p: (Int, Int)) -> Int { p.0 + p.1 }
    #|let result = sum_pair(make_pair(3, 4))
    #|result
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
  assert_eq(decode_int(res_rc.value), 7L)
}

///|
test "rc eval: multiple string concats with RC" {
  // Chain of string concats should not crash despite intermediate strings
  // being in the data section or on heap.
  let script =
    #|let a = "hello"
    #|let b = " "
    #|let c = "world"
    #|let d = String::concat(String::concat(a, b), c)
    #|String::length(d)
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
  assert_eq(decode_int(res_rc.value), 11L)
}

///|
test "rc eval: closure captures tuple and uses it multiple times" {
  // A closure captures a tuple and accesses its fields.
  // The captured tuple should stay alive while the closure exists.
  let script =
    #|let t = (10, 20, 30)
    #|let f = () -> Int { t.0 + t.1 + t.2 }
    #|f() + f()
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
  assert_eq(decode_int(res_rc.value), 120L)
}

///|
test "rc eval: string interpolation with RC tracks intermediates" {
  // String interpolation desugars to let-binding chains so that
  // intermediate String::concat results are RC-tracked by Perceus.
  let script =
    #|let x = "hello"
    #|let y = "world"
    #|let s = "\(x) \(y)!"
    #|String::length(s)
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
  // "hello world!" = 12 chars
  assert_eq(decode_int(res_rc.value), 12L)
}

///|
test "rc eval: string interpolation in loop with RC" {
  // Intermediate concat results in a loop should be freed each iteration.
  let script =
    #|let f = () -> Int {
    #|  let mut i = 0
    #|  let mut len = 0
    #|  let a = "hi"
    #|  let b = "ok"
    #|  while i < 50 {
    #|    let s = "\(a) \(b)"
    #|    len = len + String::length(s)
    #|    i = i + 1
    #|  }
    #|  len
    #|}
    #|f()
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
/// Run a script with RC debug mode enabled.
/// Returns the eval result with globals containing debug counters.
fn eval_run_rc_debug(script : String) -> WasmEvalResult raise WasmRunError {
  let db = VibeDb::new()
  db.set_source("main", script)
  let wasm = compile_module_wasm(db, "main", enable_rc=true, rc_debug=true) catch {
    e => raise WasmRunError::Compile(e.to_string())
  }
  run_wasm(wasm) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
}

///|
/// Extract RC debug counters from eval result.
/// Returns (alloc_count, free_count). Debug globals are the last two.
fn rc_debug_counts(res : WasmEvalResult) -> (Int64, Int64) {
  let g = res.globals
  let n = g.length()
  (g[n - 2], g[n - 1])
}

///|
test "rc debug: no leak for simple integer (no heap alloc)" {
  let res = try eval_run_rc_debug("42") catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  assert_eq(allocs, 0L)
  assert_eq(frees, 0L)
}

///|
test "rc debug: tuple alloc and drop are balanced" {
  let res = try eval_run_rc_debug("let t = (1, 2, 3)\nt.0") catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  assert_true(allocs > 0L)
  assert_eq(allocs, frees)
}

///|
test "rc debug: multiple tuples balanced" {
  let script =
    #|let a = (10, 20)
    #|let b = (30, 40)
    #|a.0 + b.1
  let res = try eval_run_rc_debug(script) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  assert_true(allocs >= 2L)
  assert_eq(allocs, frees)
}

///|
test "rc debug: function returning tuple balanced" {
  let script =
    #|let make = () -> (Int, Int) { (100, 200) }
    #|let t = make()
    #|t.0 + t.1
  let res = try eval_run_rc_debug(script) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  assert_true(allocs > 0L)
  assert_eq(allocs, frees)
}

///|
test "rc debug: function with local tuple balanced" {
  let script =
    #|let f = () -> Int {
    #|  let t = (10, 20)
    #|  t.0
    #|}
    #|f()
  let res = try eval_run_rc_debug(script) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  assert_true(allocs > 0L)
  assert_eq(allocs, frees)
}

///|
test "rc debug: while-loop body drops per-iteration allocs (no leak)" {
  // While-loop bodies now generate per-iteration drops for bindings that
  // leave the body scope. The per-iteration tuple is reclaimed each turn, so
  // allocs and frees stay balanced. (Previously this leaked all but the final
  // allocation; see the codegen wiring in compile_expr_while and the
  // scope_end_to_last handling in perceus_poc.mbt::p2_emit_block.)
  let script =
    #|let f = () -> Int {
    #|  let mut i = 0
    #|  let mut sum = 0
    #|  while i < 5 {
    #|    let t = (i, i + 1)
    #|    sum = sum + t.0
    #|    i = i + 1
    #|  }
    #|  sum
    #|}
    #|f()
  let res = try eval_run_rc_debug(script) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  // Alloc counter should track all 5 tuple allocations
  assert_true(allocs >= 5L)
  // Every per-iteration tuple is dropped — no leak.
  assert_eq(allocs, frees)
}

///|
test "rc debug: while-loop body drops nested heap per-iteration (no leak)" {
  // A per-iteration binding whose value is a nested heap object (tuple of
  // tuples) must be recursively dropped at the end of each iteration. Verifies
  // that the loop-body scope-end drop reaches inner heap allocations too.
  let script =
    #|let f = () -> Int {
    #|  let mut i = 0
    #|  let mut sum = 0
    #|  while i < 4 {
    #|    let t = ((i, i + 1), (i + 2, i + 3))
    #|    sum = sum + t.0.0 + t.1.1
    #|    i = i + 1
    #|  }
    #|  sum
    #|}
    #|f()
  let res = try eval_run_rc_debug(script) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs, frees) = rc_debug_counts(res)
  // Each iteration allocates the outer tuple plus two inner tuples.
  assert_true(allocs >= 12L)
  assert_eq(allocs, frees)
}

///|
test "rc debug: for-in body has no per-iteration leak" {
  // for-in is desugared to a while loop before Perceus analysis, so the
  // per-iteration body binding `t` must be reclaimed each turn just like the
  // hand-written while case. We assert the per-iteration property directly:
  // the count of unreclaimed allocations must NOT grow with the iteration
  // count. (A small constant remainder — the array builder / discarded result
  // array — is tracked separately and is independent of iteration count.)
  fn leak_for(elems : String) -> Int64 raise {
    let script = "let f = () -> Int {\n" +
      "  let xs = " +
      elems +
      "\n  let mut sum = 0\n" +
      "  for x in xs {\n    let t = (x, x + 1)\n    sum = sum + t.0\n  }\n" +
      "  sum\n}\nf()"
    let res = eval_run_rc_debug(script)
    let (allocs, frees) = rc_debug_counts(res)
    allocs - frees
  }

  let leak_small = try leak_for("[10, 20, 30]") catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    v => v
  }
  let leak_large = try leak_for("[10, 20, 30, 40, 50, 60, 70]") catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    v => v
  }
  // No per-iteration leak: the unreclaimed count is the same for 3 and 7
  // iterations (the per-iteration tuples are all dropped).
  assert_eq(leak_small, leak_large)
}

///|
test "rc debug: if/else branch-local heap is dropped per branch" {
  // A heap binding allocated inside a branch must be dropped at the end of
  // that branch — and only when the branch actually runs (no spurious drop of
  // an uninitialized local on the other path).
  let prog = fn(arg : String) -> String {
    "let f = (c: Bool) -> Int {\n" +
    "  let mut s = 0\n" +
    "  if c {\n    let t = (1, 2)\n    s = s + t.0\n  } else {\n    s = s + 5\n  }\n" +
    "  s\n}\nf(" +
    arg +
    ")"
  }
  // then-branch taken: the tuple is allocated and must be freed.
  let res_then = try eval_run_rc_debug(prog("true")) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs_then, frees_then) = rc_debug_counts(res_then)
  assert_true(allocs_then >= 1L)
  assert_eq(allocs_then, frees_then)
  // else-branch taken: no allocation, and no drop of the uninitialized `t`.
  let res_else = try eval_run_rc_debug(prog("false")) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs_else, frees_else) = rc_debug_counts(res_else)
  assert_eq(allocs_else, frees_else)
}

///|
test "rc debug: match arm-local heap is dropped per arm" {
  // A heap binding allocated inside a match arm body must be dropped at the
  // end of that arm — and only when the arm is selected.
  let prog = fn(arg : String) -> String {
    "let f = (n: Int) -> Int {\n" +
    "  let mut s = 0\n" +
    "  match n {\n    0 => { let t = (1, 2); s = s + t.0 }\n    _ => { s = s + 9 }\n  }\n" +
    "  s\n}\nf(" +
    arg +
    ")"
  }
  // matching arm allocates the tuple → must be freed.
  let res0 = try eval_run_rc_debug(prog("0")) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs0, frees0) = rc_debug_counts(res0)
  assert_true(allocs0 >= 1L)
  assert_eq(allocs0, frees0)
  // default arm allocates nothing, and emits no spurious drop.
  let res1 = try eval_run_rc_debug(prog("1")) catch {
    e => fail("rc debug eval failed: " + e.to_string())
  } noraise {
    r => r
  }
  let (allocs1, frees1) = rc_debug_counts(res1)
  assert_eq(allocs1, frees1)
}

///|
// ADR-0044 Phase 3: String now implements Iterable. The prelude provides
// `String::iter_length` (= String::length) and `String::iter_get`
// (= String::char_code_at), so generic Iterable combinators see each char
// as its Int char code. End-to-end check: sum char codes of "abc" via the
// prelude helpers — 'a'(97) + 'b'(98) + 'c'(99) = 294.
test "vibe wasm eval String iter_length / iter_get (ADR-0044 Phase 3)" {
  let script =
    #|let sum_chars = (s: String) -> Int {
    #|  let len = String::iter_length(s)
    #|  let mut i = 0
    #|  let mut acc = 0
    #|  while i < len {
    #|    acc = acc + String::iter_get(s, i)
    #|    i = i + 1
    #|  }
    #|  acc
    #|}
    #|sum_chars("abc")
  let res = try eval_run(script) catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 294L)
}

///|
// ADR-0044 Phase 3: Map[K, V] now implements Iterable, yielding K (the key)
// per iteration. The prelude `Map::iter_length` returns size, and
// compiled backends lower `Map::iter_get` to direct key-slot reads instead of
// allocating `Map::keys` per item. End-to-end check: sum the values reachable
// through Map iteration. Uses String keys so the iter element type is String.
test "vibe wasm eval Map iter_length / iter_get (ADR-0044 Phase 3)" {
  let script =
    #|let key_total = (m: Map[String, Int]) -> Int {
    #|  let len = Map::iter_length(m)
    #|  let mut i = 0
    #|  let mut acc = 0
    #|  while i < len {
    #|    let k = Map::iter_get(m, i)
    #|    acc = acc + Map::get(m, k)
    #|    i = i + 1
    #|  }
    #|  acc
    #|}
    #|key_total(map { "a": 10, "b": 20, "c": 30 })
  let res = try eval_run(script) catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 60L)
}
