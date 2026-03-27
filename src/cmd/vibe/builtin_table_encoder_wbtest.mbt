///|
test "parse_type_tag: primitive types" {
  assert_eq(parse_type_tag("Unit"), BuiltinTypeTag::Unit)
  assert_eq(parse_type_tag("Int"), BuiltinTypeTag::Int_)
  assert_eq(parse_type_tag("Bool"), BuiltinTypeTag::Bool_)
  assert_eq(parse_type_tag("String"), BuiltinTypeTag::String_)
  assert_eq(parse_type_tag("Double"), BuiltinTypeTag::Double_)
  assert_eq(parse_type_tag("Float"), BuiltinTypeTag::Float_)
  assert_eq(parse_type_tag("Bytes"), BuiltinTypeTag::Bytes_)
  assert_eq(parse_type_tag("Char"), BuiltinTypeTag::Char_)
  assert_eq(parse_type_tag("Path"), BuiltinTypeTag::Path_)
  assert_eq(parse_type_tag("V128"), BuiltinTypeTag::V128_)
  assert_eq(parse_type_tag("Json"), BuiltinTypeTag::Json_)
  assert_eq(parse_type_tag("StringBuilder"), BuiltinTypeTag::StringBuilder_)
  assert_eq(parse_type_tag("PromptText"), BuiltinTypeTag::PromptText_)
}

///|
test "parse_type_tag: type variables" {
  assert_eq(parse_type_tag("T"), BuiltinTypeTag::TypeVar(0))
  assert_eq(parse_type_tag("U"), BuiltinTypeTag::TypeVar(1))
  assert_eq(parse_type_tag("V"), BuiltinTypeTag::TypeVar(2))
}

///|
test "parse_type_tag: container types" {
  assert_eq(
    parse_type_tag("Array[Int]"),
    BuiltinTypeTag::Array_(BuiltinTypeTag::Int_),
  )
  assert_eq(
    parse_type_tag("Map[String, Int]"),
    BuiltinTypeTag::Map_(BuiltinTypeTag::String_, BuiltinTypeTag::Int_),
  )
  assert_eq(
    parse_type_tag("Set[T]"),
    BuiltinTypeTag::Set_(BuiltinTypeTag::TypeVar(0)),
  )
  assert_eq(
    parse_type_tag("Option[Int]"),
    BuiltinTypeTag::Option_(BuiltinTypeTag::Int_),
  )
  assert_eq(
    parse_type_tag("Array[T]"),
    BuiltinTypeTag::Array_(BuiltinTypeTag::TypeVar(0)),
  )
  assert_eq(
    parse_type_tag("ArrayBuilder[T]"),
    BuiltinTypeTag::ArrayBuilder_(BuiltinTypeTag::TypeVar(0)),
  )
  assert_eq(
    parse_type_tag("MapBuilder[T, U]"),
    BuiltinTypeTag::MapBuilder_(
      BuiltinTypeTag::TypeVar(0),
      BuiltinTypeTag::TypeVar(1),
    ),
  )
}

///|
test "parse_type_tag: nested containers" {
  assert_eq(
    parse_type_tag("Array[Array[Int]]"),
    BuiltinTypeTag::Array_(BuiltinTypeTag::Array_(BuiltinTypeTag::Int_)),
  )
  assert_eq(
    parse_type_tag("Array[String]"),
    BuiltinTypeTag::Array_(BuiltinTypeTag::String_),
  )
}

///|
test "parse_type_tag: function types" {
  assert_eq(
    parse_type_tag("(T) -> U"),
    BuiltinTypeTag::Fn_(
      [BuiltinTypeTag::TypeVar(0)],
      BuiltinTypeTag::TypeVar(1),
    ),
  )
  assert_eq(
    parse_type_tag("(T) -> Bool"),
    BuiltinTypeTag::Fn_([BuiltinTypeTag::TypeVar(0)], BuiltinTypeTag::Bool_),
  )
}

///|
test "parse_declare_line: simple builtin" {
  match parse_declare_line("declare String::length(String) -> Int") {
    Some(d) => {
      assert_eq(d.name, "String::length")
      assert_eq(d.params, [BuiltinTypeTag::String_])
      assert_eq(d.ret, BuiltinTypeTag::Int_)
    }
    None => fail("expected Some")
  }
}

///|
test "parse_declare_line: no params" {
  match parse_declare_line("declare array_new() -> Array[T]") {
    Some(d) => {
      assert_eq(d.name, "array_new")
      assert_eq(d.params.length(), 0)
      assert_eq(d.ret, BuiltinTypeTag::Array_(BuiltinTypeTag::TypeVar(0)))
    }
    None => fail("expected Some")
  }
}

///|
test "parse_declare_line: multiple params" {
  match parse_declare_line("declare Array::set(Array[T], Int, T) -> Unit") {
    Some(d) => {
      assert_eq(d.name, "Array::set")
      assert_eq(d.params.length(), 3)
      assert_eq(d.params[0], BuiltinTypeTag::Array_(BuiltinTypeTag::TypeVar(0)))
      assert_eq(d.params[1], BuiltinTypeTag::Int_)
      assert_eq(d.params[2], BuiltinTypeTag::TypeVar(0))
      assert_eq(d.ret, BuiltinTypeTag::Unit)
    }
    None => fail("expected Some")
  }
}

///|
test "parse_declare_line: comment line returns None" {
  assert_true(parse_declare_line("// comment") is None)
  assert_true(parse_declare_line("//# Section") is None)
  assert_true(parse_declare_line("") is None)
}

///|
test "parse_declarations: multiple lines" {
  let source =
    #|// comment
    #|declare String::length(String) -> Int
    #|
    #|declare Array::get(Array[T], Int) -> T
  let decls = parse_declarations(source)
  assert_eq(decls.length(), 2)
  assert_eq(decls[0].name, "String::length")
  assert_eq(decls[1].name, "Array::get")
}

///|
test "encode_builtin_table: magic header" {
  let decls : Array[BuiltinDecl] = []
  let bytes = encode_builtin_table(decls)
  // Check magic: "VBLT"
  assert_eq(bytes.unsafe_get(0).to_int(), 0x56) // V
  assert_eq(bytes.unsafe_get(1).to_int(), 0x42) // B
  assert_eq(bytes.unsafe_get(2).to_int(), 0x4C) // L
  assert_eq(bytes.unsafe_get(3).to_int(), 0x54) // T
  // Version
  assert_eq(bytes.unsafe_get(4).to_int(), 1)
  // Count = 0
  assert_eq(bytes.unsafe_get(5).to_int(), 0)
}

///|
test "write_leb128: small values" {
  let buf : Array[Int] = []
  write_leb128(buf, 0)
  assert_eq(buf[0], 0)
  let buf2 : Array[Int] = []
  write_leb128(buf2, 127)
  assert_eq(buf2[0], 127)
  let buf3 : Array[Int] = []
  write_leb128(buf3, 128)
  assert_eq(buf3[0], 0x80)
  assert_eq(buf3[1], 1)
}

///|
test "split_top_level_comma: simple" {
  let parts = split_top_level_comma("Int, String")
  assert_eq(parts.length(), 2)
  assert_eq(parts[0], "Int")
  assert_eq(parts[1], "String")
}

///|
test "split_top_level_comma: with brackets" {
  let parts = split_top_level_comma("Array[T], Int, T")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "Array[T]")
  assert_eq(parts[1], "Int")
  assert_eq(parts[2], "T")
}

///|
test "split_top_level_comma: nested" {
  let parts = split_top_level_comma("Map[String, Int], Bool")
  assert_eq(parts.length(), 2)
  assert_eq(parts[0], "Map[String, Int]")
  assert_eq(parts[1], "Bool")
}

///|
test "encode_builtin_table: roundtrip single entry" {
  let decl = BuiltinDecl::{
    name: "String::length",
    params: [BuiltinTypeTag::String_],
    ret: BuiltinTypeTag::Int_,
    flags: 0,
  }
  let bytes = encode_builtin_table([decl])
  // Verify magic header
  assert_eq(bytes.unsafe_get(0).to_int(), 0x56) // V
  assert_eq(bytes.unsafe_get(4).to_int(), 1) // version
  // Verify we get at least the header + some data
  assert_true(bytes.length() > 6)
}

///|
test "encode_builtin_table: roundtrip Array type" {
  let decl = BuiltinDecl::{
    name: "Array::get",
    params: [
      BuiltinTypeTag::Array_(BuiltinTypeTag::TypeVar(0)),
      BuiltinTypeTag::Int_,
    ],
    ret: BuiltinTypeTag::TypeVar(0),
    flags: 0,
  }
  let bytes = encode_builtin_table([decl])
  assert_true(bytes.length() > 6)
}

///|
test "parse_declarations: full declarations sample" {
  let source =
    #|declare Array::length(Array[T]) -> Int
    #|declare Map::get(Map[T, U], T) -> U
    #|declare Set::new() -> Set[T]
    #|declare Int::parse(String) -> Option[Int]
  let decls = parse_declarations(source)
  assert_eq(decls.length(), 4)
  assert_eq(decls[0].name, "Array::length")
  assert_eq(decls[0].params.length(), 1)
  assert_eq(
    decls[0].params[0],
    BuiltinTypeTag::Array_(BuiltinTypeTag::TypeVar(0)),
  )
  assert_eq(decls[0].ret, BuiltinTypeTag::Int_)
  assert_eq(decls[1].name, "Map::get")
  assert_eq(decls[1].params.length(), 2)
  assert_eq(
    decls[1].params[0],
    BuiltinTypeTag::Map_(BuiltinTypeTag::TypeVar(0), BuiltinTypeTag::TypeVar(1)),
  )
  assert_eq(decls[2].name, "Set::new")
  assert_eq(decls[2].params.length(), 0)
  assert_eq(decls[2].ret, BuiltinTypeTag::Set_(BuiltinTypeTag::TypeVar(0)))
  assert_eq(decls[3].name, "Int::parse")
  assert_eq(decls[3].ret, BuiltinTypeTag::Option_(BuiltinTypeTag::Int_))
}
