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

// ======================================================================
// Tests for build_perceus_plan (branch-sensitive version)
// ======================================================================

///|
fn perceus_test_if(
  cond : @core.Expr,
  then_stmts : Array[@core.Stmt],
  else_stmts : Array[@core.Stmt],
  id : Int,
) -> @core.Expr {
  @core.Expr::If(
    cond~,
    then_body={ stmts: then_stmts },
    else_body={ stmts: else_stmts },
    span=perceus_test_span(id),
  )
}

///|
test "perceus plan: unused let binding gets drop" {
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
  let lines = perceus_action_lines(build_perceus_plan(mod))
  inspect(
    lines,
    content=(
      #|["stmt[0].after drop x"]
    ),
  )
}

///|
test "perceus plan: single use, no dup needed" {
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("consume", [perceus_test_ident("x", 3)], 4),
        span=perceus_test_span(5),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // Single use → no dup, no drop
  inspect(lines, content="[]")
}

///|
test "perceus plan: two sequential uses, first gets dup" {
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use1", [perceus_test_ident("x", 3)], 4),
        span=perceus_test_span(5),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use2", [perceus_test_ident("x", 6)], 7),
        span=perceus_test_span(8),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  inspect(
    lines,
    content=(
      #|["stmt[1].expr.arg[0].before dup x"]
    ),
  )
}

///|
test "perceus plan: if/else branch-sensitive drop" {
  // let x = make()
  // if cond { use(x) } else { /* x not used → drop */ }
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_if(
          perceus_test_ident("cond", 3),
          [
            @core.Stmt::Expr(
              expr=perceus_test_call("use", [perceus_test_ident("x", 4)], 5),
              span=perceus_test_span(6),
            ),
          ],
          [],
          7,
        ),
        span=perceus_test_span(8),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x is used in then but not in else → drop in else branch
  inspect(lines, content="[\"stmt[1].expr.else.end drop x\"]")
}

///|
test "perceus plan: if/else both use x, then also uses after → dup" {
  // let x = make()
  // if cond { use1(x) } else { use2(x) }
  // use3(x)
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_if(
          perceus_test_ident("cond", 3),
          [
            @core.Stmt::Expr(
              expr=perceus_test_call("use1", [perceus_test_ident("x", 4)], 5),
              span=perceus_test_span(6),
            ),
          ],
          [
            @core.Stmt::Expr(
              expr=perceus_test_call("use2", [perceus_test_ident("x", 7)], 8),
              span=perceus_test_span(9),
            ),
          ],
          10,
        ),
        span=perceus_test_span(11),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use3", [perceus_test_ident("x", 12)], 13),
        span=perceus_test_span(14),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x used in both branches (1 each) + 1 after = 2 total uses
  // First use in then branch dups, first use in else branch dups
  inspect(
    lines,
    content=(
      #|["stmt[1].expr.then.stmt[0].expr.arg[0].before dup x", "stmt[1].expr.else.stmt[0].expr.arg[0].before dup x"]
    ),
  )
}

///|
test "perceus plan: match with two arms, only one uses x" {
  // let x = make()
  // match y { A => use(x), B => () }
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=@core.Expr::Match(
          scrutinee=perceus_test_ident("y", 3),
          arms=[
            {
              pat: @core.Pat::Bind(name="a", span=perceus_test_span(4)),
              cond: None,
              expr: perceus_test_call("use", [perceus_test_ident("x", 5)], 6),
              span: perceus_test_span(40),
            },
            {
              pat: @core.Pat::Bind(name="b", span=perceus_test_span(7)),
              cond: None,
              expr: perceus_test_call("noop", [], 8),
              span: perceus_test_span(41),
            },
          ],
          span=perceus_test_span(9),
        ),
        span=perceus_test_span(10),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x used in arm[0] but not arm[1] → drop in arm[1]
  // a and b are unused pattern bindings → drop at scope end
  inspect(
    lines,
    content=(
      #|["stmt[1].expr.arm[0].pat_bind drop a", "stmt[1].expr.arm[1].pat_bind drop b", "stmt[1].expr.arm[1].end drop x"]
    ),
  )
}

///|
test "perceus plan: scope-end drop in block" {
  // { let y = make(); use(y) }  ← y consumed, no drop
  // { let z = make() }          ← z unused, drop at scope end
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Block(
          body={
            stmts: [
              @core.Stmt::Let(
                rec=false,
                name="z",
                expr=perceus_test_call("make", [], 1),
                span=perceus_test_span(2),
              ),
            ],
          },
          span=perceus_test_span(3),
        ),
        span=perceus_test_span(4),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  inspect(
    lines,
    content=(
      #|["stmt[0].expr.body.stmt[0].after drop z"]
    ),
  )
}

///|
test "perceus plan: mutable reassignment drops old value" {
  // let mut x = make1()
  // x = make2()  ← old value of x should be dropped
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::LetMut(
        name="x",
        expr=perceus_test_call("make1", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Assign(
        name="x",
        expr=perceus_test_call("make2", [], 3),
        span=perceus_test_span(4),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  inspect(
    lines,
    content=(
      #|["stmt[0].after drop x", "stmt[1].old_value drop x"]
    ),
  )
}

///|
test "perceus plan: three uses need two dups" {
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("a", [perceus_test_ident("x", 3)], 4),
        span=perceus_test_span(5),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("b", [perceus_test_ident("x", 6)], 7),
        span=perceus_test_span(8),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("c", [perceus_test_ident("x", 9)], 10),
        span=perceus_test_span(11),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // 3 uses → dup before 1st and 2nd, last use is a move
  inspect(
    lines,
    content=(
      #|["stmt[1].expr.arg[0].before dup x", "stmt[2].expr.arg[0].before dup x"]
    ),
  )
}

// ======================================================================
// Perceus memory simulation tests
// ======================================================================

///|
fn make_unused_let_stmts(n : Int) -> Array[@core.Stmt] {
  let stmts : Array[@core.Stmt] = []
  for i = 0; i < n; i = i + 1 {
    let name = "x" + i.to_string()
    stmts.push(
      @core.Stmt::Let(
        rec=false,
        name~,
        expr=perceus_test_call("make", [], i + 100),
        span=perceus_test_span(i + 200),
      ),
    )
  }
  stmts
}

///|
test "perceus sim: 10 unused bindings → peak_rc=1 vs peak_bump=10" {
  let stmts = make_unused_let_stmts(10)
  let mod : @core.Module = { stmts, }
  let result = perceus_simulate(mod)
  assert_eq(result.peak_bump, 10)
  assert_eq(result.peak_rc, 1)
  assert_eq(result.total_allocs, 10)
  assert_eq(result.total_drops, 10)
}

///|
test "perceus sim: 100 unused bindings → peak_rc=1 vs peak_bump=100" {
  let stmts = make_unused_let_stmts(100)
  let mod : @core.Module = { stmts, }
  let result = perceus_simulate(mod)
  assert_eq(result.peak_bump, 100)
  assert_eq(result.peak_rc, 1)
  assert_eq(result.total_drops, 100)
}

///|
test "perceus sim: mutable reassignment chain → peak_rc=1" {
  let stmts : Array[@core.Stmt] = []
  stmts.push(
    @core.Stmt::LetMut(
      name="x",
      expr=perceus_test_call("make", [], 1),
      span=perceus_test_span(2),
    ),
  )
  for i = 0; i < 9; i = i + 1 {
    stmts.push(
      @core.Stmt::Assign(
        name="x",
        expr=perceus_test_call("make", [], i + 10),
        span=perceus_test_span(i + 20),
      ),
    )
  }
  let mod : @core.Module = { stmts, }
  let result = perceus_simulate(mod)
  assert_eq(result.total_allocs, 10)
  assert_eq(result.total_drops, 10)
  assert_eq(result.peak_bump, 10)
  assert_eq(result.peak_rc, 1)
}

///|
test "perceus sim: let mut overwrite in loop style → O(1) peak" {
  // Realistic scenario: building a string incrementally via mut
  // let mut acc = make()
  // acc = concat(acc, x0)  — old acc freed before new alloc
  // acc = concat(acc, x1)  — old acc freed before new alloc
  // ...
  // use(acc)
  let n = 50
  let stmts : Array[@core.Stmt] = []
  stmts.push(
    @core.Stmt::LetMut(
      name="acc",
      expr=perceus_test_call("make", [], 1),
      span=perceus_test_span(2),
    ),
  )
  for i = 0; i < n; i = i + 1 {
    stmts.push(
      @core.Stmt::Assign(
        name="acc",
        expr=perceus_test_call(
          "concat",
          [perceus_test_ident("acc", i * 10 + 100)],
          i * 10 + 101,
        ),
        span=perceus_test_span(i * 10 + 102),
      ),
    )
  }
  stmts.push(
    @core.Stmt::Expr(
      expr=perceus_test_call(
        "use", [perceus_test_ident("acc", 900)], 901,
      ),
      span=perceus_test_span(902),
    ),
  )
  let mod : @core.Module = { stmts, }
  let result = perceus_simulate(mod)
  // Without RC: 51 allocs (1 + 50 assigns), peak = 51
  assert_eq(result.peak_bump, 51)
  // With RC: old_value drop before each assign → peak = 1
  assert_eq(result.peak_rc, 1)
  assert_eq(result.total_drops, 50)
}
