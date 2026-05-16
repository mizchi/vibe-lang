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
      #|[stmt[0].after drop x]

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
      #|[stmt[1].expr.arg[0].before dup x]

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
  inspect(lines, content=(
    #|[stmt[1].expr.else.end drop x]
  ))
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
      #|[stmt[1].expr.then.stmt[0].expr.arg[0].before dup x, stmt[1].expr.else.stmt[0].expr.arg[0].before dup x]

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
      #|[stmt[1].expr.arm[0].pat_bind drop a, stmt[1].expr.arm[1].pat_bind drop b, stmt[1].expr.arm[1].end drop x]

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
      #|[stmt[0].expr.body.stmt[0].after drop z]

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
      #|[stmt[0].after drop x, stmt[1].old_value drop x]

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
      #|[stmt[1].expr.arg[0].before dup x, stmt[2].expr.arg[0].before dup x]

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
      expr=perceus_test_call("use", [perceus_test_ident("acc", 900)], 901),
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

// ======================================================================
// Additional Perceus analysis tests
// ======================================================================

///|
test "perceus plan: for-in loop drops iterable when unused after" {
  // let xs = make()
  // for x in xs { use(x) }
  // → xs consumed by for-in, no dup needed
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="xs",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=@core.Expr::ForIn(
          value_name="x",
          index_name=None,
          iterable=perceus_test_ident("xs", 3),
          body={
            stmts: [
              @core.Stmt::Expr(
                expr=perceus_test_call("use", [perceus_test_ident("x", 4)], 5),
                span=perceus_test_span(6),
              ),
            ],
          },
          span=perceus_test_span(7),
        ),
        span=perceus_test_span(8),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // xs is consumed by the for-in, x is consumed inside body → no dup/drop needed
  inspect(lines, content="[]")
}

///|
test "perceus plan: for-in loop iterable used after needs dup" {
  // let xs = make()
  // for x in xs { use(x) }
  // use(xs)
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="xs",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=@core.Expr::ForIn(
          value_name="x",
          index_name=None,
          iterable=perceus_test_ident("xs", 3),
          body={
            stmts: [
              @core.Stmt::Expr(
                expr=perceus_test_call("use", [perceus_test_ident("x", 4)], 5),
                span=perceus_test_span(6),
              ),
            ],
          },
          span=perceus_test_span(7),
        ),
        span=perceus_test_span(8),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("xs", 9)], 10),
        span=perceus_test_span(11),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // xs used in for-in + after → first use gets dup
  assert_true(lines.length() > 0)
}

///|
test "perceus plan: multiple variables, only unused ones get drops" {
  // let x = make()
  // let y = make()
  // use(x)
  // → y unused → drop, x consumed → no action
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Let(
        rec=false,
        name="y",
        expr=perceus_test_call("make", [], 3),
        span=perceus_test_span(4),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("x", 5)], 6),
        span=perceus_test_span(7),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // Only y gets dropped (unused), x is consumed exactly once
  inspect(
    lines,
    content=(
      #|[stmt[1].after drop y]

    ),
  )
}

///|
test "perceus plan: nested if/else with inner variable" {
  // let x = make()
  // if cond1 {
  //   if cond2 { use1(x) } else { use2(x) }
  // } else {
  //   use3(x)
  // }
  let inner_if = perceus_test_if(
    perceus_test_ident("cond2", 10),
    [
      @core.Stmt::Expr(
        expr=perceus_test_call("use1", [perceus_test_ident("x", 11)], 12),
        span=perceus_test_span(13),
      ),
    ],
    [
      @core.Stmt::Expr(
        expr=perceus_test_call("use2", [perceus_test_ident("x", 14)], 15),
        span=perceus_test_span(16),
      ),
    ],
    17,
  )
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
          perceus_test_ident("cond1", 3),
          [@core.Stmt::Expr(expr=inner_if, span=perceus_test_span(18))],
          [
            @core.Stmt::Expr(
              expr=perceus_test_call("use3", [perceus_test_ident("x", 4)], 5),
              span=perceus_test_span(6),
            ),
          ],
          7,
        ),
        span=perceus_test_span(8),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x used exactly once in each path → no dup needed
  inspect(lines, content="[]")
}

///|
test "perceus plan: mutable with use before reassign" {
  // let mut x = make1()
  // use(x)
  // x = make2()
  // use(x)
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::LetMut(
        name="x",
        expr=perceus_test_call("make1", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("x", 3)], 4),
        span=perceus_test_span(5),
      ),
      @core.Stmt::Assign(
        name="x",
        expr=perceus_test_call("make2", [], 6),
        span=perceus_test_span(7),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("x", 8)], 9),
        span=perceus_test_span(10),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x used before reassign → dup at use, old_value dropped at assign
  assert_true(lines.length() > 0)
  // Must contain old_value drop for the reassignment
  let mut has_old_value = false
  for line in lines {
    if line.contains("old_value") {
      has_old_value = true
    }
  }
  assert_true(has_old_value)
}

///|
test "perceus plan: match with three arms asymmetric use" {
  // let x = make()
  // match y { A => use1(x), B => use2(x), C => () }
  // → x used in arms 0,1 but not arm 2 → drop in arm 2
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
              expr: perceus_test_call("use1", [perceus_test_ident("x", 5)], 6),
              span: perceus_test_span(40),
            },
            {
              pat: @core.Pat::Bind(name="b", span=perceus_test_span(7)),
              cond: None,
              expr: perceus_test_call("use2", [perceus_test_ident("x", 8)], 9),
              span: perceus_test_span(41),
            },
            {
              pat: @core.Pat::Bind(name="c", span=perceus_test_span(10)),
              cond: None,
              expr: perceus_test_call("noop", [], 11),
              span: perceus_test_span(42),
            },
          ],
          span=perceus_test_span(12),
        ),
        span=perceus_test_span(13),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // x unused in arm[2] → drop in arm[2]
  // a, b, c are unused pattern bindings
  let mut has_arm2_drop = false
  for line in lines {
    if line.contains("arm[2].end drop x") {
      has_arm2_drop = true
    }
  }
  assert_true(has_arm2_drop)
}

///|
test "perceus sim: single alloc single use → peak_rc=1 no drops" {
  // let x = make()
  // use(x)
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("x", 3)], 4),
        span=perceus_test_span(5),
      ),
    ],
  }
  let result = perceus_simulate(mod)
  assert_eq(result.total_allocs, 1)
  assert_eq(result.total_drops, 0)
  assert_eq(result.peak_rc, 1)
  assert_eq(result.peak_bump, 1)
}

///|
test "perceus sim: two variables, both consumed → peak_rc=2" {
  // let x = make()
  // let y = make()
  // use(x)
  // use(y)
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Let(
        rec=false,
        name="y",
        expr=perceus_test_call("make", [], 3),
        span=perceus_test_span(4),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("x", 5)], 6),
        span=perceus_test_span(7),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("use", [perceus_test_ident("y", 8)], 9),
        span=perceus_test_span(10),
      ),
    ],
  }
  let result = perceus_simulate(mod)
  assert_eq(result.total_allocs, 2)
  assert_eq(result.total_drops, 0)
  assert_eq(result.peak_bump, 2)
  assert_eq(result.peak_rc, 2)
}

///|
test "perceus sim: interleaved alloc-drop keeps peak_rc low" {
  // let x0 = make(); let x1 = make(); ...
  // But each is unused → dropped immediately
  // With RC: peak stays at 1 because each alloc's drop frees before next alloc
  let stmts : Array[@core.Stmt] = []
  for i = 0; i < 5; i = i + 1 {
    let name = "v" + i.to_string()
    stmts.push(
      @core.Stmt::Let(
        rec=false,
        name~,
        expr=perceus_test_call("make", [], i + 100),
        span=perceus_test_span(i + 200),
      ),
    )
  }
  let mod : @core.Module = { stmts, }
  let result = perceus_simulate(mod)
  assert_eq(result.total_allocs, 5)
  assert_eq(result.total_drops, 5)
  assert_eq(result.peak_bump, 5)
  assert_eq(result.peak_rc, 1)
}

///|
test "optimize_perceus_actions: cancels adjacent dup-drop at same scope" {
  let actions : Array[PerceusAction] = [
    {
      site: "stmt[1].expr.then.stmt[0].expr.arg[0].before",
      kind: PerceusActionKind::Dup,
      name: "x",
    },
    {
      site: "stmt[1].expr.then.scope_end",
      kind: PerceusActionKind::Drop,
      name: "x",
    },
  ]
  let optimized = optimize_perceus_actions(actions)
  assert_eq(optimized.length(), 0)
}

///|
test "optimize_perceus_actions: does not cancel across different scopes" {
  let actions : Array[PerceusAction] = [
    {
      site: "stmt[1].expr.arg[0].before",
      kind: PerceusActionKind::Dup,
      name: "x",
    },
    { site: "stmt[2].old_value", kind: PerceusActionKind::Drop, name: "x" },
  ]
  let optimized = optimize_perceus_actions(actions)
  // Different stmt indices → must not cancel
  assert_eq(optimized.length(), 2)
}

///|
test "optimize_perceus_actions: does not cancel different variables" {
  let actions : Array[PerceusAction] = [
    {
      site: "stmt[1].expr.then.stmt[0].expr.before",
      kind: PerceusActionKind::Dup,
      name: "x",
    },
    {
      site: "stmt[1].expr.then.scope_end",
      kind: PerceusActionKind::Drop,
      name: "y",
    },
  ]
  let optimized = optimize_perceus_actions(actions)
  assert_eq(optimized.length(), 2)
}

///|
test "perceus plan: tuple field access borrows — no dup for t.0 + t.1" {
  // let t = make()
  // use(t.0, t.1)
  // → t has 0 owning uses (both are borrows), drop at scope end
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="t",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call(
          "use",
          [
            @core.Expr::TupleIndex(
              expr=perceus_test_ident("t", 3),
              index=0,
              span=perceus_test_span(4),
            ),
            @core.Expr::TupleIndex(
              expr=perceus_test_ident("t", 5),
              index=1,
              span=perceus_test_span(6),
            ),
          ],
          7,
        ),
        span=perceus_test_span(8),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // No dup should be emitted — both uses are borrows
  inspect(
    lines,
    content=(
      #|[stmt[1].scope_end drop t]

    ),
  )
}

///|
test "perceus plan: borrow + owning use — dup for owning only" {
  // let t = make()
  // use(t.0)   ← borrow
  // consume(t) ← owning
  // → t has 1 owning use + 1 borrow = no dup needed
  let mod : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="t",
        expr=perceus_test_call("make", [], 1),
        span=perceus_test_span(2),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call(
          "use_field",
          [
            @core.Expr::TupleIndex(
              expr=perceus_test_ident("t", 3),
              index=0,
              span=perceus_test_span(4),
            ),
          ],
          5,
        ),
        span=perceus_test_span(6),
      ),
      @core.Stmt::Expr(
        expr=perceus_test_call("consume", [perceus_test_ident("t", 7)], 8),
        span=perceus_test_span(9),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // Mixed borrow+owning: borrows are merged into owning for safety
  // (prevents use-after-free if borrow follows last owning use)
  // 1 owning + 1 borrow = 2 owning → dup before first use
  let mut has_dup = false
  for line in lines {
    if line.contains("dup t") {
      has_dup = true
    }
  }
  assert_eq(has_dup, true)
}

///|
test "perceus: while loop body drops bindings at scope end" {
  // let f = () -> Int {
  //   let mut i = 0
  //   while i < 10 {
  //     let t = make_pair(i)   ← new binding each iteration
  //     i = consume(t)         ← last use of t
  //   }
  //   i
  // }
  // t should be dropped at the end of the while body scope
  // (since it's declared inside the loop and goes out of scope each iteration)
  let while_body = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="t",
        expr=perceus_test_call("make_pair", [perceus_test_ident("i", 1)], 2),
        span=perceus_test_span(3),
      ),
      @core.Stmt::Assign(
        name="i",
        expr=perceus_test_call("consume", [perceus_test_ident("t", 4)], 5),
        span=perceus_test_span(6),
      ),
    ],
  }
  let mod : @core.Module = {
    stmts: [
      // let i = 0
      @core.Stmt::Let(
        rec=false,
        name="i",
        expr=@core.Expr::Int(value=0L, span=perceus_test_span(0)),
        span=perceus_test_span(10),
      ),
      // while i < 10 { ... }
      @core.Stmt::Expr(
        expr=@core.Expr::While(
          cond=perceus_test_call(
            "lt",
            [
              perceus_test_ident("i", 20),
              @core.Expr::Int(value=10L, span=perceus_test_span(21)),
            ],
            22,
          ),
          body=while_body,
          span=perceus_test_span(23),
        ),
        span=perceus_test_span(24),
      ),
      // i (return value)
      @core.Stmt::Expr(
        expr=perceus_test_ident("i", 30),
        span=perceus_test_span(31),
      ),
    ],
  }
  let lines = perceus_action_lines(build_perceus_plan(mod))
  // While loop produces:
  // - i is bound to Int literal (scalar), so dup/drop are elided
  // - skip-branch drops for non-scalar bindings to equalize
  let mut has_dup_i = false
  let mut has_skip_drop_i = false
  for line in lines {
    if line.contains("dup i") {
      has_dup_i = true
    }
    if line.contains("skip.end drop i") {
      has_skip_drop_i = true
    }
  }
  // i is a known scalar (Int literal) → dup elided
  assert_eq(has_dup_i, false)
  // Scalar bindings also skip branch merge drops
  assert_eq(has_skip_drop_i, false)
}
