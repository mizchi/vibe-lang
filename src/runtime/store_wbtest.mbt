///|
test "Runtime::new does not eagerly evaluate prelude AST" {
  let old_prelude_ast_hook = prelude_ast_hook.val
  let prelude_ast_called : Ref[Bool] = { val: false }
  prelude_ast_hook.val = fn() {
    prelude_ast_called.val = true
    { stmts: [] }
  }
  defer {
    prelude_ast_hook.val = old_prelude_ast_hook
  }

  let _ = Runtime::new(@capability.CapabilitySet::new())
  assert_false(prelude_ast_called.val)
}

///|
test "RuntimeFeatureFlags tracks thread backend id" {
  let stable = RuntimeFeatureFlags::stable()
  assert_eq(stable.thread_backend_id(), "linear-local")
  assert_false(stable.is_unstable_threads_enabled())
  let unsafe_threads = RuntimeFeatureFlags::new_with_thread_backend(
    false, true, "component-unsafe-os-threads",
  )
  assert_true(unsafe_threads.is_unstable_threads_enabled())
  assert_eq(unsafe_threads.thread_backend_id(), "component-unsafe-os-threads")
}
