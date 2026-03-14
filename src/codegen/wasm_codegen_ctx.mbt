///|
priv struct CodegenCtx {
  mut locals : Map[String, Int]
  mut local_kinds : Map[String, ValueKind]
  mut local_types : Array[ValueKind]
  mut local_count : Int
  fn_indices : Map[String, Int]
  fn_needs_env : Map[Int, Bool] // function index -> closure env required
  fn_needs_heap : Map[String, Bool] // function name -> needs heap allocation
  fn_params : Map[String, Array[ValueKind]]
  fn_param_names : Map[String, Array[String]] // function name -> param names
  fn_returns : Map[String, ValueKind]
  fn_multivalue_results : Map[String, Array[ValueKind]] // tuple-returning functions -> element kinds
  fn_return_sigs : Map[String, FuncSig] // return sig if function returns a function
  fn_closure_indices : Map[String, Int]
  fn_closure_captures : Map[String, Array[String]]
  fn_closure_capture_kinds : Map[String, Array[ValueKind]]
  fn_table_slots : Map[Int, Int] // function index -> table slot
  fn_table_order : Array[Int] // table slot order -> function index
  // enum info: ctor_name -> (tag_index, arity, arg_kinds)
  enum_ctor_tags : Map[String, Int]
  mut next_ctor_tag : Int
  enum_ctor_arities : Map[String, Int]
  enum_ctor_arg_kinds : Map[String, Array[ValueKind]]
  enum_ctor_singletons : Map[String, Int64] // 0-arg ctor name -> precomputed tagged ptr
  mut is_tail_position : Bool // true when compiling tail-position expression
  mut fn_local_sigs : Map[String, FuncSig]
  mut fn_sig_type_indices : Map[String, Int]
  mut fn_sig_order : Array[FuncSig]
  mut fn_type_indices : Map[String, Int]
  mut need_sh : Bool
  mut need_path : Bool
  mut need_dynamic_path_resolve : Bool
  mut need_env_get : Bool
  mut need_env_args_len : Bool
  mut need_env_args_get : Bool
  mut need_js_length : Bool
  mut need_js_char_code_at : Bool
  mut need_js_substring : Bool
  mut need_js_concat : Bool
  mut need_js_equals : Bool
  use_js_strings : Bool
  mut use_heap_global : Bool
  mut heap_global : Int
  mut need_heap : Bool
  mut heap_local : Int
  mut current_env_idx : Int
  mut need_exceptions : Bool
  mut error_tag_type_index : Int
  error_tag_index : Int
  embed_error_strings : Bool
  error_codes : StringConstTable
  mut need_extern_table : Bool
  mut need_funcref_table : Bool
  mut extern_table_index : Int
  mut extern_table_next_slot : Int
  known_record_fields : Map[String, Bool]
  strings : StringTable
  js_strings : StringConstTable
  // Stack switching for async
  mut need_stack_switching : Bool
  mut await_tag_type_index : Int
  mut await_tag_index : Int
  mut sleep_tag_index : Int
  mut run_func_type_index : Int
  mut async_result_global_index : Int
  // Sleep import function
  mut need_sleep : Bool
  mut sleep_import_index : Int
  // StdIO char-level import functions
  mut need_stdout_write_char : Bool
  mut need_stdin_read_char : Bool
  // Filesystem WASI imports
  mut need_fs : Bool
  // Socket WASI imports
  mut need_socket : Bool
  // HTTP WASI imports (P3 draft — stub for now)
  mut need_http : Bool
  http_host_imports : Bool
  http_component_wasi_shim : Bool
  // Source-level coverage instrumentation
  coverage_enabled : Bool
  coverage_points : Array[WasmCoveragePoint]
  mut coverage_base_offset : Int
  mut coverage_base_global_index : Int
  mut coverage_count_global_index : Int
  // Exported user functions (export let ...)
  exported_fns : Map[String, Bool]
  // Loop break/continue label offsets (-1 = not in loop)
  mut loop_break_offset : Int
  mut loop_continue_offset : Int
  // For parameterized loop: local indices for loop params
  mut loop_param_locals : Array[Int]
  // Forward-declared function tracking for mutual recursion back-patch
  // Maps function name -> span_key for forward-declarable functions
  forward_fn_keys : Map[String, String]
  // Mutable variables captured by closures (need ref cell on heap)
  mut mut_captured_vars : Map[String, Bool]
  // Per-function: which capture slots are ref cell pointers
  fn_closure_capture_is_ref_cell : Map[String, Array[Bool]]
  // Cache: scrutinee local → untagged raw pointer local (within match chains)
  mut cached_untag_ptrs : Map[Int, Int]
  // Constant values inlined at use sites (pre-tagged i64, skip local allocation)
  mut const_i64_values : Map[String, Int64]
  // Force cabi_realloc export for component string lift
  force_cabi_realloc : Bool
  // Exported closures: maps exported fn name -> global index storing env pointer
  exported_fn_env_globals : Map[String, Int]
  // S8: heap_synced tracks whether heap_local == heap_global
  mut heap_synced : Bool
  // Tail call optimization (return_call / return_call_indirect)
  enable_tail_call : Bool
}

///|
fn CodegenCtx::new(
  use_js_strings : Bool,
  coverage_enabled? : Bool = false,
  embed_error_strings? : Bool = false,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
  force_cabi_realloc? : Bool = false,
) -> CodegenCtx {
  // Register builtin enum constructors
  let enum_ctor_tags : Map[String, Int] = {}
  let enum_ctor_arities : Map[String, Int] = {}
  let enum_ctor_arg_kinds : Map[String, Array[ValueKind]] = {}
  // Option type: None = 0, Some = 1
  enum_ctor_tags["None"] = 0
  enum_ctor_tags["Some"] = 1
  enum_ctor_arities["None"] = 0
  enum_ctor_arities["Some"] = 1
  enum_ctor_arg_kinds["None"] = []
  enum_ctor_arg_kinds["Some"] = [ValueKind::I32]
  let ctx : CodegenCtx = {
    locals: {},
    local_kinds: {},
    local_types: [],
    local_count: 0,
    fn_indices: {},
    fn_needs_env: {},
    fn_needs_heap: {},
    fn_params: {},
    fn_param_names: {},
    fn_returns: {},
    fn_multivalue_results: {},
    fn_return_sigs: {},
    fn_closure_indices: {},
    fn_closure_captures: {},
    fn_closure_capture_kinds: {},
    fn_table_slots: {},
    fn_table_order: [],
    enum_ctor_tags,
    next_ctor_tag: 2,
    enum_ctor_arities,
    enum_ctor_arg_kinds,
    enum_ctor_singletons: {},
    is_tail_position: false,
    fn_local_sigs: {},
    fn_sig_type_indices: {},
    fn_sig_order: [],
    fn_type_indices: {},
    need_sh: false,
    need_path: false,
    need_dynamic_path_resolve: false,
    need_env_get: false,
    need_env_args_len: false,
    need_env_args_get: false,
    need_js_length: false,
    need_js_char_code_at: false,
    need_js_substring: false,
    need_js_concat: false,
    need_js_equals: false,
    use_js_strings,
    use_heap_global: false,
    heap_global: -1,
    need_heap: false,
    heap_local: -1,
    current_env_idx: -1,
    need_exceptions: false,
    error_tag_type_index: -1,
    error_tag_index: 0,
    embed_error_strings,
    error_codes: StringConstTable::new(),
    need_extern_table: false,
    need_funcref_table: false,
    extern_table_index: -1,
    extern_table_next_slot: 0,
    known_record_fields: {},
    strings: StringTable::new(),
    js_strings: StringConstTable::new(),
    // Stack switching for async
    need_stack_switching: false,
    await_tag_type_index: -1,
    await_tag_index: 0,
    sleep_tag_index: 0,
    run_func_type_index: -1,
    async_result_global_index: -1,
    // Sleep import function
    need_sleep: false,
    sleep_import_index: -1,
    // StdIO char-level import functions
    need_stdout_write_char: false,
    need_stdin_read_char: false,
    // Filesystem WASI imports
    need_fs: false,
    // Socket WASI imports
    need_socket: false,
    // HTTP WASI imports
    need_http: false,
    http_host_imports,
    http_component_wasi_shim,
    // Source-level coverage instrumentation
    coverage_enabled,
    coverage_points: [],
    coverage_base_offset: 0,
    coverage_base_global_index: -1,
    coverage_count_global_index: -1,
    // Exported user functions
    exported_fns: {},
    // Loop offsets
    loop_break_offset: -1,
    loop_continue_offset: -1,
    loop_param_locals: [],
    // Forward function tracking
    forward_fn_keys: {},
    // Mutable capture ref cell tracking
    mut_captured_vars: {},
    fn_closure_capture_is_ref_cell: {},
    // Untag pointer cache
    cached_untag_ptrs: {},
    // Constant values (pre-tagged i64)
    const_i64_values: {},
    // Force cabi_realloc export
    force_cabi_realloc,
    // Exported closures env globals
    exported_fn_env_globals: {},
    heap_synced: false,
    enable_tail_call: false,
  }
  // Register builtin None as singleton (strings is now initialized)
  let none_offset = ctx.strings.intern_enum_singleton("None", 0)
  ctx.enum_ctor_singletons["None"] = tag_ptr64(none_offset, tag_obj)
  ctx
}

///|
fn fn_index_needs_env(ctx : CodegenCtx, idx : Int) -> Bool {
  match ctx.fn_needs_env.get(idx) {
    Some(v) => v
    None => false
  }
}

///|
priv struct FuncDef {
  name : String?
  params : Array[@core.FuncParam]
  ret : @core.Type?
  body : @core.Module
  span_key : String
  captures : Array[String]
}

///|
fn compute_fn_env_requirements(funcs : Array[FuncDef]) -> Array[Bool] {
  let needs = Array::make(funcs.length(), false)
  for i in 0..<funcs.length() {
    // Current closure conversion always reads captured values from env slots.
    // Therefore any function with captures requires an env-backed function value.
    needs[i] = funcs[i].captures.length() > 0
  }
  needs
}

///|
priv struct FuncSig {
  params : Array[ValueKind]
  results : Array[ValueKind]
}

///|
fn span_key(span : @core.Span) -> String {
  "\{span.start}:\{span.end}"
}

///|
fn push_capture(
  name : String,
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  if not(seen.contains(name)) {
    seen[name] = true
    captures.push(name)
  }
}

///|
fn collect_pat_bindings_codegen(pat : @core.Pat, out : Array[String]) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      out.push(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pat_bindings_codegen(arg, out)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pat_bindings_codegen(item, out)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pat_bindings_codegen(field.pat, out)
      }
    }
    _ => ()
  }
}

///|
fn collect_captures_block(
  body : @core.Module,
  bound : Map[String, Bool],
  outer_bound : Map[String, Bool],
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  let scope = bound.copy()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        scope[name] = true
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        collect_captures_block(body, scope, outer_bound, captures, seen)
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = span
        collect_captures_block(body, scope, outer_bound, captures, seen)
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        collect_captures_block(else_body, scope, outer_bound, captures, seen)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        scope[name] = true
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        if not(scope.contains(name)) && outer_bound.contains(name) {
          push_capture(name, captures, seen)
        }
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        collect_captures_expr(target, scope, outer_bound, captures, seen)
        collect_captures_expr(index, scope, outer_bound, captures, seen)
        collect_captures_expr(value, scope, outer_bound, captures, seen)
      }
      _ => ()
    }
  }
}

///|
fn collect_captures_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  outer_bound : Map[String, Bool],
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      if not(bound.contains(name)) && outer_bound.contains(name) {
        push_capture(name, captures, seen)
      }
    }
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      if not(bound.contains(name)) && outer_bound.contains(name) {
        push_capture(name, captures, seen)
      }
      for arg in args {
        collect_captures_expr(arg.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_captures_expr(item, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) =>
      collect_captures_expr(expr, bound, outer_bound, captures, seen)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_captures_expr(field.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_captures_expr(item, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_captures_expr(field.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_captures_expr(cond, bound, outer_bound, captures, seen)
      collect_captures_block(then_body, bound, outer_bound, captures, seen)
      collect_captures_block(else_body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_captures_expr(scrutinee, bound, outer_bound, captures, seen)
      for arm in arms {
        let arm_bound = bound.copy()
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(arm.pat, bindings)
        for name in bindings {
          arm_bound[name] = true
        }
        match arm.cond {
          Some(c) =>
            collect_captures_expr(c, arm_bound, outer_bound, captures, seen)
          None => ()
        }
        collect_captures_expr(arm.expr, arm_bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      collect_captures_block(body, bound, outer_bound, captures, seen)
      for arm in arms {
        collect_captures_expr(arm.expr, bound, outer_bound, captures, seen)
        match arm.cond {
          Some(c) =>
            collect_captures_expr(c, bound, outer_bound, captures, seen)
          None => ()
        }
      }
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_captures_expr(value, bound, outer_bound, captures, seen)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_captures_expr(cond, bound, outer_bound, captures, seen)
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      for param in params {
        collect_captures_expr(param.init, bound, outer_bound, captures, seen)
      }
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = ret
      let _ = effects
      let _ = span
      // A nested function may reference outer-outer variables only inside its
      // own body. Propagate those through this function's capture set so nested
      // closure construction can load them from locals.
      let nested_bound : Map[String, Bool] = {}
      for param in params {
        nested_bound[param.name] = true
      }
      let nested_outer = outer_bound.copy()
      for name, _ in bound {
        nested_outer[name] = true
      }
      let nested_caps : Array[String] = []
      let nested_seen : Map[String, Bool] = {}
      collect_captures_block(
        body, nested_bound, nested_outer, nested_caps, nested_seen,
      )
      for name in nested_caps {
        if not(bound.contains(name)) && outer_bound.contains(name) {
          push_capture(name, captures, seen)
        }
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      collect_captures_block(desugared, bound, outer_bound, captures, seen)
    }
    _ => ()
  }
}

///|
fn collect_nested_funcs_block(
  body : @core.Module,
  bound : Map[String, Bool],
  funcs : Array[FuncDef],
  skip_top_level : Bool,
) -> Unit {
  let scope = bound.copy()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            let key = span_key(span)
            let captures : Array[String] = []
            let seen : Map[String, Bool] = {}
            let fn_bound : Map[String, Bool] = {}
            for param in params {
              fn_bound[param.name] = true
            }
            collect_captures_block(body, fn_bound, scope, captures, seen)
            if not(skip_top_level) {
              funcs.push(FuncDef::{
                name: Some(name),
                params,
                ret,
                body,
                span_key: key,
                captures,
              })
            }
            let inner_bound = scope.copy()
            for param in params {
              inner_bound[param.name] = true
            }
            for cap in captures {
              inner_bound[cap] = true
            }
            if rec {
              // Recursive binding name is in scope inside the function body.
              // Nested closures must be able to capture it as a closure value.
              inner_bound[name] = true
            }
            collect_nested_funcs_block(body, inner_bound, funcs, false)
          }
          _ => collect_nested_funcs_expr(expr, scope, funcs)
        }
        scope[name] = true
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
        collect_nested_funcs_block(else_body, scope, funcs, false)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
        scope[name] = true
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            let key = span_key(span)
            let captures : Array[String] = []
            let seen : Map[String, Bool] = {}
            let fn_bound : Map[String, Bool] = {}
            for param in params {
              fn_bound[param.name] = true
            }
            collect_captures_block(body, fn_bound, scope, captures, seen)
            if not(skip_top_level) {
              funcs.push(FuncDef::{
                name: Some(name),
                params,
                ret,
                body,
                span_key: key,
                captures,
              })
            }
            let inner_bound = scope.copy()
            for param in params {
              inner_bound[param.name] = true
            }
            for cap in captures {
              inner_bound[cap] = true
            }
            if rec {
              inner_bound[name] = true
            }
            collect_nested_funcs_block(body, inner_bound, funcs, false)
          }
          _ => collect_nested_funcs_expr(expr, scope, funcs)
        }
        scope[name] = true
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = name
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
      }
      _ => ()
    }
  }
}

///|
fn collect_nested_funcs_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  funcs : Array[FuncDef],
) -> Unit {
  match expr {
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = effects
      let key = span_key(span)
      let captures : Array[String] = []
      let seen : Map[String, Bool] = {}
      let fn_bound : Map[String, Bool] = {}
      for param in params {
        fn_bound[param.name] = true
      }
      collect_captures_block(body, fn_bound, bound, captures, seen)
      funcs.push(FuncDef::{
        name: None,
        params,
        ret,
        body,
        span_key: key,
        captures,
      })
      let inner_bound = bound.copy()
      for param in params {
        inner_bound[param.name] = true
      }
      for cap in captures {
        inner_bound[cap] = true
      }
      collect_nested_funcs_block(body, inner_bound, funcs, false)
    }
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_nested_funcs_expr(arg.expr, bound, funcs)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_nested_funcs_expr(item, bound, funcs)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) =>
      collect_nested_funcs_expr(expr, bound, funcs)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_nested_funcs_expr(field.expr, bound, funcs)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_nested_funcs_expr(item, bound, funcs)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_nested_funcs_expr(field.expr, bound, funcs)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_nested_funcs_expr(cond, bound, funcs)
      collect_nested_funcs_block(then_body, bound, funcs, false)
      collect_nested_funcs_block(else_body, bound, funcs, false)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_nested_funcs_expr(scrutinee, bound, funcs)
      for arm in arms {
        let arm_bound = bound.copy()
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(arm.pat, bindings)
        for name in bindings {
          arm_bound[name] = true
        }
        match arm.cond {
          Some(c) => collect_nested_funcs_expr(c, arm_bound, funcs)
          None => ()
        }
        collect_nested_funcs_expr(arm.expr, arm_bound, funcs)
      }
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      collect_nested_funcs_block(body, bound, funcs, false)
      for arm in arms {
        collect_nested_funcs_expr(arm.expr, bound, funcs)
        match arm.cond {
          Some(c) => collect_nested_funcs_expr(c, bound, funcs)
          None => ()
        }
      }
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_nested_funcs_expr(value, bound, funcs)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_nested_funcs_expr(cond, bound, funcs)
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      for param in params {
        collect_nested_funcs_expr(param.init, bound, funcs)
      }
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      collect_nested_funcs_block(desugared, bound, funcs, false)
    }
    _ => ()
  }
}

///|
fn collect_func_defs(ast : @core.Module) -> Array[FuncDef] {
  let funcs : Array[FuncDef] = []
  let top_level_fn_names : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr=@core.Expr::Fn(..), ..)
      | @core.Stmt::ExportLet(name~, expr=@core.Expr::Fn(..), ..) =>
        top_level_fn_names[name] = true
      _ => ()
    }
  }
  // Build outer_bound: all top-level non-function bindings that precede each function
  let outer_bound : Map[String, Bool] = {}
  // Pre-populate: forward-declarable functions (Fn with explicit return type)
  // so that mutual references are included in capture lists
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr=@core.Expr::Fn(ret=Some(_), ..), ..)
      | @core.Stmt::ExportLet(name~, expr=@core.Expr::Fn(ret=Some(_), ..), ..) =>
        outer_bound[name] = true
      _ => ()
    }
  }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          outer_bound[name] = true
        }
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            let key = span_key(span)
            // Collect captures: variables used in body but defined in outer scope
            let captures : Array[String] = []
            let seen : Map[String, Bool] = {}
            let fn_bound : Map[String, Bool] = {}
            for param in params {
              fn_bound[param.name] = true
            }
            collect_captures_block(body, fn_bound, outer_bound, captures, seen)
            funcs.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: key,
              captures,
            })
          }
          _ => ()
        }
        outer_bound[name] = true
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = expr
        let _ = span
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for b in bindings {
          outer_bound[b] = true
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = expr
        let _ = else_body
        let _ = span
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for b in bindings {
          outer_bound[b] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = expr
        let _ = span
        outer_bound[name] = true
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        // ExportLet is treated like Let for function collection
        let _ = span
        if rec {
          outer_bound[name] = true
        }
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            let key = span_key(span)
            let captures : Array[String] = []
            let seen : Map[String, Bool] = {}
            let fn_bound : Map[String, Bool] = {}
            for param in params {
              fn_bound[param.name] = true
            }
            collect_captures_block(body, fn_bound, outer_bound, captures, seen)
            funcs.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: key,
              captures,
            })
          }
          _ => ()
        }
        outer_bound[name] = true
      }
      _ => ()
    }
  }
  let bound : Map[String, Bool] = {}
  collect_nested_funcs_block(ast, bound, funcs, true)
  // Top-level function captures are filtered by a fixed-point:
  // keep captured top-level functions only if they are env-required
  // (directly via non-function captures, or transitively through such calls).
  let top_level_needs_env : Map[String, Bool] = {}
  for f in funcs {
    match f.name {
      Some(name) if top_level_fn_names.contains(name) =>
        for cap in f.captures {
          if not(top_level_fn_names.contains(cap)) {
            top_level_needs_env[name] = true
            break
          }
        }
      _ => ()
    }
  }
  let mut changed = true
  while changed {
    changed = false
    for f in funcs {
      match f.name {
        Some(name) if top_level_fn_names.contains(name) =>
          if not(top_level_needs_env.contains(name)) {
            let mut needs = false
            for cap in f.captures {
              if top_level_fn_names.contains(cap) &&
                top_level_needs_env.contains(cap) {
                needs = true
                break
              }
            }
            if needs {
              top_level_needs_env[name] = true
              changed = true
            }
          }
        _ => ()
      }
    }
  }
  let normalized_funcs : Array[FuncDef] = []
  for f in funcs {
    match f.name {
      Some(name) if top_level_fn_names.contains(name) => {
        let filtered_captures : Array[String] = []
        for cap in f.captures {
          if not(top_level_fn_names.contains(cap)) ||
            top_level_needs_env.contains(cap) {
            filtered_captures.push(cap)
          }
        }
        normalized_funcs.push(FuncDef::{
          name: f.name,
          params: f.params,
          ret: f.ret,
          body: f.body,
          span_key: f.span_key,
          captures: filtered_captures,
        })
      }
      _ => normalized_funcs.push(f)
    }
  }
  normalized_funcs
}

///|
/// Compute which `let mut` variables in a block are captured by closures
/// and thus need ref cell (heap pointer) treatment.
fn compute_mut_captured_for_block(
  stmts : Array[@core.Stmt],
  fn_closure_captures : Map[String, Array[String]],
) -> Map[String, Bool] {
  // Step 1: Collect LetMut names defined directly in this block
  // Track shadowing: later Let/LetMut overrides earlier
  let is_mut : Map[String, Bool] = {}
  for stmt in stmts {
    match stmt {
      @core.Stmt::LetMut(name~, ..) => is_mut[name] = true
      @core.Stmt::Let(name~, ..) => is_mut[name] = false
      @core.Stmt::ExportLet(name~, ..) => is_mut[name] = false
      @core.Stmt::LetPat(pat~, ..) => {
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for b in bindings {
          is_mut[b] = false
        }
      }
      @core.Stmt::LetPatElse(pat~, ..) => {
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for b in bindings {
          is_mut[b] = false
        }
      }
      _ => ()
    }
  }
  // Quick exit if no mutable variables
  let mut has_any_mut = false
  for _, v in is_mut {
    if v {
      has_any_mut = true
      break
    }
  }
  if not(has_any_mut) {
    return {}
  }
  // Step 2: Collect all Fn span_keys defined in this scope
  // (recurse into control flow but NOT into Fn bodies)
  let fn_keys : Array[String] = []
  for stmt in stmts {
    collect_fn_span_keys_stmt(stmt, fn_keys)
  }
  // Step 3: Cross-reference captures with LetMut names
  let result : Map[String, Bool] = {}
  for key in fn_keys {
    match fn_closure_captures.get(key) {
      Some(caps) =>
        for cap in caps {
          match is_mut.get(cap) {
            Some(true) => result[cap] = true
            _ => ()
          }
        }
      None => ()
    }
  }
  result
}

///|
fn collect_fn_span_keys_stmt(stmt : @core.Stmt, out : Array[String]) -> Unit {
  match stmt {
    @core.Stmt::Let(expr=@core.Expr::Fn(span~, ..), ..)
    | @core.Stmt::ExportLet(expr=@core.Expr::Fn(span~, ..), ..) =>
      out.push(span_key(span))
    // Don't recurse into Fn body — that's a different scope
    @core.Stmt::Let(expr~, ..) | @core.Stmt::ExportLet(expr~, ..) =>
      collect_fn_span_keys_expr(expr, out)
    @core.Stmt::Expr(expr~, ..) => collect_fn_span_keys_expr(expr, out)
    @core.Stmt::LetMut(expr~, ..) => collect_fn_span_keys_expr(expr, out)
    @core.Stmt::Assign(expr~, ..) => collect_fn_span_keys_expr(expr, out)
    @core.Stmt::LetPat(expr~, ..) => collect_fn_span_keys_expr(expr, out)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      collect_fn_span_keys_expr(expr, out)
      for s in else_body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      collect_fn_span_keys_expr(target, out)
      collect_fn_span_keys_expr(index, out)
      collect_fn_span_keys_expr(value, out)
    }
    _ => ()
  }
}

///|
fn collect_fn_span_keys_expr(expr : @core.Expr, out : Array[String]) -> Unit {
  match expr {
    @core.Expr::Fn(span~, ..) => out.push(span_key(span))
    // Don't recurse into Fn body
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_fn_span_keys_expr(arg.expr, out)
      }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        collect_fn_span_keys_expr(item, out)
      }
    @core.Expr::TupleIndex(expr~, ..) => collect_fn_span_keys_expr(expr, out)
    @core.Expr::Record(fields~, ..) =>
      for f in fields {
        collect_fn_span_keys_expr(f.expr, out)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_fn_span_keys_expr(item, out)
      }
    @core.Expr::Map(fields~, ..) =>
      for f in fields {
        collect_fn_span_keys_expr(f.expr, out)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_fn_span_keys_expr(cond, out)
      for s in then_body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
      for s in else_body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    }
    @core.Expr::Block(body~, ..) =>
      for s in body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_fn_span_keys_expr(scrutinee, out)
      for arm in arms {
        collect_fn_span_keys_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_fn_span_keys_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      for s in body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
      for arm in arms {
        collect_fn_span_keys_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_fn_span_keys_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Raise(value~, ..) => collect_fn_span_keys_expr(value, out)
    @core.Expr::While(cond~, body~, ..) => {
      collect_fn_span_keys_expr(cond, out)
      for s in body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        collect_fn_span_keys_expr(p.init, out)
      }
      for s in body.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      for s in desugared.stmts {
        collect_fn_span_keys_stmt(s, out)
      }
    }
    @core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        collect_fn_span_keys_expr(f.expr, out)
      }
    _ => ()
  }
}

///|
/// Pre-compute fn_closure_capture_is_ref_cell for ALL functions before the
/// compile loop. scope_mcv is the set of variable names that are ref cells
/// in the current scope.
fn precompute_ref_cell_captures_block(
  ctx : CodegenCtx,
  stmts : Array[@core.Stmt],
  scope_mcv : Map[String, Bool],
) -> Unit {
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(expr=@core.Expr::Fn(body~, span~, ..), ..)
      | @core.Stmt::ExportLet(expr=@core.Expr::Fn(body~, span~, ..), ..) =>
        precompute_ref_cell_for_fn(ctx, span, body, scope_mcv)
      @core.Stmt::Let(expr~, ..) | @core.Stmt::ExportLet(expr~, ..) =>
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
      @core.Stmt::Expr(expr~, ..) =>
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
      @core.Stmt::LetMut(expr~, ..) =>
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
      @core.Stmt::Assign(expr~, ..) =>
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
      @core.Stmt::LetPat(expr~, ..) =>
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
      @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
        precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
        precompute_ref_cell_captures_block(ctx, else_body.stmts, scope_mcv)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
        precompute_ref_cell_captures_expr(ctx, target, scope_mcv)
        precompute_ref_cell_captures_expr(ctx, index, scope_mcv)
        precompute_ref_cell_captures_expr(ctx, value, scope_mcv)
      }
      _ => ()
    }
  }
}

///|
fn precompute_ref_cell_captures_expr(
  ctx : CodegenCtx,
  expr : @core.Expr,
  scope_mcv : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Fn(body~, span~, ..) =>
      precompute_ref_cell_for_fn(ctx, span, body, scope_mcv)
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        precompute_ref_cell_captures_expr(ctx, arg.expr, scope_mcv)
      }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        precompute_ref_cell_captures_expr(ctx, item, scope_mcv)
      }
    @core.Expr::TupleIndex(expr~, ..) =>
      precompute_ref_cell_captures_expr(ctx, expr, scope_mcv)
    @core.Expr::Record(fields~, ..) =>
      for f in fields {
        precompute_ref_cell_captures_expr(ctx, f.expr, scope_mcv)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        precompute_ref_cell_captures_expr(ctx, item, scope_mcv)
      }
    @core.Expr::Map(fields~, ..) =>
      for f in fields {
        precompute_ref_cell_captures_expr(ctx, f.expr, scope_mcv)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      precompute_ref_cell_captures_expr(ctx, cond, scope_mcv)
      precompute_ref_cell_captures_block(ctx, then_body.stmts, scope_mcv)
      precompute_ref_cell_captures_block(ctx, else_body.stmts, scope_mcv)
    }
    @core.Expr::Block(body~, ..) =>
      precompute_ref_cell_captures_block(ctx, body.stmts, scope_mcv)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      precompute_ref_cell_captures_expr(ctx, scrutinee, scope_mcv)
      for arm in arms {
        precompute_ref_cell_captures_expr(ctx, arm.expr, scope_mcv)
        match arm.cond {
          Some(c) => precompute_ref_cell_captures_expr(ctx, c, scope_mcv)
          None => ()
        }
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      precompute_ref_cell_captures_block(ctx, body.stmts, scope_mcv)
      for arm in arms {
        precompute_ref_cell_captures_expr(ctx, arm.expr, scope_mcv)
        match arm.cond {
          Some(c) => precompute_ref_cell_captures_expr(ctx, c, scope_mcv)
          None => ()
        }
      }
    }
    @core.Expr::Raise(value~, ..) =>
      precompute_ref_cell_captures_expr(ctx, value, scope_mcv)
    @core.Expr::While(cond~, body~, ..) => {
      precompute_ref_cell_captures_expr(ctx, cond, scope_mcv)
      precompute_ref_cell_captures_block(ctx, body.stmts, scope_mcv)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        precompute_ref_cell_captures_expr(ctx, p.init, scope_mcv)
      }
      precompute_ref_cell_captures_block(ctx, body.stmts, scope_mcv)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      precompute_ref_cell_captures_block(ctx, desugared.stmts, scope_mcv)
    }
    @core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        precompute_ref_cell_captures_expr(ctx, f.expr, scope_mcv)
      }
    _ => ()
  }
}

///|
fn precompute_ref_cell_for_fn(
  ctx : CodegenCtx,
  span : @core.Span,
  body : @core.Module,
  scope_mcv : Map[String, Bool],
) -> Unit {
  let key = span_key(span)
  match ctx.fn_closure_captures.get(key) {
    Some(caps) => {
      let flags : Array[Bool] = []
      for cap in caps {
        flags.push(scope_mcv.contains(cap))
      }
      ctx.fn_closure_capture_is_ref_cell[key] = flags
      // Compute the body's own mut captured vars
      let body_mcv = compute_mut_captured_for_block(
        body.stmts,
        ctx.fn_closure_captures,
      )
      // Propagate: captures that are ref cells remain ref cells in the body
      for i in 0..<caps.length() {
        if flags[i] {
          body_mcv[caps[i]] = true
        }
      }
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
    }
    // No captures, but still recurse for nested functions
    None => {
      let body_mcv = compute_mut_captured_for_block(
        body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
    }
  }
}
