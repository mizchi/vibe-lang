///|
/// Tests for executing xsh-generated WASM
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
  value : Int
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
  ptr : Int,
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
let tag_mask = 3

///|
let tag_obj = 1

///|
let tag_int = 0

///|
let tag_bool = 3

///|
let obj_string = 1

///|
let obj_path = 2

///|
let obj_array = 5

///|
let obj_map = 6

///|
fn untag_ptr(ptr : Int) -> Int {
  ptr - (ptr & tag_mask)
}

///|
fn tag_of(ptr : Int) -> Int {
  ptr & tag_mask
}

///|
fn is_tagged_obj(ptr : Int) -> Bool {
  tag_of(ptr) == tag_obj
}

///|
fn is_tagged_int(ptr : Int) -> Bool {
  tag_of(ptr) == tag_int
}

///|
fn decode_int(ptr : Int) -> Int {
  ptr >> 2
}

///|
fn is_tagged_bool(ptr : Int) -> Bool {
  tag_of(ptr) == tag_bool
}

///|
fn decode_bool(ptr : Int) -> Bool {
  ptr >> 2 != 0
}

///|
fn object_type(mem : Array[Byte], ptr : Int) -> Int raise WasmEvalError {
  read_u32_le(mem, untag_ptr(ptr))
}

///|
fn object_len(mem : Array[Byte], ptr : Int) -> Int raise WasmEvalError {
  read_u32_le(mem, untag_ptr(ptr) + 4)
}

///|
fn is_tagged_string(mem : Array[Byte], ptr : Int) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_string
}

///|
fn is_tagged_path(mem : Array[Byte], ptr : Int) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_path
}

///|
fn is_tagged_array(mem : Array[Byte], ptr : Int) -> Bool raise WasmEvalError {
  is_tagged_obj(ptr) && object_type(mem, ptr) == obj_array
}

///|
fn is_tagged_map(mem : Array[Byte], ptr : Int) -> Bool raise WasmEvalError {
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
    if ty != 127 {
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
      65 | 32 | 33 | 34 | 16 => {
        let _ = code.read_leb_u32()
      }
      40 | 54 => {
        let _ = code.read_leb_u32()
        let _ = code.read_leb_u32()
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
      65 | 32 | 33 | 34 | 16 => {
        let _ = code.read_leb_u32()
      }
      40 | 54 => {
        let _ = code.read_leb_u32()
        let _ = code.read_leb_u32()
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
          if module_name == "xsh" && name == "sh" {
            sh_index = Some(import_index)
          } else if module_name == "xsh" && name == "path" {
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
  let locals : Array[Int] = Array::make(locals_total, 0)
  let stack : Array[Int] = []
  let outputs : Array[String] = []
  let mut if_depth = 0
  while true {
    let op = code.read_u8()
    match op {
      65 => {
        let v = code.read_leb_u32()
        stack.push(v)
      }
      106 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(a + b)
      }
      107 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(a - b)
      }
      70 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(if a == b { 1 } else { 0 })
      }
      72 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(if a < b { 1 } else { 0 })
      }
      114 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(a | b)
      }
      113 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(a & b)
      }
      115 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let b = stack[stack.length() - 1]
        let _ = stack.pop()
        let a = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(a ^ b)
      }
      116 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack[stack.length() - 1]
        let _ = stack.pop()
        let value = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(value << shift)
      }
      118 => {
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let shift = stack[stack.length() - 1]
        let _ = stack.pop()
        let value = stack[stack.length() - 1]
        let _ = stack.pop()
        stack.push(value >> shift)
      }
      40 => {
        let _ = code.read_leb_u32() // align
        let offset = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let addr = stack[stack.length() - 1]
        let _ = stack.pop()
        let value = read_u32_le(mem, addr + offset)
        stack.push(value)
      }
      54 => {
        let _ = code.read_leb_u32() // align
        let offset = code.read_leb_u32()
        if stack.length() < 2 {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let value = stack[stack.length() - 1]
        let _ = stack.pop()
        let addr = stack[stack.length() - 1]
        let _ = stack.pop()
        write_u32_le(mem, addr + offset, value)
      }
      32 => {
        let idx = code.read_leb_u32()
        if idx >= locals.length() {
          raise WasmEvalError::Invalid("local.get")
        }
        stack.push(locals[idx])
      }
      33 => {
        let idx = code.read_leb_u32()
        if idx >= locals.length() {
          raise WasmEvalError::Invalid("local.set")
        }
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let v = stack[stack.length() - 1]
        let _ = stack.pop()
        locals[idx] = v
      }
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
      16 => {
        let idx = code.read_leb_u32()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let ptr = stack[stack.length() - 1]
        let _ = stack.pop()
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
            stack.push(alloc.ptr | tag_obj)
          }
          _ =>
            match sh_index {
              Some(sidx) if idx == sidx => {
                let msg = read_string_object(mem, ptr)
                outputs.push(msg)
                stack.push(0)
              }
              _ => raise WasmEvalError::Unsupported("call")
            }
        }
      }
      26 => {
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let _ = stack.pop()
      }
      4 => {
        let _ = code.read_u8()
        if stack.is_empty() {
          raise WasmEvalError::Invalid("stack underflow")
        }
        let cond = stack[stack.length() - 1]
        let _ = stack.pop()
        if cond != 0 {
          if_depth += 1
        } else {
          let has_else = skip_to_else_or_end(code)
          if has_else {
            if_depth += 1
          }
        }
      }
      5 => {
        if if_depth == 0 {
          raise WasmEvalError::Invalid("unexpected else")
        }
        skip_to_end(code)
        if_depth -= 1
      }
      11 => if if_depth > 0 { if_depth -= 1 } else { break }
      _ => raise WasmEvalError::Unsupported("opcode")
    }
  }
  let value = if stack.is_empty() { 0 } else { stack[stack.length() - 1] }
  { value, outputs, mem }
}

///|
fn eval_run(script : String) -> WasmEvalResult raise WasmRunError {
  let db = XshDb::new()
  db.set_source("main", script)
  let wasm = compile_module_wasm(db, "main") catch {
    e => raise WasmRunError::Compile(e.to_string())
  }
  run_wasm(wasm) catch {
    e => raise WasmRunError::Eval(e.to_string())
  }
}

///|
test "xsh wasm eval returns value" {
  let res = try eval_run("let x = 1\nx") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 1)
}

///|
test "xsh wasm eval handles locals" {
  let res = try eval_run("let x = 1\nlet y = 2\ny") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 2)
}

///|
test "xsh wasm eval add/sub/eq/lt" {
  let add_res = try eval_run("add(1, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(add_res.value))
  assert_eq(decode_int(add_res.value), 3)
  let sub_res = try eval_run("sub(5, 2)") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(sub_res.value), 3)
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
test "xsh wasm eval returns tagged string" {
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
test "xsh wasm eval returns tagged bool" {
  let res = try eval_run("true") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_bool(res.value))
  assert_true(decode_bool(res.value))
}

///|
test "xsh wasm eval if expression" {
  let res_true = try eval_run("if true { 1 } else { 2 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res_true.value))
  assert_eq(decode_int(res_true.value), 1)
  let res_false = try eval_run("if false { 1 } else { 2 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res_false.value))
  assert_eq(decode_int(res_false.value), 2)
}

///|
test "xsh wasm eval if branches effects" {
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
test "xsh wasm eval block expression" {
  let res = try eval_run("{ let x = 4\n x }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 4)
}

///|
test "xsh wasm eval match expression" {
  let res = try eval_run("match 2 { 1 => 10, 2 => 20, _ => 0 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 20)
}

///|
test "xsh wasm eval match bind" {
  let res = try eval_run("match 3 { v => add(v, 1) }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 4)
}

///|
test "xsh wasm eval match tuple" {
  let res = try eval_run("match (1, 2) { (a, b) => add(a, b), _ => 0 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 3)
}

///|
test "xsh wasm eval match nested tuple" {
  let res = try
    eval_run("match (1, (2, 3)) { (a, (b, c)) => add(add(a, b), c), _ => 0 }")
  catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 6)
}

///|
test "xsh wasm eval match record" {
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
  assert_eq(decode_int(res.value), 3)
}

///|
test "xsh wasm eval match nested record" {
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
  assert_eq(decode_int(res.value), 5)
}

///|
test "xsh wasm eval array literal" {
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
  let v0 = read_u32_le(res.mem, base + 8)
  let v1 = read_u32_le(res.mem, base + 12)
  assert_true(is_tagged_int(v0))
  assert_true(is_tagged_int(v1))
  assert_eq(decode_int(v0), 1)
  assert_eq(decode_int(v1), 2)
}

///|
test "xsh wasm eval map literal" {
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
  let key_ptr = read_u32_le(res.mem, base + 8)
  let val = read_u32_le(res.mem, base + 12)
  let key = read_string_object(res.mem, key_ptr)
  assert_eq(key, "a")
  assert_true(is_tagged_int(val))
  assert_eq(decode_int(val), 1)
}

///|
test "xsh wasm eval match guard" {
  let res_false = try eval_run("match 2 { v if lt(v, 2) => 1, _ => 9 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(res_false.value), 9)
  let res_true = try eval_run("match 1 { v if lt(v, 2) => 1, _ => 9 }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_eq(decode_int(res_true.value), 1)
}

///|
test "xsh wasm eval bool ops" {
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
test "xsh wasm eval captures sh output" {
  let res = try eval_run("do { sh(\"hello\") }") catch {
    e => fail(e.to_string())
  } noraise {
    r => r
  }
  assert_true(is_tagged_int(res.value))
  assert_eq(decode_int(res.value), 0)
  assert_eq(res.outputs.length(), 1)
  assert_eq(res.outputs[0], "hello")
}

///|
test "xsh wasm eval normalizes path" {
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
