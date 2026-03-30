///|
let hooks_initialized : Ref[Bool] = { val: false }

///|
/// Initialize runtime compiler hooks.
/// Wires @codegen.expr_address and @pipeline.desugar_method_calls
/// into the runtime package via its hook mechanism.
/// Safe to call multiple times (idempotent).
pub fn init_hooks() -> Unit {
  if hooks_initialized.val {
    return
  }
  hooks_initialized.val = true
  @runtime.set_expr_address_hook(@codegen.expr_address)
  @runtime.set_desugar_method_calls_hook(@pipeline.desugar_method_calls)
}

///|
/// Ensure hooks are initialized. Called automatically by key entry points.
fn ensure_hooks() -> Unit {
  if not(hooks_initialized.val) {
    init_hooks()
  }
}
