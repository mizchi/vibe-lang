///|
test "vibe_compile_wasi parse compile args --wasm maps to MVP" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--wite", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_false(opts.no_dce)
      assert_false(opts.debug_errors)
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
test "vibe_compile_wasi compile args reject no-dce on wit" {
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
test "vibe_compile_wasi parse compile args keeps mvp on --wasm-mvp" {
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
test "vibe_compile_wasi parse compile args accepts -O4" {
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

///|
test "vibe_compile_wasi parse compile args http host imports on wasm-mvp" {
  let parsed = parse_compile_cmd_args([
    "--wasm-mvp", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.http_host_imports)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args http host imports on component" {
  let parsed = parse_compile_cmd_args([
    "--component", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Component)
      assert_true(opts.http_host_imports)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args accept http host imports on --wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.http_host_imports)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args supports wac mode" {
  let parsed = parse_compile_cmd_args(["--wac", "--wite", "main.wac"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wac)
      assert_eq(opts.entry_path, "main.wac")
      match opts.opt_level {
        Some(level) => assert_eq(level, "-Oz")
        None => fail("expected opt_level")
      }
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args --wasm-gc maps to WasmGc" {
  let parsed = parse_compile_cmd_args(["--wasm-gc", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::WasmGc)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args --debug-errors accepted on --wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--debug-errors", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.debug_errors)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi parse compile args reject --debug-errors on --wasm-gc" {
  let parsed = parse_compile_cmd_args([
    "--wasm-gc", "--debug-errors", "main.vibe",
  ])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --debug-errors is only supported with --wasm or --wasm-js-string",
      )
  }
}

///|
test "vibe_compile_wasi parse compile args reject http host imports on --wasm-gc" {
  let parsed = parse_compile_cmd_args([
    "--wasm-gc", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --http-host-imports is only supported with --wasm or --component",
      )
  }
}
