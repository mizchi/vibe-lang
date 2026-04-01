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
test "typecheck keeps exported schemes for threads runtime wrappers" {
  let script =
    #|export let recv = (channel: Int) -> String with { Threads } {
    #|  Threads::recv(channel)
    #|}
    #|export let send = (channel: Int, message: String) -> Bool with { Threads } {
    #|  Threads::send(channel, message)
    #|}
    #|export let wait = (task: Int) -> Int with { Threads } {
    #|  Threads::wait(task)
    #|}
    #|export let spawn = (name: String, mailbox: Int) -> Int with { Threads } {
    #|  {
    #|    Threads::spawn(name, mailbox)
    #|  }
    #|}
    #|export let probe_wat = () -> String with { Threads } {
    #|  Threads::probe_wat()
    #|}
    #|export let channel_new = (capacity: Int) -> Int with { Threads } {
    #|  Threads::channel_new(capacity)
    #|}
    #|export let runtime_hints = () -> Unit with { Threads } {
    #|  let _ = Threads::runtime_hints()
    #|  if true {
    #|  } else {
    #|  }
    #|}
  let ast = @parser.parse_ast(script)
  let env = type_check(ast)
  let names = [
    "recv", "send", "wait", "spawn", "probe_wat", "channel_new", "runtime_hints",
  ]
  for name in names {
    match env.get_scheme(name) {
      Some(_) => ()
      None => fail("expected exported scheme: " + name)
    }
  }
}
