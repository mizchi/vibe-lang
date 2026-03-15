///|
test "bundle_for_wasm keeps enum defs from re-exported directory wrapper" {
  let db = VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    "export enum Type {\n" +
    "  CtInt;\n" +
    "  CtArray(Type)\n" +
    "}\n",
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
test "bundle_for_wasm keeps enum defs through nested wrapper re-exports" {
  let db = VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    "export enum Type {\n" +
    "  CtInt;\n" +
    "  CtArray(Type)\n" +
    "}\n",
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
