///|
/// Global set of ForIn span starts whose iterable is String-typed.
/// Populated by the frontend rewrite pass (rewrite_string_add),
/// consumed by codegen backends to dispatch to string for-in desugar.
let string_for_in_spans : Map[Int, Bool] = {}

///|
/// Register a ForIn span as iterating over a String.
pub fn mark_string_for_in(span_start : Int) -> Unit {
  string_for_in_spans[span_start] = true
}

///|
/// Check whether a ForIn span iterates over a String.
pub fn is_string_for_in(span_start : Int) -> Bool {
  string_for_in_spans.contains(span_start)
}

///|
/// Clear the string for-in registry (call before each compilation unit).
pub fn clear_string_for_in_spans() -> Unit {
  string_for_in_spans.clear()
}

///|
/// Global set of ForIn span starts whose iterable is a pull closure
/// (`() -> Option[T]`), i.e. lazy `for await x in stream { ... }`. Populated by
/// the checker, consumed by codegen to dispatch to the pull desugar.
let pull_for_in_spans : Map[Int, Bool] = {}

///|
/// Register a ForIn span as iterating over a pull closure (lazy `for await`).
pub fn mark_pull_for_in(span_start : Int) -> Unit {
  pull_for_in_spans[span_start] = true
}

///|
/// Check whether a ForIn span iterates over a pull closure.
pub fn is_pull_for_in(span_start : Int) -> Bool {
  pull_for_in_spans.contains(span_start)
}

///|
/// Clear the pull for-in registry (call before each compilation unit).
pub fn clear_pull_for_in_spans() -> Unit {
  pull_for_in_spans.clear()
}

///|
/// Desugar a lazy `for await x in pull { body }` where `pull : () -> Option[T]`
/// into a pull loop that drains the iterator to `None`:
///
/// {
///   let __pull_next = pull
///   let __pull_b = ArrayBuilder::new()
///   let mut __pull_done = false
///   while not(__pull_done) {
///     match __pull_next() {
///       Some(x) => { <body init>; ArrayBuilder::push(__pull_b, <last_expr>) }
///       None => { __pull_done = true; () }
///     }
///   }
///   ArrayBuilder::freeze(__pull_b)
/// }
///
/// Like `desugar_for_in`, the loop collects each iteration's last expression so
/// the for-in expression yields `Array[bodyresult]`.
pub fn desugar_for_in_pull(
  value_name : String,
  iterable : Expr,
  body : Module,
  span : Span,
) -> Module {
  let synth_span = fn(offset : Int) -> Span {
    Span::new(span.start + offset, span.start + offset + 1)
  }
  let suffix = span.start.to_string()
  let next_span = synth_span(1)
  let b_span = synth_span(2)
  let done_span = synth_span(3)
  let next_ident = Expr::Ident(name="__pull_next" + suffix, span=next_span)
  let b_ident = Expr::Ident(name="__pull_b" + suffix, span=b_span)
  let done_ident = Expr::Ident(name="__pull_done" + suffix, span=done_span)
  // let __pull_next = iterable
  let let_next = Stmt::Let(
    rec=false,
    name="__pull_next" + suffix,
    expr=iterable,
    span~,
  )
  // let __pull_b = ArrayBuilder::new()
  let let_b = Stmt::Let(
    rec=false,
    name="__pull_b" + suffix,
    expr=Expr::Call(name="ArrayBuilder::new", type_args=[], args=[], span~),
    span~,
  )
  // let mut __pull_done = false
  let let_done = Stmt::LetMut(
    name="__pull_done" + suffix,
    expr=Expr::Bool(value=false, span=done_span),
    span~,
  )
  // not(__pull_done)
  let cond = Expr::Call(
    name="not",
    type_args=[],
    args=[CallArg::{ label: None, expr: done_ident, span: done_span }],
    span~,
  )
  // __pull_next()
  let pull_call = Expr::Call(
    name="__pull_next" + suffix,
    type_args=[],
    args=[],
    span~,
  )
  let (init_stmts, collect_expr) = desugar_split_body_last_expr(body, span)
  // Some(x) arm: { <body init>; ArrayBuilder::push(__pull_b, <last_expr>) }
  let some_stmts : Array[Stmt] = []
  for stmt in init_stmts {
    some_stmts.push(stmt)
  }
  some_stmts.push(
    Stmt::Expr(
      expr=Expr::Call(
        name="ArrayBuilder::push",
        type_args=[],
        args=[
          CallArg::{ label: None, expr: b_ident, span: b_span },
          CallArg::{
            label: None,
            expr: collect_expr,
            span: collect_expr.span(),
          },
        ],
        span~,
      ),
      span~,
    ),
  )
  let some_arm = MatchArm::{
    pat: Pat::Ctor(name="Some", args=[Pat::Bind(name=value_name, span~)], span~),
    cond: None,
    expr: Expr::Block(body=Module::{ stmts: some_stmts }, span~),
    span,
  }
  // None arm: { __pull_done = true; () }
  let none_stmts : Array[Stmt] = [
    Stmt::Assign(
      name="__pull_done" + suffix,
      expr=Expr::Bool(value=true, span=done_span),
      span~,
    ),
    Stmt::Expr(expr=Expr::Tuple(items=[], span~), span~),
  ]
  let none_arm = MatchArm::{
    pat: Pat::Ctor(name="None", args=[], span~),
    cond: None,
    expr: Expr::Block(body=Module::{ stmts: none_stmts }, span~),
    span,
  }
  let match_expr = Expr::Match(
    scrutinee=pull_call,
    arms=[some_arm, none_arm],
    span~,
  )
  let while_body = Module::{ stmts: [Stmt::Expr(expr=match_expr, span~)] }
  let while_expr = Expr::While(cond~, body=while_body, span~)
  let freeze_expr = Expr::Call(
    name="ArrayBuilder::freeze",
    type_args=[],
    args=[CallArg::{ label: None, expr: b_ident, span: b_span }],
    span~,
  )
  Module::{
    stmts: [
      let_next,
      let_b,
      let_done,
      Stmt::Expr(expr=while_expr, span~),
      Stmt::Expr(expr=freeze_expr, span~),
    ],
  }
}

///|
/// Desugar ForIn AST node into a Block with array builder pattern.
///
/// for x in iterable { body } →
/// {
///   let __for_arr = iterable
///   let __for_iter = iter_require(__for_arr)
///   let __for_len = iter_length(__for_iter)
///   let __for_b = array_builder()
///   let mut __for_i = 0
///   while __for_i < __for_len {
///     let x = iter_get(__for_iter, __for_i)
///     [let i = __for_i]
///     __for_i = __for_i + 1
///     <body init stmts>
///     array_builder_push(__for_b, <last_expr>)
///   }
///   array_builder_freeze(__for_b)
/// }
pub fn desugar_for_in(
  value_name : String,
  index_name : String?,
  iterable : Expr,
  body : Module,
  span : Span,
) -> Module {
  desugar_for_in_with(
    value_name, index_name, iterable, body, span, "iter_length", "iter_get", true,
  )
}

///|
/// Generic for-in desugar parameterized on length/get function names.
/// When `use_iter_require` is true, wraps iterable in `iter_require()` call
/// (for Iterable trait constraint check).
pub fn desugar_for_in_with(
  value_name : String,
  index_name : String?,
  iterable : Expr,
  body : Module,
  span : Span,
  length_fn : String,
  get_fn : String,
  use_iter_require : Bool,
) -> Module {
  let synth_span = fn(offset : Int) -> Span {
    Span::new(span.start + offset, span.start + offset + 1)
  }
  let suffix = span.start.to_string()
  let arr_span = synth_span(1)
  let iter_span = synth_span(2)
  let len_span = synth_span(3)
  let i_span = synth_span(4)
  let b_span = synth_span(5)
  let arr_ident = Expr::Ident(name="__for_arr" + suffix, span=arr_span)
  let iter_ident = Expr::Ident(name="__for_iter" + suffix, span=iter_span)
  let len_ident = Expr::Ident(name="__for_len" + suffix, span=len_span)
  let i_ident = Expr::Ident(name="__for_i" + suffix, span=i_span)
  let b_ident = Expr::Ident(name="__for_b" + suffix, span=b_span)
  let zero = Expr::Int(value=0L, span=i_span)
  let one = Expr::Int(value=1L, span=i_span)
  // let __for_arrN = iterable
  let let_arr = Stmt::Let(
    rec=false,
    name="__for_arr" + suffix,
    expr=iterable,
    span~,
  )
  // let __for_iterN = iter_require(__for_arrN) or just alias
  let let_iter = Stmt::Let(
    rec=false,
    name="__for_iter" + suffix,
    expr=if use_iter_require {
      Expr::Call(
        name="iter_require",
        type_args=[],
        args=[CallArg::{ label: None, expr: arr_ident, span: arr_span }],
        span~,
      )
    } else {
      arr_ident
    },
    span~,
  )
  // let __for_lenN = <length_fn>(__for_iterN)
  let let_len = Stmt::Let(
    rec=false,
    name="__for_len" + suffix,
    expr=Expr::Call(
      name=length_fn,
      type_args=[],
      args=[CallArg::{ label: None, expr: iter_ident, span: iter_span }],
      span~,
    ),
    span~,
  )
  // let __for_bN = array_builder()
  let let_b = Stmt::Let(
    rec=false,
    name="__for_b" + suffix,
    expr=Expr::Call(name="ArrayBuilder::new", type_args=[], args=[], span~),
    span~,
  )
  // let mut __for_iN = 0
  let let_i = Stmt::LetMut(name="__for_i" + suffix, expr=zero, span~)
  // while __for_iN < __for_lenN
  let cond = desugar_call2("__lt", i_ident, len_ident)
  // Split body: init stmts + last expr to collect
  let (init_stmts, collect_expr) = desugar_split_body_last_expr(body, span)
  // Build while body stmts
  let while_stmts : Array[Stmt] = []
  // let x = <get_fn>(__for_iter, __for_i)
  while_stmts.push(
    Stmt::Let(
      rec=false,
      name=value_name,
      expr=Expr::Call(
        name=get_fn,
        type_args=[],
        args=[
          CallArg::{ label: None, expr: iter_ident, span: iter_span },
          CallArg::{ label: None, expr: i_ident, span: i_span },
        ],
        span~,
      ),
      span~,
    ),
  )
  // Optional: let i = __for_i
  match index_name {
    Some(idx_name) =>
      while_stmts.push(Stmt::Let(rec=false, name=idx_name, expr=i_ident, span~))
    None => ()
  }
  // __for_iN = __for_iN + 1  (BEFORE body to prevent infinite loop on continue)
  while_stmts.push(
    Stmt::Assign(
      name="__for_i" + suffix,
      expr=desugar_call2("__add", i_ident, one),
      span~,
    ),
  )
  // Add body init stmts (everything except the last expr)
  for stmt in init_stmts {
    while_stmts.push(stmt)
  }
  // array_builder_push(__for_b, <last_expr>)
  while_stmts.push(
    Stmt::Expr(
      expr=Expr::Call(
        name="ArrayBuilder::push",
        type_args=[],
        args=[
          CallArg::{ label: None, expr: b_ident, span: b_span },
          CallArg::{
            label: None,
            expr: collect_expr,
            span: collect_expr.span(),
          },
        ],
        span~,
      ),
      span~,
    ),
  )
  let while_body = Module::{ stmts: while_stmts }
  let while_expr = Expr::While(cond~, body=while_body, span~)
  // Wrap in block, return frozen array
  let freeze_expr = Expr::Call(
    name="ArrayBuilder::freeze",
    type_args=[],
    args=[CallArg::{ label: None, expr: b_ident, span: b_span }],
    span~,
  )
  let do_stmts : Array[Stmt] = [
    let_arr,
    let_iter,
    let_len,
    let_b,
    let_i,
    Stmt::Expr(expr=while_expr, span~),
    Stmt::Expr(expr=freeze_expr, span~),
  ]
  Module::{ stmts: do_stmts }
}

///|
/// Desugar ForIn over String — delegates to generic desugar_for_in_with.
pub fn desugar_for_in_string(
  value_name : String,
  index_name : String?,
  iterable : Expr,
  body : Module,
  span : Span,
) -> Module {
  desugar_for_in_with(
    value_name, index_name, iterable, body, span, "String::length", "String::char_code_at",
    false,
  )
}

///|
fn desugar_call2(name : String, left : Expr, right : Expr) -> Expr {
  let left_span = left.span()
  let right_span = right.span()
  let span = Span::merge(left_span, right_span)
  Expr::Call(
    name~,
    type_args=[],
    args=[
      CallArg::{ label: None, expr: left, span: left_span },
      CallArg::{ label: None, expr: right, span: right_span },
    ],
    span~,
  )
}

///|
/// Split a module body into init statements and the last expression to collect.
/// If the last statement is Expr, extract it. Otherwise return Unit.
fn desugar_split_body_last_expr(
  body : Module,
  span : Span,
) -> (Array[Stmt], Expr) {
  let stmts = body.stmts
  if stmts.length() == 0 {
    return ([], Expr::Tuple(items=[], span~))
  }
  let last = stmts[stmts.length() - 1]
  match last {
    Stmt::Expr(expr~, ..) => {
      let init : Array[Stmt] = []
      for i in 0..<(stmts.length() - 1) {
        init.push(stmts[i])
      }
      (init, expr)
    }
    _ => {
      let init : Array[Stmt] = []
      for stmt in stmts {
        init.push(stmt)
      }
      (init, Expr::Tuple(items=[], span~))
    }
  }
}
