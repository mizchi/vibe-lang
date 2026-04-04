///|
/// Compiler hook functions injected by runtime_compile to decouple runtime
/// from direct compiler package imports (codegen, pipeline, parser, checker).
///
/// These are set once at initialization time before any VibeDb or Runtime
/// usage. The default implementations provide basic functionality; when
/// runtime_compile.init_hooks() is called, they are replaced with full
/// compiler-backed implementations.
///
/// Critical hooks (type checking, prelude init) will abort with a clear
/// message if called before init_hooks() — this prevents silent misuse.

///|
/// Tracks whether compiler hooks have been initialized.
/// Critical hooks check this flag and abort if false.
let compiler_hooks_initialized : Ref[Bool] = { val: false }

///|
/// Mark hooks as initialized. Called by set_type_check_with_env_hook.
pub fn mark_compiler_hooks_initialized() -> Unit {
  compiler_hooks_initialized.val = true
}

///|
fn assert_hooks_initialized(caller : String) -> Unit {
  if not(compiler_hooks_initialized.val) {
    abort(
      caller +
      ": compiler hooks not initialized. Call runtime_compile.init_hooks() first.",
    )
  }
}

///|
/// Hook: compute a content-addressed expression address for caching.
/// Default: hash the expression's string representation.
/// Replaced by @codegen.expr_address when runtime_compile is loaded.
let expr_address_hook : Ref[
  (@core.Expr, Map[String, String], String?) -> String,
] = {
  val: fn(expr, _env, _self_name) {
    @core.git_blob_hash_string(expr.to_string())
  },
}

///|
/// Hook: desugar method calls in a module.
/// Default: identity (no desugaring).
/// Replaced by @pipeline.desugar_method_calls when runtime_compile is loaded.
let desugar_method_calls_hook : Ref[
  (@core.Module, Map[String, @core.Ref]) -> @core.Module,
] = { val: fn(ast, _aliases) { ast } }

///|
/// Set the expr_address hook (called by runtime_compile at init time).
pub fn set_expr_address_hook(
  f : (@core.Expr, Map[String, String], String?) -> String,
) -> Unit {
  expr_address_hook.val = f
}

///|
/// Set the desugar_method_calls hook (called by runtime_compile at init time).
pub fn set_desugar_method_calls_hook(
  f : (@core.Module, Map[String, @core.Ref]) -> @core.Module,
) -> Unit {
  desugar_method_calls_hook.val = f
}

///|
/// Compute expr address using the injected hook.
pub fn compute_expr_address(
  expr : @core.Expr,
  env : Map[String, String],
  self_name : String?,
) -> String {
  (expr_address_hook.val)(expr, env, self_name)
}

///|
/// Desugar method calls using the injected hook.
pub fn desugar_method_calls(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  (desugar_method_calls_hook.val)(ast, aliases)
}

///|
/// Hook: parse source code to AST.
/// Default: returns empty module (no parser linked).
/// Replaced by @parser.parse_ast when runtime_compile is loaded.
let parse_ast_hook : Ref[
  (String) -> (@core.Module, @core.Diagnostic?) raise Error,
] = {
  val: fn(_source) -> (@core.Module, @core.Diagnostic?) raise Error {
    ({ stmts: [] }, None)
  },
}

///|
/// Hook: parse source code to CST.
/// Default: returns empty node.
/// Replaced by @parser.parse_cst when runtime_compile is loaded.
let parse_cst_hook : Ref[(String) -> @cst.SyntaxNode] = {
  val: fn(_source) {
    let builder = @cst.GreenNodeBuilder::new()
    builder.start_node(@cst.SyntaxKind::eof())
    builder.finish_node()
    @cst.SyntaxNode::new_root(builder.finish())
  },
}

///|
/// Set the parse_ast hook (called by runtime_compile at init time).
pub fn set_parse_ast_hook(
  f : (String) -> (@core.Module, @core.Diagnostic?) raise Error,
) -> Unit {
  parse_ast_hook.val = f
}

///|
/// Set the parse_cst hook (called by runtime_compile at init time).
pub fn set_parse_cst_hook(f : (String) -> @cst.SyntaxNode) -> Unit {
  parse_cst_hook.val = f
}

///|
fn hook_parse_ast(source : String) -> @core.Module raise Error {
  let (m, _diag) = (parse_ast_hook.val)(source)
  m
}

///|
fn hook_parse_ast_diagnostic(
  source : String,
) -> (@core.Module?, @core.Diagnostic?) {
  try {
    let (m, diag) = (parse_ast_hook.val)(source)
    (Some(m), diag)
  } catch {
    e =>
      (
        None,
        Some(@core.Diagnostic::{
          stage: "parse",
          message: e.to_string(),
          span: None,
          hint: None,
          note: None,
          severity: None,
          code: None,
        }),
      )
  }
}

///|
fn hook_parse_cst(source : String) -> @cst.SyntaxNode {
  (parse_cst_hook.val)(source)
}

///|
/// Hook: compute purity info for a let binding.
/// Default: returns impure.
/// Replaced by @checker.purity_for_let when runtime_compile is loaded.
let purity_for_let_hook : Ref[
  (@checker.TypeEnv, Bool, String, @core.Expr) -> @checker.PurityInfo,
] = {
  val: fn(_env, _rec, _name, _expr) {
    @checker.PurityInfo::{
      expr: false,
      value: false,
      expr_tier: @checker.TopLevelPurityTier::Impure,
      value_tier: @checker.TopLevelPurityTier::Impure,
    }
  },
}

///|
/// Set the purity_for_let hook (called by runtime_compile at init time).
pub fn set_purity_for_let_hook(
  f : (@checker.TypeEnv, Bool, String, @core.Expr) -> @checker.PurityInfo,
) -> Unit {
  purity_for_let_hook.val = f
}

///|
/// Compute purity info using the injected hook.
pub fn hook_purity_for_let(
  env : @checker.TypeEnv,
  rec : Bool,
  name : String,
  expr : @core.Expr,
) -> @checker.PurityInfo {
  (purity_for_let_hook.val)(env, rec, name, expr)
}

///|
/// Hook: create a new TypeEnv.
/// Default: returns @checker.TypeEnv::new().
let new_type_env_hook : Ref[() -> @checker.TypeEnv] = {
  val: fn() { @checker.TypeEnv::new() },
}

///|
pub fn set_new_type_env_hook(f : () -> @checker.TypeEnv) -> Unit {
  new_type_env_hook.val = f
}

///|
pub fn hook_new_type_env() -> @checker.TypeEnv {
  (new_type_env_hook.val)()
}

///|
/// Hook: initialize a prelude-equipped TypeEnv for a new module.
/// Default: returns @checker.TypeEnv::new() (no prelude).
/// Replaced by the real @checker.get_prelude_only_env_for_module when
/// runtime_compile is loaded.
let get_prelude_env_hook : Ref[() -> @checker.TypeEnv] = {
  val: fn() { @checker.TypeEnv::new() },
}

///|
pub fn set_get_prelude_env_hook(f : () -> @checker.TypeEnv) -> Unit {
  get_prelude_env_hook.val = f
}

///|
pub fn hook_get_prelude_env() -> @checker.TypeEnv {
  assert_hooks_initialized("hook_get_prelude_env")
  (get_prelude_env_hook.val)()
}

///|
/// Hook: type check a module with an existing TypeEnv.
/// Default: returns the env unchanged (no type checking).
/// Replaced by @checker.type_check_with_env when runtime_compile is loaded.
let type_check_with_env_hook : Ref[
  (@checker.TypeEnv, @core.Module, Map[String, @core.Ref]) -> @checker.TypeEnv raise @checker.TypeError,
] = {
  val: fn(env, _ast, _aliases) -> @checker.TypeEnv raise @checker.TypeError {
    env
  },
}

///|
pub fn set_type_check_with_env_hook(
  f : (@checker.TypeEnv, @core.Module, Map[String, @core.Ref]) -> @checker.TypeEnv raise @checker.TypeError,
) -> Unit {
  type_check_with_env_hook.val = f
}

///|
pub fn hook_type_check_with_env(
  env : @checker.TypeEnv,
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> @checker.TypeEnv raise @checker.TypeError {
  assert_hooks_initialized("hook_type_check_with_env")
  (type_check_with_env_hook.val)(env, ast, aliases)
}

///|
/// Hook: initialize a Runtime's TypeEnv with prelude.
/// Default: returns @checker.TypeEnv::new() (no prelude).
/// Replaced by the real init logic when runtime_compile is loaded.
let init_runtime_type_env_hook : Ref[() -> @checker.TypeEnv] = {
  val: fn() { @checker.TypeEnv::new() },
}

///|
pub fn set_init_runtime_type_env_hook(f : () -> @checker.TypeEnv) -> Unit {
  init_runtime_type_env_hook.val = f
}

///|
pub fn hook_init_runtime_type_env() -> @checker.TypeEnv {
  assert_hooks_initialized("hook_init_runtime_type_env")
  (init_runtime_type_env_hook.val)()
}

///|
/// Hook: get the prelude AST module.
/// Default: returns empty module.
/// Replaced by @checker.prelude_ast when runtime_compile is loaded.
let prelude_ast_hook : Ref[() -> @core.Module] = { val: fn() { { stmts: [] } } }

///|
pub fn set_prelude_ast_hook(f : () -> @core.Module) -> Unit {
  prelude_ast_hook.val = f
}

///|
pub fn hook_prelude_ast() -> @core.Module {
  (prelude_ast_hook.val)()
}

///|
/// Hook: collect warnings from an AST.
/// Default: returns empty array.
/// Replaced by @checker.collect_warnings when runtime_compile is loaded.
let collect_warnings_hook : Ref[(@core.Module) -> Array[@core.Diagnostic]] = {
  val: fn(_ast) { [] },
}

///|
pub fn set_collect_warnings_hook(
  f : (@core.Module) -> Array[@core.Diagnostic],
) -> Unit {
  collect_warnings_hook.val = f
}

///|
pub fn hook_collect_warnings(ast : @core.Module) -> Array[@core.Diagnostic] {
  (collect_warnings_hook.val)(ast)
}
