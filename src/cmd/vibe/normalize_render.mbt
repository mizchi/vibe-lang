///|
fn normalize_collect_normalize_entry_names(
  ast : @vibe_core.Module,
  extra_entry_names : Array[String],
) -> Array[String] {
  let names : Map[String, Bool] = {}
  for name in normalize_collect_export_names(ast) {
    names[name] = true
  }
  for name in extra_entry_names {
    if name.trim().to_string().length() > 0 {
      names[name] = true
    }
  }
  let out : Array[String] = []
  for name, _ in names {
    out.push(name)
  }
  out.sort()
  out
}

///|
fn normalize_select_stmts(
  ast : @vibe_core.Module,
  extra_entry_names : Array[String],
) -> Array[@vibe_core.Stmt] {
  let entry_names = normalize_collect_normalize_entry_names(
    ast, extra_entry_names,
  )
  if entry_names.length() == 0 {
    return ast.stmts
  }
  let dced = @runtime.dce_module_with_entry_names(ast, entry_names)
  dced.stmts
}

///|
fn normalize_collect_export_names(ast : @vibe_core.Module) -> Array[String] {
  let entries : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, ..)
      | @vibe_core.Stmt::ExportEnumDef(name~, ..)
      | @vibe_core.Stmt::ExportTypeAlias(name~, ..)
      | @vibe_core.Stmt::ExportStructDef(name~, ..) => entries[name] = true
      @vibe_core.Stmt::TraitDef(name~, exported~, ..) =>
        if exported {
          entries[name] = true
        }
      @vibe_core.Stmt::Export(names~, ..)
      | @vibe_core.Stmt::ReExport(names~, ..) =>
        for name in names {
          entries[name] = true
        }
      _ => ()
    }
  }
  let out : Array[String] = []
  for name, _ in entries {
    out.push(name)
  }
  out.sort()
  out
}

///|
fn normalize_render_name_list(names : Array[String]) -> String {
  let out = StringBuilder::new()
  for i, name in names {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(name)
  }
  out.to_string()
}

///|
fn normalize_has_exact_export_stmt(
  stmts : Array[@vibe_core.Stmt],
  names : Array[String],
) -> Bool {
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::Export(names=export_names, ..) =>
        if export_names.length() != names.length() {
          ()
        } else {
          let mut all_match = true
          for i, name in names {
            if export_names[i] != name {
              all_match = false
              break
            }
          }
          if all_match {
            return true
          }
        }
      _ => ()
    }
  }
  false
}

///|
fn normalize_all_names_already_exported(
  stmts : Array[@vibe_core.Stmt],
  entry_names : Array[String],
) -> Bool {
  let exported : Map[String, Bool] = {}
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, ..)
      | @vibe_core.Stmt::ExportEnumDef(name~, ..)
      | @vibe_core.Stmt::ExportStructDef(name~, ..)
      | @vibe_core.Stmt::ExportTypeAlias(name~, ..) => exported[name] = true
      @vibe_core.Stmt::TraitDef(name~, exported=is_exported, ..) =>
        if is_exported {
          exported[name] = true
        }
      _ => ()
    }
  }
  for name in entry_names {
    if not(exported.contains(name)) {
      return false
    }
  }
  true
}

///|
fn normalize_append_entry_export_stmt(
  stmts : Array[@vibe_core.Stmt],
  entry_names : Array[String],
) -> Array[@vibe_core.Stmt] {
  if entry_names.length() == 0 ||
    normalize_has_exact_export_stmt(stmts, entry_names) {
    return stmts
  }
  if normalize_all_names_already_exported(stmts, entry_names) {
    return stmts
  }
  let out : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    out.push(stmt)
  }
  out.push(
    @vibe_core.Stmt::Export(names=entry_names, span=@vibe_core.Span::new(0, 0)),
  )
  out
}

///|
fn normalize_render_module_ref(source : @vibe_core.ModuleRef) -> String {
  match source {
    @vibe_core.ModuleRef::Path(path~) => path
    @vibe_core.ModuleRef::Hash(hash~) => "#" + hash
    @vibe_core.ModuleRef::Version(name~) => "version@" + name
    @vibe_core.ModuleRef::Symbol(name~) => "symbol@" + name
  }
}

///|
fn normalize_render_stmt_fallback(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Export(names~, ..) =>
      Some("export { " + normalize_render_name_list(names) + " }")
    @vibe_core.Stmt::ReExport(names~, source~, ..) =>
      Some(
        "export use " +
        normalize_render_module_ref(source) +
        " { " +
        normalize_render_name_list(names) +
        " }",
      )
    _ => None
  }
}

///|
fn normalize_render_stmt(
  source : String,
  stmt : @vibe_core.Stmt,
  rewritten_exprs : Map[String, @vibe_core.Expr],
  inferred_annotations : Map[String, String],
  export_decl_annotations : Map[String, String],
  env : @checker.TypeEnv,
) -> String? {
  let key = normalize_stmt_key(stmt)
  let rewritten_expr = rewritten_exprs.get(key)
  let annotation = inferred_annotations.get(key)
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, span~) => {
      let should_preserve_raw = rewritten_expr is None &&
        annotation is None &&
        not(normalize_let_stmt_prefers_rendered_expr(expr, env.get(name)))
      if should_preserve_raw {
        let snippet = normalize_strip_trailing_comments(
          normalize_source_slice_by_span(source, span.start, span.end)
          .trim()
          .to_string(),
        )
        if normalize_render_stmt_accept_raw_snippet(snippet) {
          return Some(snippet)
        }
      }
      normalize_render_let_stmt(
        source, false, rec, name, expr, rewritten_expr, annotation, env,
      )
    }
    @vibe_core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      if export_decl_annotations.contains(key) {
        return normalize_render_decl_assign_stmt(
          source, name, expr, rewritten_expr,
        )
      }
      // Unwrap local type assert wrapper from declare+assign to get inner expr
      let render_expr = match normalize_unwrap_local_type_assert(expr) {
        Some((_, inner)) => inner
        None => expr
      }
      let should_preserve_raw = rewritten_expr is None &&
        annotation is None &&
        not(
          normalize_let_stmt_prefers_rendered_expr(render_expr, env.get(name)),
        )
      if should_preserve_raw {
        let snippet = normalize_strip_trailing_comments(
          normalize_source_slice_by_span(source, span.start, span.end)
          .trim()
          .to_string(),
        )
        if snippet.has_prefix("export ") &&
          normalize_render_stmt_accept_raw_snippet(snippet) {
          return Some(snippet)
        }
      }
      normalize_render_let_stmt(
        source, true, rec, name, render_expr, rewritten_expr, annotation, env,
      )
    }
    _ => normalize_render_stmt_fallback(stmt)
  }
}

///|
fn normalize_render_stmt_accept_raw_snippet(snippet : String) -> Bool {
  if snippet.length() == 0 {
    return false
  }
  let parsed = @parser.parse_ast(snippet) catch { _ => return false }
  parsed.stmts.length() == 1
}

///|
fn normalize_let_stmt_prefers_rendered_expr(
  expr : @vibe_core.Expr,
  inferred_ty : @vibe_core.Type?,
) -> Bool {
  match expr {
    @vibe_core.Expr::Fn(type_params~, type_bounds~, ret~, ..) =>
      if type_params.length() > 0 || type_bounds.length() > 0 || ret is Some(_) {
        false
      } else {
        match inferred_ty {
          Some(@vibe_core.Type::Func(..)) => true
          _ => false
        }
      }
    _ => false
  }
}

///|
fn normalize_render_fn_param_name(param : @vibe_core.FuncParam) -> String {
  match param.label {
    @vibe_core.ParamLabel::Positional => param.name
    @vibe_core.ParamLabel::Required => param.name + "~"
    @vibe_core.ParamLabel::Optional => param.name + "?"
    @vibe_core.ParamLabel::Variadic => "..." + param.name
  }
}

///|
fn normalize_render_fn_param(param : @vibe_core.FuncParam) -> String? {
  let ty_text = normalize_render_type_annotation(param.ty)
  if ty_text.length() == 0 {
    return None
  }
  let out = StringBuilder::new()
  out.write_string(normalize_render_fn_param_name(param))
  out.write_string(": ")
  out.write_string(ty_text)
  if param.bounds.length() > 0 {
    out.write_string(": ")
    for i, bound in param.bounds {
      if i > 0 {
        out.write_string(" + ")
      }
      out.write_string(bound)
    }
  }
  Some(out.to_string())
}

///|
fn normalize_render_fn_effects(
  effects : Array[@vibe_core.EffectAtom],
) -> String {
  if effects.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  out.write_string(" with {")
  for i, effect in effects {
    if i > 0 {
      out.write_string(", ")
    }
    match effect {
      @vibe_core.EffectAtom::Const(name) => out.write_string(name)
      @vibe_core.EffectAtom::Var(name) => out.write_string(name)
    }
  }
  out.write_char('}')
  out.to_string()
}

///|
fn normalize_find_fn_body_start(snippet : String) -> Int? {
  let mut depth_paren = 0
  let mut depth_bracket = 0
  let mut in_string = false
  let mut escaped = false
  for i, c in snippet {
    if in_string {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        in_string = false
      }
      continue
    }
    match c {
      '"' => in_string = true
      '(' => depth_paren += 1
      ')' => if depth_paren > 0 { depth_paren -= 1 }
      '[' => depth_bracket += 1
      ']' => if depth_bracket > 0 { depth_bracket -= 1 }
      '{' => if depth_paren == 0 && depth_bracket == 0 { return Some(i) }
      _ => ()
    }
  }
  None
}

///|
fn normalize_render_fn_expr_with_inferred_type(
  source : String,
  expr : @vibe_core.Expr,
  inferred_ty : @vibe_core.Type?,
) -> String? {
  let (type_params, type_bounds, params, ret, effects, span) = match expr {
    @vibe_core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body=_,
      span~
    ) => (type_params, type_bounds, params, ret, effects, span)
    _ => return None
  }
  if type_params.length() > 0 || type_bounds.length() > 0 {
    return None
  }
  let inferred_func = match inferred_ty {
    Some(
      @vibe_core.Type::Func(
        params=func_params,
        ret=func_ret,
        effects=func_effects
      )
    ) => Some((func_params, func_ret, func_effects))
    _ => None
  }
  let (resolved_params, resolved_ret, resolved_effects) = match inferred_func {
    Some((func_params, func_ret, func_effects)) =>
      if func_params.length() != params.length() {
        return None
      } else {
        let next_params : Array[@vibe_core.FuncParam] = []
        for i, param in params {
          let inferred_param = func_params[i]
          if inferred_param.label != param.label {
            return None
          }
          let next_ty = if param.ty == @vibe_core.Type::Unit {
            inferred_param.ty
          } else {
            param.ty
          }
          next_params.push(@vibe_core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: next_ty,
            bounds: param.bounds,
          })
        }
        let next_ret = match ret {
          Some(r) => r
          None => func_ret
        }
        let next_effects = if effects.length() > 0 {
          effects
        } else {
          func_effects
        }
        (next_params, Some(next_ret), next_effects)
      }
    None => (params, ret, effects)
  }
  let snippet = normalize_source_slice_by_span(source, span.start, span.end)
    .trim()
    .to_string()
  if snippet.length() == 0 {
    return None
  }
  let body_start = match normalize_find_fn_body_start(snippet) {
    Some(v) => v
    None => return None
  }
  let body_text = snippet.unsafe_substring(
    start=body_start,
    end=snippet.length(),
  )
  let out = StringBuilder::new()
  out.write_char('(')
  for i, param in resolved_params {
    if i > 0 {
      out.write_string(", ")
    }
    let rendered = match normalize_render_fn_param(param) {
      Some(v) => v
      None => return None
    }
    out.write_string(rendered)
  }
  out.write_char(')')
  match resolved_ret {
    Some(ret_ty) => {
      let ret_text = normalize_render_type_annotation(ret_ty)
      if ret_text.length() > 0 {
        out.write_string(" -> ")
        out.write_string(ret_text)
      }
    }
    None => ()
  }
  out.write_string(normalize_render_fn_effects(resolved_effects))
  out.write_char(' ')
  out.write_string(body_text)
  Some(out.to_string())
}

///|
fn normalize_render_stmt_expr_text(
  source : String,
  original_expr : @vibe_core.Expr,
  rewritten_expr : @vibe_core.Expr?,
) -> String? {
  let expr_text = match rewritten_expr {
    Some(expr) =>
      match normalize_render_expr_for_stmt(source, expr) {
        Some(v) => v
        None => return None
      }
    None =>
      match normalize_render_expr_for_stmt(source, original_expr) {
        Some(v) => v
        None =>
          normalize_source_slice_by_span(
            source,
            original_expr.span().start,
            original_expr.span().end,
          )
          .trim()
          .to_string()
      }
  }
  if expr_text.length() == 0 {
    None
  } else {
    Some(expr_text)
  }
}

///|
fn normalize_render_let_stmt(
  source : String,
  exported : Bool,
  rec_flag : Bool,
  name : String,
  original_expr : @vibe_core.Expr,
  rewritten_expr : @vibe_core.Expr?,
  annotation : String?,
  env : @checker.TypeEnv,
) -> String? {
  let target_expr = match rewritten_expr {
    Some(expr) => expr
    None => original_expr
  }
  let expr_text = match
    normalize_render_fn_expr_with_inferred_type(
      source,
      target_expr,
      env.get(name),
    ) {
    Some(v) => v
    None =>
      match
        normalize_render_stmt_expr_text(source, original_expr, rewritten_expr) {
        Some(v) => v
        None => return None
      }
  }
  let out = StringBuilder::new()
  if exported {
    out.write_string("export ")
  }
  out.write_string("let ")
  if rec_flag {
    out.write_string("rec ")
  }
  out.write_string(name)
  match annotation {
    Some(ty_text) => {
      out.write_string(": ")
      out.write_string(ty_text)
    }
    None => ()
  }
  out.write_string(" = ")
  out.write_string(expr_text)
  Some(out.to_string())
}

///|
fn normalize_render_decl_assign_stmt(
  source : String,
  name : String,
  original_expr : @vibe_core.Expr,
  rewritten_expr : @vibe_core.Expr?,
) -> String? {
  let (declared_ty, source_expr) = match
    normalize_unwrap_local_type_assert(original_expr) {
    Some((ann_ty, inner_expr)) => (Some(ann_ty), inner_expr)
    None => (None, original_expr)
  }
  if rewritten_expr is None {
    match
      normalize_render_decl_assign_fn_without_param_annotations(
        source, name, declared_ty, source_expr,
      ) {
      Some(rendered) => return Some(name + " = " + rendered)
      None => ()
    }
  }
  let expr_text = match
    normalize_render_stmt_expr_text(source, source_expr, rewritten_expr) {
    Some(v) => v
    None => return None
  }
  Some(name + " = " + expr_text)
}

///|
fn normalize_render_decl_assign_fn_without_param_annotations(
  source : String,
  name : String,
  declared_ty : @vibe_core.Type?,
  expr : @vibe_core.Expr,
) -> String? {
  let decl_ty = match declared_ty {
    Some(v) => v
    None => return None
  }
  let decl_ty_text = match normalize_render_decl_annotation_type(decl_ty) {
    Some(v) => v
    None => return None
  }
  match expr {
    @vibe_core.Expr::Fn(type_params~, params~, ..) => {
      if type_params.length() > 0 {
        return None
      }
      for param in params {
        if param.bounds.length() > 0 {
          return None
        }
      }
      let span = expr.span()
      let snippet = normalize_source_slice_by_span(source, span.start, span.end)
        .trim()
        .to_string()
      if snippet.length() == 0 {
        return None
      }
      let stripped = match normalize_strip_fn_param_annotations(snippet) {
        Some(v) => v
        None => return None
      }
      if stripped == snippet {
        return None
      }
      let probe = "declare export let " +
        name +
        ": " +
        decl_ty_text +
        "\n" +
        name +
        " = " +
        stripped
      let probe_ast = @parser.parse_ast(probe) catch { _ => return None }
      let _ = @checker.type_check(probe_ast) catch { _ => return None }
      Some(stripped)
    }
    _ => None
  }
}

///|
fn normalize_strip_fn_param_annotations(snippet : String) -> String? {
  let mut open_index = -1
  for i, c in snippet {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      continue
    }
    if c != '(' {
      return None
    }
    open_index = i
    break
  }
  if open_index < 0 {
    return None
  }
  let close_index = match normalize_find_matching_paren(snippet, open_index) {
    Some(v) => v
    None => return None
  }
  let inner = normalize_source_slice_by_span(
    snippet,
    open_index + 1,
    close_index,
  )
  let stripped_inner = match normalize_strip_param_annotation_list(inner) {
    Some(v) => v
    None => return None
  }
  let prefix = normalize_source_slice_by_span(snippet, 0, open_index)
  let suffix = normalize_source_slice_by_span(
    snippet,
    close_index + 1,
    snippet.length(),
  )
  Some(prefix + "(" + stripped_inner + ")" + suffix)
}

///|
fn normalize_find_matching_paren(source : String, open_index : Int) -> Int? {
  let mut depth = 0
  for i, c in source {
    if i < open_index {
      continue
    }
    if c == '(' {
      depth += 1
      continue
    }
    if c == ')' {
      depth -= 1
      if depth == 0 {
        return Some(i)
      }
    }
  }
  None
}

///|
fn normalize_strip_param_annotation_list(params_text : String) -> String? {
  if params_text.trim().to_string().length() == 0 {
    return Some("")
  }
  let parts : Array[String] = []
  let mut start = 0
  let mut paren_depth = 0
  let mut bracket_depth = 0
  let mut brace_depth = 0
  for i, c in params_text {
    if c == '(' {
      paren_depth += 1
      continue
    }
    if c == ')' {
      paren_depth -= 1
      continue
    }
    if c == '[' {
      bracket_depth += 1
      continue
    }
    if c == ']' {
      bracket_depth -= 1
      continue
    }
    if c == '{' {
      brace_depth += 1
      continue
    }
    if c == '}' {
      brace_depth -= 1
      continue
    }
    if c == ',' && paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 {
      let part = normalize_source_slice_by_span(params_text, start, i)
      match normalize_strip_single_param_annotation(part) {
        Some(v) => parts.push(v)
        None => return None
      }
      start = i + 1
    }
  }
  let tail = normalize_source_slice_by_span(
    params_text,
    start,
    params_text.length(),
  )
  match normalize_strip_single_param_annotation(tail) {
    Some(v) => parts.push(v)
    None => return None
  }
  Some(parts.join(", "))
}

///|
fn normalize_strip_single_param_annotation(param_text : String) -> String? {
  let trimmed = param_text.trim().to_string()
  if trimmed.length() == 0 {
    return Some(trimmed)
  }
  let mut paren_depth = 0
  let mut bracket_depth = 0
  let mut brace_depth = 0
  for i, c in trimmed {
    if c == '(' {
      paren_depth += 1
      continue
    }
    if c == ')' {
      paren_depth -= 1
      continue
    }
    if c == '[' {
      bracket_depth += 1
      continue
    }
    if c == ']' {
      bracket_depth -= 1
      continue
    }
    if c == '{' {
      brace_depth += 1
      continue
    }
    if c == '}' {
      brace_depth -= 1
      continue
    }
    if c == ':' && paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 {
      let name_text = normalize_source_slice_by_span(trimmed, 0, i)
        .trim()
        .to_string()
      if name_text.length() == 0 {
        return None
      }
      return Some(name_text)
    }
  }
  Some(trimmed)
}

///|
fn normalize_render_expr_for_stmt(
  source : String,
  expr : @vibe_core.Expr,
) -> String? {
  match normalize_render_expr(expr) {
    Some(v) => Some(v)
    None => {
      let span = expr.span()
      let snippet = normalize_source_slice_by_span(source, span.start, span.end)
        .trim()
        .to_string()
      if snippet.length() == 0 {
        None
      } else {
        Some(snippet)
      }
    }
  }
}

///|
fn normalize_render_pipeline(expr : @vibe_core.Expr) -> String? {
  // Build chain of (name, extra_args) from outer to inner
  let chain : Array[(String, Array[@vibe_core.CallArg])] = []
  let mut current : @vibe_core.Expr = expr
  while true {
    match current {
      @vibe_core.Expr::Call(name~, type_args~, args~, ..) => {
        if type_args.length() > 0 || args.length() == 0 {
          break
        }
        if args[0].label is Some(_) {
          break
        }
        let extra : Array[@vibe_core.CallArg] = []
        for i = 1; i < args.length(); i = i + 1 {
          extra.push(args[i])
        }
        chain.push((name, extra))
        current = args[0].expr
      }
      _ => break
    }
  }
  if chain.length() < 2 {
    return None
  }
  let out = StringBuilder::new()
  // Render base expression (innermost)
  match normalize_render_expr(current) {
    Some(rendered) => out.write_string(rendered)
    None => return None
  }
  // Render pipeline stages inner→outer (reverse iteration)
  for i = chain.length() - 1; i >= 0; i = i - 1 {
    let step = chain[i]
    let name = step.0
    let extra_args = step.1
    out.write_string(" |> ")
    out.write_string(name)
    if extra_args.length() > 0 {
      out.write_char('(')
      for j = 0; j < extra_args.length(); j = j + 1 {
        let arg = extra_args[j]
        if arg.label is Some(_) {
          return None
        }
        match normalize_render_expr(arg.expr) {
          Some(rendered) => {
            if j > 0 {
              out.write_string(", ")
            }
            out.write_string(rendered)
          }
          None => return None
        }
      }
      out.write_char(')')
    }
  }
  Some(out.to_string())
}

///|
fn normalize_render_expr(expr : @vibe_core.Expr) -> String? {
  match expr {
    @vibe_core.Expr::Int(value~, ..) => Some(value.to_string())
    @vibe_core.Expr::Float(value~, ..) => Some(value.to_string() + "f")
    @vibe_core.Expr::Double(value~, ..) => {
      let s = value.to_string()
      // Ensure double literal contains '.' so it's not parsed as an integer
      if s.contains(".") ||
        s.contains("e") ||
        s.contains("E") ||
        s.contains("inf") ||
        s.contains("nan") {
        Some(s)
      } else {
        Some(s + ".0")
      }
    }
    @vibe_core.Expr::Bool(value~, ..) =>
      Some(if value { "true" } else { "false" })
    @vibe_core.Expr::String(value~, ..) => Some(normalize_quote_string(value))
    @vibe_core.Expr::Ident(name~, ..) => Some(name)
    @vibe_core.Expr::Call(name~, type_args~, args~, ..) =>
      match normalize_render_pipeline(expr) {
        Some(piped) => Some(piped)
        None => {
          if type_args.length() > 0 {
            return None
          }
          let out = StringBuilder::new()
          out.write_string(name)
          out.write_char('(')
          for i, arg in args {
            if arg.label is Some(_) {
              return None
            }
            match normalize_render_expr(arg.expr) {
              Some(rendered) => {
                if i > 0 {
                  out.write_string(", ")
                }
                out.write_string(rendered)
              }
              None => return None
            }
          }
          out.write_char(')')
          Some(out.to_string())
        }
      }
    @vibe_core.Expr::Tuple(items~, ..) => {
      let out = StringBuilder::new()
      out.write_char('(')
      for i, item in items {
        match normalize_render_expr(item) {
          Some(rendered) => {
            if i > 0 {
              out.write_string(", ")
            }
            out.write_string(rendered)
          }
          None => return None
        }
      }
      out.write_char(')')
      Some(out.to_string())
    }
    @vibe_core.Expr::Array(items~, ..) => {
      let out = StringBuilder::new()
      out.write_char('[')
      for i, item in items {
        match normalize_render_expr(item) {
          Some(rendered) => {
            if i > 0 {
              out.write_string(", ")
            }
            out.write_string(rendered)
          }
          None => return None
        }
      }
      out.write_char(']')
      Some(out.to_string())
    }
    _ => None
  }
}

///|
fn normalize_quote_string(text : String) -> String {
  let out = StringBuilder::new()
  out.write_char('"')
  for c in text {
    normalize_write_escaped_char(out, c)
  }
  out.write_char('"')
  out.to_string()
}

///|
fn normalize_write_escaped_char(buf : StringBuilder, c : Char) -> Unit {
  match c {
    '\\' => buf.write_string("\\\\")
    '"' => buf.write_string("\\\"")
    '\n' => buf.write_string("\\n")
    '\r' => buf.write_string("\\r")
    '\t' => buf.write_string("\\t")
    _ => {
      let code = c.to_int()
      if code >= 0 && code < 0x20 {
        buf.write_string("\\u{")
        buf.write_string(code.to_string())
        buf.write_char('}')
      } else {
        buf.write_char(c)
      }
    }
  }
}

///|
fn normalize_stmt_group_section_name(group : NormalizeStmtGroup) -> String {
  match group {
    NormalizeStmtGroup::Use => "Imports"
    NormalizeStmtGroup::TypeDecl | NormalizeStmtGroup::TraitDecl => "Types"
    NormalizeStmtGroup::FnDef => "Functions"
    NormalizeStmtGroup::Other => "Misc"
  }
}

///|
fn normalize_strip_trailing_comments(text : String) -> String {
  let lines : Array[String] = []
  for part in text.split("\n") {
    lines.push(part.to_string())
  }
  let mut end = lines.length()
  while end > 0 {
    let line = lines[end - 1].trim().to_string()
    if line.length() == 0 || line.has_prefix("//") {
      end -= 1
    } else {
      break
    }
  }
  if end <= 0 {
    return ""
  }
  let buf = StringBuilder::new()
  for i = 0; i < end; i = i + 1 {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(lines[i])
  }
  buf.to_string()
}

///|
fn normalize_trim_rendered_block(text : String) -> String {
  let mut end = text.length()
  while end > 0 {
    let c = text[end - 1].to_int().unsafe_to_char()
    if c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if end <= 0 {
    ""
  } else {
    text.unsafe_substring(start=0, end~)
  }
}

///|
fn normalize_type_has_effects(ty : @vibe_core.Type) -> Bool {
  match ty {
    @vibe_core.Type::Func(effects~, ..) => effects.length() > 0
    _ => false
  }
}

///|
fn normalize_render_signature_comment(
  name : String,
  env : @checker.TypeEnv,
) -> String? {
  match env.get(name) {
    Some(ty) => {
      if not(normalize_type_has_effects(ty)) {
        return None
      }
      let ty_text = normalize_render_type_annotation(ty)
      if ty_text.length() == 0 {
        None
      } else {
        Some("// " + name + ": " + ty_text)
      }
    }
    None => None
  }
}

///|
fn normalize_inject_signature_comments(
  rendered : String,
  env : @checker.TypeEnv,
) -> String {
  let lines : Array[String] = []
  for part in rendered.split("\n") {
    lines.push(part.to_string())
  }
  let out = StringBuilder::new()
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    let trimmed = line.trim().to_string()
    let name : String? = if trimmed.has_prefix("export let ") {
      normalize_extract_let_name(trimmed, 11)
    } else if trimmed.has_prefix("let rec ") {
      normalize_extract_let_name(trimmed, 8)
    } else if trimmed.has_prefix("let ") {
      normalize_extract_let_name(trimmed, 4)
    } else {
      None
    }
    match name {
      Some(n) => {
        let comment = normalize_render_signature_comment(n, env)
        match comment {
          Some(c) => {
            let prev_is_sig = {
              let mut k = i - 1
              let mut found = false
              while k >= 0 {
                let prev = lines[k].trim().to_string()
                if prev.length() == 0 {
                  k -= 1
                  continue
                }
                if prev.has_prefix("// " + n + ": ") {
                  found = true
                }
                break
              }
              found
            }
            if not(prev_is_sig) {
              out.write_string(c)
              out.write_char('\n')
            }
          }
          None => ()
        }
      }
      None => ()
    }
    out.write_string(line)
    if i < lines.length() - 1 {
      out.write_char('\n')
    }
    i += 1
  }
  out.to_string()
}

///|
fn normalize_extract_let_name(line : String, start : Int) -> String? {
  if start >= line.length() {
    return None
  }
  let rest = line.unsafe_substring(start~, end=line.length())
  let trimmed = rest.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  // Skip "rec " if present
  let name_start = if trimmed.has_prefix("rec ") { 4 } else { 0 }
  let buf = StringBuilder::new()
  let mut j = name_start
  while j < trimmed.length() {
    let c = trimmed[j].to_int().unsafe_to_char()
    if c == ' ' || c == ':' || c == '=' || c == '(' || c == '\t' {
      break
    }
    buf.write_char(c)
    j += 1
  }
  let name = buf.to_string()
  if name.length() > 0 {
    Some(name)
  } else {
    None
  }
}

///|
fn normalize_render_source(
  source : String,
  stmts : Array[@vibe_core.Stmt],
  rewritten_exprs : Map[String, @vibe_core.Expr],
  inferred_annotations : Map[String, String],
  env : @checker.TypeEnv,
) -> Result[String, String] {
  let export_decl_annotations = normalize_collect_export_decl_annotations(
    @vibe_core.Module::{ stmts, },
    inferred_annotations,
    env,
  )
  let rendered : Array[NormalizeRenderedBlock] = []
  let declare_lines : Array[String] = []
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, ..) => {
        let key = normalize_stmt_key(stmt)
        match export_decl_annotations.get(key) {
          Some(ty_text) =>
            declare_lines.push("declare export let " + name + ": " + ty_text)
          None => ()
        }
      }
      _ => ()
    }
  }
  let push_rendered = fn(group : NormalizeStmtGroup, raw_text : String) {
    let text = normalize_trim_rendered_block(raw_text)
    if text.trim().to_string().length() == 0 {
      return
    }
    rendered.push({ group, text })
  }
  let mut inserted_declare_lines = false
  for stmt in stmts {
    // Skip redundant Export stmts when all names are already individually exported
    match stmt {
      @vibe_core.Stmt::Export(names~, ..) =>
        if normalize_all_names_already_exported(stmts, names) {
          continue
        }
      _ => ()
    }
    let group = normalize_stmt_group(stmt)
    if not(inserted_declare_lines) && declare_lines.length() > 0 {
      if group != NormalizeStmtGroup::Use &&
        group != NormalizeStmtGroup::TypeDecl &&
        group != NormalizeStmtGroup::TraitDecl {
        for line in declare_lines {
          push_rendered(NormalizeStmtGroup::FnDef, line)
        }
        inserted_declare_lines = true
      }
    }
    match
      normalize_render_stmt(
        source, stmt, rewritten_exprs, inferred_annotations, export_decl_annotations,
        env,
      ) {
      Some(rendered_line) => push_rendered(group, rendered_line)
      None => {
        let span = stmt.span()
        let snippet = normalize_strip_trailing_comments(
          normalize_source_slice_by_span(source, span.start, span.end),
        )
        push_rendered(group, snippet)
      }
    }
  }
  if not(inserted_declare_lines) {
    for line in declare_lines {
      push_rendered(NormalizeStmtGroup::FnDef, line)
    }
  }
  if rendered.length() == 0 {
    return Err("normalize: no statements kept")
  }
  let blocks : Array[String] = []
  let mut current_section : String? = None
  for item in rendered {
    let section = normalize_stmt_group_section_name(item.group)
    match current_section {
      Some(cur) =>
        if cur != section {
          blocks.push("//# " + section)
          current_section = Some(section)
        }
      None => {
        blocks.push("//# " + section)
        current_section = Some(section)
      }
    }
    blocks.push(item.text)
  }
  if blocks.length() == 0 {
    return Err("normalize: no statements kept")
  }
  let out = StringBuilder::new()
  for i, block in blocks {
    if i > 0 {
      out.write_string("\n\n")
    }
    out.write_string(block)
  }
  out.write_char('\n')
  let result = out.to_string()
  let _ = @parser.parse_ast(result) catch {
    e => return Err("normalize: rendered source parse failed: " + e.to_string())
  }
  Ok(result)
}

///|
fn normalize_clamp_source_offset(source : String, offset : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
fn normalize_source_slice_by_span(
  source : String,
  start : Int,
  end : Int,
) -> String {
  let s = normalize_clamp_source_offset(source, start)
  let e = normalize_clamp_source_offset(source, end)
  let stop = if e < s { s } else { e }
  if stop <= s {
    return ""
  }
  try source[s:stop] catch {
    _ => ""
  } noraise {
    value => value.to_string()
  }
}

///|
fn normalize_stmt_key(stmt : @vibe_core.Stmt) -> String {
  let span = stmt.span()
  span.start.to_string() + ":" + span.end.to_string()
}
