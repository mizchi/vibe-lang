///|
/// Tests for the wasm `name` custom section emission in the wasm-gc
/// backend. Lets the wasmtime GuestProfiler / browser devtools render
/// stack frames with the source identifier instead of
/// `<wasm function N>`.

///|
fn names_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn names_int(n : Int64) -> @core.Expr {
  @core.Expr::Int(value=n, span=names_span())
}

///|
fn names_call(name : String, args : Array[@core.Expr]) -> @core.Expr {
  let span = names_span()
  let call_args : Array[@core.CallArg] = []
  for a in args {
    call_args.push(@core.CallArg::{ label: None, expr: a, span })
  }
  @core.Expr::Call(name~, type_args=[], args=call_args, span~)
}

///|
fn names_fn_int(stmts : Array[@core.Stmt]) -> @core.Expr {
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[],
    ret=Some(@core.Type::Int),
    effects=[],
    body=@core.Module::{ stmts, },
    span=names_span(),
  )
}

///|
fn names_let(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Let(rec=false, name~, expr~, span=names_span())
}

///|
fn names_stmt_expr(expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Expr(expr~, span=names_span())
}

///|
/// Build `let main = () -> Int { 42 }; main()` — two functions visible
/// in the name section: `main` and the synthetic `_start` wrapper.
fn names_two_func_ast() -> @core.Module {
  let body = [names_stmt_expr(names_int(42L))]
  @core.Module::{
    stmts: [
      names_let("main", names_fn_int(body)),
      names_stmt_expr(names_call("main", [])),
    ],
  }
}

///|
/// Locate the custom `name` section payload (subsection 1 contents) in
/// a wasm binary. Returns `None` when the section isn't present.
fn find_name_subsection1(bytes : Bytes) -> Bytes? {
  let view : Array[Int] = []
  for b in bytes {
    view.push(b.to_int())
  }
  if view.length() < 8 {
    return None
  }
  let mut i = 8
  while i < view.length() {
    let id = view[i]
    i += 1
    // LEB128 section size
    let mut size = 0
    let mut shift = 0
    let mut continues = true
    while continues {
      let b = view[i]
      i += 1
      size = size | ((b & 0x7f).lsl(shift))
      shift += 7
      continues = (b & 0x80) != 0
    }
    let payload_end = i + size
    if id == 0 {
      // Custom section — read name string
      let mut name_size = 0
      let mut ns_shift = 0
      let mut ns_continues = true
      while ns_continues {
        let b = view[i]
        i += 1
        name_size = name_size | ((b & 0x7f).lsl(ns_shift))
        ns_shift += 7
        ns_continues = (b & 0x80) != 0
      }
      let mut name = ""
      for k in 0..<name_size {
        name = name + Char::from_int(view[i + k]).to_string()
      }
      i += name_size
      if name == "name" {
        // Find subsection 1
        while i < payload_end {
          let sub_id = view[i]
          i += 1
          let mut sub_size = 0
          let mut ss_shift = 0
          let mut ss_continues = true
          while ss_continues {
            let b = view[i]
            i += 1
            sub_size = sub_size | ((b & 0x7f).lsl(ss_shift))
            ss_shift += 7
            ss_continues = (b & 0x80) != 0
          }
          if sub_id == 1 {
            let arr : Array[Byte] = []
            for k in 0..<sub_size {
              arr.push(view[i + k].to_byte())
            }
            return Some(Bytes::from_array(arr))
          }
          i += sub_size
        }
        return None
      }
      // Custom section but not "name" — skip its body
      i = payload_end
    } else {
      i = payload_end
    }
  }
  None
}

///|
/// Parse a name-section subsection 1 payload (vec of (idx LEB, name str))
/// into an `Array[(Int, String)]`.
fn parse_name_subsection1(payload : Bytes) -> Array[(Int, String)] {
  let view : Array[Int] = []
  for b in payload {
    view.push(b.to_int())
  }
  let mut i = 0
  let mut count = 0
  let mut shift = 0
  let mut continues = true
  while continues {
    let b = view[i]
    i += 1
    count = count | ((b & 0x7f).lsl(shift))
    shift += 7
    continues = (b & 0x80) != 0
  }
  let out : Array[(Int, String)] = []
  for _ in 0..<count {
    let mut idx = 0
    let mut isz = 0
    let mut ic = true
    while ic {
      let b = view[i]
      i += 1
      idx = idx | ((b & 0x7f).lsl(isz))
      isz += 7
      ic = (b & 0x80) != 0
    }
    let mut n_len = 0
    let mut ns = 0
    let mut nc = true
    while nc {
      let b = view[i]
      i += 1
      n_len = n_len | ((b & 0x7f).lsl(ns))
      ns += 7
      nc = (b & 0x80) != 0
    }
    let mut name = ""
    for k in 0..<n_len {
      name = name + Char::from_int(view[i + k]).to_string()
    }
    i += n_len
    out.push((idx, name))
  }
  out
}

///|
test "emit_module_wasm_gc includes a name custom section" {
  let ast = names_two_func_ast()
  let bytes = try! emit_module_wasm_gc(ast)
  let payload = find_name_subsection1(bytes)
  match payload {
    None => @debug.assert_eq("name subsection missing", "<expected present>")
    Some(p) => {
      let entries = parse_name_subsection1(p)
      // Expect at least the user function `main` and the synthetic
      // `_start` wrapper.
      let mut has_main = false
      let mut has_start = false
      for entry in entries {
        let (_, n) = entry
        if n == "main" {
          has_main = true
        }
        if n == "_start" {
          has_start = true
        }
      }
      @debug.assert_eq(has_main, true)
      @debug.assert_eq(has_start, true)
    }
  }
}

///|
test "emit_module_wasm_gc name section indices match function order" {
  let ast = names_two_func_ast()
  let bytes = try! emit_module_wasm_gc(ast)
  let payload = find_name_subsection1(bytes).unwrap()
  let entries = parse_name_subsection1(payload)
  // Indices must be monotonically non-decreasing per the wasm spec.
  let mut prev = -1
  for entry in entries {
    let (idx, _) = entry
    @debug.assert_eq(idx > prev, true)
    prev = idx
  }
}

///|
/// `let mk_adder = (n) -> { (x) -> { x + n } }`. The inner lambda
/// becomes a lifted closure and must surface in the name section as
/// `mk_adder::lambda@<offset>` so profiler stack traces show the
/// enclosing function alongside the lambda's source position.
fn names_closure_ast() -> @core.Module {
  let inner_span = @core.Span::empty(80)
  let n_ident = @core.Expr::Ident(name="n", span=names_span())
  let x_ident = @core.Expr::Ident(name="x", span=names_span())
  let add = names_call("__add", [x_ident, n_ident])
  let inner_body : @core.Module = { stmts: [names_stmt_expr(add)] }
  let inner_fn = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[
      @core.FuncParam::{
        name: "x",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Int,
        bounds: [],
      },
    ],
    ret=Some(@core.Type::Int),
    effects=[],
    body=inner_body,
    span=inner_span,
  )
  let outer_body : @core.Module = { stmts: [names_stmt_expr(inner_fn)] }
  let outer_fn = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[
      @core.FuncParam::{
        name: "n",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Int,
        bounds: [],
      },
    ],
    ret=Some(
      @core.Type::Func(
        params=[
          {
            name: "x",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=@core.Type::Int,
        effects=[],
      ),
    ),
    effects=[],
    body=outer_body,
    span=names_span(),
  )
  @core.Module::{ stmts: [names_let("mk_adder", outer_fn)] }
}

///|
test "lifted closures label with parent function and source offset" {
  let ast = names_closure_ast()
  let bytes = try! emit_module_wasm_gc(ast)
  let payload = find_name_subsection1(bytes).unwrap()
  let entries = parse_name_subsection1(payload)
  let mut has_qualified_lambda = false
  for entry in entries {
    let (_, n) = entry
    if n.has_prefix("mk_adder::lambda@") {
      has_qualified_lambda = true
    }
  }
  @debug.assert_eq(has_qualified_lambda, true)
}

///|
/// Real source string: the inner lambda starts at line 2, col 3.
/// `emit_module_wasm_gc_with_source` should upgrade the label from a
/// byte offset to `<line>:<col>`.
test "emit_module_wasm_gc_with_source upgrades lambda label to line:col" {
  let src =
    #|let mk_adder = (n: Int) -> (Int) -> Int {
    #|  (x: Int) -> Int { x + n }
    #|}
    #|mk_adder(1)
  let ast = try! @parser.parse_ast(src)
  let bytes = try! emit_module_wasm_gc_with_source(ast, src)
  let payload = find_name_subsection1(bytes).unwrap()
  let entries = parse_name_subsection1(payload)
  let mut lambda_label : String = ""
  for entry in entries {
    let (_, n) = entry
    if n.has_prefix("mk_adder::lambda@") {
      lambda_label = n
    }
  }
  // The inner lambda body opens with `(x` at line 2, column 3
  // (1-based). Confirm the upgrade kicked in — i.e. the label
  // contains a `:` after the `@`.
  @debug.assert_eq(lambda_label, "mk_adder::lambda@2:3")
}
