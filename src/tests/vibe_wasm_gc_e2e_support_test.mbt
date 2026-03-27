///|
#borrow(cmd)
extern "c" fn gc_e2e_system(cmd : Bytes) -> Int = "system"

///|
pub fn gc_e2e_system_cmd(cmd : String) -> Int {
  let encoded = @utf8.encode(cmd[:])
  let n = encoded.length()
  let bytes = Bytes::makei(n + 1, fn(i) {
    if i == n {
      b'\x00'
    } else {
      encoded[i]
    }
  })
  gc_e2e_system(bytes)
}

///|
pub fn gc_e2e_run_wasmtime(wasm_path : String, out_path : String) -> Int {
  let cmd = "wasmtime run -W gc --invoke _start " +
    wasm_path +
    " > " +
    out_path +
    " 2>&1"
  gc_e2e_system_cmd(cmd)
}

///|
pub fn gc_e2e_compile_and_run(
  source : String,
  label : String,
) -> (Int, String) raise {
  let db = VibeDb::new()
  db.set_source("main", source)
  let wasm = try @runtime_compile.compile_module_wasm_gc(db, "main") catch {
    e => fail("[\{label}] compile error: \{e.to_string()}")
  } noraise {
    b => b
  }
  if wasm.length() < 8 {
    fail("[\{label}] wasm too small: \{wasm.length()}")
  }
  let wasm_path = "/tmp/vibe_gc_e2e_\{label}.wasm"
  let out_path = "/tmp/vibe_gc_e2e_\{label}.out"
  @os_fs.write_bytes_to_file(wasm_path, wasm) catch {
    e => fail("[\{label}] write wasm failed: \{e.to_string()}")
  }
  let exit_code = gc_e2e_run_wasmtime(wasm_path, out_path)
  let output = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let _ = try? @os_fs.remove_file(wasm_path)
  let _ = try? @os_fs.remove_file(out_path)
  (exit_code, output.trim().to_string())
}

///|
pub fn gc_e2e_env_truthy(name : String) -> Bool {
  match @sys.get_env_var(name) {
    Some("1") | Some("true") | Some("TRUE") | Some("yes") | Some("on") => true
    _ => false
  }
}

///|
pub fn gc_mainlane_should_skip(test_name : String) -> Bool {
  if gc_e2e_env_truthy("VIBE_WASM_GC_MAINLANE") {
    false
  } else {
    println(
      "[wasm-gc mainlane] skipped \{test_name} (set VIBE_WASM_GC_MAINLANE=1)",
    )
    true
  }
}
