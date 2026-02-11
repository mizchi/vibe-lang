///|
/// Formatter tests

///|
test "xsh format roundtrip regression: trait impl import test and literals" {
  let input =
    #|use ./mod.xsh { type Option, trait Eq, eq }
    #|trait Eq
    #|impl Eq for Int
    #|test "quoted case" {
    #|  let msg = "hello world"
    #|  let escaped = "\"ok\""
    #|  let ch = 'z'
    #|  let f = () -> Int with { Error } { 1 }
    #|  assert_true(msg == "hello world")
    #|}
  let formatted = format_script(input)
  let before = parse_ast(input) catch {
    e => fail("[before-format] parse failed: \{e.to_string()}\n---\n\{input}")
  }
  let after = parse_ast(formatted) catch {
    e =>
      fail("[after-format] parse failed: \{e.to_string()}\n---\n\{formatted}")
  }
  assert_eq(@core.normalize_module(after), @core.normalize_module(before))
  if not(formatted.contains("trait Eq")) {
    fail("[trait spacing] missing trait Eq\n---\n\{formatted}")
  }
  if not(formatted.contains("impl Eq for Int")) {
    fail("[impl spacing] missing impl Eq for Int\n---\n\{formatted}")
  }
  if not(formatted.contains("test \"quoted case\"")) {
    fail("[test quoted name] missing quoted test name\n---\n\{formatted}")
  }
  if not(formatted.contains("use ./mod.xsh")) {
    fail("[use source spacing] missing use source clause spacing\n---\n\{formatted}")
  }
  if not(formatted.contains("\"hello world\"")) {
    fail("[string quotes] missing quoted string literal\n---\n\{formatted}")
  }
  if not(formatted.contains("'z'")) {
    fail("[char quotes] missing quoted char literal\n---\n\{formatted}")
  }
  if formatted.contains("traitEq") {
    fail("[trait join regression] found traitEq\n---\n\{formatted}")
  }
  if formatted.contains("implEq") {
    fail("[impl join regression] found implEq\n---\n\{formatted}")
  }
  if formatted.contains("}use") {
    fail("[use join regression] found }use\n---\n\{formatted}")
  }
}

///|
test "xsh format roundtrip regression: effect signatures stay parse-equivalent" {
  let input =
    #|let run = (f: () -> Int with { Error, Io }) -> Int with { Error } {
    #|  f()
    #|}
    #|let g = () -> Int with { Error } { 0 }
  let formatted = format_script(input)
  let before = parse_ast(input) catch {
    e => fail("[before-format] parse failed: \{e.to_string()}\n---\n\{input}")
  }
  let after = parse_ast(formatted) catch {
    e =>
      fail("[after-format] parse failed: \{e.to_string()}\n---\n\{formatted}")
  }
  assert_eq(@core.normalize_module(after), @core.normalize_module(before))
}

///|
test "xsh format keeps import list forms parse-equivalent" {
  let input =
    #|use ./mod.xsh { type Option, trait Eq, value as value_alias }
    #|use ./mod.xsh { value_alias }
  let formatted = format_script(input)
  let before = parse_ast(input) catch {
    e => fail("[before-format] parse failed: \{e.to_string()}\n---\n\{input}")
  }
  let after = parse_ast(formatted) catch {
    e =>
      fail("[after-format] parse failed: \{e.to_string()}\n---\n\{formatted}")
  }
  assert_eq(@core.normalize_module(after), @core.normalize_module(before))
  if not(formatted.contains("trait Eq")) {
    fail("[import trait item spacing] missing trait Eq\n---\n\{formatted}")
  }
  if formatted.contains("}use") {
    fail("[use spacing] found }use\n---\n\{formatted}")
  }
}

///|
test "xsh parse/format import list allows trailing comma" {
  let input =
    #|use ./mod.xsh { type Option, trait Eq, value as value_alias, }
  let ast = parse_ast(input) catch {
    e => fail("[parse] import trailing comma failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] import trailing comma format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "xsh parse/format import list supports module qualifier" {
  let input =
    #|export module math {
    #|  export let inc = (x: Int) -> Int { add(x, 1) }
    #|}
    #|use ./math.xm { module math }
    #|math::inc(1)
  let ast = parse_ast(input) catch {
    e => fail("[parse] module import qualifier failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] module import qualifier format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
  if not(formatted.contains("module math")) {
    fail("[format] missing module qualifier\n---\n\{formatted}")
  }
  if not(formatted.contains("use ./math.xm")) {
    fail("[format] missing use source\n---\n\{formatted}")
  }
}

///|
test "xsh parse/format import list supports module qualifier alias" {
  let input =
    #|export module math {
    #|  export let inc = (x: Int) -> Int { add(x, 1) }
    #|}
    #|use ./math.xm { module math as m }
    #|m::inc(1)
  let ast = parse_ast(input) catch {
    e => fail("[parse] module import qualifier alias failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] module import qualifier alias format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
  if not(formatted.contains("module math as m")) {
    fail("[format] missing module alias qualifier\n---\n\{formatted}")
  }
}

///|
test "xsh parse rejects quoted use source" {
  let input = "use \"./mod.xsh\" { value }\nvalue"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected quoted use source to be rejected")
    Err(err) =>
      assert_true(
        err.to_string().contains(
          "module path without quotes (e.g. ./xsh/std/string.xsh)",
        ),
      )
  }
}

///|
test "xsh parse/format local let annotation is parser-equivalent" {
  let input =
    #|let x: Int = 1
    #|let mut y: Int = x
    #|let z: String = "ok"
  let ast = parse_ast(input) catch {
    e => fail("[parse] let annotation failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] let annotation format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "xsh parse/format test declaration accepts unquoted names" {
  let input =
    #|test smoke_case {
    #|  let x = 1
    #|}
    #|test "quoted case" {
    #|  let y = 2
    #|}
  let ast = parse_ast(input) catch {
    e => fail("[parse] unquoted test name failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] unquoted test name format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "xsh parse/format map keyword is contextual in identifier positions" {
  let input =
    #|let map = (x: Int) -> Int { x }
    #|let y = map(1)
  let ast = parse_ast(input) catch {
    e => fail("[parse] contextual map identifier failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] contextual map identifier format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "xsh parse/format loop expression is parser-equivalent" {
  let input =
    #|let mut i = 0
    #|loop {
    #|  i += 1
    #|  if i == 3 { break } else { }
    #|}
    #|i
  let ast = parse_ast(input) catch {
    e => fail("[parse] loop expression failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] loop expression format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "xsh format basic" {
  let input =
    #|let x=1
    #|let y = {
    #|let a=1
    #|  add(a,2)
    #|}
  let expected =
    #|let x = 1
    #|let y = {
    #|  let a = 1
    #|  add(a, 2)
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format collections" {
  let input =
    #|let arr=[1,2]
    #|let r = record { a:1, b:2 }
    #|let m = map { a:1, b:2 }
  let expected =
    #|let arr = [
    #|  1,
    #|  2
    #|]
    #|let r = record {
    #|  a: 1,
    #|  b: 2
    #|}
    #|let m = map {
    #|  a: 1,
    #|  b: 2
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format match" {
  let input =
    #|match v { Ok(v)=>1, None if true=>0 }
  let expected =
    #|match v {
    #|  Ok(v) => 1,
    #|  None if true => 0
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format type args and index" {
  let input =
    #|let x: Option[Int] = none
    #|let y = xs[0]
    #|let z = foo()[0]
    #|type Box[T] = Array[T]
  let expected =
    #|let x: Option[Int] = none
    #|let y = xs[0]
    #|let z = foo()[0]
    #|type Box[T] = Array[T]
  inspect(format_script(input), content=expected)
}

///|
test "xsh format enum uses semicolon separator" {
  let input =
    #|enum Result[T] { Ok(T), Err }
  let expected =
    #|enum Result[T] {
    #|  Ok(T);
    #|  Err
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format keeps enum payload commas" {
  let input =
    #|enum List { Nil, Cons(Int, List) }
  let expected =
    #|enum List {
    #|  Nil;
    #|  Cons(Int,
    #|  List)
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format normalizes struct literal separator" {
  let input =
    #|let p = Point::{x:1,y:1}
    #|let q = Point {x:1,y:1}
  let expected =
    #|let p = Point::{
    #|  x: 1, y: 1
    #|}
    #|let q = Point::{
    #|  x: 1, y: 1
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format is idempotent" {
  let input =
    #|enum Result[T] { Ok(T), Err }
    #|struct Point { x : Int; y : Int }
    #|let p = Point {x:1,y:1}
    #|let q = Point::{x:2,y:2}
    #|match p { Point::{x,y} => add(x,y), _ => 0 }
  let once = format_script(input)
  let twice = format_script(once)
  inspect(twice, content=once)
}

///|
test "xsh format keeps declaration braces and return type blocks" {
  let input =
    #|struct Point { x : Int; y : Int }
    #|let make = () -> Int { 1 }
    #|let p = Point {x:1,y:1}
    #|let eff = () -> Int with { Error } { 0 }
  let expected =
    #|struct Point {
    #|  x: Int; y: Int
    #|}
    #|let make = () -> Int {
    #|  1
    #|}
    #|let p = Point::{
    #|  x: 1, y: 1
    #|}
    #|let eff = () -> Int with {
    #|  Error
    #|} {
    #|  0
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format derive declarations is idempotent" {
  let input =
    #|struct Point { x : Int; y : Int } derive(Eq)
    #|enum Token { A, B } derive(Eq, Ord)
  let once = format_script(input)
  let twice = format_script(once)
  inspect(twice, content=once)
}
