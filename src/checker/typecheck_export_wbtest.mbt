///|
test "derive(Eq) enum typechecks with builtin Eq trait" {
  let script =
    #|enum Color { Red; Green; Blue } derive(Eq)
    #|let _x = Color::Red == Color::Blue
  let ast = @parser.parse_ast(script)
  let _ = type_check(ast)
}

///|
test "derive(Eq) struct typechecks with builtin Eq trait" {
  let script =
    #|struct Point { x: Int; y: Int } derive(Eq)
    #|let _x = Point::{ x: 1, y: 2 } == Point::{ x: 3, y: 4 }
  let ast = @parser.parse_ast(script)
  let _ = type_check(ast)
}

///|
test "typecheck keeps exported schemes for struct-returning functions" {
  let script =
    #|export struct PathRef { raw : String }
    #|export let from_literal = (literal: String) -> PathRef {
    #|  PathRef::{ raw: literal }
    #|}
  let ast = @parser.parse_ast(script)
  let env = type_check(ast)
  match env.get_scheme("add") {
    Some(_) => ()
    None => fail("expected prelude scheme: add")
  }
  match env.get_scheme("from_literal") {
    Some(_) => ()
    None => fail("expected exported scheme: from_literal")
  }
}

///|
test "typecheck keeps exported schemes for path wrapper module" {
  let script =
    #|export struct PathRef { raw : String }
    #|export struct DynamicPath { raw : String }
    #|export let from_literal = (literal: String) -> PathRef {
    #|  PathRef::{ raw: Path::to_string(Path::ref(literal)) }
    #|}
    #|export let dynamic = (raw: String) -> DynamicPath {
    #|  DynamicPath::{ raw: raw }
    #|}
    #|export let resolve = (path: DynamicPath) -> PathRef with {Env} {
    #|  {
    #|    PathRef::{ raw: Path::to_string(Path::resolve(path.raw)) }
    #|  }
    #|}
  let ast = @parser.parse_ast(script)
  let env = type_check(ast)
  match env.get_scheme("from_literal") {
    Some(_) => ()
    None => fail("expected exported scheme: from_literal")
  }
  match env.get_scheme("dynamic") {
    Some(_) => ()
    None => fail("expected exported scheme: dynamic")
  }
  match env.get_scheme("resolve") {
    Some(_) => ()
    None => fail("expected exported scheme: resolve")
  }
}

///|
test "typecheck keeps exported schemes with ArrayBuilder::new local recursion" {
  let script =
    #|export let build = (n: Int) -> Array[Int] {
    #|  let rec go = (i: Int, b: ArrayBuilder[Int]) -> Array[Int] {
    #|    if i >= n {
    #|      {
    #|        ArrayBuilder::freeze(b)
    #|      }
    #|    } else {
    #|      {
    #|        ArrayBuilder::push(b, i)
    #|        go(i + 1, b)
    #|      }
    #|    }
    #|  }
    #|  {
    #|    go(0, ArrayBuilder::new())
    #|  }
    #|}
  let ast = @parser.parse_ast(script)
  let env = type_check(ast)
  match env.get_scheme("build") {
    Some(_) => ()
    None => fail("expected exported scheme: build")
  }
}

///|
