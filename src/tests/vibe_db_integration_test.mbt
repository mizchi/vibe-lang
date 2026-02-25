///|
test "vibe ripple db" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 1")
  let ast = db.ast("main")
  assert_eq(ast.stmts.length(), 1)
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

///|
test "vibe warning reports unused let binding" {
  let db = VibeDb::new()
  db.set_source("main", "let unused = 1\nlet x = 2\nx")
  let _ = db.types("main")
  let warnings = db.warnings("main")
  assert_eq(warnings.length(), 1)
  assert_eq(warnings[0].stage, "warning")
  assert_true(warnings[0].message.contains("unused variable: unused"))
}

///|
test "vibe warning ignores underscore-prefixed name" {
  let db = VibeDb::new()
  db.set_source("main", "let _unused = 1\nlet x = 2\nx")
  let _ = db.types("main")
  let warnings = db.warnings("main")
  assert_eq(warnings.length(), 0)
}

///|
test "vibe warning reports unnecessary mut binding" {
  let db = VibeDb::new()
  db.set_source("main", "let mut value = 1\nvalue")
  let _ = db.types("main")
  let warnings = db.warnings("main")
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].message.contains("unnecessary `mut` binding: value"))
}

///|
test "vibe warning reports unused import local name" {
  let db = VibeDb::new()
  db.set_source("./lib.vibe", "export let foo = 1")
  db.set_source("main", "import ./lib.vibe { foo as local_foo }\nlet x = 1\nx")
  let _ = db.types("main")
  let warnings = db.warnings("main")
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].message.contains("unused import: local_foo"))
}

///|
test "vibe import parsing" {
  // Test that import syntax parses correctly
  let db = VibeDb::new()
  db.set_source("main", "import ./foo.vibe { y }\nlet x = 1")
  db.set_source("./foo.vibe", "export let y = 2")
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
test "vibe hash import resolves by content hash" {
  let db = VibeDb::new()
  let lib_source = "export let y = 2"
  let lib_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./foo.vibe", lib_source)
  db.set_source("main", "import #\{lib_hash} { y }\nlet x = y")
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  match imp.hash {
    Some(h) => {
      assert_eq(h, lib_hash)
      assert_eq(imp.module_ref, Some(@core.module_ref_from_hash(h)))
    }
    None => fail("missing hash for hash import")
  }
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

///|
test "vibe import cycle reports diagnostic" {
  let db = VibeDb::new()
  db.set_source("main", "import ./a.vibe { a }\nlet x = a")
  db.set_source("./a.vibe", "import ./b.vibe { b }\nexport let a = b")
  db.set_source("./b.vibe", "import ./a.vibe { a }\nexport let b = a")
  let _ = db.imports("main")
  let diags = db.diagnostics("main")
  let mut found = false
  for diag in diags {
    if diag.stage == "import" && diag.message.contains("import cycle:") {
      found = true
    }
  }
  assert_true(found)
}

///|
test "vibe import keeps normalized path object" {
  let db = VibeDb::new()
  db.set_source("/project/lib/util.vibe", "export let y = 2")
  db.set_source(
    "/project/main.vibe", "import ./lib/./util.vibe { y }\nlet x = y",
  )
  let imports = db.imports("/project/main.vibe")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  assert_eq(imp.path, "/project/lib/util.vibe")
  match imp.path_obj {
    Some(path_obj) => {
      assert_eq(path_obj.raw, "/project/lib/util.vibe")
      assert_eq(path_obj.base, "/project")
      assert_eq(path_obj.normalized, "/project/lib/util.vibe")
    }
    None => fail("missing path object")
  }
}

///|
test "vibe path import lock missing reports diagnostic when required" {
  let db = VibeDb::new()
  db.require_path_lock(true)
  db.set_source("main", "import ./foo.vibe { y }\nlet x = y")
  db.set_source("./foo.vibe", "export let y = 2")
  let _ = db.imports("main")
  let diags = db.diagnostics("main")
  let mut found = false
  for diag in diags {
    if diag.stage == "import" && diag.message.contains("missing lock entry") {
      found = true
    }
  }
  assert_true(found)
}

///|
test "vibe path import lock mismatch reports diagnostic when required" {
  let db = VibeDb::new()
  db.require_path_lock(true)
  db.set_source("main", "import ./foo.vibe { y }\nlet x = y")
  let lib_source = "export let y = 2"
  db.set_source("./foo.vibe", lib_source)
  db.set_path_ref("./foo.vibe", "0000000000000000000000000000000000000000")
  let _ = db.imports("main")
  let diags = db.diagnostics("main")
  let mut found = false
  for diag in diags {
    if diag.stage == "import" && diag.message.contains("lock mismatch") {
      found = true
    }
  }
  assert_true(found)
}

///|
test "vibe path import lock accepts matching hash" {
  let db = VibeDb::new()
  db.require_path_lock(true)
  db.set_source("main", "import ./foo.vibe { y }\nlet x = y")
  let lib_source = "export let y = 2"
  db.set_source("./foo.vibe", lib_source)
  let lib_hash = @core.git_blob_hash_string(lib_source)
  db.set_path_ref("./foo.vibe", lib_hash)
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  assert_eq(imports[0].hash, Some(lib_hash))
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

///|
test "vibe compile fails on import diagnostics" {
  let db = VibeDb::new()
  db.require_path_lock(true)
  db.set_source("main", "import ./foo.vibe { y }\nlet x = y")
  db.set_source("./foo.vibe", "export let y = 2")
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected compile error for missing lock")
    Err(err) => assert_true(err.to_string().contains("missing lock entry"))
  }
}

///|
test "vibe compile keeps parse error variant" {
  let db = VibeDb::new()
  db.set_source("main", "let x =")
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_true(err.to_string().contains("Parse("))
  }
}

///|
test "vibe hash import keeps immutable snapshot after source update" {
  let db = VibeDb::new()
  let lib_v1 = "export let y = 2"
  let lib_v2 = "export let y = 3"
  let hash_v1 = @core.git_blob_hash_string(lib_v1)
  db.set_source("./foo.vibe", lib_v1)
  db.set_source("./foo.vibe", lib_v2)
  db.set_source("main", "import #\{hash_v1} { y }\nlet x = y")
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  assert_eq(imp.hash, Some(hash_v1))
  assert_eq(imp.source_hash, Some(hash_v1))
  match db.get_source(imp.path) {
    Some(snapshot) => assert_eq(snapshot, lib_v1)
    None => fail("missing immutable hash snapshot")
  }
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
}

///|
test "vibe version import resolves through lock ref" {
  let db = VibeDb::new()
  let lib_source = "export let y = 2"
  let lib_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./foo.vibe", lib_source)
  db.set_version_ref("main", lib_hash)
  db.set_source("entry", "import version@main { y }\nlet x = y")
  let imports = db.imports("entry")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  assert_eq(imp.source_version, Some("main"))
  assert_eq(imp.hash, Some(lib_hash))
  let _ = db.types("entry")
  let diags = db.diagnostics("entry")
  assert_true(diags.is_empty())
}

///|
test "vibe symbol import resolves through lock ref" {
  let db = VibeDb::new()
  let lib_source = "export let y = 2"
  let lib_hash = @core.git_blob_hash_string(lib_source)
  db.set_source("./foo.vibe", lib_source)
  db.set_symbol_ref("std/math", lib_hash)
  db.set_source("entry", "import symbol@std/math { y }\nlet x = y")
  let imports = db.imports("entry")
  assert_eq(imports.length(), 1)
  let imp = imports[0]
  assert_eq(imp.source_symbol, Some("std/math"))
  assert_eq(imp.hash, Some(lib_hash))
  let _ = db.types("entry")
  let diags = db.diagnostics("entry")
  assert_true(diags.is_empty())
}

///|
test "vibe wasm import resolves binary module and type checks call" {
  let lib_db = VibeDb::new()
  lib_db.set_source(
    "lib", "export let inflate = (src: Int, dst: Int) -> Int { add(src, dst) }",
  )
  let wasm = try compile_module_wasm(lib_db, "lib") catch {
    e => fail("failed to build wasm fixture: " + e.to_string())
  } noraise {
    b => b
  }
  let db = VibeDb::new()
  db.set_binary_source("./zlib.wasm", wasm)
  db.set_source(
    "main", "import ./zlib.wasm { inflate }\nlet x = inflate(1, 2, 0)\nx",
  )
  let imports = db.imports("main")
  assert_eq(imports.length(), 1)
  assert_true(imports[0].hash is Some(_))
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  assert_true(diags.is_empty())
  let compiled = compile_module(db, "main")
  assert_eq(compiled.imports.length(), 1)
}

///|
test "vibe wasm import reports missing exported function" {
  let lib_db = VibeDb::new()
  lib_db.set_source("lib", "export let inflate = (n: Int) -> Int { n }")
  let wasm = try compile_module_wasm(lib_db, "lib") catch {
    e => fail("failed to build wasm fixture: " + e.to_string())
  } noraise {
    b => b
  }
  let db = VibeDb::new()
  db.set_binary_source("./zlib.wasm", wasm)
  db.set_source("main", "import ./zlib.wasm { deflate }\nlet x = deflate(1)\nx")
  let _ = db.types("main")
  let diags = db.diagnostics("main")
  let mut found = false
  for diag in diags {
    if diag.stage == "import" && diag.message.contains("missing wasm export") {
      found = true
    }
  }
  assert_true(found)
}

///|
test "vibe wasm import reports type mismatch on call" {
  let lib_db = VibeDb::new()
  lib_db.set_source("lib", "export let inflate = (n: Int) -> Int { n }")
  let wasm = try compile_module_wasm(lib_db, "lib") catch {
    e => fail("failed to build wasm fixture: " + e.to_string())
  } noraise {
    b => b
  }
  let db = VibeDb::new()
  db.set_binary_source("./zlib.wasm", wasm)
  db.set_source(
    "main", "import ./zlib.wasm { inflate }\nlet x = inflate(\"bad\")\nx",
  )
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected type error")
    Err(err) => assert_true(err.to_string().contains("type"))
  }
}

///|
test "vibe db path std module has no type diagnostics" {
  let db = VibeDb::new()
  let source = @os_fs.read_file_to_string("vibe/prelude/path.vibe") catch {
    e => fail("failed to read vibe/prelude/path.vibe: " + e.to_string())
  }
  db.set_source("path", source)
  let env = db.types("path")
  let diags = db.diagnostics("path")
  if not(diags.is_empty()) {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  let ast = db.ast("path")
  let mut has_export_from_literal = false
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..) =>
        if name == "from_literal" {
          has_export_from_literal = true
        }
      _ => ()
    }
  }
  assert_true(has_export_from_literal)
  match env.get_scheme("add") {
    Some(_) => ()
    None => fail("expected prelude scheme: add")
  }
  match env.get_scheme("dynamic") {
    Some(_) => ()
    None => fail("expected dynamic export scheme")
  }
  match env.get_scheme("from_literal") {
    Some(_) => ()
    None => fail("expected from_literal export scheme")
  }
}
