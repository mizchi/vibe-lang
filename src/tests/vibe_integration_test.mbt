///|
/// Integration test for import parsing
fn register_import_modules(
  rt : Runtime,
  db : VibeDb,
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
test "vibe integration import parsing" {
  let db = VibeDb::new()
  let lib_source = "export let value = 7"
  let main_source = "use ./lib.vibe { value }\nlet x = 1"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_hash = @core.git_blob_hash_string(lib_source)
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  // Note: import bindings are not yet resolved, just check parsing works
}

///|
test "vibe integration hash import parsing" {
  let db = VibeDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  let main_source = "use #\{import_hash} { value }\nlet x = value"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
}

///|
test "vibe integration version import parsing" {
  let db = VibeDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration symbol import parsing" {
  let db = VibeDb::new()
  let lib_source = "export let value = 7"
  let import_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration import alias forwards generic helper" {
  let db = VibeDb::new()
  let lib_source =
    #|let option_unwrap_or = [T](opt: Option[T], fallback: T) -> T {
    #|  match opt { Some(v) => v, _ => fallback }
    #|}
    #|export let unwrap_or = [T](opt: Option[T], fallback: T) -> T {
    #|  option_unwrap_or(opt, fallback)
    #|}
  let main_source = "use ./lib.vibe { unwrap_or }\nunwrap_or(Some(5), 0)"
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration cross-module trait-bound eq" {
  let db = VibeDb::new()
  let lib_source =
    #|export trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.vibe { Eq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration cross-module option_equals" {
  let db = VibeDb::new()
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
  let main_source = "use ./lib.vibe { Eq, option_equals }\noption_equals(Some(1), Some(1))"
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration sealed exported trait rejects external impl" {
  let db = VibeDb::new()
  let lib_source = "export trait Eq"
  let main_source = "use ./lib.vibe { Eq }\nimpl Eq for String"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected sealed trait error")
    Err(err) => assert_true(err.to_string().contains("[TROP001]"))
  }
}

///|
test "vibe integration non-exported trait rejects external impl" {
  let db = VibeDb::new()
  let lib_source = "trait Eq"
  let main_source = "use ./lib.vibe { Eq }\nimpl Eq for String"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected non-exported trait error")
    Err(err) => assert_true(err.to_string().contains("[TROP002]"))
  }
}

///|
test "vibe integration export open trait allows external impl" {
  let db = VibeDb::new()
  let lib_source = "export open trait Eq"
  let main_source =
    #|use ./lib.vibe { Eq }
    #|impl Eq for String
    #|let same = [T: Eq](a: T, b: T) -> Bool { a == b }
    #|same("a", "a")
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration trait bound requires explicit trait import" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.vibe { cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration explicit trait import enables trait-bounded call" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source = "use ./lib.vibe { Eq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration imported subtrait keeps supertrait relation" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait Eq
    #|export open trait Ord: Eq
    #|impl Ord for Int
  let main_source =
    #|use ./lib.vibe { Ord }
    #|let same = [T: Ord](a: T, b: T) -> Bool { a == b }
    #|same(1, 1)
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration trait alias import satisfies imported bound" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait Eq
    #|impl Eq for String
    #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool { a == b }
  let main_source =
    #|use ./lib.vibe { Eq as Equality, cmp_eq }
    #|cmp_eq("a", "a")
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration trait alias keeps supertrait chain" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait Eq
    #|export open trait Ord: Eq
    #|impl Ord for Int
    #|export let same_ord = [T: Ord](a: T, b: T) -> Bool { a == b }
  let main_source =
    #|use ./lib.vibe { Eq as Equality, Ord as Ordering, same_ord }
    #|let same = [T: Ordering](a: T, b: T) -> Bool { a == b }
    #|same(1, 1) && same_ord(1, 1)
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration imported suberror can be raised as Error" {
  let db = VibeDb::new()
  let lib_source = "export suberror AppError(String);"
  let main_source =
    #|use ./lib.vibe { AppError }
    #|let fail = () -> Unit with {Error} {
    #|  raise AppError("boom")
    #|}
    #|let run = () -> String {
    #|  try { fail(); "ok" } catch { "caught" }
    #|}
    #|run()
  db.set_source("./lib.vibe", lib_source)
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
test "vibe integration module-qualified import namespace" {
  let db = VibeDb::new()
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
test "vibe integration module-qualified import accepts alias" {
  let db = VibeDb::new()
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
test "vibe integration module-qualified import rejects .vibe source" {
  let db = VibeDb::new()
  db.set_source(
    "./lib.vibe", "export module math { export let inc = (x: Int) -> Int { add(x, 1) } }",
  )
  db.set_source("main", "use ./lib.vibe { module math }\nmath::inc(1)")
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected import error for .vibe module namespace import")
    Err(err) =>
      assert_true(
        err
        .to_string()
        .contains("module import is only supported for .xm source"),
      )
  }
}

///|
test "vibe integration module-qualified import rejects member path" {
  let db = VibeDb::new()
  db.set_source(
    "./lib.vibe", "export module math { export let inc = (x: Int) -> Int { add(x, 1) } }",
  )
  db.set_source("main", "use ./lib.vibe { module math::inc }\nmath::inc(1)")
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected parse error for module member import")
    Err(err) =>
      assert_true(err.to_string().contains("`use <module-ref> { module foo }`"))
  }
}
