///|
struct GcFixtureSpec {
  opcode : String
  todo : Bool
  skip : Bool
}

///|
fn join_lines_gc(lines : Array[String]) -> String {
  let sb = StringBuilder::new()
  let mut first = true
  for line in lines {
    if first {
      first = false
    } else {
      sb.write_char('\n')
    }
    sb.write_string(line)
  }
  sb.to_string()
}

///|
fn sort_strings_gc(arr : Array[String]) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if arr[j].compare(arr[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = arr[i]
      arr[i] = arr[min_index]
      arr[min_index] = tmp
    }
  }
}

///|
fn split_fixture_gc(source : String, path : String) -> (String, String) raise {
  let script_lines : Array[String] = []
  let data_lines : Array[String] = []
  let mut in_data = false
  for line_view in source.split("\n") {
    let line = line_view.to_string()
    if line.trim().to_string() == "__DATA__" {
      in_data = true
      continue
    }
    if in_data {
      data_lines.push(line)
    } else {
      script_lines.push(line)
    }
  }
  if !in_data {
    fail("[\{path}] missing __DATA__ section")
  }
  (join_lines_gc(script_lines), join_lines_gc(data_lines))
}

///|
fn json_string_field_gc(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> String? raise {
  match obj.get(key) {
    Some(Json::String(value)) => Some(value)
    Some(Json::Null) => None
    Some(_) => fail("[\{path}] __DATA__.{key} must be a string")
    None => None
  }
}

///|
fn json_bool_field_gc(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Bool raise {
  match obj.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    Some(Json::Null) => false
    Some(_) => fail("[\{path}] __DATA__.{key} must be a boolean")
    None => false
  }
}

///|
fn parse_spec_gc(data : String, path : String) -> GcFixtureSpec raise {
  let json = @json.parse(data) catch {
    e => fail("[\{path}] invalid __DATA__ JSON: \{e.to_string()}")
  }
  match json {
    Json::Object(obj) => {
      let opcode = match json_string_field_gc(obj, "opcode", path) {
        Some(value) => value
        None => fail("[\{path}] __DATA__.opcode is required")
      }
      let todo = json_bool_field_gc(obj, "TODO", path) ||
        json_bool_field_gc(obj, "todo", path)
      let skip = json_bool_field_gc(obj, "skip", path)
      { opcode, todo, skip }
    }
    _ => fail("[\{path}] __DATA__ must be a JSON object")
  }
}

///|
fn opcode_bytes_gc(opcode : String) -> Array[Byte] raise {
  match opcode {
    "struct.new" => [0xfb, 0x00]
    "struct.get" => [0xfb, 0x02]
    "struct.get_s" => [0xfb, 0x02]
    "struct.get_u" => [0xfb, 0x03]
    "struct.set" => [0xfb, 0x05]
    _ => fail("unsupported opcode: " + opcode)
  }
}

///|
struct CursorGc {
  bytes : Bytes
  mut pos : Int
}

///|
fn CursorGc::new(bytes : Bytes) -> CursorGc {
  { bytes, pos: 0 }
}

///|
fn CursorGc::read_u8(self : CursorGc) -> Int raise {
  if self.pos >= self.bytes.length() {
    fail("unexpected eof")
  }
  let b = self.bytes[self.pos]
  self.pos += 1
  b.to_int()
}

///|
fn CursorGc::read_bytes(self : CursorGc, n : Int) -> Bytes raise {
  if self.pos + n > self.bytes.length() {
    fail("unexpected eof")
  }
  let view = self.bytes.sub(start=self.pos, end=self.pos + n)
  self.pos += n
  view.to_bytes()
}

///|
fn CursorGc::read_leb_u32(self : CursorGc) -> Int raise {
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
      fail("leb overflow")
    }
  }
  result
}

///|
fn code_section_bytes_gc(wasm : Bytes) -> Bytes raise {
  let cur = CursorGc::new(wasm)
  if cur.read_u8() != 0x00 ||
    cur.read_u8() != 0x61 ||
    cur.read_u8() != 0x73 ||
    cur.read_u8() != 0x6d {
    fail("invalid wasm magic")
  }
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  while cur.pos < wasm.length() {
    let id = cur.read_u8()
    let size = cur.read_leb_u32()
    let section = cur.read_bytes(size)
    if id == 10 {
      return section
    }
  }
  fail("code section not found")
}

///|
fn bytes_contains_gc(hay : Bytes, needle : Array[Byte]) -> Bool {
  if needle.length() == 0 {
    return true
  }
  let hay_arr = hay.to_array()
  let limit = hay_arr.length() - needle.length()
  if limit < 0 {
    return false
  }
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<needle.length() {
      if hay_arr[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
test "wasm gc opcode fixtures" {
  let fixture_dir = "fixtures/wasm_gc"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[\{fixture_dir}] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[\{fixture_dir}] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".xsh") {
      files.push(path)
    }
  }
  sort_strings_gc(files)
  if files.length() == 0 {
    fail("[\{fixture_dir}] no .xsh fixtures found")
  }
  for path in files {
    let source = @os_fs.read_file_to_string(path) catch {
      e => fail("[\{path}] read failed: \{e.to_string()}")
    }
    let (script, data) = split_fixture_gc(source, path)
    let spec = parse_spec_gc(data, path)
    if spec.skip {
      println("[\{path}] skipped")
      continue
    }
    let db = XshDb::new()
    db.set_source("main", script)
    let wasm = try compile_module_wasm_gc(db, "main") catch {
      e => fail("[\{path}] compile error: \{e.to_string()}")
    } noraise {
      b => b
    }
    let code_section = code_section_bytes_gc(wasm)
    let opcode_bytes = opcode_bytes_gc(spec.opcode)
    let found = bytes_contains_gc(code_section, opcode_bytes)
    if spec.todo {
      if found {
        fail("[\{path}] TODO opcode found (remove TODO)")
      }
    } else if !found {
      fail("[\{path}] opcode not found: \{spec.opcode}")
    }
  }
}
