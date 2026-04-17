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
