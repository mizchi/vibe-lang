///|
struct SizeSnapshot {
  wasm_size : Int?
  ir_size : Int
  note : String?
} derive(Show)

///|
fn snapshot_sizes(
  name : String,
  source : String,
  use_js_strings? : Bool = false,
) -> SizeSnapshot raise {
  let db = @xsh.XshDb::new()
  db.set_source(name, source)
  let compiled = try @xsh.compile_module(db, name) catch {
    e => fail("[\{name}] compile error: \{e.to_string()}")
  } noraise {
    c => c
  }
  let ir_size = compiled.ir.length()
  let wasm_result : Result[Int, String] = if use_js_strings {
    try @xsh.compile_module_wasm_js_string(db, name) catch {
      e => Err(e.to_string())
    } noraise {
      wasm => Ok(wasm.length())
    }
  } else {
    try @xsh.compile_module_wasm(db, name) catch {
      e => Err(e.to_string())
    } noraise {
      wasm => Ok(wasm.length())
    }
  }
  match wasm_result {
    Ok(size) => SizeSnapshot::{ wasm_size: Some(size), ir_size, note: None }
    Err(msg) => SizeSnapshot::{ wasm_size: None, ir_size, note: Some(msg) }
  }
}

///|
test "bench: wasm.size.pipeline" {
  let snapshot = snapshot_sizes("bench_pipeline", sample_pipeline_script)
  inspect(snapshot, content="{wasm_size: Some(74), ir_size: 237, note: None}")
}

///|
test "bench: wasm.size.pipeline_js_string" {
  let snapshot = snapshot_sizes(
    "bench_pipeline_js_string",
    sample_pipeline_js_string_script,
    use_js_strings=true,
  )
  inspect(snapshot, content="{wasm_size: Some(131), ir_size: 184, note: None}")
}

///|
test "bench: wasm.size.user_fn" {
  let snapshot = snapshot_sizes("bench_user_fn", sample_user_fn_script)
  inspect(
    snapshot,
    content=(
      #|{wasm_size: Some(290), ir_size: 344, note: None}
    ),
  )
}

///|
test "bench: wasm.size.effect_ho" {
  let snapshot = snapshot_sizes("bench_effect_ho", sample_effect_ho_script)
  inspect(
    snapshot,
    content=(
      #|{wasm_size: Some(424), ir_size: 930, note: None}
    ),
  )
}
