///|
/// Compiler hook functions injected by runtime_compile to decouple runtime
/// from direct compiler package imports (codegen, pipeline).
///
/// These are set once at initialization time before any VibeDb or Runtime
/// usage. The default implementations provide basic functionality; when
/// runtime_compile.init_hooks() is called, they are replaced with full
/// compiler-backed implementations.

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
