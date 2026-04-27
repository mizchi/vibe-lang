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
  // Effect resume globals for cross-function perform dispatch
  effect_handled_ops : Map[String, Bool]
  mut need_effect_resume : Bool
  // Per-effect resume globals: effect_name -> (idx, count, buf) global indices.
  // Each handled effect gets its own (idx, count, buf) triple so nested
  // handles for *different* effects don't clobber each other's resume state.
  // Same-effect nesting is handled via save/restore in handle codegen.
  effect_resume_globals : Map[String, (Int, Int, Int)]
  mut effect_perform_arg_global : Int // i64: perform argument value for cross-function dispatch
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
  mut need_json_host_parse : Bool
  mut need_json_host_stringify : Bool
  mut need_json_host_get : Bool
  mut need_json_host_string : Bool
  // Socket WASI imports
  mut need_socket : Bool
  // HTTP WASI imports (P3 draft — stub for now)
  mut need_http : Bool
  http_host_imports : Bool
  http_component_wasi_shim : Bool
  // Filesystem host imports (vibe module instead of WASI)
  fs_host_imports : Bool
  // Source-level coverage instrumentation
  coverage_enabled : Bool
  coverage_points : Array[WasmCoveragePoint]
  mut coverage_base_offset : Int
  mut coverage_base_global_index : Int
  mut coverage_count_global_index : Int
  // Effect operation imports: "Effect::Op" → import func index
  effect_op_imports : Map[String, Int]
  // Effect operation param counts: "Effect::Op" → number of i64 params
  effect_op_param_counts : Map[String, Int]
  // Exported user functions (export let ...)
  exported_fns : Map[String, Bool]
  exported_fn_aliases : Map[String, String]
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
  // Cache: raw_ptr local → obj_type local (within match chains)
  mut cached_obj_types : Map[Int, Int]
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
  // Library mode: skip _start, suitable for --preload linking
  library_mode : Bool
  // Linked function imports: func_name -> absolute import func index
  // Used for debug linked builds where imported modules are pre-compiled .wasm
  linked_fn_imports : Map[String, Int]
  // Linked function param counts: func_name -> param count (for env arg)
  linked_fn_param_counts : Map[String, Int]
  // Linked function return counts: func_name -> return count (1=scalar, 2+=tuple)
  linked_fn_return_counts : Map[String, Int]
  // Linked imports list: (wasm_module_name, func_name, param_count, return_count)
  mut linked_fn_imports_list : Array[(String, String, Int, Int)]
  // Perceus RC: enable reference counting codegen
  mut enable_rc : Bool
  mut rc_debug : Bool
  // Perceus RC: per-stmt actions keyed by (prefix, stmt_index)
  // prefix="" for top-level, "stmt[2].expr.body" for nested blocks, etc.
  mut rc_pre_actions : Map[String, Map[Int, Array[RcStmtAction]]]
  mut rc_post_actions : Map[String, Map[Int, Array[RcStmtAction]]]
  mut rc_action_prefix : String
  // Per-function RC actions: func_name → raw action tuples
  mut rc_func_actions : Map[String, Array[(String, Bool, String)]]
  // RC free-list head global index (-1 if not allocated)
  mut rc_free_list_global : Int
  // Perceus RC: temp locals for dup/drop operations (allocated per function)
  mut rc_tmp_local : Int
  mut rc_new_rc_local : Int
  // RC helper function indices (compiled_funcs-relative, -1 if not allocated)
  mut rc_dup_func_idx : Int
  mut rc_drop_func_idx : Int
  mut rc_alloc_func_idx : Int
  mut rc_try_reuse_func_idx : Int
  // Reuse candidate: local holding obj_ptr from try_reuse (-1 if none)
  mut rc_reuse_local : Int
  // RC drop optimization: which object types are actually allocated
  // (used to slim down $rc_drop by only emitting relevant type branches)
  mut rc_has_tuple_or_array : Bool
  mut rc_has_record_or_map : Bool
  mut rc_has_closure : Bool
  mut rc_has_enum : Bool
  mut rc_has_view : Bool
  // RC header size: 4 bytes (no free-list) or 8 bytes (with free-list).
  // Without free-list: [rc_count@-4][type_id@0][length@4][data@8...]
  // With free-list:    [alloc_size@-8][rc_count@-4][type_id@0][length@4][data@8...]
  mut rc_header_size : Int
  // RC: heap_start boundary for static data protection.
  // Pointers below this are in the data section and must not be RC-dropped.
  mut rc_heap_start : Int
  // RC debug mode: global indices for alloc/free counters (-1 if disabled)
  mut rc_debug_alloc_global : Int
  mut rc_debug_free_global : Int
  // Deep-compare helper for nested enum payloads: needed when any `__eq`
  // call could reach a heap-allocated enum value. The inline `__eq` in
  // `compile_binary_cmp_op` shallow-compares obj_enum payload slots via
  // `i32.eq` (i.e. pointer compare for tag_obj payloads), so structurally
  // equal but separately allocated values like
  // `Tree::Node(Tree::Leaf(1), Tree::Leaf(2))` would otherwise miscompare.
  // The helper recurses on each payload via self-call.
  mut need_value_eq : Bool
  mut value_eq_func_idx : Int
}

///|
fn CodegenCtx::new(
  use_js_strings : Bool,
  coverage_enabled? : Bool = false,
  embed_error_strings? : Bool = false,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
  fs_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
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
    effect_handled_ops: {},
    need_effect_resume: false,
    effect_resume_globals: {},
    effect_perform_arg_global: -1,
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
    need_json_host_parse: false,
    need_json_host_stringify: false,
    need_json_host_get: false,
    need_json_host_string: false,
    // Socket WASI imports
    need_socket: false,
    // HTTP WASI imports
    need_http: false,
    http_host_imports,
    http_component_wasi_shim,
    fs_host_imports,
    // Source-level coverage instrumentation
    coverage_enabled,
    coverage_points: [],
    coverage_base_offset: 0,
    coverage_base_global_index: -1,
    coverage_count_global_index: -1,
    // Exported user functions
    effect_op_imports: {},
    effect_op_param_counts: {},
    exported_fns: {},
    exported_fn_aliases: {},
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
    cached_obj_types: {},
    // Constant values (pre-tagged i64)
    const_i64_values: {},
    // Force cabi_realloc export
    force_cabi_realloc,
    // Exported closures env globals
    exported_fn_env_globals: {},
    heap_synced: false,
    enable_tail_call: false,
    library_mode,
    linked_fn_imports: {},
    linked_fn_param_counts: {},
    linked_fn_return_counts: {},
    linked_fn_imports_list: [],
    enable_rc: false,
    rc_debug: false,
    rc_pre_actions: {},
    rc_post_actions: {},
    rc_action_prefix: "",
    rc_func_actions: {},
    rc_free_list_global: -1,
    rc_tmp_local: -1,
    rc_new_rc_local: -1,
    rc_dup_func_idx: -1,
    rc_drop_func_idx: -1,
    rc_alloc_func_idx: -1,
    rc_try_reuse_func_idx: -1,
    rc_reuse_local: -1,
    rc_has_tuple_or_array: false,
    rc_has_record_or_map: false,
    rc_has_closure: false,
    rc_has_enum: false,
    rc_has_view: false,
    rc_header_size: 4, // default: no free-list, 4-byte header
    rc_heap_start: 0,
    rc_debug_alloc_global: -1,
    rc_debug_free_global: -1,
    need_value_eq: false,
    value_eq_func_idx: -1,
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
/// Build a span key that is unique within the func array by appending a
/// disambiguating suffix when the bare span key collides with an earlier
/// entry.  Both `collect_func_defs` (registration) and `compile_expr_fn`
/// (lookup) use this function, so the keys always agree.
fn span_key_unique(
  span : @core.Span,
  params : Array[@core.FuncParam],
) -> String {
  let base = span_key(span)
  if params.length() == 0 {
    return base
  }
  let buf = StringBuilder::new()
  buf.write_string(base)
  buf.write_char('/')
  for i, p in params {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(p.name)
  }
  buf.to_string()
}

///|
fn span_key_named(
  name : String?,
  span : @core.Span,
  params : Array[@core.FuncParam],
) -> String {
  let base = span_key_unique(span, params)
  match name {
    Some(fn_name) => base + "#" + fn_name
    None => base
  }
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
fn collect_pat_binding_kinds_codegen(
  ctx : CodegenCtx,
  pat : @core.Pat,
  scrut_kind : ValueKind,
  out : Map[String, ValueKind],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      out[name] = scrut_kind
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      let arg_kinds = match ctx.enum_ctor_arg_kinds.get(name) {
        Some(kinds) => kinds
        None => []
      }
      for i, arg in args {
        let raw_arg_kind = if i < arg_kinds.length() {
          arg_kinds[i]
        } else {
          ValueKind::I64
        }
        let arg_kind = match raw_arg_kind {
          ValueKind::BoxedF32 | ValueKind::BoxedF64 | ValueKind::ExternRef =>
            raw_arg_kind
          _ => ValueKind::I64
        }
        collect_pat_binding_kinds_codegen(ctx, arg, arg_kind, out)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pat_binding_kinds_codegen(ctx, item, ValueKind::I64, out)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pat_binding_kinds_codegen(ctx, field.pat, ValueKind::I64, out)
      }
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = name
      let _ = span
      for field in fields {
        collect_pat_binding_kinds_codegen(ctx, field.pat, ValueKind::I64, out)
      }
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      if pats.length() > 0 {
        collect_pat_binding_kinds_codegen(ctx, pats[0], scrut_kind, out)
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
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
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
            let key = span_key_named(Some(name), span, params)
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
            let key = span_key_named(Some(name), span, params)
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
      let key = span_key_unique(span, params)
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
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
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
            let key = span_key_named(Some(name), span, params)
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
            let key = span_key_named(Some(name), span, params)
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
fn scoped_mut_captured_for_block(
  parent_mcv : Map[String, Bool],
  stmts : Array[@core.Stmt],
  fn_closure_captures : Map[String, Array[String]],
) -> Map[String, Bool] {
  let scoped = parent_mcv.copy()
  for stmt in stmts {
    match stmt {
      @core.Stmt::LetMut(name~, ..)
      | @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..) => scoped.remove(name)
      @core.Stmt::LetPat(pat~, ..) | @core.Stmt::LetPatElse(pat~, ..) => {
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for b in bindings {
          scoped.remove(b)
        }
      }
      _ => ()
    }
  }
  let local_mcv = compute_mut_captured_for_block(stmts, fn_closure_captures)
  for name, _ in local_mcv {
    scoped[name] = true
  }
  scoped
}

///|
fn collect_fn_span_keys_stmt(stmt : @core.Stmt, out : Array[String]) -> Unit {
  match stmt {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(params~, span~, ..), ..)
    | @core.Stmt::ExportLet(name~, expr=@core.Expr::Fn(params~, span~, ..), ..) =>
      out.push(span_key_named(Some(name), span, params))
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
    @core.Expr::Fn(params~, span~, ..) =>
      out.push(span_key_unique(span, params))
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
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
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
      @core.Stmt::Let(name~, expr=@core.Expr::Fn(params~, body~, span~, ..), ..)
      | @core.Stmt::ExportLet(
        name~,
        expr=@core.Expr::Fn(params~, body~, span~, ..),
        ..
      ) =>
        precompute_ref_cell_for_fn(
          ctx,
          span,
          params,
          body,
          scope_mcv,
          Some(name),
        )
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
        let else_mcv = scoped_mut_captured_for_block(
          scope_mcv,
          else_body.stmts,
          ctx.fn_closure_captures,
        )
        precompute_ref_cell_captures_block(ctx, else_body.stmts, else_mcv)
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
    @core.Expr::Fn(params~, body~, span~, ..) =>
      precompute_ref_cell_for_fn(ctx, span, params, body, scope_mcv, None)
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
      let then_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        then_body.stmts,
        ctx.fn_closure_captures,
      )
      let else_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        else_body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, then_body.stmts, then_mcv)
      precompute_ref_cell_captures_block(ctx, else_body.stmts, else_mcv)
    }
    @core.Expr::Block(body~, ..) => {
      let body_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
    }
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
      let body_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
      for arm in arms {
        precompute_ref_cell_captures_expr(ctx, arm.expr, scope_mcv)
        match arm.cond {
          Some(c) => precompute_ref_cell_captures_expr(ctx, c, scope_mcv)
          None => ()
        }
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      precompute_ref_cell_captures_expr(ctx, cond, scope_mcv)
      let body_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        precompute_ref_cell_captures_expr(ctx, p.init, scope_mcv)
      }
      let body_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        body.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, body.stmts, body_mcv)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      let body_mcv = scoped_mut_captured_for_block(
        scope_mcv,
        desugared.stmts,
        ctx.fn_closure_captures,
      )
      precompute_ref_cell_captures_block(ctx, desugared.stmts, body_mcv)
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
  params : Array[@core.FuncParam],
  body : @core.Module,
  scope_mcv : Map[String, Bool],
  fn_name : String?,
) -> Unit {
  let key = span_key_named(fn_name, span, params)
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
