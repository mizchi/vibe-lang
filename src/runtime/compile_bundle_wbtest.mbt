///|
test "bundle_for_wasm keeps enum defs from re-exported directory wrapper" {
  let db = VibeDb::new()
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
test "bundle_for_wasm_linked resolves ReExport function as linked import" {
  let db = VibeDb::new()
  db.set_source(
    "/project/adder.vibe",
    "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/wrapper.vibe",
    "export ./adder.vibe { add }\nexport { add }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./wrapper.vibe { add }\nlet result = add(1, 2)\nresult\n",
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
test "bundle_for_wasm_linked resolves ReExport enum type from chain" {
  let db = VibeDb::new()
  db.set_source(
    "/project/token_defs.vibe",
    "export enum Token { TEof; TInt(Int) }\n" +
    "export let token_name = (t: Token) -> Int { match t { TEof => 0, TInt(_) => 1 } }\n",
  )
  db.set_source(
    "/project/token_wrapper.vibe",
    "export ./token_defs.vibe { Token, token_name }\nexport { Token, token_name }\n",
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
  let db = VibeDb::new()
  // Level 2: actual definition
  db.set_source(
    "/project/inner.vibe",
    "export let parse = (s: String) -> Int { 42 }\n",
  )
  // Level 1: re-export facade
  db.set_source(
    "/project/mid.vibe",
    "export ./inner.vibe { parse }\nexport { parse }\n",
  )
  // Entry dep: re-export facade
  db.set_source(
    "/project/wrapper.vibe",
    "export ./mid.vibe { parse }\nexport { parse }\n",
  )
  // Entry
  db.set_source(
    "/project/main.vibe",
    "import ./wrapper.vibe { parse }\nlet r = parse(\"hello\")\nr\n",
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
  let db = VibeDb::new()
  db.set_source(
    "/project/defs.vibe",
    "export enum Color { Red; Blue }\n" +
    "export let name = () -> Int { 1 }\n",
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
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Color" {
          has_color = true
        }
      _ => ()
    }
  }
  assert_false(has_reexport)
  // Color enum should be resolved from entry's own ReExport
  assert_true(has_color)
}

///|
test "bundle_for_wasm_linked_with_imports skips ReExport and uses extra_type_stmts" {
  let zero_span = @core.Span::{ start: 0, end: 0 }
  let extra_types : Array[@core.Stmt] = [
    @core.Stmt::EnumDef(
      name="Token",
      params=[],
      ctors=[
        @core.TypeCtor::{ name: "TEof", args: [], span: zero_span },
        @core.TypeCtor::{
          name: "TInt",
          args: [@core.Type::Named(name="Int", args=[])],
          span: zero_span,
        },
      ],
      span=zero_span,
    ),
  ]
  let ast = @core.Module::{
    stmts: [
      @core.Stmt::ReExport(
        spec=@core.ImportSpec::{
          items: [
            @core.ImportItem::{
              kind: @core.ImportKind::Value,
              name: "Token",
              rename: None,
            },
          ],
        },
        source=@core.ModuleRef::Path(path="./token.vibe"),
        span=zero_span,
      ),
      @core.Stmt::Let(
        rec=false,
        name="t",
        expr=@core.Expr::Ident(name="TEof", span=zero_span),
        span=zero_span,
      ),
    ],
  }
  let linked : Array[LinkedImport] = []
  let (bundled, _) = bundle_for_wasm_linked_with_imports(
    ast, linked, extra_type_stmts=extra_types,
  )
  let mut has_token = false
  let mut has_reexport = false
  for stmt in bundled.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "Token" {
          has_token = true
        }
      @core.Stmt::ReExport(..) => has_reexport = true
      _ => ()
    }
  }
  assert_true(has_token)
  assert_false(has_reexport)
}

///|
test "bundle_for_wasm_linked detects HOF through ReExport chain" {
  let db = VibeDb::new()
  db.set_source(
    "/project/hof_defs.vibe",
    "export let map_fn = (f: (Int) -> Int, x: Int) -> Int { f(x) }\n",
  )
  db.set_source(
    "/project/hof_facade.vibe",
    "export ./hof_defs.vibe { map_fn }\nexport { map_fn }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./hof_facade.vibe { map_fn }\nlet r = map_fn((x) -> Int { x + 1 }, 5)\nr\n",
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
test "bundle_for_wasm keeps enum defs through nested wrapper re-exports" {
  let db = VibeDb::new()
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
