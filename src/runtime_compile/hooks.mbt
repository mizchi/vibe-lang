///|
let hooks_initialized : Ref[Bool] = { val: false }

///|
/// Initialize runtime compiler hooks.
/// Wires compiler-backed implementations into the runtime package
/// via its hook mechanism, decoupling runtime from direct imports
/// of parser, checker, codegen, and pipeline.
/// Safe to call multiple times (idempotent).
pub fn init_hooks() -> Unit {
  if hooks_initialized.val {
    return
  }
  hooks_initialized.val = true
  // Codegen & pipeline
  @runtime.set_expr_address_hook(@codegen.expr_address)
  @runtime.set_desugar_method_calls_hook(@pipeline.desugar_method_calls)
  // Parser
  @runtime.set_parse_ast_hook(fn(
    source,
  ) -> (@core.Module, @core.Diagnostic?) {
    let ast = @parser.parse_ast(source) catch {
      e => return ({ stmts: [] }, Some(e.diagnostic()))
    }
    (ast, None)
  })
  @runtime.set_parse_cst_hook(@parser.parse_cst)
  // Checker: purity
  @runtime.set_purity_for_let_hook(@checker.purity_for_let)
  // Checker: type env creation
  @runtime.set_new_type_env_hook(fn() { @checker.TypeEnv::new() })
  @runtime.set_get_prelude_env_hook(fn() {
    try! @checker.get_prelude_only_env_for_module()
  })
  @runtime.set_type_check_with_env_hook(@checker.type_check_with_env)
  @runtime.mark_compiler_hooks_initialized()
  // Checker: runtime init
  @runtime.set_init_runtime_type_env_hook(fn() {
    let env = @checker.TypeEnv::new()
    let _ = try! @checker.ensure_prelude_option(env)
    let _ = try! @checker.ensure_prelude_functions(env, {})
    @checker.ensure_builtin_modules(env, {})
    env
  })
  @runtime.set_prelude_ast_hook(@checker.prelude_ast)
  // Checker: warnings
  @runtime.set_collect_warnings_hook(@checker.collect_warnings)
}

///|
/// Ensure hooks are initialized. Called automatically by key entry points.
fn ensure_hooks() -> Unit {
  if !hooks_initialized.val {
    init_hooks()
  }
}
