///|
test "xsh_compile_wasi parse compile args with wite default" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--wite", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::WasmGc)
      assert_false(opts.no_dce)
      assert_eq(opts.entry_path, "main.vibe")
      match opts.out_path {
        Some(path) => assert_eq(path, "/tmp/out.wasm")
        None => fail("expected out_path")
      }
      match opts.opt_level {
        Some(level) => assert_eq(level, "-Oz")
        None => fail("expected opt_level")
      }
    }
    Err(err) => fail(err)
  }
}

///|
test "xsh_compile_wasi compile args reject no-dce on wit" {
  let parsed = parse_compile_cmd_args(["--wit", "--no-dce", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --no-dce is only supported with --wasm/--wasm-mvp, --wasm-js-string, or --wasm-gc",
      )
  }
}

///|
test "xsh_compile_wasi parse compile args keeps mvp on --wasm-mvp" {
  let parsed = parse_compile_cmd_args(["--wasm-mvp", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "xsh_compile_wasi parse compile args accepts -O4" {
  let parsed = parse_compile_cmd_args(["--wasm-gc", "-O4", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::WasmGc)
      match opts.opt_level {
        Some(level) => assert_eq(level, "-O4")
        None => fail("expected opt_level")
      }
    }
    Err(err) => fail(err)
  }
}
