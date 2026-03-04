///|
fn wbtest_temp_dir(name : String) -> String {
  let root = "/tmp/vibe_wasm_wbtest_" + name + "_" + @env.now().to_string()
  @os_fs.create_dir(root) catch {
    _ => ()
  }
  root
}

///|
fn wbtest_remove_file_if_exists(path : String) -> Unit {
  let exists = @os_fs.path_exists(path)
  if not(exists) {
    return
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if is_file {
    ignore(@os_fs.remove_file(path) catch { _ => () })
  }
}

///|
test "parse cmd args defaults to run core wasm" {
  let parsed = parse_cmd_args(["examples/hello.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.command, CommandKind::Run)
      assert_eq(opts.mode, RunMode::CoreWasm)
      assert_eq(opts.entry_path, "examples/hello.vibe")
      assert_false(opts.keep_artifact)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "parse cmd args compile component with out and wite" {
  let parsed = parse_cmd_args([
    "compile", "--component", "--wite", "-o", "dist/app.component.wasm", "app.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.command, CommandKind::Compile)
      assert_eq(opts.mode, RunMode::Component)
      assert_eq(opts.out_path, Some("dist/app.component.wasm"))
      assert_eq(opts.opt_level, Some("-Oz"))
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "default output path uses mode extension" {
  assert_eq(
    default_output_path("examples/hello.vibe", RunMode::CoreWasm),
    "dist/hello.wasm",
  )
  assert_eq(
    default_output_path("examples/hello.vibe", RunMode::Component),
    "dist/hello.component.wasm",
  )
}

///|
test "parse compare rejects explicit output path" {
  let parsed = parse_cmd_args([
    "compare", "-o", "dist/out.wasm", "examples/hello.vibe",
  ])
  match parsed {
    Ok(_) => fail("expected compare parse error")
    Err(msg) =>
      assert_true(msg.contains("vibe_wasm compare: -o/--out is not supported"))
  }
}

///|
test "component invoke default uses run signature" {
  let runner = { wasmtime_bin: "/bin/wasmtime", wasm_flags: [], wasi_flags: [] }
  let cmd = build_wasmtime_invoke_command(
    runner,
    RunMode::Component,
    "/tmp/app.component.wasm",
    None,
  )
  assert_true(cmd.contains("--invoke"))
  assert_true(cmd.contains("\"run()\""))
}

///|
test "snapshot restore rewinds file content" {
  let root = wbtest_temp_dir("snapshot_rewind")
  let file = root + "/index.lock"
  @os_fs.write_string_to_file(file, "before") catch {
    e => fail("write before failed: " + e.to_string())
  }
  let snapshot = snapshot_file(file)
  @os_fs.write_string_to_file(file, "after") catch {
    e => fail("write after failed: " + e.to_string())
  }
  restore_file_snapshot(file, snapshot)
  let restored = @os_fs.read_file_to_string(file) catch {
    e => fail("read restored failed: " + e.to_string())
  }
  assert_eq(restored, "before")
  wbtest_remove_file_if_exists(file)
}

///|
test "snapshot restore removes newly created file" {
  let root = wbtest_temp_dir("snapshot_remove")
  let file = root + "/index.lock"
  let snapshot = snapshot_file(file)
  @os_fs.write_string_to_file(file, "created") catch {
    e => fail("write created failed: " + e.to_string())
  }
  restore_file_snapshot(file, snapshot)
  let exists = @os_fs.path_exists(file)
  assert_false(exists)
}
