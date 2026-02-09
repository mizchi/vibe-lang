///|
test "threads recommended wasm flags" {
  let flags = recommended_wasm_flags()
  assert_eq(flags.length(), 2)
  assert_eq(flags[0], "threads=y")
  assert_eq(flags[1], "shared-memory=y")
}

///|
test "threads recommended wasi flags" {
  let flags = recommended_wasi_flags()
  assert_eq(flags.length(), 1)
  assert_eq(flags[0], "threads=y")
}

///|
test "threads flags env formatting" {
  let wasm_env = flags_to_env_value(recommended_wasm_flags())
  let wasi_env = flags_to_env_value(recommended_wasi_flags())
  assert_eq(wasm_env, "threads=y shared-memory=y")
  assert_eq(wasi_env, "threads=y")
  assert_eq(flags_to_env_value([]), "")
}

///|
test "threads probe wat contains wasi-threads primitives" {
  let wat = probe_wat()
  assert_true(wat.contains("(import \"env\" \"memory\" (memory 1 1 shared))"))
  assert_true(wat.contains("(import \"wasi\" \"thread-spawn\""))
  assert_true(wat.contains("(export \"wasi_thread_start\")"))
  assert_true(wat.contains("memory.atomic.wait32"))
  assert_true(wat.contains("memory.atomic.notify"))
}
