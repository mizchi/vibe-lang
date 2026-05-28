///|
/// Issue #417 / Phase A: wasm-gc coverage instrumentation. The
/// public `emit_module_wasm_gc_with_coverage` mirrors the linear
/// backend's `emit_module_wasm_with_coverage` so the same JS reader
/// (`scripts/coverage_wasm_source.mjs`) and `.wasm.cov.json` sidecar
/// path work on either backend.

///|
fn cov_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn cov_int(n : Int64) -> @core.Expr {
  @core.Expr::Int(value=n, span=cov_span())
}

///|
fn cov_call(name : String, args : Array[@core.Expr]) -> @core.Expr {
  let span = cov_span()
  let call_args : Array[@core.CallArg] = []
  for a in args {
    call_args.push(@core.CallArg::{ label: None, expr: a, span })
  }
  @core.Expr::Call(name~, type_args=[], args=call_args, span~)
}

///|
fn cov_fn_int(stmts : Array[@core.Stmt]) -> @core.Expr {
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[],
    ret=Some(@core.Type::Int),
    effects=[],
    body=@core.Module::{ stmts, },
    span=cov_span(),
  )
}

///|
fn cov_let(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Let(rec=false, name~, expr~, span=cov_span())
}

///|
fn cov_stmt_expr(expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Expr(expr~, span=cov_span())
}

///|
/// `let main = () -> Int { 42 }` then `main()`.
fn cov_simple_ast() -> @core.Module {
  let body = [cov_stmt_expr(cov_int(42L))]
  @core.Module::{
    stmts: [
      cov_let("main", cov_fn_int(body)),
      cov_stmt_expr(cov_call("main", [])),
    ],
  }
}

///|
/// `let main = () -> Int { if true { 1 } else { 2 } }` then `main()`.
fn cov_if_ast() -> @core.Module {
  let then_body : @core.Module = { stmts: [cov_stmt_expr(cov_int(1L))] }
  let else_body : @core.Module = { stmts: [cov_stmt_expr(cov_int(2L))] }
  let if_expr = @core.Expr::If(
    cond=@core.Expr::Bool(value=true, span=cov_span()),
    then_body~,
    else_body~,
    span=cov_span(),
  )
  let main_body = [cov_stmt_expr(if_expr)]
  @core.Module::{
    stmts: [
      cov_let("main", cov_fn_int(main_body)),
      cov_stmt_expr(cov_call("main", [])),
    ],
  }
}

///|
test "emit_module_wasm_gc_with_coverage records points and emits valid header" {
  let ast = cov_simple_ast()
  let artifact = try! emit_module_wasm_gc_with_coverage(ast)
  // At least the two top-level statements get Line points.
  @debug.assert_eq(artifact.points.length() >= 2, true)
  @debug.assert_eq(artifact.counter_base, 0)
  @debug.assert_eq(artifact.counter_count, artifact.points.length())
  // Wasm magic + version (\0asm 0x01000000) is intact.
  @debug.assert_eq(artifact.bytes.length() > 8, true)
  @debug.assert_eq(artifact.bytes[0], b'\x00')
  @debug.assert_eq(artifact.bytes[1], b'\x61')
  @debug.assert_eq(artifact.bytes[2], b'\x73')
  @debug.assert_eq(artifact.bytes[3], b'\x6d')
}

///|
test "emit_module_wasm_gc_with_coverage records both branch arms" {
  let ast = cov_if_ast()
  let artifact = try! emit_module_wasm_gc_with_coverage(ast)
  let mut has_then = false
  let mut has_else = false
  for p in artifact.points {
    match p.kind {
      WasmCoveragePointKind::BranchIfThen => has_then = true
      WasmCoveragePointKind::BranchIfElse => has_else = true
      _ => ()
    }
  }
  @debug.assert_eq(has_then, true)
  @debug.assert_eq(has_else, true)
}

///|
test "emit_module_wasm_gc (no coverage) skips counter wiring" {
  let ast = cov_simple_ast()
  let bytes = try! emit_module_wasm_gc(ast)
  let s = bytes.to_unchecked_string()
  // Default emit_module_wasm_gc must not contain the coverage
  // descriptor export names so we don't accidentally embed them in
  // production builds.
  @debug.assert_eq(s.contains("__vibe_cov_base"), false)
  @debug.assert_eq(s.contains("__vibe_cov_count"), false)
}
