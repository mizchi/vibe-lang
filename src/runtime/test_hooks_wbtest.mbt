///|
/// Initialize compiler hooks for whitebox tests.
/// This file provides the real @parser and @checker backed implementations
/// so that whitebox tests in the runtime package can exercise full
/// parsing and type checking.

///|
fn init {
  // Parser hooks
  parse_ast_hook.val = fn(
    source,
  ) -> (@core.Module, @core.Diagnostic?) {
    let ast = @parser.parse_ast(source) catch {
      e => return ({ stmts: [] }, Some(e.diagnostic()))
    }
    (ast, None)
  }
  parse_cst_hook.val = fn(source) { @parser.parse_cst(source) }
  // Checker hooks
  purity_for_let_hook.val = @checker.purity_for_let
  new_type_env_hook.val = fn() { @checker.TypeEnv::new() }
  get_prelude_env_hook.val = fn() {
    try! @checker.get_prelude_only_env_for_module()
  }
  type_check_with_env_hook.val = @checker.type_check_with_env
  compiler_hooks_initialized.val = true
  init_runtime_type_env_hook.val = fn() {
    let env = @checker.TypeEnv::new()
    let _ = try! @checker.ensure_prelude_option(env)
    let _ = try! @checker.ensure_prelude_functions(env, {})
    @checker.ensure_builtin_modules(env, {})
    env
  }
  prelude_ast_hook.val = @checker.prelude_ast
  collect_warnings_hook.val = @checker.collect_warnings
}
