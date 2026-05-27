///|
/// Helper: default on_name that adds any unbound name (no filtering).
fn add_all_refs(
  name : String,
  bound : WalkerScope,
  refs : Map[String, Bool],
) -> Unit {
  if !bound.contains(name) {
    refs[name] = true
  }
}

///|
fn empty_span() -> Span {
  Span::empty(0)
}

///|
test "walk_expr_refs collects free variable from Ident" {
  let refs : Map[String, Bool] = {}
  walk_expr_refs(
    Expr::Ident(name="x", span=empty_span()),
    WalkerScope::new(),
    refs,
    add_all_refs,
  )
  @debug.debug_inspect(
    refs.keys().collect(),
    content=(
      #|["x"]
    ),
  )
}

///|
test "walk_expr_refs skips bound variable" {
  let refs : Map[String, Bool] = {}
  let bound = WalkerScope::new()
  bound.bindings["x"] = true
  walk_expr_refs(
    Expr::Ident(name="x", span=empty_span()),
    bound,
    refs,
    add_all_refs,
  )
  @debug.debug_inspect(refs.keys().collect(), content="[]")
}

///|
test "walk_expr_refs collects call name and arg refs" {
  let refs : Map[String, Bool] = {}
  walk_expr_refs(
    Expr::Call(
      name="f",
      type_args=[],
      args=[
        CallArg::{
          label: None,
          expr: Expr::Ident(name="a", span=empty_span()),
          span: empty_span(),
        },
      ],
      span=empty_span(),
    ),
    WalkerScope::new(),
    refs,
    add_all_refs,
  )
  let keys = refs.keys().collect()
  keys.sort()
  @debug.debug_inspect(
    keys,
    content=(
      #|["a", "f"]
    ),
  )
}

///|
test "walk_expr_refs fn params bind correctly" {
  let refs : Map[String, Bool] = {}
  walk_expr_refs(
    Expr::Fn(
      type_params=[],
      type_bounds={},
      params=[
        FuncParam::{
          name: "x",
          ty: Type::Unit,
          label: ParamLabel::Positional,
          bounds: [],
        },
      ],
      ret=None,
      effects=[],
      body=Module::{
        stmts: [
          Stmt::Expr(
            expr=Expr::Ident(name="x", span=empty_span()),
            span=empty_span(),
          ),
        ],
      },
      span=empty_span(),
    ),
    WalkerScope::new(),
    refs,
    add_all_refs,
  )
  @debug.debug_inspect(refs.keys().collect(), content="[]")
}

///|
test "walk_expr_refs match arm binds pattern names" {
  let refs : Map[String, Bool] = {}
  walk_expr_refs(
    Expr::Match(
      scrutinee=Expr::Ident(name="val", span=empty_span()),
      arms=[
        MatchArm::{
          pat: Pat::Bind(name="x", span=empty_span()),
          cond: None,
          expr: Expr::Call(
            name="f",
            type_args=[],
            args=[
              CallArg::{
                label: None,
                expr: Expr::Ident(name="x", span=empty_span()),
                span: empty_span(),
              },
            ],
            span=empty_span(),
          ),
          span: empty_span(),
        },
      ],
      span=empty_span(),
    ),
    WalkerScope::new(),
    refs,
    add_all_refs,
  )
  let keys = refs.keys().collect()
  keys.sort()
  // "val" (scrutinee) and "f" (call), but "x" is bound by pattern
  @debug.debug_inspect(
    keys,
    content=(
      #|["f", "val"]
    ),
  )
}

///|
test "walk_block_refs let binding scopes correctly" {
  let refs : Map[String, Bool] = {}
  walk_block_refs(
    Module::{
      stmts: [
        Stmt::Let(
          rec=false,
          name="x",
          expr=Expr::Ident(name="a", span=empty_span()),
          span=empty_span(),
        ),
        Stmt::Expr(
          expr=Expr::Ident(name="x", span=empty_span()),
          span=empty_span(),
        ),
      ],
    },
    WalkerScope::new(),
    refs,
    add_all_refs,
  )
  // "a" is free, "x" is bound by the let
  @debug.debug_inspect(
    refs.keys().collect(),
    content=(
      #|["a"]
    ),
  )
}

///|
test "bind_pattern_names_walker binds nested patterns" {
  let bound : Map[String, Bool] = {}
  bind_pattern_names_walker(
    bound,
    Pat::Tuple(
      items=[
        Pat::Bind(name="a", span=empty_span()),
        Pat::Bind(name="b", span=empty_span()),
      ],
      span=empty_span(),
    ),
  )
  let keys = bound.keys().collect()
  keys.sort()
  @debug.debug_inspect(
    keys,
    content=(
      #|["a", "b"]
    ),
  )
}

///|
test "clone_bool_map creates independent copy" {
  let original : Map[String, Bool] = { "x": true }
  let copy = clone_bool_map(original)
  copy["y"] = true
  inspect(original.contains("y"), content="false")
  inspect(copy.contains("y"), content="true")
}
