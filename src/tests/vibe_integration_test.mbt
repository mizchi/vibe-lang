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
  let main_source = "import ./lib.vibe { value }\nlet x = 1"
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
  let main_source = "import #\{import_hash} { value }\nlet x = value"
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
  db.set_source("main", "import version@main { value }\nlet x = value")
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
  db.set_source("main", "import symbol@std/math { value }\nlet x = value")
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
  let main_source = "import ./lib.vibe { unwrap_or }\nunwrap_or(Some(5), 0)"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  rt.set_type_env(compiled.type_env)
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
test "vibe integration local declaration wins over explicit import" {
  let db = VibeDb::new()
  db.set_source("./lib.vibe", "export let abs = (x: Int) -> Int { sub(0, x) }")
  db.set_source(
    "main", "let abs = (x: Int) -> Int { add(x, 100) }\nimport ./lib.vibe { abs }\nabs(1)",
  )
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  rt.set_type_env(compiled.type_env)
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
    Some(@core.Value::Int(v)) => assert_eq(v, 101)
    _ => fail("expected Int(101)")
  }
}

///|
test "vibe integration re-export alias forwards value" {
  let db = VibeDb::new()
  db.set_source("./lib.vibe", "export let value = 7\nexport { value }\n")
  db.set_source("./facade.vibe", "export ./lib.vibe { value as number }\n")
  db.set_source("main", "import ./facade.vibe { number }\nnumber\n")
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  rt.set_type_env(compiled.type_env)
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
    Some(@core.Value::Int(v)) => assert_eq(v, 7)
    _ => fail("expected Int(7)")
  }
}

///|
test "vibe integration type namespace import auto-forwards receiver-first function" {
  let db = VibeDb::new()
  let lib_source =
    #|export enum Maybe[T] { Nope; Yep(T) }
    #|export let is_yep = [T](value: Maybe[T]) -> Bool {
    #|  match value {
    #|    Yep(_) => true,
    #|    _ => false
    #|  }
    #|}
  let main_source = "import ./lib.vibe { Maybe }\nYep(1) |> is_yep"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  db.set_source("probe", "import ./lib.vibe { Maybe }\nlet x = 1")
  let imported_env = db.types("./lib.vibe")
  assert_true(imported_env.get_scheme("is_yep") is Some(_))
  let probe_env = db.types("probe")
  assert_true(probe_env.get_scheme("Maybe::is_yep") is Some(_))
  let main_env = db.types("main")
  assert_true(main_env.get_scheme("Maybe::is_yep") is Some(_))
  let probe_compiled = compile_module(db, "probe")
  let probe_rt = Runtime::new(@capability.CapabilitySet::new())
  probe_rt.set_type_env(probe_compiled.type_env)
  let probe_visited : Map[String, Bool] = {}
  let probe_path_to_hash : Map[String, String] = {}
  register_import_modules(
    probe_rt, db, "probe", probe_visited, probe_path_to_hash,
  )
  let probe_ast = @core.convert_imports_to_hash(probe_compiled.ast, fn(path) {
    probe_path_to_hash.get(path)
  })
  for name, target in probe_compiled.aliases {
    probe_rt.set_alias(name, target)
  }
  let _ = probe_rt.eval_module(probe_ast)
  assert_true(probe_rt.get("Maybe::is_yep") is Some(@core.Value::Fn(_)))
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  rt.set_type_env(compiled.type_env)
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
    _ => fail("expected Bool(true), got: " + result.last.to_string())
  }
}

///|
test "vibe integration raw identifier supports reserved names" {
  let db = VibeDb::new()
  let main_source =
    #|let r#if = 1
    #|let r#bench = 2
    #|r#if + r#bench
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("expected Int(3)")
  }
}

///|
test "vibe integration char literal has Char type" {
  let db = VibeDb::new()
  let main_source =
    #|let c: Char = 'A'
    #|let d: Char = 'a'
    #|if c == 'A' {
    #|  d
    #|} else {
    #|  c
    #|}
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Char(v)) => assert_eq(v, 'a')
    _ => fail("expected Char('a')")
  }
}

///|
test "vibe integration imports module using array_builder helper" {
  let db = VibeDb::new()
  let lib_source =
    #|export let build = (n: Int) -> Array[Int] {
    #|  let rec loop = (i: Int, b: ArrayBuilder[Int]) -> Array[Int] {
    #|    if i >= n {
    #|      {
    #|        array_builder_freeze(b)
    #|      }
    #|    } else {
    #|      {
    #|        array_builder_push(b, i)
    #|        loop(i + 1, b)
    #|      }
    #|    }
    #|  }
    #|  {
    #|    loop(0, array_builder())
    #|  }
    #|}
  let main_source = "import ./lib.vibe { build }\narray_length(build(3))"
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let imported_env = db.types("./lib.vibe")
  assert_true(imported_env.get_scheme("build") is Some(_))
  let main_env = db.types("main")
  assert_true(main_env.get_scheme("build") is Some(_))
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  rt.set_type_env(compiled.type_env)
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
    Some(@core.Value::Int(v)) => assert_eq(v, 3)
    _ => fail("expected Int(3)")
  }
}

///|
test "vibe integration cross-module trait-bound eq" {
  let db = VibeDb::new()
  let lib_source =
    #|export trait LocalEq
    #|impl LocalEq for String
    #|export let cmp_eq = [T: LocalEq](a: T, b: T) -> Bool { true }
  let main_source = "import ./lib.vibe { LocalEq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
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
    #|export trait LocalEq
    #|impl LocalEq for Int
    #|impl [T: LocalEq] LocalEq for Option[T]
    #|export let option_equals = [T: LocalEq](a: Option[T], b: Option[T]) -> Bool {
    #|  match (a, b) {
    #|    (Some(_), Some(_)) => true,
    #|    (None, None) => true,
    #|    _ => false
    #|  }
    #|}
  let main_source = "import ./lib.vibe { LocalEq, option_equals }\noption_equals(Some(1), Some(1))"
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
  let lib_source = "export trait LocalEq"
  let main_source = "import ./lib.vibe { LocalEq }\nimpl LocalEq for String"
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
  let lib_source = "trait LocalEq"
  let main_source = "import ./lib.vibe { LocalEq }\nimpl LocalEq for String"
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
  let lib_source = "export open trait LocalEq"
  let main_source =
    #|import ./lib.vibe { LocalEq }
    #|impl LocalEq for String
    #|let same = [T: LocalEq](a: T, b: T) -> Bool { true }
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
test "vibe integration trait bound works without explicit trait import" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait LocalEq
    #|impl LocalEq for String
    #|export let cmp_eq = [T: LocalEq](a: T, b: T) -> Bool { true }
  let main_source = "import ./lib.vibe { cmp_eq }\ncmp_eq(\"a\", \"a\")"
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
test "vibe integration explicit trait import enables trait-bounded call" {
  let db = VibeDb::new()
  let lib_source =
    #|export open trait LocalEq
    #|impl LocalEq for String
    #|export let cmp_eq = [T: LocalEq](a: T, b: T) -> Bool { true }
  let main_source = "import ./lib.vibe { LocalEq, cmp_eq }\ncmp_eq(\"a\", \"a\")"
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
    #|export open trait LocalEq
    #|export open trait LocalOrd: LocalEq
    #|impl LocalOrd for Int
  let main_source =
    #|import ./lib.vibe { LocalOrd }
    #|let same = [T: LocalOrd](a: T, b: T) -> Bool { true }
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
    #|export open trait LocalEq
    #|impl LocalEq for String
    #|export let cmp_eq = [T: LocalEq](a: T, b: T) -> Bool { true }
  let main_source =
    #|import ./lib.vibe { LocalEq as Equality, cmp_eq }
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
    #|export open trait LocalEq
    #|export open trait LocalOrd: LocalEq
    #|impl LocalOrd for Int
    #|export let same_ord = [T: LocalOrd](a: T, b: T) -> Bool { true }
  let main_source =
    #|import ./lib.vibe { LocalEq as Equality, LocalOrd, same_ord }
    #|let same = [T: LocalOrd](a: T, b: T) -> Bool { true }
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
test "vibe integration for-in uses imported Iterable impl and type members" {
  let db = VibeDb::new()
  let lib_source =
    #|export enum List[T] {
    #|  Nil;
    #|  Cons(T, List[T])
    #|}
    #|impl [T] Iterable for List[T]
    #|export let of3 = [T](a: T, b: T, c: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Nil)))
    #|}
    #|export let iter_length = [T](xs: List[T]) -> Int {
    #|  let rec go = (rest: List[T], acc: Int) -> Int {
    #|    match rest {
    #|      Nil => acc,
    #|      Cons(_, t) => go(t, acc + 1)
    #|    }
    #|  }
    #|  go(xs, 0)
    #|}
    #|export let rec iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { iter_get(t, index - 1) },
    #|    Nil => iter_get(xs, index)
    #|  }
    #|}
  let main_source =
    #|import ./lib.vibe { List, of3 }
    #|let values = for x in of3(1, 2, 3) {
    #|  x + 1
    #|}
    #|values
  db.set_source("./lib.vibe", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  assert_true(compiled.type_env.get_scheme("values") is Some(_))
}

///|
test "vibe integration imported suberror can be thrown as Error" {
  let db = VibeDb::new()
  let lib_source = "export suberror AppError(String);"
  let main_source =
    #|import ./lib.vibe { AppError }
    #|let fail = () -> Unit with {Error} {
    #|  throw(AppError("boom"))
    #|}
    #|let run = () -> String {
    #|  handle { fail(); "ok" } { _ => "caught" }
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
    #|import ./lib.xm { module math }
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
  db.set_source("main", "import ./lib.xm { module math as m }\nm::inc(41)")
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
  db.set_source("main", "import ./lib.vibe { module math }\nmath::inc(1)")
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
  db.set_source("main", "import ./lib.vibe { module math::inc }\nmath::inc(1)")
  let compiled : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match compiled {
    Ok(_) => fail("expected parse error for module member import")
    Err(err) =>
      assert_true(
        err
        .to_string()
        .contains(
          "`import <module-ref> { module foo }` (module namespace only)",
        ),
      )
  }
}

///|
test "vibe integration handle catches error" {
  let db = VibeDb::new()
  let main_source =
    #|let fail = () -> String with {Error} { throw("oops") }
    #|handle { fail() } {
    #|  Error(e) => e
    #|}
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::String(v)) => assert_true(v.contains("oops"))
    _ => fail("expected String containing oops")
  }
}

///|
test "vibe integration handle passthrough" {
  let db = VibeDb::new()
  let main_source =
    #|handle { 42 } {
    #|  Error(_) => -1
    #|}
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int(42)")
  }
}

///|
test "vibe integration perform handle typed payload" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int)
    #|}
    #|let run = () -> Int {
    #|  handle {
    #|    perform(Ask(41))
    #|  } {
    #|    Ask(v) => add(v, 1)
    #|  }
    #|}
    #|run()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 42)
    _ => fail("expected Int(42)")
  }
}

///|
test "vibe integration perform multi-layer handle" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int);
    #|  Log(String);
    #|}
    #|let program = () -> Int with {Ask, Log} {
    #|  perform(Log("start"))
    #|}
    #|let with_log = () -> Int with {Ask} {
    #|  handle {
    #|    program()
    #|  } {
    #|    Log(_) => perform(Ask(32))
    #|  }
    #|}
    #|let run = () -> Int {
    #|  handle {
    #|    with_log()
    #|  } {
    #|    Ask(v) => v
    #|  }
    #|}
    #|run()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 32)
    _ => fail("expected Int(32)")
  }
}

///|
test "vibe integration resume continues after perform" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int)
    #|}
    #|let run = () -> Int {
    #|  handle {
    #|    add(1, perform(Ask(41)))
    #|  } {
    #|    Ask(v) => resume(add(v, 1))
    #|  }
    #|}
    #|run()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 43)
    _ => fail("expected Int(43)")
  }
}

///|
test "vibe integration resume multi-layer perform" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int);
    #|  Log(String);
    #|}
    #|let run = () -> Int {
    #|  handle {
    #|    handle {
    #|      add(10, perform(Log("x")))
    #|    } {
    #|      Log(_) => resume(perform(Ask(32)))
    #|    }
    #|  } {
    #|    Ask(v) => resume(add(v, 1))
    #|  }
    #|}
    #|run()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = rt.eval_module(compiled.ast)
  match result.last {
    Some(@core.Value::Int(v)) => assert_eq(v, 43)
    _ => fail("expected Int(43)")
  }
}

///|
test "vibe integration resume rejects mismatched resumed value type" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int)
    #|}
    #|let run = () -> Int {
    #|  handle {
    #|    let resumed: Int = perform(Ask(41))
    #|    add(1, resumed)
    #|  } {
    #|    Ask(v) => resume("oops")
    #|  }
    #|}
    #|run()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = try? rt.eval_module(compiled.ast)
  match result {
    Ok(_) => fail("expected runtime error for resume value")
    Err(err) =>
      assert_true(err.to_string().contains("resume value type mismatch"))
  }
}

///|
test "vibe integration resume rejects prior effects before perform" {
  let db = VibeDb::new()
  let main_source =
    #|enum Eff {
    #|  Ask(Int)
    #|}
    #|let run = () -> Int with {Ask, Stdout} {
    #|  { stdout_write_char(65) }
    #|  add(1, perform(Ask(41)))
    #|}
    #|let main = () -> Int with {Stdout} {
    #|  handle {
    #|    run()
    #|  } {
    #|    Ask(v) => resume(v)
    #|  }
    #|}
    #|main()
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = try? rt.eval_module(compiled.ast)
  match result {
    Ok(_) => fail("expected runtime error for resume after prior effects")
    Err(err) =>
      assert_true(
        err.to_string().contains("resume cannot continue after prior effects"),
      )
  }
}
