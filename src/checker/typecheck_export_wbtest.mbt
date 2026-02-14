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
    #|  PathRef::{ raw: path_to_string(path_ref(literal)) }
    #|}
    #|export let dynamic = (raw: String) -> DynamicPath {
    #|  DynamicPath::{ raw: raw }
    #|}
    #|export let resolve = (path: DynamicPath) -> PathRef with {Env} {
    #|  do {
    #|    PathRef::{ raw: path_to_string(dynamic_path_resolve(path.raw)) }
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
test "typecheck keeps exported schemes with array_builder local recursion" {
  let script =
    #|export let build = (n: Int) -> Array[Int] {
    #|  let rec loop = (i: Int, b: ArrayBuilder[Int]) -> Array[Int] {
    #|    if i >= n {
    #|      do {
    #|        array_builder_freeze(b)
    #|      }
    #|    } else {
    #|      do {
    #|        array_builder_push(b, i)
    #|        loop(i + 1, b)
    #|      }
    #|    }
    #|  }
    #|  do {
    #|    loop(0, array_builder())
    #|  }
    #|}
  let ast = @parser.parse_ast(script)
  let env = type_check(ast)
  match env.get_scheme("build") {
    Some(_) => ()
    None => fail("expected exported scheme: build")
  }
}
