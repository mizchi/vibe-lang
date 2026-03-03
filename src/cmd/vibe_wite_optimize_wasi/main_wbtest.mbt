test "wite optimize wasi parse minimal args" {
  let parsed = parse_cmd_args(["-o", "out.wasm", "in.wasm"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, InputMode::Binary)
      assert_eq(opts.input_path, "in.wasm")
      assert_eq(opts.output_path, "out.wasm")
      assert_eq(opts.opt_level, None)
    }
    Err(msg) => fail("unexpected parse error: " + msg)
  }
}

test "wite optimize wasi parse supports wac mode and --wite" {
  let parsed = parse_cmd_args(["--wac", "--wite", "-o", "out.component.wasm", "main.wac"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, InputMode::Wac)
      assert_eq(opts.input_path, "main.wac")
      assert_eq(opts.output_path, "out.component.wasm")
      assert_eq(opts.opt_level, Some("-Oz"))
    }
    Err(msg) => fail("unexpected parse error: " + msg)
  }
}

test "wite optimize wasi parse rejects missing output" {
  let parsed = parse_cmd_args(["in.wasm"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) => assert_eq(msg, "wite-opt: missing required -o/--output")
  }
}

test "wite optimize wasi parse rejects unknown option" {
  let parsed = parse_cmd_args(["--unknown", "-o", "out.wasm", "in.wasm"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) => assert_eq(msg, "wite-opt: unknown option: --unknown")
  }
}

test "wite optimize wasi normalize rejects unknown opt level" {
  let normalized = normalize_opt_level("-Ox")
  match normalized {
    Ok(_) => fail("expected opt-level error")
    Err(msg) =>
      assert_eq(
        msg,
        "wite-opt: unsupported wite optimize level -Ox (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
      )
  }
}

test "wite optimize wasi detects gc unsupported optimize errors" {
  assert_true(
    is_gc_unsupported_optimize_error(
      "invalid format: unsupported type form in coalesce-locals: 94",
    ),
  )
  assert_true(
    is_gc_unsupported_optimize_error(
      "invalid format: unsupported gc type form in type-refine: 95",
    ),
  )
  assert_false(is_gc_unsupported_optimize_error("some other error"))
}
