///|
/// Tests for vibe prototype
test "vibe detection" {
  assert_true(is_vibe_script("let x = 1"))
  assert_false(is_vibe_script("flake { }"))
  assert_false(is_vibe_script("alias foo = bar#abc"))
  assert_true(is_vibe_script("enum Option[T] { Some(T); None }"))
  assert_false(is_vibe_script("echo hello"))
}

///|
test "vibe parser mode dispatch is explicit" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let ok : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let x = 1",
    ParserMode::XshMode,
  )
  match ok {
    Ok(_) => ()
    Err(err) => fail("unexpected vibe mode error: " + err.to_string())
  }
}

///|
test "vibe posix mode command pipeline with where" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let run = () -> Array[String] with {Stdout} {\n" +
    "  do {\n" +
    "    ls |> where((line: String) -> Bool { string_contains(line, \"x\") })\n" +
    "  }\n" +
    "}\n" +
    "let out = run()",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected posix mode error: " + err.to_string())
    Ok(eval_result) => {
      assert_eq(eval_result.effects.length(), 2)
      match eval_result.effects[0] {
        Effect::PosixDesugar(note) => {
          assert_true(note.contains("ls"))
          assert_true(note.contains("sh_lines(\"ls\")"))
        }
        _ => fail("expected posix desugar note")
      }
      match eval_result.effects[1] {
        Effect::ShellExec(cmd) => assert_eq(cmd, "ls")
        _ => fail("expected shell effect")
      }
    }
  }
  match rt.get("out") {
    Some(@core.Value::Array(_)) => ()
    _ => fail("expected out array")
  }
}

///|
test "vibe posix mode keeps bound identifiers" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let ls = [\"a\", \"bb\"]\n" +
    "let ys = where(ls, (line: String) -> Bool { string_contains(line, \"b\") })\n" +
    "let n = array_length(ys)",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 0)
  }
  match rt.get("n") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("expected filtered size")
  }
}

///|
test "vibe where prelude filters strings" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let xs = [\"a\", \"bb\", \"ccc\"]\n" +
    "let ys = where(xs, (line: String) -> Bool { string_contains(line, \"b\") })\n" +
    "let n = array_length(ys)",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(_) => ()
  }
  match rt.get("n") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("expected filtered size")
  }
}

///|
test "vibe sh_lines returns command output lines" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Array[String] with {Stdout} { do { sh_lines(\"echo hello\") } }\n" +
    "let lines = run()\n" +
    "let line0 = array_get(lines, 0)\n" +
    "let n = array_length(lines)",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 1)
  }
  match rt.get("line0") {
    Some(@core.Value::String(line)) => assert_eq(line, "hello")
    _ => fail("expected line0")
  }
  match rt.get("n") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("expected line count")
  }
}

///|
test "vibe eval path normalization" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let p = path(\"a/../b\")")
  match rt.get("p") {
    Some(@core.Value::Path(p)) => assert_eq(p.as_string(), "/b")
    _ => fail("expected path value")
  }
}

///|
test "vibe store gc" {
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
test "vibe alias statement is removed" {
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
test "vibe flake statement is removed" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script("flake { }")
  match result {
    Err(_) => ()
    _ => fail("expected parse error")
  }
}

///|
test "vibe alias can be used as identifier" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let alias = 41\nlet y = alias + 1")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "vibe flake can be used as identifier" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let flake = 41\nlet y = flake + 1")
  match rt.get("y") {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int")
  }
}

///|
test "vibe compile simple" {
  // Test compilation without imports
  let db = VibeDb::new()
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
test "vibe prelude add/sub/eq/lt" {
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
test "vibe float and double ops" {
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
test "vibe method call and pipe" {
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
test "vibe prelude to_string works with parenthesized literal method call" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let a = to_string(3.14)
    #|let b = 3.14.to_string()
    #|let c = (3.14).to_string()
    #|let d = true.to_string()
  let _ = rt.eval_script(script)
  match rt.get("a") {
    Some(@core.Value::String(v)) => assert_eq(v, "3.14")
    _ => fail("missing a")
  }
  match rt.get("b") {
    Some(@core.Value::String(v)) => assert_eq(v, "3.14")
    _ => fail("missing b")
  }
  match rt.get("c") {
    Some(@core.Value::String(v)) => assert_eq(v, "3.14")
    _ => fail("missing c")
  }
  match rt.get("d") {
    Some(@core.Value::String(v)) => assert_eq(v, "true")
    _ => fail("missing d")
  }
}

///|
test "vibe char literal" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let a = 'a'\nlet b = '\\n'\nlet c = '\\''",
  )
  match result {
    Err(e) => fail(e.to_string())
    Ok(_) => ()
  }
  match rt.get("a") {
    Some(@core.Value::Char(v)) => assert_eq(v, 'a')
    _ => fail("missing a")
  }
  match rt.get("b") {
    Some(@core.Value::Char(v)) => assert_eq(v, '\n')
    _ => fail("missing b")
  }
  match rt.get("c") {
    Some(@core.Value::Char(v)) => assert_eq(v, '\'')
    _ => fail("missing c")
  }
}

///|
test "vibe pipe and logical precedence" {
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
test "vibe fn expression and call" {
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
test "vibe fn effect requires declaration" {
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
test "vibe declared effects allow direct builtin call without do" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit with {Stdout} { sh(\"ls\") }",
  )
  match result {
    Ok(_) => ()
    Err(_) => fail("expected declared effect to allow direct builtin call")
  }
}

///|
test "vibe do does not grant missing function effect declaration" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let f = (x: Int) -> Int with {Error} { x }\n" +
    "let g = (y: Int) -> Int { do { f(y) } }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected missing effect declaration error")
  }
}

///|
test "vibe higher-order effects propagate" {
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
test "vibe fn labeled and optional args" {
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
test "vibe stdout permission requires effect" {
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
test "vibe sleep requires runtime capability" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::new(),
    RuntimeFeatureFlags::unstable_async_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit with {Async} { do { sleep(1) } }\n" + "run()",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("clock_read"))
    Ok(_) => fail("expected sleep capability error")
  }
}

///|
test "vibe sleep succeeds with developer capability" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_async_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit with {Async} { do { sleep(1) } }\n" + "run()",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 0)
  }
}

///|
test "vibe sleep requires unstable async flag" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Unit with {Async} { do { sleep(1) } }\n" + "run()",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("--unstable-async"))
    Ok(_) => fail("expected unstable async gate error")
  }
}

///|
test "vibe await requires unstable async flag" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Int with {Async} { await 1 }\n" + "run()",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("--unstable-async"))
    Ok(_) => fail("expected unstable async gate error")
  }
}

///|
test "vibe await works when unstable async is enabled" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_async_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let run = () -> Int with {Async} { await 1 }\n" + "run()",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::Int(v)) => assert_eq(v, 1)
        _ => fail("expected last int value")
      }
  }
}

///|
test "vibe runtime feature flags default to stable" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let flags = rt.feature_flags()
  assert_false(flags.is_unstable_async_enabled())
  assert_false(flags.is_unstable_threads_enabled())
}

///|
test "vibe runtime feature flags enable threads when requested" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::new(),
    RuntimeFeatureFlags::unstable_threads_only(),
  )
  let flags = rt.feature_flags()
  assert_false(flags.is_unstable_async_enabled())
  assert_true(flags.is_unstable_threads_enabled())
}

///|
test "vibe let underscore can be reused and is not bound" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let _ = 1\n" + "let _ = 2\n" + "42",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::Int(v)) => assert_eq(v, 42)
        _ => fail("expected last int value")
      }
  }
  match rt.get("_") {
    Some(_) => fail("`_` must not be stored in runtime env")
    None => ()
  }
  match rt.type_env().get("_") {
    Some(_) => fail("`_` must not be stored in type env")
    None => ()
  }
}

///|
test "vibe let rec underscore is rejected" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let rec _ = (x: Int) -> Int { x }",
  )
  match result {
    Err(err) =>
      assert_true(
        err.to_string().contains("wildcard binding cannot be recursive"),
      )
    Ok(_) => fail("expected let rec _ to fail")
  }
}

///|
test "vibe threads probe builtin requires unstable threads flag" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "threads_probe_wat()",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("--unstable-threads"))
    Ok(_) => fail("expected unstable threads gate error")
  }
}

///|
test "vibe threads probe builtin works when unstable threads is enabled" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_threads_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "threads_probe_wat()",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::String(wat)) =>
          assert_true(wat.contains("(import \"wasi\" \"thread-spawn\""))
        _ => fail("expected wat string")
      }
  }
}

///|
test "vibe threads runtime hints requires unstable threads flag" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "threads_runtime_hints()",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("--unstable-threads"))
    Ok(_) => fail("expected unstable threads gate error")
  }
}

///|
test "vibe threads runtime hints returns recommended flags" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_threads_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "threads_runtime_hints()",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::Record(fields)) => {
          match fields.get("wasm_env") {
            Some(@core.Value::String(v)) =>
              assert_eq(v, "threads=y shared-memory=y")
            _ => fail("expected wasm_env string")
          }
          match fields.get("wasi_env") {
            Some(@core.Value::String(v)) => assert_eq(v, "threads=y")
            _ => fail("expected wasi_env string")
          }
        }
        _ => fail("expected record value")
      }
  }
}

///|
test "vibe threads runtime queue builtins require unstable threads flag" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let ch = threads_channel_new(1)\n" + "threads_send(ch, \"hello\")",
  )
  match result {
    Err(err) => assert_true(err.to_string().contains("--unstable-threads"))
    Ok(_) => fail("expected unstable threads gate error")
  }
}

///|
test "vibe threads runtime queue builtins work when unstable threads is enabled" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_threads_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let ch = threads_channel_new(2)\n" +
    "let task = threads_spawn(\"worker\", ch)\n" +
    "let ok = threads_send(ch, \"hello\")\n" +
    "let msg = threads_recv(ch)\n" +
    "let status = threads_wait(task)\n" +
    "ok && msg == \"hello\" && status == 0",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::Bool(v)) => assert_true(v)
        _ => fail("expected bool result")
      }
  }
}

///|
test "vibe threads send returns false when channel is full" {
  let rt = Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    RuntimeFeatureFlags::unstable_threads_only(),
  )
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let ch = threads_channel_new(1)\n" +
    "let first = threads_send(ch, \"a\")\n" +
    "let second = threads_send(ch, \"b\")\n" +
    "let got = threads_recv(ch)\n" +
    "first && not(second) && got == \"a\"",
  )
  match result {
    Err(err) => fail(err.to_string())
    Ok(eval_result) =>
      match eval_result.last {
        Some(@core.Value::Bool(v)) => assert_true(v)
        _ => fail("expected bool result")
      }
  }
}

///|
test "vibe stdio builtins require effects" {
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
test "vibe stdio stream builtins require effects" {
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
test "vibe string_from_char_code and stdio eval" {
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
test "vibe char literal and char conversion builtins eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let a: Char = 'A'\n" +
    "let b = char_to_int(a)\n" +
    "let c = char_from_int(98)\n" +
    "let d = __to_string(c)\n" +
    "match c {\n" +
    "  'b' => b,\n" +
    "  _ => 0\n" +
    "}",
  )
  match result {
    Err(e) => fail(e.to_string())
    Ok(r) =>
      match r.last {
        Some(@core.Value::Int(v)) => assert_eq(v, 65)
        _ => fail("expected Int(65)")
      }
  }
  match rt.get("c") {
    Some(@core.Value::Char(v)) => assert_eq(v, 'b')
    _ => fail("missing c")
  }
  match rt.get("d") {
    Some(@core.Value::String(v)) => assert_eq(v, "b")
    _ => fail("missing d")
  }
}

///|
test "vibe stdio stream builtins eval" {
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
test "vibe none is polymorphic" {
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
test "vibe do value restriction allows values" {
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
test "vibe do value restriction blocks expansive" {
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
test "vibe repl keeps type env across eval_script calls" {
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
test "vibe fn missing label is type error" {
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
test "vibe let rec function" {
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
test "vibe recursion depth regression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let rec sum = (n: Int) -> Int {
    #|  if eq(n, 0) {
    #|    0
    #|  } else {
    #|    add(n, sum(sub(n, 1)))
    #|  }
    #|}
    #|let out = sum(40)
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::Int(v)) => assert_eq(v, 820)
    _ => fail("expected Int")
  }
}

///|
test "vibe stack safety regression in while loop" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let run = () -> Int {
    #|  let mut i = 0
    #|  let mut acc = 0
    #|  while i < 5000 {
    #|    acc = add(acc, i)
    #|    i = add(i, 1)
    #|  }
    #|  acc
    #|}
    #|let out = run()
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::Int(v)) => assert_eq(v, 12497500)
    _ => fail("expected Int")
  }
}

///|
test "vibe while break exits loop" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let run = () -> Int {
    #|  let mut i = 0
    #|  while true {
    #|    if i == 3 {
    #|      break
    #|    } else {
    #|      i = i
    #|    }
    #|    i = add(i, 1)
    #|  }
    #|  i
    #|}
    #|let out = run()
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("expected Int(3)")
  }
}

///|
test "vibe while continue skips iteration" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let run = () -> Int {
    #|  let mut i = 0
    #|  let mut acc = 0
    #|  while i < 6 {
    #|    i = add(i, 1)
    #|    if i % 2 == 0 {
    #|      continue
    #|    } else {
    #|      acc = acc
    #|    }
    #|    acc = add(acc, i)
    #|  }
    #|  acc
    #|}
    #|let out = run()
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::Int(v)) => assert_eq(v, 9)
    _ => fail("expected Int(9)")
  }
}

///|
test "vibe break outside while is type error" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let x = break",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

///|
test "vibe continue outside while is type error" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "let x = continue",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

///|
test "vibe string concat hotspot regression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let rec repeat = (s: String, n: Int) -> String {
    #|  if eq(n, 0) {
    #|    ""
    #|  } else {
    #|    string_concat(s, repeat(s, sub(n, 1)))
    #|  }
    #|}
    #|let rec concat_loop = (s: String, i: Int) -> String {
    #|  if eq(i, 0) {
    #|    s
    #|  } else {
    #|    concat_loop(string_concat(s, "x"), sub(i, 1))
    #|  }
    #|}
    #|let base = repeat("abcdef", 20)
    #|let out = concat_loop(base, 40)
    #|let len = string_length(out)
  let _ = rt.eval_script(script)
  match rt.get("len") {
    Some(@core.Value::Int(v)) => assert_eq(v, 160)
    _ => fail("expected Int")
  }
}

///|
test "vibe let rec requires return type" {
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
test "vibe type alias still works" {
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
test "vibe trait bound on type parameter" {
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
test "vibe trait bound violation is type error" {
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
test "vibe inline param trait bound" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let script =
    #|let keep = [T](x: T: Show) -> T { x }
    #|let out = keep("ok")
  let _ = rt.eval_script(script)
  match rt.get("out") {
    Some(@core.Value::String(v)) => assert_eq(v, "ok")
    _ => fail("expected String")
  }
}

///|
test "vibe test block ignored by eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("test { let x = 1 }")
  match rt.get("x") {
    Some(_) => fail("test block should not bind in module env")
    None => ()
  }
}

///|
test "vibe bench block ignored by eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("bench { let x = 1 }")
  match rt.get("x") {
    Some(_) => fail("bench block should not bind in module env")
    None => ()
  }
}

///|
test "vibe bool literal" {
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
test "vibe bool ops" {
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
test "vibe assert" {
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
test "vibe boolean operators" {
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
test "vibe if expression" {
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
test "vibe if block scope" {
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
test "vibe block expression" {
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
test "vibe array and map literals" {
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
test "vibe match expression" {
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
test "vibe if else expression" {
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
test "vibe binary operators" {
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
test "vibe comparison operators" {
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
test "vibe ctor match" {
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
test "vibe type def and ctor call" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script(
    "enum Result[T] { Ok(T); Err }\ntype IntResult = Result[Int]",
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
test "vibe match exhaustiveness for type def" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script(
    "enum Result[T] { Ok(T); Err }\nlet x = match Ok(1) { Ok(v) => v }",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected exhaustiveness error")
  }
}

///|
test "vibe match bind pattern" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 3 { v => add(v, 1) }")
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 4)
    _ => fail("match bind")
  }
}

///|
test "vibe match tuple and record patterns" {
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
test "vibe match guard" {
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
test "vibe effect requires do" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script("sh(\"ls\")")
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

///|
test "vibe builder requires do" {
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
test "vibe array builder freeze snapshot" {
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
test "vibe map builder freeze snapshot" {
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
test "vibe pure cache snapshot" {
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
test "vibe compile ignores test block" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 1\ntest { let y = 2 }")
  db.set_source("plain", "let x = 1")
  let compiled_with = compile_module(db, "main")
  let compiled_plain = compile_module(db, "plain")
  assert_eq(compiled_with.ir, compiled_plain.ir)
  assert_eq(compiled_with.ir_hash, compiled_plain.ir_hash)
}

///|
test "vibe test runner report" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("let x = 1\ntest { let y = x }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 0)
}

///|
test "vibe test cache invalidates on update" {
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
test "vibe test runner failure" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("test { do { sh(\"ls\") } }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 0)
  assert_eq(report.failed, 1)
  assert_eq(report.failures.length(), 1)
}

///|
test "vibe bench runner report" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_benches(
    "let x = 1\nbench \"sum\" { add(x, 1) }", 1000, 10,
  )
  assert_eq(report.total, 1)
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 0)
  assert_eq(report.results.length(), 1)
  assert_eq(report.results[0].name, Some("sum"))
}

///|
test "vibe bench runner failure" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_benches("bench { do { sh(\"ls\") } }", 1, 0)
  assert_eq(report.total, 1)
  assert_eq(report.passed, 0)
  assert_eq(report.failed, 1)
  assert_eq(report.failures.length(), 1)
}

///|
test "vibe posix mode bare command desugar" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let run = () -> Array[String] with {Stdout} {\n" +
    "  do { echo }\n" +
    "}\n" +
    "let out = run()",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected error: " + err.to_string())
    Ok(eval_result) => {
      assert_true(eval_result.effects.length() >= 1)
      match eval_result.effects[0] {
        Effect::PosixDesugar(note) => {
          assert_true(note.contains("echo"))
          assert_true(note.contains("sh_lines(\"echo\")"))
        }
        _ => fail("expected posix desugar note")
      }
      match eval_result.effects[1] {
        Effect::ShellExec(cmd) => assert_eq(cmd, "echo")
        _ => fail("expected shell effect")
      }
    }
  }
  match rt.get("out") {
    Some(@core.Value::Array(_)) => ()
    _ => fail("expected out array")
  }
}

///|
test "vibe posix mode echo pipeline" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let run = () -> Array[String] with {Stdout} {\n" +
    "  do {\n" +
    "    echo |> where((line: String) -> Bool { string_contains(line, \"\") })\n" +
    "  }\n" +
    "}\n" +
    "let out = run()",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected posix mode error: " + err.to_string())
    Ok(eval_result) => {
      assert_true(eval_result.effects.length() >= 2)
      match eval_result.effects[0] {
        Effect::PosixDesugar(note) => {
          assert_true(note.contains("echo"))
          assert_true(note.contains("sh_lines(\"echo\")"))
        }
        _ => fail("expected posix desugar note for echo")
      }
      match eval_result.effects[1] {
        Effect::ShellExec(cmd) => assert_eq(cmd, "echo")
        _ => fail("expected shell effect for echo")
      }
    }
  }
}

///|
test "vibe posix mode nested scope shadows command" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let f = (ls: Array[String]) -> Int {\n" +
    "  array_length(ls)\n" +
    "}\n" +
    "let n = f([\"a\", \"b\"])",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected error: " + err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 0)
  }
  match rt.get("n") {
    Some(@core.Value::Int(v)) => assert_eq(v, 2)
    _ => fail("expected int result")
  }
}

///|
test "vibe posix mode builtin names preserved" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let x = string_concat(\"hello\", \" world\")\n" +
    "let n = array_length([1, 2, 3])",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected error: " + err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 0)
  }
  match rt.get("x") {
    Some(@core.Value::String(v)) => assert_eq(v, "hello world")
    _ => fail("expected string result")
  }
  match rt.get("n") {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("expected int result")
  }
}

///|
test "vibe posix mode unknown command error" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let run = () -> Array[String] with {Stdout} {\n" +
    "  do { zzz }\n" +
    "}\n" +
    "let out = run()",
    ParserMode::PosixMode,
  )
  match result {
    Ok(_) => fail("expected error for unknown command")
    Err(_) => ()
  }
}

///|
test "vibe posix mode multiple desugars in block" {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let run = () -> Array[String] with {Stdout} {\n" +
    "  do {\n" +
    "    let a = ls\n" +
    "    let b = echo\n" +
    "    a\n" +
    "  }\n" +
    "}\n" +
    "let out = run()",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected error: " + err.to_string())
    Ok(eval_result) => {
      let desugar_count = {
        let mut count = 0
        for effect in eval_result.effects {
          match effect {
            Effect::PosixDesugar(_) => count = count + 1
            _ => ()
          }
        }
        count
      }
      assert_eq(desugar_count, 2)
    }
  }
}

///|
test "vibe posix mode let binding prevents desugar" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script_with_mode(
    "let cat = \"meow\"\n" +
    "let out = cat",
    ParserMode::PosixMode,
  )
  match result {
    Err(err) => fail("unexpected error: " + err.to_string())
    Ok(eval_result) => assert_eq(eval_result.effects.length(), 0)
  }
  match rt.get("out") {
    Some(@core.Value::String(v)) => assert_eq(v, "meow")
    _ => fail("expected string result")
  }
}
