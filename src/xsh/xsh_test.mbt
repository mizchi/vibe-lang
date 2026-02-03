///| Tests for xsh prototype

test "xsh detection" {
  assert_true(is_xsh_script("let x = 1"))
  assert_true(is_xsh_script("flake { }"))
  assert_true(is_xsh_script("alias foo = bar#abc"))
  assert_false(is_xsh_script("echo hello"))
}

test "xsh eval path normalization" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let p = path(\"a/../b\")")
  match rt.get("p") {
    Some(Value::Path(p)) => assert_eq(p.as_string(), "/b")
    _ => fail("expected path value")
  }
}

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

test "xsh alias statement" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("alias foo = bar#abc")
  match rt.get_alias("foo") {
    Some(r) => {
      assert_eq(r.name, "bar")
      assert_eq(r.hash_prefix, Some("abc"))
    }
    None => fail("missing alias")
  }
}

test "xsh ripple db" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1")
  let ast = db.ast("main")
  assert_eq(ast.stmts.length(), 1)
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

test "xsh import hashes" {
  let db = XshDb::new()
  db.set_source("main", "import foo.xsh\nlet x = 1")
  db.set_source("foo.xsh", "let y = 2")
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  match imp.hash {
    Some(h) => {
      assert_eq(h, git_blob_hash_string("let y = 2"))
      assert_eq(imp.module_ref, Some(module_ref_from_hash(h)))
      assert_eq(imp.alias_name, "foo")
    }
    None => fail("missing hash")
  }
}

test "xsh import alias resolution" {
  let db = XshDb::new()
  db.set_source("main", "import foo.xsh")
  db.set_source("foo.xsh", "let y = 2")
  let aliases = db.import_aliases("main")
  let resolved = resolve_qualified("foo.bar", aliases)
  match aliases.get("foo") {
    Some(r) => assert_eq(resolved, r.name + "/bar")
    None => fail("missing alias")
  }
}

test "xsh compile and run" {
  let db = XshDb::new()
  db.set_source("main", "import foo.xsh\nlet x = 1\nfoo.bar")
  db.set_source("foo.xsh", "let y = 2")
  let compiled = compile_module(db, "main")
  let import_hash = git_blob_hash_string("let y = 2")
  let import_ref = module_ref_from_hash(import_hash)
  assert_true(compiled.ir.contains(import_ref + "/bar"))
  assert_eq(compiled.module_ref, module_ref_from_hash(compiled.ir_hash))
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.run_compiled(compiled)
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("missing x binding")
  }
}

test "xsh builtin add/sub/eq/lt" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let a = add(1, 2)\nlet b = sub(5, 3)\nlet c = eq(2, 2)\nlet d = lt(1, 2)")
  match rt.get("a") {
    Some(Value::Int(v)) => assert_eq(v, 3)
    _ => fail("add")
  }
  match rt.get("b") {
    Some(Value::Int(v)) => assert_eq(v, 2)
    _ => fail("sub")
  }
  match rt.get("c") {
    Some(Value::Bool(v)) => assert_true(v)
    _ => fail("eq")
  }
  match rt.get("d") {
    Some(Value::Bool(v)) => assert_true(v)
    _ => fail("lt")
  }
}

test "xsh test block ignored by eval" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("test { let x = 1 }")
  match rt.get("x") {
    Some(_) => fail("test block should not bind in module env")
    None => ()
  }
}

test "xsh bool literal" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let t = true\nlet f = false")
  match rt.get("t") {
    Some(Value::Bool(v)) => assert_true(v)
    _ => fail("true")
  }
  match rt.get("f") {
    Some(Value::Bool(v)) => assert_false(v)
    _ => fail("false")
  }
}

test "xsh bool ops" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let a = not(true)\nlet b = and(true, false)\nlet c = or(true, false)")
  match rt.get("a") {
    Some(Value::Bool(v)) => assert_false(v)
    _ => fail("not")
  }
  match rt.get("b") {
    Some(Value::Bool(v)) => assert_false(v)
    _ => fail("and")
  }
  match rt.get("c") {
    Some(Value::Bool(v)) => assert_true(v)
    _ => fail("or")
  }
}

test "xsh if expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = if true { 1 } else { 2 }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("if true")
  }
  let _ = rt.eval_script("let y = if false { 1 } else { 2 }")
  match rt.get("y") {
    Some(Value::Int(v)) => assert_eq(v, 2)
    _ => fail("if false")
  }
}

test "xsh if block scope" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = if true { let y = 1\n y } else { 2 }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("if block")
  }
  match rt.get("y") {
    Some(_) => fail("block binding leaked")
    None => ()
  }
}

test "xsh block expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = { let y = 3\n y }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 3)
    _ => fail("block expr")
  }
  match rt.get("y") {
    Some(_) => fail("block binding leaked")
    None => ()
  }
}

test "xsh match expression" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 2 { 1 => 10, 2 => 20, _ => 0 }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 20)
    _ => fail("match int")
  }
  let _ = rt.eval_script("let y = match true { true => 1, _ => 0 }")
  match rt.get("y") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("match bool")
  }
}

test "xsh match bind pattern" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 3 { v => add(v, 1) }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 4)
    _ => fail("match bind")
  }
}

test "xsh match tuple and record patterns" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match (1, 2) { (a, b) => add(a, b), _ => 0 }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 3)
    _ => fail("match tuple")
  }
  let _ = rt.eval_script("let y = match record { a: 1, b: 2 } { record { a: v } => v, _ => 0 }")
  match rt.get("y") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("match record")
  }
}

test "xsh match guard" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.eval_script("let x = match 2 { v if lt(v, 2) => 1, _ => 9 }")
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 9)
    _ => fail("guard false")
  }
  let _ = rt.eval_script("let y = match 1 { v if lt(v, 2) => 1, _ => 9 }")
  match rt.get("y") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("guard true")
  }
}

test "xsh effect requires do" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result : Result[EvalResult, XshError] = try? rt.eval_script("sh(\"ls\")")
  match result {
    Err(_) => ()
    Ok(_) => fail("expected type error")
  }
}

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

test "xsh compile ignores test block" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\ntest { let y = 2 }")
  db.set_source("plain", "let x = 1")
  let compiled_with = compile_module(db, "main")
  let compiled_plain = compile_module(db, "plain")
  assert_eq(compiled_with.ir, compiled_plain.ir)
  assert_eq(compiled_with.ir_hash, compiled_plain.ir_hash)
}

test "xsh test runner report" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("let x = 1\ntest { let y = x }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 0)
}

test "xsh test runner failure" {
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let report = rt.run_script_tests("test { do { sh(\"ls\") } }")
  assert_eq(report.total, 1)
  assert_eq(report.passed, 0)
  assert_eq(report.failed, 1)
  assert_eq(report.failures.length(), 1)
}
