///|
/// Non-operator calls are opaque to placeholder sugar: `Array::any(xs, _ > 5)`
/// wraps at `_ > 5` (producing `Array::any(xs, x -> x > 5)`), not at the outer
/// `Array::any` call. Regression guard for #326.
test "parse placeholder sugar does not wrap enclosing non-op call" {
  let input = "Array::any(xs, _ > 5)"
  let ast = parse_ast(input)
  // Expected: outer Call is Array::any (not Fn), arg[1] is Fn (the wrapped _ > 5).
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name~, args~, ..) => {
          assert_eq(name, "Array::any")
          assert_eq(args.length(), 2)
          match args[1].expr {
            @core.Expr::Fn(params~, ..) => assert_eq(params.length(), 1)
            other => fail("expected arg[1] to be wrapped as Fn, got: \{other}")
          }
        }
        other => fail("expected outer Call, got: \{other}")
      }
    _ => fail("expected Expr stmt")
  }
}

///|
/// Pipe `_` slot: `x |> f(a, _)` substitutes the piped value at the hole
/// (`f(a, x)`) instead of prepending. Host parity with selfhost `pipe_desugar`.
test "parse pipe placeholder substitutes at hole" {
  let ast = parse_ast("x |> f(a, _)")
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name="f", args~, ..) => {
          assert_eq(args.length(), 2)
          match (args[0].expr, args[1].expr) {
            (@core.Expr::Ident(name="a", ..), @core.Expr::Ident(name="x", ..)) =>
              ()
            other => fail("expected args [a, x], got: \{other}")
          }
        }
        other => fail("expected Call f, got: \{other}")
      }
    _ => fail("expected Expr stmt")
  }
}

///|
/// A labeled hole keeps its label: `x |> f(a=1, b=_)` => `f(a=1, b=x)`,
/// not a positional `f(a=1, x)` (the checker would reject that). Regression
/// for the #590 Codex review.
test "parse pipe placeholder preserves a labeled slot" {
  let ast = parse_ast("x |> f(a=1, b=_)")
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name="f", args~, ..) => {
          assert_eq(args.length(), 2)
          assert_eq(args[1].label, Some("b"))
          match args[1].expr {
            @core.Expr::Ident(name="x", ..) => ()
            other => fail("expected b slot filled with x, got: \{other}")
          }
        }
        other => fail("expected Call f, got: \{other}")
      }
    _ => fail("expected Expr stmt")
  }
}

///|
/// Pipe without a `_` hole still prepends the piped value as the first arg:
/// `x |> f(a)` → `f(x, a)`.
test "parse pipe without placeholder prepends" {
  let ast = parse_ast("x |> f(a)")
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name="f", args~, ..) => {
          assert_eq(args.length(), 2)
          match (args[0].expr, args[1].expr) {
            (@core.Expr::Ident(name="x", ..), @core.Expr::Ident(name="a", ..)) =>
              ()
            other => fail("expected args [x, a], got: \{other}")
          }
        }
        other => fail("expected Call f, got: \{other}")
      }
    _ => fail("expected Expr stmt")
  }
}

///|
/// Operator-chain placeholders stay in the same lambda scope:
/// `_ % 2 == 0` → `x -> x % 2 == 0` (one Fn, not nested).
test "parse placeholder sugar spans operator chain" {
  let input = "Array::filter(xs, _ % 2 == 0)"
  let ast = parse_ast(input)
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name="Array::filter", args~, ..) =>
          match args[1].expr {
            @core.Expr::Fn(params~, body~, ..) => {
              assert_eq(params.length(), 1)
              // Body should be a single __eq call, not a nested Fn
              match body.stmts[0] {
                @core.Stmt::Expr(expr=body_expr, ..) =>
                  match body_expr {
                    @core.Expr::Call(name="__eq", ..) => ()
                    other => fail("expected __eq body, got: \{other}")
                  }
                _ => fail("expected Expr stmt in body")
              }
            }
            other => fail("expected Fn wrap, got: \{other}")
          }
        _ => fail("expected Array::filter Call")
      }
    _ => fail("expected Expr stmt")
  }
}

///|
/// Placeholder enclosed inside two layers of non-op calls still wraps at the
/// innermost op-chain, leaving both outer calls intact. Regression for #326
/// where `assert(Array::any(xs, _ > 5))` incorrectly wrapped at Array::any.
test "parse placeholder inside nested non-op calls preserves outer structure" {
  let input = "assert(Array::any(xs, _ > 5))"
  let ast = parse_ast(input)
  match ast.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name="assert", args~, ..) =>
          match args[0].expr {
            @core.Expr::Call(name="Array::any", args=inner_args, ..) => {
              assert_eq(inner_args.length(), 2)
              match inner_args[1].expr {
                @core.Expr::Fn(params~, ..) => assert_eq(params.length(), 1)
                other =>
                  fail("expected Array::any arg[1] to be Fn, got: \{other}")
              }
            }
            other =>
              fail(
                "expected assert arg[0] to stay as Array::any Call, got: \{other}",
              )
          }
        _ => fail("expected outer assert Call")
      }
    _ => fail("expected Expr stmt")
  }
}
