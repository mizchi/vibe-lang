///|
/// Helper: convert Array[Int] to Bytes.
fn ints_to_bytes(arr : Array[Int]) -> Bytes {
  let byte_arr : Array[Byte] = []
  for v in arr {
    byte_arr.push(v.to_byte())
  }
  Bytes::from_array(byte_arr[:])
}

///|
/// Helper: build a minimal binary table entry for testing.
/// param_count is the logical number of parameters, param_tag_bytes is the raw
/// byte sequence for all parameter type tags.
fn build_test_table_v2(
  entries : Array[(String, Int, Array[Int], Int, Int)],
) -> Bytes {
  let buf : Array[Int] = []
  // Magic
  buf.push(0x56) // V
  buf.push(0x42) // B
  buf.push(0x4C) // L
  buf.push(0x54) // T
  // Version
  buf.push(1)
  // Count
  buf.push(entries.length())
  for entry in entries {
    let (name, param_count, param_tag_bytes, ret_tag, flags) = entry
    // Write name as raw ASCII bytes
    buf.push(name.length())
    for i = 0; i < name.length(); i = i + 1 {
      buf.push(name[i].to_int())
    }
    // param count (logical)
    buf.push(param_count)
    // param type tag bytes
    for tag in param_tag_bytes {
      buf.push(tag)
    }
    buf.push(ret_tag)
    buf.push(flags)
  }
  ints_to_bytes(buf)
}

///|
test "decode_builtin_table: empty table" {
  let data = build_test_table_v2([])
  match decode_builtin_table(data) {
    Some(entries) => assert_eq(entries.length(), 0)
    None => fail("expected Some")
  }
}

///|
test "decode_builtin_table: invalid magic returns None" {
  let data = Bytes::new(6)
  match decode_builtin_table(data) {
    Some(_) => fail("expected None")
    None => ()
  }
}

///|
test "decode_builtin_table: single entry String::length" {
  // String::length(String) -> Int, flags=0
  // 1 param: String (0x03)
  let data = build_test_table_v2([("String::length", 1, [0x03], 0x01, 0)])
  match decode_builtin_table(data) {
    Some(entries) => {
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, "String::length")
      assert_eq(entries[0].params, [BuiltinTypeId::BTString])
      assert_eq(entries[0].ret, BuiltinTypeId::BTInt)
      assert_eq(entries[0].flags, 0)
    }
    None => fail("expected Some")
  }
}

///|
test "decode_builtin_table: Array::get with container type" {
  // Array::get(Array[T], Int) -> T
  // 2 params: Array[T] (0x10 0xF0), Int (0x01)
  // ret: T (0xF0)
  let data = build_test_table_v2([
    ("Array::get", 2, [0x10, 0xF0, 0x01], 0xF0, 0),
  ])
  match decode_builtin_table(data) {
    Some(entries) => {
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, "Array::get")
      assert_eq(entries[0].params.length(), 2)
      assert_eq(
        entries[0].params[0],
        BuiltinTypeId::BTArray(BuiltinTypeId::BTTypeVar(0)),
      )
      assert_eq(entries[0].params[1], BuiltinTypeId::BTInt)
      assert_eq(entries[0].ret, BuiltinTypeId::BTTypeVar(0))
    }
    None => fail("expected Some")
  }
}

///|
test "decode_builtin_table: Map type" {
  // Map::get(Map[T,U], T) -> U
  // 2 params: Map[T,U] (0x11 0xF0 0xF1), T (0xF0)
  // ret: U (0xF1)
  let data = build_test_table_v2([
    ("Map::get", 2, [0x11, 0xF0, 0xF1, 0xF0], 0xF1, 0),
  ])
  match decode_builtin_table(data) {
    Some(entries) => {
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, "Map::get")
      assert_eq(entries[0].params.length(), 2)
      assert_eq(
        entries[0].params[0],
        BuiltinTypeId::BTMap(
          BuiltinTypeId::BTTypeVar(0),
          BuiltinTypeId::BTTypeVar(1),
        ),
      )
      assert_eq(entries[0].params[1], BuiltinTypeId::BTTypeVar(0))
      assert_eq(entries[0].ret, BuiltinTypeId::BTTypeVar(1))
    }
    None => fail("expected Some")
  }
}

///|
test "decode_builtin_table: multiple entries" {
  let data = build_test_table_v2([
    ("Fs::getcwd", 0, [], 0x03, 0),
    ("Bytes::length", 1, [0x06], 0x01, 0),
  ])
  match decode_builtin_table(data) {
    Some(entries) => {
      assert_eq(entries.length(), 2)
      assert_eq(entries[0].name, "Fs::getcwd")
      assert_eq(entries[0].params.length(), 0)
      assert_eq(entries[0].ret, BuiltinTypeId::BTString)
      assert_eq(entries[1].name, "Bytes::length")
      assert_eq(entries[1].params, [BuiltinTypeId::BTBytes])
      assert_eq(entries[1].ret, BuiltinTypeId::BTInt)
    }
    None => fail("expected Some")
  }
}

///|
test "read_leb128: multi-byte" {
  // 300 = 0b100101100 -> LEB128: 0xAC 0x02
  let data = ints_to_bytes([0xAC, 0x02])
  let pos : Array[Int] = [0]
  let val = read_leb128(data, pos)
  assert_eq(val, 300)
  assert_eq(pos[0], 2)
}

///|
test "decode_builtin_table: too short returns None" {
  let data = Bytes::new(3)
  match decode_builtin_table(data) {
    Some(_) => fail("expected None")
    None => ()
  }
}

///|
test "decode_builtin_table: Set type" {
  // Set::size(Set[T]) -> Int
  // 1 param: Set[T] (0x12 0xF0)
  let data = build_test_table_v2([("Set::size", 1, [0x12, 0xF0], 0x01, 0)])
  match decode_builtin_table(data) {
    Some(entries) => {
      assert_eq(entries[0].params.length(), 1)
      assert_eq(
        entries[0].params[0],
        BuiltinTypeId::BTSet(BuiltinTypeId::BTTypeVar(0)),
      )
    }
    None => fail("expected Some")
  }
}

///|
test "decode_builtin_table: Option type" {
  // Int::parse(String) -> Option[Int]
  // 1 param: String (0x03), ret: Option[Int] (0x13 0x01)
  let buf : Array[Int] = []
  buf.push(0x56)
  buf.push(0x42)
  buf.push(0x4C)
  buf.push(0x54)
  buf.push(1) // version
  buf.push(1) // count
  let name = "Int::parse"
  buf.push(name.length()) // name_len
  for i = 0; i < name.length(); i = i + 1 {
    buf.push(name[i].to_int())
  }
  buf.push(1) // param count
  buf.push(0x03) // String
  buf.push(0x13) // Option
  buf.push(0x01) // Int
  buf.push(0) // flags
  let data = ints_to_bytes(buf)
  match decode_builtin_table(data) {
    Some(entries) =>
      assert_eq(entries[0].ret, BuiltinTypeId::BTOption(BuiltinTypeId::BTInt))
    None => fail("expected Some")
  }
}
