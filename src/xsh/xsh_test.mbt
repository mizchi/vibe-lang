///|
/// Tests for xsh prototype
test "xsh detection" {
  assert_true(is_xsh_script("let x = 1"))
  assert_false(is_xsh_script("flake { }"))
  assert_false(is_xsh_script("alias foo = bar#abc"))
  assert_true(is_xsh_script("enum Option[T] { Some(T), None }"))
  assert_false(is_xsh_script("echo hello"))
}

///|
test "xsh eval path normalization" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let p = path(\"a/../b\")")
  match rt.get("p") {
    Some(@core.Value::Path(p)) => assert_eq(p.as_string(), "/b")
    _ => fail("expected path value")
  }
}

///|
test "xsh store gc" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = 1; let y = 2")
  let hx = match rt.get_hash("x") {
    Some(h) => h
    None => fail("missing hash for x")
  }
  let hy = match rt.get_hash("y") {
    Some(h) => h
    None => fail("missing hash for y")
  }
  assert_true(rt.store_contains(hx))
  assert_true(rt.store_contains(hy))
  assert_true(rt.remove_binding("x"))
  rt.gc()
  assert_false(rt.store_contains(hx))
  assert_true(rt.store_contains(hy))
}

///|
test "xsh alias statement is removed" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "alias foo = bar#abc",
  )
  match result {
    Err(_) => ()
    _ => fail("expected parse error")
  }
}

///|
test "xsh flake statement is removed" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script("flake { }")
  match result {
    Err(_) => ()
    _ => fail("expected parse error")
  }
}

///|
test "xsh alias can be used as identifier" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let alias = 41\nlet y = alias + 1")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "xsh flake can be used as identifier" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let flake = 41\nlet y = flake + 1")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "xsh ripple db" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1")
  let ast = db.ast("main")
  assert_eq(ast.stmts.length(), 1)
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

///|
test "xsh import parsing" {
  // Test that import syntax parses correctly
  let db = XshDb::new()
  db.set_source("main", "import { y } from ./foo.xsh\nlet x = 1")
  db.set_source("./foo.xsh", "export let y = 2")
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  match imp.hash {
    Some(h) => {
      assert_eq(h, @core.git_blob_hash_string("export let y = 2"))
      assert_eq(imp.module_ref, Some(@core.module_ref_from_hash(h)))
    }
    None => fail("missing hash")
  }
}

///|
test "xsh compile simple" {
  // Test compilation without imports
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nlet y = 2")
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.run_compiled(compiled)
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("missing x binding")
  }
}

///|
test "xsh prelude add/sub/eq/lt" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  match rt.get("add") {
    Some(@core.Value::Fn(_)) => ()
    _ => fail("add should be fn")
  }
  let _ = rt.eval_script(
    "let a = add(1, 2)\nlet b = sub(5, 3)\nlet c = eq(2, 2)\nlet d = lt(1, 2)",
  )
  match rt.get("a") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("add")
  }
  match rt.get("b") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("sub")
  }
  match rt.get("c") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("eq")
  }
  match rt.get("d") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("lt")
  }
}

///|
test "xsh float and double ops" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let a = 1.25
    #|let b = 1.5f
    #|let c = -2.0
    #|let d = 1.0 + 2.0
    #|let e = 1.0f + 2.0f
    #|let f = 1.0 < 2.0
    #|let g = 1.0 == 1.0
  let _ = rt.eval_script(script)
  match rt.get("a") {
    Some(@core.Value::Double(v)) => assert_true(Double::equal(v, 1.25))
    _ => fail("a")
  }
  match rt.get("b") {
    Some(@core.Value::Float(v)) =>
      assert_true(Float::equal(v, Float::from_double(1.5)))
    _ => fail("b")
  }
  match rt.get("c") {
    Some(@core.Value::Double(v)) => assert_true(Double::equal(v, -2.0))
    _ => fail("c")
  }
  match rt.get("d") {
    Some(@core.Value::Double(v)) => assert_true(Double::equal(v, 3.0))
    _ => fail("d")
  }
  match rt.get("e") {
    Some(@core.Value::Float(v)) =>
      assert_true(Float::equal(v, Float::from_double(3.0)))
    _ => fail("e")
  }
  match rt.get("f") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("f")
  }
  match rt.get("g") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("g")
  }
}

///|
test "xsh method call and pipe" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let inc = (a: Int) -> Int { add(a, 1) }
    #|let x = 2
    #|let y = x.inc()
    #|let z = x |> inc
    #|let w = x |> add(5)
    #|let r = w |> inc |> inc
  let _ = rt.eval_script(script)
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("missing y")
  }
  match rt.get("z") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("missing z")
  }
  match rt.get("w") {
    Some(@core.Value::Int(v)) => assert_eq(v, 7)
    _ => fail("missing w")
  }
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 9)
    _ => fail("missing r")
  }
}

///|
test "xsh char literal" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let a = 'a'\nlet b = '\\n'\nlet c = '\\''")
  match rt.get("a") {
    Some(@core.Value::Int(v)) => assert_eq(v, 97)
    _ => fail("missing a")
  }
  match rt.get("b") {
    Some(@core.Value::Int(v)) => assert_eq(v, 10)
    _ => fail("missing b")
  }
  match rt.get("c") {
    Some(@core.Value::Int(v)) => assert_eq(v, 39)
    _ => fail("missing c")
  }
}

///|
test "xsh pipe and logical precedence" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let id = (x: Bool) -> Bool { x }\n" + "let v = true |> id && false",
  )
  match rt.get("v") {
    Some(@core.Value::Bool(v)) => assert_false(v)
    _ => fail("missing v")
  }
}

///|
test "xsh fn expression and call" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let f = (x: Int, y: Int) -> Int { add(x, y) }\nlet r = f(1, 2)",
  )
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("fn call")
  }
}

///|
test "xsh fn effect requires declaration" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let f = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int { f(y) }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected effect error")
  }
  let rt_ok = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt_ok.eval_script(
    "let f = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int with {Error} { f(y) }\n" +
    "let r = g(1)",
  )
  match rt_ok.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("effect ok")
  }
  let rt_try = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt_try.eval_script(
    "let f = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int { try { f(y) } catch { 0 } }\n" +
    "let r = g(1)",
  )
  match rt_try.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("effect try")
  }
}

///|
test "xsh higher-order effects propagate" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let apply = (f: (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }\n" +
    "let boom = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int { apply(boom, y) }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected higher-order effect error")
  }
  let rt_ok = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt_ok.eval_script(
    "let apply = (f: (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }\n" +
    "let boom = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int with {Error} { apply(boom, y) }\n" +
    "let r = g(2)",
  )
  match rt_ok.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("expected higher-order ok")
  }
}

///|
test "xsh fn labeled and optional args" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let f = (x: Int, y~: String, z?: Bool) { y }\nlet a = f(1, y=\"ok\")",
  )
  match rt.get("a") {
    Some(@core.Value::String(v)) => assert_eq(v, "ok")
    _ => fail("labeled arg")
  }
  let _ = rt.eval_script(
    "let g = (z?: Bool) { z }\nlet n = g()\nlet s = g(z=true)",
  )
  match rt.get("n") {
    Some(@core.Value::Record(map)) =>
      match map.get("None") {
        Some(@core.Value::Unit) => ()
        _ => fail("optional none")
      }
    _ => fail("optional none")
  }
  match rt.get("s") {
    Some(@core.Value::Record(map)) =>
      match map.get("Some") {
        Some(@core.Value::Bool(v)) => assert_true(v)
        _ => fail("optional some")
      }
    _ => fail("optional some")
  }
}

///|
test "xsh stdout permission requires effect" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit { do { sh(\"ls\") } }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected stdout effect error")
  }
}

///|
test "xsh stdio builtins require effects" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result_stdout : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit { do { stdout_write_char(65) } }",
  )
  match result_stdout {
    Err(_) => ()
    Ok(_) => fail("expected stdout_write_char effect error")
  }
  let result_stdin : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Int { do { stdin_read_char() } }",
  )
  match result_stdin {
    Err(_) => ()
    Ok(_) => fail("expected stdin_read_char effect error")
  }
}

///|
test "xsh stdio stream builtins require effects" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result_stdout : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit { do { stdout_write_stream(\"hi\") } }",
  )
  match result_stdout {
    Err(_) => ()
    Ok(_) => fail("expected stdout_write_stream effect error")
  }
  let result_stdin : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> String { do { stdin_read_stream(8) } }",
  )
  match result_stdin {
    Err(_) => ()
    Ok(_) => fail("expected stdin_read_stream effect error")
  }
}

///|
test "xsh string_from_char_code and stdio eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let a = string_from_char_code(65)\n" +
    "let readc = () -> Int with {Stdin} { do { stdin_read_char() } }\n" +
    "let writec = (x: Int) -> Unit with {Stdout} { do { stdout_write_char(x) } }\n" +
    "let b = readc()\n" +
    "let c = writec(66)\n" +
    "let d = string_concat(a, string_from_char_code(66))\n" +
    "d",
  )
  match result {
    Err(e) => fail(e.to_string())
    Ok(r) => assert_eq(r.effects.length(), 2)
  }
  match rt.get("a") {
    Some(@core.Value::String(v)) => assert_eq(v, "A")
    _ => fail("missing a")
  }
  match rt.get("b") {
    Some(@core.Value::Int(v)) => assert_eq(v, -1)
    _ => fail("missing b")
  }
  match rt.get("d") {
    Some(@core.Value::String(v)) => assert_eq(v, "AB")
    _ => fail("missing d")
  }
}

///|
test "xsh stdio stream builtins eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let read_chunk = () -> String with {Stdin} { do { stdin_read_stream(8) } }\n" +
    "let write_chunk = (s: String) -> Unit with {Stdout} { do { stdout_write_stream(s) } }\n" +
    "let r = read_chunk()\n" +
    "let u = write_chunk(\"hi\")\n" +
    "r",
  )
  match result {
    Err(e) => fail(e.to_string())
    Ok(r) => assert_eq(r.effects.length(), 2)
  }
  match rt.get("r") {
    Some(@core.Value::String(v)) => assert_eq(v, "")
    _ => fail("missing r")
  }
}

///|
test "xsh none is polymorphic" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let x = None\nlet f = (v: Option[Int]) { v }\nlet g = (v: Option[String]) { v }\nlet a = f(x)\nlet b = g(x)",
  )
  match result {
    Err(_) => fail("expected polymorphic None")
    Ok(_) => ()
  }
}

///|
test "xsh do value restriction allows values" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "do { let x = None\nlet f = (v: Option[Int]) { v }\nlet g = (v: Option[String]) { v }\nlet a = f(x)\nlet b = g(x) }",
  )
  match result {
    Err(_) => fail("expected value generalization in do")
    Ok(_) => ()
  }
}

///|
test "xsh do value restriction blocks expansive" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "do { let x = if true { None } else { None }\nlet f = (v: Option[Int]) { v }\nlet g = (v: Option[String]) { v }\nlet a = f(x)\nlet b = g(x) }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected monomorphic let in do")
  }
}

///|
test "xsh repl keeps type env across eval_script calls" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let add2 = (x: Int, y: Int) -> Int { add(x, y) }")
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let r = add2(1, 2)",
  )
  match result {
    Err(_) => fail("expected add2 to be callable")
    Ok(_) => ()
  }
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("missing r")
  }
}

///|
test "xsh fn missing label is type error" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let f = (y~: Int) { y }\nf(1)",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected error")
  }
}

///|
test "xsh let rec function" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let rec sum = (n: Int) -> Int { if lt(n, 1) { 0 } else { add(n, sum(sub(n, 1))) } }",
  )
  match rt.get_addr("sum") {
    Some(_) => ()
    None => fail("missing addr")
  }
  let _ = rt.eval_script("let r = sum(3)")
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 6)
    _ => fail("rec result")
  }
}

///|
test "xsh let rec requires return type" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let rec f = (x: Int) { x }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected error")
  }
}

///|
test "xsh type alias still works" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "type MyInt = Int\nlet id = (x: MyInt) -> MyInt { x }\nlet y = id(42)",
  )
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "xsh trait bound on type parameter" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|trait Eq
    #|impl Eq for Int
    #|let id = [T: Eq](x: T) -> T { x }
    #|let y = id(42)
  let _ = rt.eval_script(script)
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "xsh trait bound violation is type error" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|trait Eq
    #|impl Eq for Int
    #|let id = [T: Eq](x: T) -> T { x }
    #|id("nope")
  let result : Result[EvalResult, XshError] = try? rt.eval_script(script)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected trait bound error")
  }
}

///|
test "xsh inline param trait bound" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|trait Show
    #|impl Show for String
    #|let keep = [T](x: T: Show) -> T { x }
    #|let out = keep("ok")
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::String(v)) => assert_eq(v, "ok")
    _ => fail("expected String")
  }
}

///|
test "xsh test block ignored by eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("test { let x = 1 }")
  match rt.get("x") {
    Some(_) => fail("test block should not bind in module env")
    None => ()
  }
}

///|
test "xsh bool literal" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let t = true\nlet f = false")
  match rt.get("t") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("true")
  }
  match rt.get("f") {
    Some(@core.Value::Bool(v)) => assert_false(v)
    _ => fail("false")
  }
}

///|
test "xsh bool ops" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let a = not(true)\nlet b = and(true, false)\nlet c = or(true, false)",
  )
  match rt.get("a") {
    Some(@core.Value::Bool(v)) => assert_false(v)
    _ => fail("not")
  }
  match rt.get("b") {
    Some(@core.Value::Bool(v)) => assert_false(v)
    _ => fail("and")
  }
  match rt.get("c") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("or")
  }
}

///|
test "xsh assert" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let ok = assert(true)")
  match rt.get("ok") {
    Some(@core.Value::Unit) => ()
    _ => fail("assert true")
  }
  let result : Result[EvalResult, Error] = try? rt.eval_script("assert(false)")
  match result {
    Err(_) => ()
    Ok(_) => fail("assert false")
  }
}

///|
test "xsh boolean operators" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let a = true && false\nlet b = true || false\nlet c = !false",
  )
  match rt.get("a") {
    Some(@core.Value::Bool(v)) => assert_false(v)
    _ => fail("and and")
  }
  match rt.get("b") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("or or")
  }
  match rt.get("c") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("not")
  }
}

///|
test "xsh if expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = if true { 1 } else { 2 }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("if true")
  }
  let _ = rt.eval_script("let y = if false { 1 } else { 2 }")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("if false")
  }
}

///|
test "xsh if block scope" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = if true { let y = 1\n y } else { 2 }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("if block")
  }
  match rt.get("y") {
    Some(_) => fail("block binding leaked")
    None => ()
  }
}

///|
test "xsh block expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = { let y = 3\n y }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("block expr")
  }
  match rt.get("y") {
    Some(_) => fail("block binding leaked")
    None => ()
  }
}

///|
test "xsh array and map literals" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let a = [1, 2, 3]")
  match rt.get("a") {
    Some(@core.Value::Array(values)) => {
      assert_eq(values.length(), 3)
      match values[0] {
        @core.Value::Int(v) => assert_eq(v, 1)
        _ => fail("array[0]")
      }
    }
    _ => fail("array literal")
  }
  let _ = rt.eval_script("let m = map { a: 1, \"b\": 2 }")
  match rt.get("m") {
    Some(@core.Value::Map(map)) => {
      match map.get("a") {
        Some(@core.Value::Int(v)) => assert_eq(v, 1)
        _ => fail("map a")
      }
      match map.get("b") {
        Some(@core.Value::Int(v)) => assert_eq(v, 2)
        _ => fail("map b")
      }
    }
    _ => fail("map literal")
  }
}

///|
test "xsh match expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 2 { 1 => 10, 2 => 20, _ => 0 }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 20)
    _ => fail("match int")
  }
  let _ = rt.eval_script("let y = match true { true => 1, _ => 0 }")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("match bool")
  }
}

///|
test "xsh if else expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = if true {1} else 2")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("if true")
  }
  let _ = rt.eval_script("let y = if false {1} else 2")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("if false")
  }
}

///|
test "xsh binary operators" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = 1 + 2 * 3")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 7)
    _ => fail("binary ops")
  }
  let _ = rt.eval_script("let y = 8 - 3 * 2")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("binary ops sub")
  }
  let _ = rt.eval_script("let z = 8 / 2 + 1")
  match rt.get("z") {
    Some(@core.Value::Int(v)) => assert_eq(v, 5)
    _ => fail("binary ops div")
  }
  let _ = rt.eval_script("let w = 8/2+1\nlet m = 8-3*2")
  match rt.get("w") {
    Some(@core.Value::Int(v)) => assert_eq(v, 5)
    _ => fail("binary ops div no space")
  }
  match rt.get("m") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("binary ops sub no space")
  }
}

///|
test "xsh comparison operators" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let a = 1 == 1\nlet b = 1 != 2\nlet c = 1 < 2\nlet d = 2 <= 2\nlet e = 3 > 2\nlet f = 2 >= 2",
  )
  match rt.get("a") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("eqeq")
  }
  match rt.get("b") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("neq")
  }
  match rt.get("c") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("lt")
  }
  match rt.get("d") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("lte")
  }
  match rt.get("e") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("gt")
  }
  match rt.get("f") {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("gte")
  }
}

///|
test "xsh ctor match" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let v = Ok(1)")
  let _ = rt.eval_script("let r = match v { Ok(x) => 1, Err => 0 }")
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("match ok")
  }
  let _ = rt.eval_script("let n = Err")
  let _ = rt.eval_script("let r2 = match n { Ok(x) => 1, Err => 0 }")
  match rt.get("r2") {
    Some(@core.Value::Int(v)) => assert_eq(v, 0)
    _ => fail("match none")
  }
}

///|
test "xsh type def and ctor call" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "enum Result[T] { Ok(T), Err }\ntype IntResult = Result[Int]",
  )
  let _ = rt.eval_script(
    "let f = (x: IntResult) -> Int { match x { Ok(v) => v, Err => 0 } }",
  )
  let _ = rt.eval_script("let r = f(Ok(2))")
  match rt.get("r") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("type def call")
  }
}

///|
test "xsh match exhaustiveness for type def" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "enum Result[T] { Ok(T), Err }\nlet x = match Ok(1) { Ok(v) => v }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected exhaustiveness error")
  }
}

///|
test "xsh match bind pattern" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 3 { v => add(v, 1) }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 4)
    _ => fail("match bind")
  }
}

///|
test "xsh match tuple and record patterns" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match (1, 2) { (a, b) => add(a, b), _ => 0 }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("match tuple")
  }
  let _ = rt.eval_script(
    "let y = match record { a: 1, b: 2 } { record { a: v } => v, _ => 0 }",
  )
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("match record")
  }
}

///|
test "xsh match guard" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 2 { v if lt(v, 2) => 1, _ => 9 }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 9)
    _ => fail("guard false")
  }
  let _ = rt.eval_script("let y = match 1 { v if lt(v, 2) => 1, _ => 9 }")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("guard true")
  }
}

///|
test "xsh effect requires do" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script("sh(\"ls\")")
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

///|
test "xsh builder requires do" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let b = array_builder()",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

///|
test "xsh array builder freeze snapshot" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let a = do { let b = array_builder()\narray_builder_push(b, 1)\nlet x = array_builder_freeze(b)\narray_builder_push(b, 2)\nlet y = array_builder_freeze(b)\n(x, y) }",
  )
  match rt.get("a") {
    Some(@core.Value::Tuple(items)) =>
      if items.length() != 2 {
        fail("tuple size")
      } else {
        match (items[0], items[1]) {
          (@core.Value::Array(xs), @core.Value::Array(ys)) => {
            assert_eq(xs.length(), 1)
            assert_eq(ys.length(), 2)
            match (xs[0], ys[0], ys[1]) {
              (@core.Value::Int(a0), @core.Value::Int(b0), @core.Value::Int(b1)) => {
                assert_eq(a0, 1)
                assert_eq(b0, 1)
                assert_eq(b1, 2)
              }
              _ => fail("array contents")
            }
          }
          _ => fail("array freeze")
        }
      }
    _ => fail("missing a")
  }
}

///|
test "xsh map builder freeze snapshot" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "let m = do { let b = map_builder()\nmap_builder_set(b, \"a\", 1)\nlet x = map_builder_freeze(b)\nmap_builder_set(b, \"b\", 2)\nlet y = map_builder_freeze(b)\n(x, y) }",
  )
  match rt.get("m") {
    Some(@core.Value::Tuple(items)) =>
      if items.length() != 2 {
        fail("tuple size")
      } else {
        match (items[0], items[1]) {
          (@core.Value::Map(xs), @core.Value::Map(ys)) => {
            match (xs.get("a"), xs.get("b")) {
              (Some(@core.Value::Int(v)), None) => assert_eq(v, 1)
              _ => fail("map snapshot a")
            }
            match (ys.get("a"), ys.get("b")) {
              (Some(@core.Value::Int(a0)), Some(@core.Value::Int(b0))) => {
                assert_eq(a0, 1)
                assert_eq(b0, 2)
              }
              _ => fail("map snapshot b")
            }
          }
          _ => fail("map freeze")
        }
      }
    _ => fail("missing m")
  }
}

///|
test "xsh pure cache snapshot" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let a = path(\"/a\")")
  let _ = rt.eval_script("let b = path(\"/a\")")
  assert_eq(rt.pure_cache_len(), 1)
  let snap = rt.pure_cache_snapshot()
  let rt2 = Runtime::new(@capability.CapabilitySet::new())
  rt2.load_pure_cache(snap)
  assert_eq(rt2.pure_cache_len(), 1)
}

///|
test "xsh compile ignores test block" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\ntest { let y = 2 }")
  db.set_source("plain", "let x = 1")
  let compiled_with = compile_module(db, "main")
  let compiled_plain = compile_module(db, "plain")
  assert_eq(compiled_with.ir, compiled_plain.ir)
  assert_eq(compiled_with.ir_hash, compiled_plain.ir_hash)
}

///|
test "xsh test runner report" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("let x = 1\ntest { let y = x }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 0)
}

///|
test "xsh test cache invalidates on update" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report1 = rt.run_script_tests(
    "let f = (x: Int) { x }\n" +
    "test { if eq(f(1), 1) { 0 } else { div(1, 0) } }",
  )
  assert_eq(report1.failed, 0)
  let _ = rt.eval_script("let f = (x: Int) { add(x, 1) }")
  let report2 = rt.run_script_tests(
    "test { if eq(f(1), 1) { 0 } else { div(1, 0) } }",
  )
  assert_eq(report2.failed, 1)
}

///|
test "xsh test runner failure" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("test { do { sh(\"ls\") } }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 0)
  assert_eq(report.failed, 1)
  assert_eq(report.failures.length(), 1)
}
