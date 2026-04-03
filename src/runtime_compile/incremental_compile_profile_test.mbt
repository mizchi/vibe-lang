///|
fn load_test_entry(entry_path : String) -> (@runtime.VibeDb, String) {
  match @loader.load_db_for_test(entry_path) {
    Ok(v) => v
    Err(err) => abort("incremental compile profile load failed: " + err)
  }
}

///|
fn profiled_compile_pair(
  entry_path : String,
) -> (WasmCompileStageProfile, WasmCompileStageProfile) {
  let (db, entry) = load_test_entry(entry_path)
  let (_, cold) = compile_module_wasm_with_opt_level_profiled(
    db,
    entry,
    no_dce=true,
  ) catch {
    e =>
      abort(
        "incremental compile profile cold compile failed: " + e.user_message(),
      )
  }
  let (_, hot) = compile_module_wasm_with_opt_level_profiled(
    db,
    entry,
    no_dce=true,
  ) catch {
    e =>
      abort(
        "incremental compile profile hot compile failed: " + e.user_message(),
      )
  }
  (cold, hot)
}

///|
fn ratio_percent(numerator : Int, denominator : Int) -> Int {
  if denominator <= 0 {
    0
  } else {
    numerator * 100 / denominator
  }
}

///|
fn print_profile_summary(
  label : String,
  cold : WasmCompileStageProfile,
  hot : WasmCompileStageProfile,
) -> Unit {
  println(
    label +
    ": cold_total_us=" +
    cold.total_us.to_string() +
    " hot_total_us=" +
    hot.total_us.to_string() +
    " hot_ratio_pct=" +
    ratio_percent(hot.total_us, cold.total_us).to_string() +
    " cold_module_us=" +
    cold.module_us.to_string() +
    " hot_module_us=" +
    hot.module_us.to_string() +
    " cold_bundle_us=" +
    cold.bundle_us.to_string() +
    " hot_bundle_us=" +
    hot.bundle_us.to_string() +
    " cold_emit_us=" +
    cold.emit_us.to_string() +
    " hot_emit_us=" +
    hot.emit_us.to_string(),
  )
}

///|
test "incremental compile profile short" {
  let (cold, hot) = profiled_compile_pair("vibe/compiler/checker_error.vibe")
  print_profile_summary("short", cold, hot)
  assert_true(hot.total_us < cold.total_us)
  assert_true(hot.module_us < cold.module_us)
  assert_eq(hot.emit_us, 0)
  assert_eq(hot.optimize_us, 0)
  assert_true(hot.total_us * 3 < cold.total_us * 2)
}

///|
test "incremental compile profile medium" {
  let (cold, hot) = profiled_compile_pair("examples/base64.vibe")
  print_profile_summary("medium", cold, hot)
  assert_true(hot.total_us < cold.total_us)
  assert_true(hot.module_us < cold.module_us)
  assert_eq(hot.emit_us, 0)
  assert_eq(hot.optimize_us, 0)
  assert_true(hot.total_us < cold.total_us * 2)
}

///|
test "compile checker_stmt selfhost module" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let wasm = try
    compile_module_wasm_with_opt_level(db, entry, no_dce=true)
  catch {
    e => fail("compile error: " + e.user_message())
  } noraise {
    bytes => bytes
  }
  assert_true(wasm.length() > 8)
}

///|
test "bundle checker_stmt selfhost module keeps TypeDef before checker lets" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let ast = db.ast_with_hash_imports(entry)
  let bundled = bundle_for_wasm_no_dce(db, entry, ast)
  let mut typedef_idx = -1
  let mut type_idx = -1
  let mut check_program_idx = -1
  let mut check_program_with_env_idx = -1
  let mut typedef_count = 0
  for i = 0; i < bundled.stmts.length(); i = i + 1 {
    match bundled.stmts[i] {
      @core.Stmt::EnumDef(name~, ..) =>
        if name == "TypeDef" {
          typedef_count = typedef_count + 1
          if typedef_idx < 0 {
            typedef_idx = i
          }
        } else if name == "Type" && type_idx < 0 {
          type_idx = i
        }
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..) =>
        if name == "check_program" && check_program_idx < 0 {
          check_program_idx = i
        } else if name == "check_program_with_env" &&
          check_program_with_env_idx < 0 {
          check_program_with_env_idx = i
        }
      _ => ()
    }
  }
  println(
    "bundle-order type=" +
    type_idx.to_string() +
    " typedef=" +
    typedef_idx.to_string() +
    " typedef_count=" +
    typedef_count.to_string() +
    " check_program=" +
    check_program_idx.to_string() +
    " check_program_with_env=" +
    check_program_with_env_idx.to_string(),
  )
  assert_true(type_idx >= 0)
  assert_true(typedef_idx >= 0)
  assert_eq(typedef_count, 1)
  assert_true(check_program_idx >= 0)
  assert_true(check_program_with_env_idx >= 0)
  assert_true(typedef_idx < check_program_idx)
  assert_true(typedef_idx < check_program_with_env_idx)
}

///|
test "bundle checker_stmt selfhost module raw bundle typechecks" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let ast = db.ast_with_hash_imports(entry)
  let bundled = bundle_for_wasm_no_dce(db, entry, ast)
  let ok : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    bundled,
  )
  match ok {
    Ok(_) => ()
    Err(err) =>
      fail("raw bundle typecheck failed: " + err.diagnostic().to_string())
  }
}

///|
test "bundle checker_stmt selfhost module prepared bundle typechecks" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let ast = db.ast_with_hash_imports(entry)
  let bundled = bundle_for_wasm_no_dce(db, entry, ast)
  let desugared = @frontend.desugar_method_calls(bundled, {})
  let prepared = @frontend.rewrite_effect_handles(desugared)
  let ok : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    prepared,
  )
  match ok {
    Ok(_) => ()
    Err(err) =>
      fail("prepared bundle typecheck failed: " + err.diagnostic().to_string())
  }
}

///|
test "bundle checker_stmt selfhost module has no duplicate value names after dedupe" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let ast = db.ast_with_hash_imports(entry)
  let bundled = bundle_for_wasm_no_dce(db, entry, ast)
  let counts : Map[String, Int] = {}
  for stmt in bundled.stmts {
    let name = match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) => Some(name)
      _ => None
    }
    match name {
      Some(value_name) =>
        match counts.get(value_name) {
          Some(n) => counts[value_name] = n + 1
          None => counts[value_name] = 1
        }
      None => ()
    }
  }
  let mut dup_count = 0
  for name, count in counts {
    if count > 1 {
      dup_count = dup_count + 1
      println("duplicate-value " + name + ":" + count.to_string())
    }
  }
  assert_eq(dup_count, 0)
}

///|
test "bundle compiled checker_stmt selfhost module reports duplicate value names" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let compiled = compile_module(db, entry) catch {
    e => fail("compile_module failed: " + e.to_string())
  }
  let bundled = bundle_for_wasm_no_dce(db, entry, compiled.ast)
  let counts : Map[String, Int] = {}
  for stmt in bundled.stmts {
    let name = match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) => Some(name)
      _ => None
    }
    match name {
      Some(value_name) =>
        match counts.get(value_name) {
          Some(n) => counts[value_name] = n + 1
          None => counts[value_name] = 1
        }
      None => ()
    }
  }
  let mut dup_count = 0
  for name, count in counts {
    if count > 1 {
      dup_count = dup_count + 1
      println("compiled-duplicate-value " + name + ":" + count.to_string())
    }
  }
  assert_eq(dup_count, 0)
}

///|
test "bundle compiled checker_stmt selfhost module raw bundle typechecks" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let compiled = compile_module(db, entry) catch {
    e => fail("compile_module failed: " + e.to_string())
  }
  let bundled = bundle_for_wasm_no_dce(db, entry, compiled.ast)
  let ok : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    bundled,
  )
  match ok {
    Ok(_) => ()
    Err(err) =>
      fail(
        "compiled raw bundle typecheck failed: " + err.diagnostic().to_string(),
      )
  }
}

///|
test "bundle compiled checker_stmt selfhost module prepared bundle typechecks" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let compiled = compile_module(db, entry) catch {
    e => fail("compile_module failed: " + e.to_string())
  }
  let bundled = bundle_for_wasm_no_dce(db, entry, compiled.ast)
  let desugared = @frontend.desugar_method_calls(bundled, {})
  let prepared = @frontend.rewrite_effect_handles(desugared)
  let ok : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    prepared,
  )
  match ok {
    Ok(_) => ()
    Err(err) =>
      fail(
        "compiled prepared bundle typecheck failed: " +
        err.diagnostic().to_string(),
      )
  }
}

///|
test "bundle compiled checker_stmt selfhost module desugared bundle typechecks" {
  let (db, entry) = load_test_entry("vibe/compiler/checker/checker_stmt.vibe")
  let compiled = compile_module(db, entry) catch {
    e => fail("compile_module failed: " + e.to_string())
  }
  let bundled = bundle_for_wasm_no_dce(db, entry, compiled.ast)
  let desugared = @frontend.desugar_method_calls(bundled, {})
  let ok : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    desugared,
  )
  match ok {
    Ok(_) => ()
    Err(err) =>
      fail(
        "compiled desugared bundle typecheck failed: " +
        err.diagnostic().to_string(),
      )
  }
}
