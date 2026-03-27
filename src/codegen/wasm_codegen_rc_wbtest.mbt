///|
/// Helper: create a LetMut stmt
fn rc_let_mut(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::LetMut(name~, expr~, span=wb_span())
}

///|
/// Helper: create an Assign stmt
fn rc_assign(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Assign(name~, expr~, span=wb_span())
}

///|
test "RC codegen: enable_rc flag is set in context" {
  let options = wasm_emit_options(enable_rc=true)
  assert_true(options.enable_rc)
  let options2 = wasm_emit_options()
  assert_false(options2.enable_rc)
}

///|
test "RC codegen: build_rc_action_maps parses site strings" {
  let actions : Array[(String, Bool, String)] = [
    ("stmt[0].after", false, "x"),
    ("stmt[1].old_value", false, "y"),
    ("stmt[2].before", true, "z"),
  ]
  let (pre, post) = build_rc_action_maps(actions)
  // stmt[1].old_value → pre[1]
  inspect(pre.get(1).map(fn(a) { a.length() }), content="Some(1)")
  // stmt[0].after → post[0]
  inspect(post.get(0).map(fn(a) { a.length() }), content="Some(1)")
  // stmt[2].before → post[2] (not old_value, so it's post)
  inspect(post.get(2).map(fn(a) { a.length() }), content="Some(1)")
}

///|
test "RC codegen: emit_rc_init generates extra WASM bytes" {
  let buf = ByteBuf::new()
  let len_before = buf.len
  emit_rc_init(buf, 0, 16)
  let len_after = buf.len
  // emit_rc_init: local.get + i32.const + i32.sub + i32.const + i32.store
  assert_true(len_after > len_before)
}

///|
test "RC codegen: emit_rc_init called during tuple compilation" {
  let tuple_expr = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let ast = @core.Module::{
    stmts: [wb_let("x", tuple_expr), wb_expr(wb_ident("x"))],
  }
  let options = wasm_emit_options(enable_rc=true)
  let wat = wasm_to_wat(emit_module_wasm_with_options(ast, options))
  // RC init uses i32.sub to compute ptr-4 for the RC field
  assert_true(wat.contains("i32.sub"))
}

///|
test "RC codegen: mutable assign emits rc_drop on old value" {
  let tuple1 = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let tuple2 = @core.Expr::Tuple(
    items=[wb_int(3), wb_int(4)],
    span=wb_span(),
  )
  let ast = @core.Module::{
    stmts: [rc_let_mut("x", tuple1), rc_assign("x", tuple2)],
  }
  let options = wasm_emit_options(enable_rc=true)
  let wat = wasm_to_wat(emit_module_wasm_with_options(ast, options))
  // Should contain RC drop pattern: tag check + i32.sub (decrement)
  assert_true(wat.contains("i32.sub"))
}

///|
test "RC codegen: perceus plan actions emit dup/drop at stmt boundaries" {
  let tuple_expr = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let ast = @core.Module::{
    stmts: [wb_let("x", tuple_expr), wb_expr(wb_ident("x"))],
  }
  // Verify the action maps are built correctly
  let rc_actions : Array[(String, Bool, String)] = [
    ("stmt[1].after", false, "x"),
  ]
  let (pre, post) = build_rc_action_maps(rc_actions)
  inspect(pre.length(), content="0")
  inspect(post.length(), content="1")
  inspect(
    post.get(1).map(fn(a) { a[0].name }),
    content="Some(\"x\")",
  )
  // Compile with RC + actions
  let options_rc = wasm_emit_options(enable_rc=true, rc_actions~)
  let wasm_rc = emit_module_wasm_with_options(ast, options_rc)
  let wat = wasm_to_wat(wasm_rc)
  // i32.sub should be present from stmt-boundary actions or assign-time drops
  assert_true(wat.contains("i32.sub"))
}

///|
test "RC codegen: negative-offset layout preserves field offsets" {
  let tuple_expr = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let ast_no_rc = @core.Module::{
    stmts: [wb_let("x", tuple_expr), wb_expr(wb_ident("x"))],
  }
  let ast_rc = @core.Module::{
    stmts: [wb_let("x", tuple_expr), wb_expr(wb_ident("x"))],
  }
  let wat_no_rc = wasm_to_wat(
    emit_module_wasm_with_options(ast_no_rc, wasm_emit_options()),
  )
  let wat_rc = wasm_to_wat(
    emit_module_wasm_with_options(ast_rc, wasm_emit_options(enable_rc=true)),
  )
  // RC version has i32.sub for the ptr-4 computation
  assert_true(wat_rc.contains("i32.sub"))
  // Both should have i32.store for tuple fields
  assert_true(wat_no_rc.contains("i32.store"))
  assert_true(wat_rc.contains("i32.store"))
}

///|
test "RC codegen: rc_drop tombstones object when rc reaches 0" {
  // let mut x = (1, 2)
  // x = (3, 4)  ← drops old tuple, rc should reach 0 → tombstone
  let tuple1 = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let tuple2 = @core.Expr::Tuple(
    items=[wb_int(3), wb_int(4)],
    span=wb_span(),
  )
  let ast = @core.Module::{
    stmts: [rc_let_mut("x", tuple1), rc_assign("x", tuple2)],
  }
  let options = wasm_emit_options(enable_rc=true)
  let wat = wasm_to_wat(emit_module_wasm_with_options(ast, options))
  // The tombstone logic uses i32.eqz to check if new_rc == 0
  assert_true(wat.contains("i32.eqz"))
  // And an if block for the tombstone write
  assert_true(wat.contains("if"))
}

///|
test "RC codegen: per-function actions emit dup/drop in named functions" {
  // let f = fn() { let x = (1, 2); x }
  // f()
  let fn_body = @core.Module::{
    stmts: [
      wb_let(
        "x",
        @core.Expr::Tuple(items=[wb_int(1), wb_int(2)], span=wb_span()),
      ),
      wb_expr(wb_ident("x")),
    ],
  }
  let fn_expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[],
    ret=None,
    effects=[],
    body=fn_body,
    span=wb_span(),
  )
  let ast = @core.Module::{
    stmts: [
      wb_let("f", fn_expr),
      wb_expr(
        @core.Expr::Call(name="f", args=[], span=wb_span(), type_args=[]),
      ),
    ],
  }
  // Build per-function actions: drop x after stmt[1] in f's body
  let rc_func_actions : Map[String, Array[(String, Bool, String)]] = {
    "f": [("stmt[0].after", false, "x")],
  }
  let options = wasm_emit_options(
    enable_rc=true,
    rc_func_actions~,
  )
  let wat = wasm_to_wat(emit_module_wasm_with_options(ast, options))
  // Should contain RC operations (i32.eqz from tombstone check in rc_drop)
  assert_true(wat.contains("i32.eqz"))
}

///|
test "RC codegen: without enable_rc no RC operations emitted" {
  let tuple_expr = @core.Expr::Tuple(
    items=[wb_int(1), wb_int(2)],
    span=wb_span(),
  )
  let ast = @core.Module::{ stmts: [wb_let("x", tuple_expr)] }
  let options = wasm_emit_options()
  let wat = wasm_to_wat(emit_module_wasm_with_options(ast, options))
  // Without RC, no i32.sub for rc operations
  assert_false(wat.contains("i32.sub"))
}
