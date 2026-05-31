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
test "threads shared-everything recommended wasm flags" {
  let flags = shared_everything_wasm_flags()
  assert_eq(flags.length(), 3)
  assert_eq(flags[0], "gc=y")
  assert_eq(flags[1], "function-references=y")
  assert_eq(flags[2], "shared-everything-threads=y")
  assert_eq(
    flags_to_env_value(flags),
    "gc=y function-references=y shared-everything-threads=y",
  )
}

///|
test "threads shared-everything recommended wasi flags are empty" {
  let flags = shared_everything_wasi_flags()
  assert_eq(flags.length(), 0)
  assert_eq(flags_to_env_value(flags), "")
}

///|
test "threads component model threading recommended wasm flags" {
  let flags = component_model_threading_wasm_flags()
  assert_eq(flags.length(), 3)
  assert_eq(flags[0], "component-model=y")
  assert_eq(flags[1], "component-model-async=y")
  assert_eq(flags[2], "component-model-threading=y")
  assert_eq(
    flags_to_env_value(flags),
    "component-model=y component-model-async=y component-model-threading=y",
  )
}

///|
test "threads shared-everything component recommended wasm flags" {
  let flags = shared_everything_component_wasm_flags()
  assert_eq(flags.length(), 6)
  assert_eq(flags[0], "component-model=y")
  assert_eq(flags[1], "component-model-async=y")
  assert_eq(flags[2], "component-model-threading=y")
  assert_eq(flags[3], "gc=y")
  assert_eq(flags[4], "function-references=y")
  assert_eq(flags[5], "shared-everything-threads=y")
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

///|
test "threads shared-everything i31 probe wast contains current primitives" {
  let wast = shared_everything_i31_probe_wast()
  assert_true(wast.contains("(ref (shared i31))"))
  assert_true(wast.contains("(ref null (shared any))"))
  assert_true(wast.contains("ref.i31_shared"))
  assert_true(wast.contains("i31.get_u"))
  assert_true(wast.contains("(assert_return (invoke \"new\""))
}

///|
test "threads component model threading probe wast contains current intrinsics" {
  let wast = component_model_threading_probe_wast()
  assert_true(wast.contains("(component"))
  assert_true(wast.contains("canon thread.new-indirect"))
  assert_true(wast.contains("canon thread.suspend-to-suspended"))
  assert_true(wast.contains("canon thread.unsuspend"))
  assert_true(wast.contains("(assert_return (invoke \"run\")"))
}
