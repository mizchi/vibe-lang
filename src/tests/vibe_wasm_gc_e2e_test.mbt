///|
#borrow(cmd)
extern "c" fn gc_e2e_system(cmd : Bytes) -> Int = "system"

///|
fn gc_e2e_system_cmd(cmd : String) -> Int {
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
fn gc_e2e_run_wasmtime(wasm_path : String, out_path : String) -> Int {
  let cmd = "wasmtime run -W gc --invoke _start " +
    wasm_path +
    " > " +
    out_path +
    " 2>&1"
  gc_e2e_system_cmd(cmd)
}

///|
fn gc_e2e_compile_and_run(
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
  // cleanup
  let _ = try? @os_fs.remove_file(wasm_path)
  let _ = try? @os_fs.remove_file(out_path)
  (exit_code, output.trim().to_string())
}

///|
test "wasm-gc e2e: return 42" {
  let src =
    #|let main = () -> Int { 42 }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "return_42")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("42") {
    fail("output should contain 42, got: \{output}")
  }
}

///|
test "wasm-gc e2e: arithmetic" {
  let src =
    #|let main = () -> Int { let x = 1; let y = 2; x + y }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "arithmetic")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("3") {
    fail("output should contain 3, got: \{output}")
  }
}

///|
test "wasm-gc e2e: if-else" {
  let src =
    #|let main = () -> Int { if true { 1 } else { 0 } }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "if_else")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("1") {
    fail("output should contain 1, got: \{output}")
  }
}
