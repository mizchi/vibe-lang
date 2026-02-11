///|
/// Integration test for import parsing
fn register_import_modules(
  rt : Runtime,
  db : XshDb,
  path : String,
  visited : Map[String, Bool],
  path_to_hash : Map[String, String],
) -> Unit {
  if visited.contains(path) {
    return
  }
  visited[path] = true
  let imports = db.imports(path)
  for imp in imports {
    match imp.hash {
      Some(hash) => {
        path_to_hash[imp.path] = hash
        let ast = db.ast_with_hash_imports(imp.path)
        rt.register_module(hash, ast)
        register_import_modules(rt, db, imp.path, visited, path_to_hash)
      }
      None => ()
    }
  }
}

///|
test "xsh integration import parsing" {
  let db = XshDb::new()
  let lib_source = "export let value = 7"
  let main_source = "use ./lib.xsh { value }\nlet x = 1"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_hash = @core.git_blob_hash_string(lib_source)
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  // Note: import bindings are not yet resolved, just check parsing works
}

///|
test "xsh integration hash import parsing" {
  let db = XshDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  let main_source = "use #\{import_hash} { value }\nlet x = value"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
}

///|
test "xsh integration version import parsing" {
  let db = XshDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./lib.xsh", lib_source)
  db.set_version_ref("main", import_hash)
  db.set_source("main", "use version@main { value }\nlet x = value")
  let compiled = compile_module(db, "main")
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  match compiled.ast.stmts[0] {
    @core.Stmt::Import(source~, ..) =>
      match source {
        @core.ModuleRef::Hash(hash~) => assert_eq(hash, import_hash)
        _ => fail("version import should normalize to hash ref")
      }
    _ => fail("expected import stmt")
  }
}

///|
test "xsh integration symbol import parsing" {
  let db = XshDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./lib.xsh", lib_source)
  db.set_symbol_ref("std/math", import_hash)
  db.set_source("main", "use symbol@std/math { value }\nlet x = value")
  let compiled = compile_module(db, "main")
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  match compiled.ast.stmts[0] {
    @core.Stmt::Import(source~, ..) =>
      match source {
        @core.ModuleRef::Hash(hash~) => assert_eq(hash, import_hash)
        _ => fail("symbol import should normalize to hash ref")
      }
    _ => fail("expected import stmt")
  }
}

///|
test "xsh integration import alias forwards generic helper" {
  let db = XshDb::new()
  let lib_source =
    #|let option_unwrap_or = [T](opt: Option[T], fallback: T) -> T {
    #|  match opt { Some(v) => v, _ => fallback }
    #|}
    #|export let unwrap_or = [T](opt: Option[T], fallback: T) -> T {
    #|  option_unwrap_or(opt, fallback)
    #|}
  let main_source = "use ./lib.xsh { unwrap_or }\nunwrap_or(Some(5), 0)"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 5)
    _ => fail("expected Int(5)")
  }
}

///|
test "xsh integration cross-module trait-bound eq" {
  let db = XshDb::new()
  let lib_source =
    #|export trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.xsh { Eq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration cross-module option_equals" {
  let db = XshDb::new()
  let lib_source =
    #|export trait Eq
    #|impl Eq for Int
    #|impl [T: Eq] Eq for Option[T]
    #|export let option_equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool {
    #|  match (a, b) {
    #|    (Some(x), Some(y)) => x == y,
    #|    (None, None) => true,
    #|    _ => false
    #|  }
    #|}
  let main_source = "use ./lib.xsh { Eq, option_equals }\noption_equals(Some(1), Some(1))"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration sealed exported trait rejects external impl" {
  let db = XshDb::new()
  let lib_source = "export trait Eq"
  let main_source = "use ./lib.xsh { Eq }\nimpl Eq for String"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected sealed trait error")
    Err(err) => assert_true(err.to_string().contains("trait is sealed: Eq"))
  }
}

///|
test "xsh integration export open trait allows external impl" {
  let db = XshDb::new()
  let lib_source = "export open trait Eq"
  let main_source =
    #|use ./lib.xsh { Eq }
    #|impl Eq for String
    #|let same = [T: Eq](a: T, b: T) -> Bool { a == b }
    #|same("a", "a")
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration trait bound requires explicit trait import" {
  let db = XshDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.xsh { cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected unknown trait import error")
    Err(err) => assert_true(err.to_string().contains("Eq"))
  }
}

///|
test "xsh integration explicit trait import enables trait-bounded call" {
  let db = XshDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.xsh { Eq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration imported subtrait keeps supertrait relation" {
  let db = XshDb::new()
  let lib_source =
    #|export open trait Eq
    #|export open trait Ord: Eq
    #|impl Ord for Int
  let main_source =
    #|use ./lib.xsh { Ord }
    #|let same = [T: Ord](a: T, b: T) -> Bool { a == b }
    #|same(1, 1)
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration trait alias import satisfies imported bound" {
  let db = XshDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source =
    #|use ./lib.xsh { Eq as Equality, cmp_eq }
    #|cmp_eq("a", "a")
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration trait alias keeps supertrait chain" {
  let db = XshDb::new()
  let lib_source =
    #|export open trait Eq
    #|export open trait Ord: Eq
    #|impl Ord for Int
    #|export let same_ord = [T: Ord](a: T, b: T) -> Bool { a == b }
  let main_source =
    #|use ./lib.xsh { Eq as Equality, Ord as Ordering, same_ord }
    #|let same = [T: Ordering](a: T, b: T) -> Bool { a == b }
    #|same(1, 1) && same_ord(1, 1)
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Bool(v)) => assert_true(v)
    _ => fail("expected Bool(true)")
  }
}

///|
test "xsh integration imported suberror can be raised as Error" {
  let db = XshDb::new()
  let lib_source = "export suberror AppError(String);"
  let main_source =
    #|use ./lib.xsh { AppError }
    #|let fail = () -> Unit with {Error} {
    #|  raise AppError("boom")
    #|}
    #|let run = () -> String {
    #|  try { fail(); "ok" } catch { "caught" }
    #|}
    #|run()
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::String(v)) => assert_eq(v, "caught")
    _ => fail("expected String(\"caught\")")
  }
}

///|
test "xsh integration module-qualified import namespace" {
  let db = XshDb::new()
  let lib_source =
    #|export module math {
    #|  export let inc = (x: Int) -> Int { add(x, 1) }
    #|}
  let main_source =
    #|use ./lib.xm { module math }
    #|math::inc(41)
  db.set_source("./lib.xm", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int(42)")
  }
}

///|
test "xsh integration module-qualified import accepts alias" {
  let db = XshDb::new()
  db.set_source(
    "./lib.xm", "export module math { export let inc = (x: Int) -> Int { add(x, 1) } }",
  )
  db.set_source("main", "use ./lib.xm { module math as m }\nm::inc(41)")
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_import_modules(rt, db, "main", visited, path_to_hash)
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let result = rt.eval_module(converted_ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int(42)")
  }
}

///|
test "xsh integration module-qualified import rejects .xsh source" {
  let db = XshDb::new()
  db.set_source(
    "./lib.xsh", "export module math { export let inc = (x: Int) -> Int { add(x, 1) } }",
  )
  db.set_source("main", "use ./lib.xsh { module math }\nmath::inc(1)")
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected import error for .xsh module namespace import")
    Err(err) =>
      assert_true(
        err
        .to_string()
        .contains("module import is only supported for .xm source"),
      )
  }
}

///|
test "xsh integration module-qualified import rejects member path" {
  let db = XshDb::new()
  db.set_source(
    "./lib.xsh", "export module math { export let inc = (x: Int) -> Int { add(x, 1) } }",
  )
  db.set_source(
    "main", "use ./lib.xsh { module math::inc }\nmath::inc(1)",
  )
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected parse error for module member import")
    Err(err) =>
      assert_true(
        err.to_string().contains("`use <module-ref> { module foo }`"),
      )
  }
}
