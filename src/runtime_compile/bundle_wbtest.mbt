///|
test "bundle_for_wasm keeps enum defs from re-exported directory wrapper" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    "export enum Type {\n" + "  CtInt;\n" + "  CtArray(Type)\n" + "}\n",
  )
  db.set_source(
    "/project/core/index.vibe",
    "export ./types_impl.vibe { Type }\n" + "export { Type }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./core { Type }\n" +
    "let value: Type = CtArray(CtInt)\n" +
    "let result = match value { CtArray(inner) => inner, _ => CtInt }\n" +
    "result\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm(db, "/project/main.vibe", ast)
  let mut type_enum_count = 0
  let mut has_import = false
  let mut has_reexport = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Type" {
          type_enum_count += 1
        }
      @core.Stmt::Import(..) => has_import = true
      @core.Stmt::ReExport(..) => has_reexport = true
      _ => ()
    }
  }
  assert_eq(type_enum_count, 1)
  assert_false(has_import)
  assert_false(has_reexport)
}

///|
test "bundle_for_wasm_no_dce rewrites import alias calls in entry module" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/helper.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./helper.vibe { add as plus }\n" +
    "let result = plus(1, 2)\n" +
    "result\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", ast)
  let mut saw_rewritten_call = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::Let(
        name="result",
        expr=@core.Expr::Call(name=call_name, ..),
        ..
      ) => {
        assert_eq(call_name, "add")
        saw_rewritten_call = true
      }
      _ => ()
    }
  }
  assert_true(saw_rewritten_call)
}

///|
test "bundle_for_wasm_no_dce namespaces dependency private helper against entry helper" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/dep.vibe",
    "let helper: () -> Int = () -> { 1 }\n" +
    "export let answer: () -> Int = () -> { helper() }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./dep.vibe { answer as dep_answer }\n" +
    "let helper: () -> Int = () -> { 2 }\n" +
    "test \"entry helper collision\" {\n" +
    "  assert_eq(dep_answer() + helper(), 3)\n" +
    "}\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", ast)
  let sexp = module_to_sexp(bundled, {})
  if !sexp.contains("helper$dep$") || !sexp.contains("(let \"answer\"") {
    fail(sexp)
  }
  let test_bundle = bundle_for_codegen(db, "/project/main.vibe", ast, "tests") catch {
    e => fail(e.to_string())
  }
  let lowered = lower_top_level_tests_to_exprs(test_bundle)
  let test_sexp = module_to_sexp(lowered, {})
  if !test_sexp.contains("helper$dep$") ||
    !test_sexp.contains("(call \"answer\"") ||
    !test_sexp.contains("(call \"helper\"") {
    fail(test_sexp)
  }
}

///|
test "bundle_for_wasm_no_dce keeps imported trait impls" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iter_mod.vibe",
    (
      #|export enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|export let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iter_mod.vibe {
      #|  trio_of3
      #|}
      #|let value = trio_of3(1, 2, 3)
    ),
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", ast)
  let mut has_trio_impl = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::TraitImpl(trait_name~, target~, ..) =>
        if trait_name == "Iterable" {
          match target {
            @core.Type::Named(name~, ..) =>
              if name == "Trio" {
                has_trio_impl = true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(has_trio_impl)
}

///|
test "bundle_for_wasm_no_dce keeps mixed wrapper and direct type defs concrete" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    (
      #|export enum Type {
      #|  CtUnit
      #|}
      #|export enum TypeDef {
      #|  TDAlias(String, Type)
      #|}
    ),
  )
  db.set_source(
    "/project/types.vibe",
    (
      #|export ./core/types_impl.vibe {
      #|  Type, TypeDef
      #|}
      #|export {
      #|  Type, TypeDef
      #|}
    ),
  )
  db.set_source(
    "/project/use_wrapper.vibe",
    (
      #|import ./types.vibe {
      #|  Type
      #|}
      #|export let make_type = () -> Type {
      #|  CtUnit
      #|}
    ),
  )
  db.set_source(
    "/project/use_core.vibe",
    (
      #|import ./core/types_impl.vibe {
      #|  Type, TypeDef
      #|}
      #|export let make_type_def = () -> TypeDef {
      #|  TDAlias("dummy", CtUnit)
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./use_wrapper.vibe {
      #|  make_type
      #|}
      #|import ./use_core.vibe {
      #|  make_type_def
      #|}
      #|let _t = make_type()
      #|let _d = make_type_def()
    ),
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", ast)
  let sexp = module_to_sexp(bundled, {})
  if sexp.contains("Import ") || sexp.contains("ReExport ") {
    fail(sexp)
  }
  let mut has_type = false
  let mut has_typedef = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Type" {
          has_type = true
        } else if name == "TypeDef" {
          has_typedef = true
        }
      _ => ()
    }
  }
  if !has_type || !has_typedef {
    fail(sexp)
  }
}

///|
test "bundle_for_wasm_linked resolves ReExport function as linked import" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/adder.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/wrapper.vibe", "export ./adder.vibe { add }\nexport { add }\n",
  )
  db.set_source(
    "/project/main.vibe", "import ./wrapper.vibe { add }\nlet result = add(1, 2)\nresult\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  // add should be a linked import, not inlined
  let mut has_add_import = false
  for li in linked {
    if li.func_name == "add" {
      has_add_import = true
      assert_eq(li.param_count, 2)
      assert_eq(li.return_count, 1)
    }
  }
  assert_true(has_add_import)
  // bundled should not contain Import or ReExport
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::Import(..) => assert_true(false)
      @core.Stmt::ReExport(..) => assert_true(false)
      _ => ()
    }
  }
}

///|
test "bundle_for_wasm_linked resolves export let ident alias as linked import" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/adder.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/wrapper.vibe",
    "import ./adder.vibe { add }\n" + "export let plus = add\n",
  )
  db.set_source(
    "/project/main.vibe", "import ./wrapper.vibe { plus }\nlet result = plus(1, 2)\nresult\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  let mut has_plus_import = false
  for li in linked {
    if li.func_name == "plus" {
      has_plus_import = true
      assert_eq(li.param_count, 2)
      assert_eq(li.return_count, 1)
    }
  }
  assert_true(has_plus_import)
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::Import(..) => assert_true(false)
      @core.Stmt::ReExport(..) => assert_true(false)
      _ => ()
    }
  }
}

///|
test "bundle_for_wasm_linked resolves ReExport enum type from chain" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/token_defs.vibe",
    "export enum Token { TEof; TInt(Int) }\n" +
    "export let token_name = (t: Token) -> Int { match t { TEof => 0, TInt(_) => 1 } }\n",
  )
  db.set_source(
    "/project/token_wrapper.vibe", "export ./token_defs.vibe { Token, token_name }\nexport { Token, token_name }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./token_wrapper.vibe { Token, token_name }\n" +
    "let t: Token = TEof\nlet r = token_name(t)\nr\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  // Token enum should be inlined as EnumDef
  let mut has_token_enum = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Token" {
          has_token_enum = true
        }
      _ => ()
    }
  }
  assert_true(has_token_enum)
  // token_name should be a linked import
  let mut has_token_name = false
  for li in linked {
    if li.func_name == "token_name" {
      has_token_name = true
    }
  }
  assert_true(has_token_name)
}

///|
test "bundle_for_wasm_linked resolves multi-level ReExport chain" {
  let db = @runtime.VibeDb::new()
  // Level 2: actual definition
  db.set_source(
    "/project/inner.vibe", "export let parse = (s: String) -> Int { 42 }\n",
  )
  // Level 1: re-export facade
  db.set_source(
    "/project/mid.vibe", "export ./inner.vibe { parse }\nexport { parse }\n",
  )
  // Entry dep: re-export facade
  db.set_source(
    "/project/wrapper.vibe", "export ./mid.vibe { parse }\nexport { parse }\n",
  )
  // Entry
  db.set_source(
    "/project/main.vibe", "import ./wrapper.vibe { parse }\nlet r = parse(\"hello\")\nr\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (_bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  let mut has_parse = false
  for li in linked {
    if li.func_name == "parse" {
      has_parse = true
      assert_eq(li.param_count, 1)
    }
  }
  assert_true(has_parse)
}

///|
test "bundle_for_wasm_linked strips ReExport from entry and resolves types" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/defs.vibe",
    "export enum Color { Red; Blue }\n" + "export let name = () -> Int { 1 }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "export ./defs.vibe { Color, name }\n" +
    "export { Color, name }\n" +
    "let c: Color = Red\nlet x = name()\nx\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, _linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  // Entry's ReExport should be stripped
  let mut has_reexport = false
  let mut has_color = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::ReExport(..) => has_reexport = true
      @core.Stmt::EnumDef(name~, ..) => if name == "Color" { has_color = true }
      _ => ()
    }
  }
  assert_false(has_reexport)
  // Color enum should be resolved from entry's own ReExport
  assert_true(has_color)
}

///|
test "bundle_for_wasm_linked detects HOF through ReExport chain" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/hof_defs.vibe", "export let map_fn = (f: (Int) -> Int, x: Int) -> Int { f(x) }\n",
  )
  db.set_source(
    "/project/hof_facade.vibe", "export ./hof_defs.vibe { map_fn }\nexport { map_fn }\n",
  )
  db.set_source(
    "/project/main.vibe", "import ./hof_facade.vibe { map_fn }\nlet r = map_fn((x) -> Int { x + 1 }, 5)\nr\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  // HOF: map_fn has Func param → should be inlined, not linked
  let mut has_map_fn_linked = false
  for li in linked {
    if li.func_name == "map_fn" {
      has_map_fn_linked = true
    }
  }
  assert_false(has_map_fn_linked)
  // Should be inlined as Let in bundled stmts
  let mut has_map_fn_inlined = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..) | @core.Stmt::Let(name~, ..) =>
        if name == "map_fn" {
          has_map_fn_inlined = true
        }
      _ => ()
    }
  }
  assert_true(has_map_fn_inlined)
}

///|
test "bundle_for_wasm_linked inlines deps that require Fs host imports" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/fs_dep.vibe", "export let load = (path: String) -> String with { Error, Fs } { perform Fs::ReadFile(path) }\n",
  )
  db.set_source(
    "/project/main.vibe", "import ./fs_dep.vibe { load }\nlet result = load(\"/tmp/input.txt\")\nresult\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  let mut has_load_linked = false
  for li in linked {
    if li.func_name == "load" {
      has_load_linked = true
    }
  }
  assert_false(has_load_linked)
  let mut has_load_inlined = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..) | @core.Stmt::Let(name~, ..) =>
        if name == "load" {
          has_load_inlined = true
        }
      _ => ()
    }
  }
  assert_true(has_load_inlined)
}

///|
test "bundle_for_wasm_linked inlines deps that require Env host imports" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/env_dep.vibe", "export let read_home = () -> String with { Env } { perform Env::Get(\"HOME\") }\n",
  )
  db.set_source(
    "/project/main.vibe", "import ./env_dep.vibe { read_home }\nlet result = read_home()\nresult\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let (bundled, linked) = bundle_for_wasm_linked(db, "/project/main.vibe", ast)
  let mut has_read_home_linked = false
  for li in linked {
    if li.func_name == "read_home" {
      has_read_home_linked = true
    }
  }
  assert_false(has_read_home_linked)
  let mut has_read_home_inlined = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..) | @core.Stmt::Let(name~, ..) =>
        if name == "read_home" {
          has_read_home_inlined = true
        }
      _ => ()
    }
  }
  assert_true(has_read_home_inlined)
}

///|
test "bundle_for_wasm keeps enum defs through nested wrapper re-exports" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    "export enum Type {\n" + "  CtInt;\n" + "  CtArray(Type)\n" + "}\n",
  )
  db.set_source(
    "/project/core/index.vibe",
    "export ./types_impl.vibe { Type }\n" + "export { Type }\n",
  )
  db.set_source(
    "/project/types.vibe",
    "export ./core { Type }\n" + "export { Type }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./types.vibe { Type }\n" +
    "let value: Type = CtArray(CtInt)\n" +
    "let result = match value { CtArray(inner) => inner, _ => CtInt }\n" +
    "result\n",
  )
  let ast = db.ast_with_hash_imports("/project/main.vibe")
  let bundled = bundle_for_wasm(db, "/project/main.vibe", ast)
  let mut type_enum_count = 0
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Type" {
          type_enum_count += 1
        }
      _ => ()
    }
  }
  assert_eq(type_enum_count, 1)
}

///|
test "bundle_for_wasm resolves cross-directory transitive import via ../regexp" {
  // Simulates vibe/x/url_test.vibe scenario:
  // /x/url_test.vibe -> ./url/pattern.vibe -> ../regexp/index.vibe -> ./regexp.vibe
  let db = @runtime.VibeDb::new()
  // regexp module (sibling of url/)
  db.set_source(
    "/x/regexp/regexp.vibe", "export let compile = (s: String) -> String { s }\n",
  )
  db.set_source(
    "/x/regexp/index.vibe", "export ./regexp.vibe { compile }\nexport { compile }\n",
  )
  // url/pattern.vibe imports ../regexp (resolves to /x/regexp/index.vibe)
  db.set_source(
    "/x/url/pattern.vibe", "import ../regexp { compile }\nexport let make_pattern = (s: String) -> String { compile(s) }\n",
  )
  // Entry test file
  db.set_source(
    "/x/url_test.vibe", "import ./url/pattern.vibe { make_pattern }\nlet result = make_pattern(\"test\")\nresult\n",
  )
  let ast = db.ast_with_hash_imports("/x/url_test.vibe")
  let bundled = bundle_for_wasm(db, "/x/url_test.vibe", ast)
  // Verify that compile and make_pattern are both in the bundle
  let mut has_compile = false
  let mut has_make_pattern = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => {
        if name == "compile" {
          has_compile = true
        }
        if name == "make_pattern" {
          has_make_pattern = true
        }
      }
      _ => ()
    }
  }
  assert_true(has_compile)
  assert_true(has_make_pattern)
}
