///|
fn perceus_test_span(id : Int) -> @core.Span {
  { start: id * 10, end: id * 10 + 1 }
}

///|
fn perceus_test_arg(expr : @core.Expr, id : Int) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: perceus_test_span(id) }
}

///|
fn perceus_test_ident(name : String, id : Int) -> @core.Expr {
  @core.Expr::Ident(name~, span=perceus_test_span(id))
}

///|
fn perceus_test_call(
  name : String,
  args : Array[@core.Expr],
  id : Int,
) -> @core.Expr {
  let call_args : Array[@core.CallArg] = []
  for i = 0; i < args.length(); i = i + 1 {
    call_args.push(perceus_test_arg(args[i], id * 10 + i))
  }
  @core.Expr::Call(
    name~,
    type_args=[],
    args=call_args,
    span=perceus_test_span(id),
  )
}

///|
fn perceus_action_lines(actions : Array[PerceusAction]) -> Array[String] {
  let lines : Array[String] = []
  for action in actions {
    lines.push(perceus_action_debug_string(action))
  }
  lines
}

///|
test "perceus poc drops unused let binding" {
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan_poc(mod))
  assert_eq(lines, ["stmt[0].after drop x"])
}

///|
test "perceus poc inserts dup before first sequential use" {
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 10),
        span=perceus_test_span(11),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("consume1", [perceus_test_ident("x", 12)], 13),
        span=perceus_test_span(14),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("consume2", [perceus_test_ident("x", 15)], 16),
        span=perceus_test_span(17),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan_poc(mod))
  assert_eq(lines, ["stmt[1].expr.arg[0].before dup x"])
}

///|
test "perceus poc inserts dup at closure capture when outer value stays live" {
  let closure = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[],
    ret=None,
    effects=[],
    body={
      stmts: [
        @core.Stmt::Expr(
          expr=perceus_test_ident("x", 21),
          span=perceus_test_span(22),
        ),
      ],
    },
    span=perceus_test_span(23),
  )
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 24),
        span=perceus_test_span(25),
      ),
      @core.Stmt::Let(
        rec=false,
        name="f",
        expr=closure,
        span=perceus_test_span(26),
      ),
      @core.Stmt::Expr(
        expr=@core.Expr::Call(
          name="f",
          type_args=[],
          args=[perceus_test_arg(perceus_test_ident("x", 27), 28)],
          span=perceus_test_span(29),
        ),
        span=perceus_test_span(30),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan_poc(mod))
  assert_eq(lines, ["stmt[1].expr.capture[x].before dup x"])
}

///|
test "perceus poc drops unused binding inside block expression" {
  let block = @core.Expr::Block(
    body={
      stmts: [
        @core.Stmt::Let(
          rec=false,
          name="y",
          expr=perceus_test_call("make", [], 31),
          span=perceus_test_span(32),
        ),
      ],
    },
    span=perceus_test_span(33),
  )
  let mod : @core.Module = {
    stmts: [@core.Stmt::Expr(expr=block, span=perceus_test_span(34))],
  }
  let lines = perceus_action_lines(build_perceus_plan_poc(mod))
  assert_eq(lines, ["stmt[0].expr.body.stmt[0].after drop y"])
}
