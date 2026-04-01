///|
/// Formatter tests

///|
test "vibe format roundtrip regression: trait impl import test and literals" {
  let input =
    #|import ./mod.vibe { type Option, trait Eq, eq }
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
  if !formatted.contains("trait Eq") {
    fail("[trait spacing] missing trait Eq\n---\n\{formatted}")
  }
  if !formatted.contains("impl Eq for Int") {
    fail("[impl spacing] missing impl Eq for Int\n---\n\{formatted}")
  }
  if !formatted.contains("test \"quoted case\"") {
    fail("[test quoted name] missing quoted test name\n---\n\{formatted}")
  }
  if !formatted.contains("import ./mod.vibe") {
    fail(
      "[import source spacing] missing import source clause spacing\n---\n\{formatted}",
    )
  }
  if !formatted.contains("\"hello world\"") {
    fail("[string quotes] missing quoted string literal\n---\n\{formatted}")
  }
  if !formatted.contains("'z'") {
    fail("[char quotes] missing quoted char literal\n---\n\{formatted}")
  }
  if formatted.contains("traitEq") {
    fail("[trait join regression] found traitEq\n---\n\{formatted}")
  }
  if formatted.contains("implEq") {
    fail("[impl join regression] found implEq\n---\n\{formatted}")
  }
  if formatted.contains("}import") {
    fail("[import join regression] found }import\n---\n\{formatted}")
  }
}

///|
test "vibe format roundtrip regression: effect signatures stay parse-equivalent" {
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
test "vibe format roundtrip regression: effect declarations stay parse-equivalent" {
  let input =
    #|effect ParseRecur {
    #|  Call(Array[Token], Int, Int) -> (Expr, Int)
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
  if formatted.contains("ParseRecur::") {
    fail("[effect decl regression] found ParseRecur::\n---\n\{formatted}")
  }
}

///|
test "vibe format roundtrip regression: suberror declarations stay parse-equivalent" {
  let input =
    #|suberror HttpError {
    #|  BadRequest(String);
    #|  NotFound;
    #|  MethodNotAllowed;
    #|  Forbidden;
    #|  InternalError(String)
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
}

///|
test "vibe format roundtrip regression: sectioned suberror declarations stay parse-equivalent" {
  let input =
    #|//# Types
    #|suberror HttpError {
    #|  BadRequest(String);
    #|  NotFound;
    #|  MethodNotAllowed;
    #|  Forbidden;
    #|  InternalError(String)
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
}

///|
test "vibe format roundtrip regression: export struct declarations stay parse-equivalent" {
  let input =
    #|export struct HttpRequest {
    #|  method: String;
    #|  url: String;
    #|  headers: Map[String, String];
    #|  body: String
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
}

///|
test "vibe format roundtrip regression: namespaced struct constructors stay parse-equivalent" {
  let input =
    #|let resp = HttpResponse::{ status: 200, headers: MapBuilder::freeze(MapBuilder::new()), body: "" }
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
test "vibe format roundtrip regression: array comment lines keep following hex items separated" {
  let input =
    #|let bytes = [
    #|  // component section id=4, size=8
    #|  0x04, 0x08,
    #|  // nested component header
    #|  0x00, 0x61
    #|]
  let before = parse_ast(input) catch {
    e => fail("[before-format] parse failed: \{e.to_string()}\n---\n\{input}")
  }
  let formatted = format_script(input)
  let after = parse_ast(formatted) catch {
    e =>
      fail("[after-format] parse failed: \{e.to_string()}\n---\n\{formatted}")
  }
  assert_eq(@core.normalize_module(after), @core.normalize_module(before))
  if formatted.contains("size=80x04") {
    fail("[format] comment swallowed following hex item\n---\n\{formatted}")
  }
  if formatted.contains("header0x00") {
    fail(
      "[format] second comment swallowed following hex item\n---\n\{formatted}",
    )
  }
}

///|
test "vibe format keeps import list forms parse-equivalent" {
  let input =
    #|import ./mod.vibe { type Option, trait Eq, value as value_alias }
    #|import ./mod.vibe { value_alias }
  let formatted = format_script(input)
  let before = parse_ast(input) catch {
    e => fail("[before-format] parse failed: \{e.to_string()}\n---\n\{input}")
  }
  let after = parse_ast(formatted) catch {
    e =>
      fail("[after-format] parse failed: \{e.to_string()}\n---\n\{formatted}")
  }
  assert_eq(@core.normalize_module(after), @core.normalize_module(before))
  if !formatted.contains("trait Eq") {
    fail("[import trait item spacing] missing trait Eq\n---\n\{formatted}")
  }
  if formatted.contains("}import") {
    fail("[import spacing] found }import\n---\n\{formatted}")
  }
}

///|
test "vibe parse/format import list allows trailing comma" {
  let input =
    #|import ./mod.vibe { type Option, trait Eq, value as value_alias, }
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
test "vibe parse/format import list supports module qualifier" {
  let input =
    #|export module math {
    #|  export let inc = (x: Int) -> Int { add(x, 1) }
    #|}
    #|import ./math.xm { module math }
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
  if !formatted.contains("module math") {
    fail("[format] missing module qualifier\n---\n\{formatted}")
  }
  if !formatted.contains("import ./math.xm") {
    fail("[format] missing import source\n---\n\{formatted}")
  }
}

///|
test "vibe parse/format import list supports module qualifier alias" {
  let input =
    #|export module math {
    #|  export let inc = (x: Int) -> Int { add(x, 1) }
    #|}
    #|import ./math.xm { module math as m }
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
  if !formatted.contains("module math as m") {
    fail("[format] missing module alias qualifier\n---\n\{formatted}")
  }
}

///|
test "vibe parse/format import keyword is parser-equivalent" {
  let input =
    #|import ./math.vibe { add }
    #|add(1, 2)
  let ast = parse_ast(input) catch {
    e => fail("[parse] import keyword failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] import keyword format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "vibe parse rejects quoted import source" {
  let input = "import \"./mod.vibe\" { value }\nvalue"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected quoted import source to be rejected")
    Err(err) =>
      assert_true(
        err
        .to_string()
        .contains(
          "module path without quotes (e.g. ./vibe/prelude/string.vibe)",
        ),
      )
  }
}

///|
test "vibe parse/format local let annotation is parser-equivalent" {
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
test "vibe parse/format extern let signature is parser-equivalent" {
  let input =
    #|extern let %run: () -> Int
    #|let helper = () -> Int { 1 }
  let ast = parse_ast(input) catch {
    e => fail("[parse] extern let failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] extern let format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "vibe parse rejects extern let without percent prefix" {
  let input = "extern let run: () -> Int"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected extern let without `%` to be rejected")
    Err(err) => assert_true(err.to_string().contains("%"))
  }
}

///|
test "vibe parse rejects legacy declare export let" {
  let input = "declare export let run: () -> Int"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected legacy declare export let to be rejected")
    Err(err) => assert_true(err.to_string().contains("declare"))
  }
}

///|
test "vibe parse/format test declaration accepts unquoted names" {
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
test "vibe parse/format map is a reserved keyword (not usable as identifier)" {
  let input =
    #|let r#map = (x: Int) -> Int { x }
    #|let y = r#map(1)
  let ast = parse_ast(input) catch {
    e => fail("[parse] raw map identifier failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] raw map identifier format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "vibe parse/format raw identifier keeps reserved-name bindings" {
  let input =
    #|let r#bench = 1
    #|let r#if = 2
    #|r#bench + r#if
  let ast = parse_ast(input) catch {
    e => fail("[parse] raw identifier failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] raw identifier format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "vibe parse/format loop expression is parser-equivalent" {
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
test "vibe format basic" {
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
test "vibe format collections" {
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
test "vibe format match" {
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
test "vibe format match keeps tuple/call args compact in arms" {
  let input =
    #|match option_zip(Some(1), Some(2)) { Some((x,y)) => x+y, _ => 0 }
  let expected =
    #|match option_zip(Some(1), Some(2)) {
    #|  Some((x, y)) => x + y,
    #|  _ => 0
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "vibe format type args and index" {
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
test "vibe format generic parameter brackets stay compact" {
  let input =
    #|trait Eq
    #|impl Eq for Int
    #|impl [T: Eq] Eq for Option[T]
    #|let id = [T](x: T) -> T { x }
  let formatted = format_script(input)
  if !formatted.contains("impl [T: Eq] Eq for Option[T]") {
    fail(
      "[generic impl] expected compact impl generic params\n---\n\{formatted}",
    )
  }
  if !formatted.contains("let id = [T](x: T) -> T {") {
    fail("[generic let] expected compact let generic params\n---\n\{formatted}")
  }
  if formatted.contains("impl [\n") {
    fail(
      "[generic impl] unexpected multiline generic bracket\n---\n\{formatted}",
    )
  }
  if formatted.contains("let id = [\n") {
    fail(
      "[generic let] unexpected multiline generic bracket\n---\n\{formatted}",
    )
  }
}

///|
test "vibe format enum uses semicolon separator" {
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
test "vibe format keeps enum payload commas" {
  let input =
    #|enum List { Nil, Cons(Int, List) }
  let expected =
    #|enum List {
    #|  Nil;
    #|  Cons(Int, List)
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "vibe format normalizes struct literal separator" {
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
test "vibe format is idempotent" {
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
test "vibe format keeps declaration braces and return type blocks" {
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
    #|let eff = () -> Int with { Error } {
    #|  0
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "vibe format derive declarations is idempotent" {
  let input =
    #|struct Point { x : Int; y : Int } derive(Eq)
    #|enum Token { A, B } derive(Eq, Ord)
  let once = format_script(input)
  let twice = format_script(once)
  inspect(twice, content=once)
}

///|
test "vibe format trait impl top-level spacing" {
  let input =
    #|trait Eq
    #|impl Eq for Int
  let expected =
    #|trait Eq
    #|impl Eq for Int
  inspect(format_script(input), content=expected)
}
