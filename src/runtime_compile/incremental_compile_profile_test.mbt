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
  let (cold, hot) = profiled_compile_pair(
    "vibe/compiler/checker_trait_test.vibe",
  )
  print_profile_summary("short", cold, hot)
  assert_true(hot.total_us < cold.total_us)
  assert_true(hot.module_us < cold.module_us)
  assert_eq(hot.emit_us, 0)
  assert_eq(hot.optimize_us, 0)
  assert_true(hot.total_us * 4 < cold.total_us)
}

///|
test "incremental compile profile medium" {
  let (cold, hot) = profiled_compile_pair(
    "vibe/compiler/builtins_type_test.vibe",
  )
  print_profile_summary("medium", cold, hot)
  assert_true(hot.total_us < cold.total_us)
  assert_true(hot.module_us < cold.module_us)
  assert_eq(hot.emit_us, 0)
  assert_eq(hot.optimize_us, 0)
  assert_true(hot.total_us * 4 < cold.total_us)
}
