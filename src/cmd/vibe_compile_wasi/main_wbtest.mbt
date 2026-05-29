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
  let parsed = parse_compile_cmd_args(["--wasm", "--debug-errors", "main.vibe"])
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

///|
test "vibe_compile_wasi compile-lite validate allows wasm no-dce" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--no-dce", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => ()
        Err(err) => fail(err)
      }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi compile-lite validate rejects component mode" {
  let parsed = parse_compile_cmd_args([
    "--component", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => fail("expected validation error")
        Err(err) =>
          assert_eq(
            err, "compile-lite: only --wasm/--wasm-linear/--wasm-gc mode is supported",
          )
      }
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi compile-lite split args extracts profile tsv path" {
  let parsed = split_compile_lite_args([
    "--wasm", "--profile-tsv", "/tmp/profile.tsv", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok((args, Some(path), _, in_memory)) => {
      assert_eq(path, "/tmp/profile.tsv")
      assert_eq(args.length(), 4)
      assert_eq(args[0], "--wasm")
      assert_eq(args[1], "-o")
      assert_false(in_memory)
    }
    Ok(_) => fail("expected profile path")
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi compile-lite split args extracts callstack profile path" {
  let parsed = split_compile_lite_args([
    "--wasm", "--profile-callstack", "/tmp/profile.callstack.tsv", "-o", "/tmp/out.wasm",
    "main.vibe",
  ])
  match parsed {
    Ok((args, _, Some(path), in_memory)) => {
      assert_eq(path, "/tmp/profile.callstack.tsv")
      assert_eq(args.length(), 4)
      assert_eq(args[0], "--wasm")
      assert_eq(args[1], "-o")
      assert_false(in_memory)
    }
    Ok(_) => fail("expected callstack profile path")
    Err(err) => fail(err)
  }
}

///|
test "vibe_compile_wasi compile-lite split args rejects missing profile path" {
  let parsed = split_compile_lite_args(["--wasm", "--profile-tsv"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_eq(err, "compile-lite: missing path after --profile-tsv")
  }
}

///|
test "vibe_compile_wasi compile-lite split args rejects missing callstack profile path" {
  let parsed = split_compile_lite_args(["--wasm", "--profile-callstack"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) =>
      assert_eq(err, "compile-lite: missing path after --profile-callstack")
  }
}

///|
test "vibe_compile_wasi compile-lite validate allows in-memory without out" {
  let parsed = parse_compile_cmd_args(["--wasm", "main.vibe"])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, true) {
        Ok(_) => ()
        Err(err) => fail(err)
      }
    Err(err) => fail(err)
  }
}
