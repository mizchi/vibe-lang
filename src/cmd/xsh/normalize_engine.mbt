///|
struct NormalizeSourceRange {
  start : Int
  end : Int
} derive(Show, Eq)

///|
enum NormalizeStmtGroup {
  Use
  TypeDecl
  TraitDecl
  PureFn
  EffectfulFn
  Other
} derive(Show, Eq)

///|
struct NormalizeEngine {
  rt : @ripple.Runtime
  source_input : @ripple.Input[String, String]
  normalized_query : @ripple.Query[String, Result[String, String]]
}

///|
fn normalize_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("normalize: expected <file...>")
  }
  let mut write = false
  let files : Array[String] = []
  for arg in args {
    match arg {
      "--write" | "-w" => write = true
      _ => files.push(arg)
    }
  }
  if files.length() == 0 {
    abort("normalize: expected <file...>")
  }
  if not(write) && files.length() > 1 {
    abort("normalize: use --write for multiple files")
  }
  for path in files {
    let resolved = @loader.resolve_entry_path(path)
    let src = @os_fs.read_file_to_string(resolved) catch {
      e => abort("normalize: " + e.to_string())
    }
    let normalized = match normalize_source_text(src) {
      Ok(v) => v
      Err(err) => abort(err)
    }
    let output = if write {
      normalize_apply_lock_annotations_for_format(resolved, normalized)
    } else {
      normalized
    }
    if write {
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("normalize: " + e.to_string())
      }
    } else {
      println(output)
    }
  }
}

///|
fn normalize_apply_lock_annotations_for_format(
  path : String,
  source : String,
) -> String {
  let lock_path = @codebase.lock_file_path(path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => abort("normalize: " + err)
  }
  match @codebase.apply_annotations_to_source(path, source, lock.annotations) {
    Ok(v) => v
    Err(err) => abort("normalize: " + err)
  }
}

///|
fn NormalizeEngine::new() -> NormalizeEngine {
  let db = @ripple.Database::new()
  let rt = db.runtime()
  let source_input : @ripple.Input[String, String] = db.input()
  source_input.register(rt)
  let module_ranges_query : @ripple.Query[String, Array[NormalizeSourceRange]] = db.query(fn(
      rt,
      path,
    ) {
      match source_input.get(rt, path) {
        Some(source) => collect_top_level_module_stmt_ranges(source)
        None => []
      }
    },
  )
  module_ranges_query.register(rt)
  let normalized_query : @ripple.Query[String, Result[String, String]] = db.query(fn(
      rt,
      path,
    ) {
      let source = match source_input.get(rt, path) {
        Some(v) => v
        None => ""
      }
      let module_ranges = module_ranges_query.fetch(rt, path)
      if module_ranges.length() == 0 {
        normalize_source_text_flat(source)
      } else {
        normalize_source_text_with_modules(source, module_ranges)
      }
    },
  )
  normalized_query.register(rt)
  { rt, source_input, normalized_query }
}

///|
fn NormalizeEngine::set_source(
  self : NormalizeEngine,
  key : String,
  source : String,
) -> Unit {
  let _ = self.source_input.set(self.rt, key, source)
}

///|
fn NormalizeEngine::normalize(
  self : NormalizeEngine,
  key : String,
) -> Result[String, String] {
  self.normalized_query.fetch(self.rt, key)
}

///|
fn normalize_source_text(source : String) -> Result[String, String] {
  let engine = NormalizeEngine::new()
  engine.set_source("__source__", source)
  engine.normalize("__source__")
}

///|
fn normalize_source_text_with_modules(
  source : String,
  module_ranges : Array[NormalizeSourceRange],
) -> Result[String, String] {
  let out = StringBuilder::new()
  let mut cursor = 0
  for range in module_ranges {
    if range.start < cursor {
      continue
    }
    out.write_string(normalize_source_slice_by_span(source, cursor, range.start))
    let stmt_source = normalize_source_slice_by_span(source, range.start, range.end)
    let normalized_stmt = match normalize_module_stmt_source(stmt_source) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    out.write_string(normalized_stmt)
    if not(normalized_stmt.has_suffix("\n")) {
      out.write_char('\n')
    }
    cursor = range.end
  }
  out.write_string(normalize_source_slice_by_span(source, cursor, source.length()))
  Ok(@parser.format_script(out.to_string()))
}

///|
fn normalize_module_stmt_source(stmt_source : String) -> Result[String, String] {
  let (open_index, close_index) = match
    normalize_find_brace_bounds(stmt_source) {
    Some(v) => v
    None => return Err("normalize: malformed module block")
  }
  let head = normalize_source_slice_by_span(
    stmt_source,
    0,
    open_index,
  ).trim().to_string()
  let body_source = normalize_source_slice_by_span(
    stmt_source,
    open_index + 1,
    close_index,
  )
  let normalized_body = match normalize_source_text_flat(body_source) {
    Ok(v) => v.trim().to_string()
    Err(err) => return Err(err)
  }
  let out = StringBuilder::new()
  out.write_string(head)
  out.write_string(" {")
  out.write_char('\n')
  if normalized_body.length() > 0 {
    out.write_string(normalize_indent_block(normalized_body, 2))
    out.write_char('\n')
  }
  out.write_char('}')
  if normalize_module_stmt_has_trailing_semi(stmt_source, close_index) {
    out.write_char(';')
  }
  Ok(@parser.format_script(out.to_string()))
}

///|
fn normalize_module_stmt_has_trailing_semi(
  stmt_source : String,
  close_index : Int,
) -> Bool {
  let tail = normalize_source_slice_by_span(
    stmt_source,
    close_index + 1,
    stmt_source.length(),
  )
  for c in tail {
    if c == ';' {
      return true
    }
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      continue
    }
    return false
  }
  false
}

///|
fn normalize_find_brace_bounds(source : String) -> (Int, Int)? {
  let mut open_index = -1
  let mut depth = 0
  let mut in_string = false
  let mut in_char = false
  let mut in_line_comment = false
  let mut escaped = false
  let mut saw_slash = false
  for i, c in source {
    if in_line_comment {
      if c == '\n' {
        in_line_comment = false
      }
      continue
    }
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
    if in_char {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '\'' {
        in_char = false
      }
      continue
    }
    if saw_slash {
      if c == '/' {
        in_line_comment = true
        saw_slash = false
        continue
      }
      saw_slash = false
    }
    if c == '/' {
      saw_slash = true
      continue
    }
    if c == '"' {
      in_string = true
      escaped = false
      continue
    }
    if c == '\'' {
      in_char = true
      escaped = false
      continue
    }
    if c == '{' {
      if open_index < 0 {
        open_index = i
      }
      depth += 1
      continue
    }
    if c == '}' && open_index >= 0 {
      depth -= 1
      if depth == 0 {
        return Some((open_index, i))
      }
    }
  }
  None
}

///|
fn normalize_indent_block(source : String, indent_spaces : Int) -> String {
  let out = StringBuilder::new()
  let mut first = true
  for line_view in source.split("\n") {
    if not(first) {
      out.write_char('\n')
    }
    first = false
    let line = line_view.to_string()
    if line.trim().to_string().length() == 0 {
      continue
    }
    for _ in 0..<indent_spaces {
      out.write_char(' ')
    }
    out.write_string(line)
  }
  out.to_string()
}

///|
fn collect_top_level_module_stmt_ranges(
  source : String,
) -> Array[NormalizeSourceRange] {
  let root = @parser.parse_cst(source)
  let out : Array[NormalizeSourceRange] = []
  for child in root.children() {
    match child.as_node() {
      Some(node) =>
        if normalize_is_module_stmt_node(node) {
          let range = node.text_range()
          out.push({ start: range.start().to_int(), end: range.end().to_int() })
        }
      None => ()
    }
  }
  out
}

///|
fn normalize_is_module_stmt_node(node : @cst.SyntaxNode) -> Bool {
  if node.kind() == @parser.module_stmt() {
    return true
  }
  if node.kind() == @parser.export_stmt() {
    for child in node.child_nodes() {
      if normalize_node_contains_kind(child, @parser.module_stmt()) {
        return true
      }
    }
  }
  false
}

///|
fn normalize_node_contains_kind(
  node : @cst.SyntaxNode,
  kind : @cst.SyntaxKind,
) -> Bool {
  if node.kind() == kind {
    return true
  }
  for child in node.child_nodes() {
    if normalize_node_contains_kind(child, kind) {
      return true
    }
  }
  false
}

///|
fn normalize_source_text_flat(source : String) -> Result[String, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("normalize: parse failed: " + e.to_string())
  }
  let selected = normalize_select_stmts(ast)
  let sorted = normalize_sort_stmts(selected)
  if sorted.length() == 0 {
    return Ok("")
  }
  let rendered = match normalize_render_source(source, sorted) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let formatted = @parser.format_script(rendered)
  let reparsed = @parser.parse_ast(formatted) catch {
    e => return Err("normalize: rendered parse failed: " + e.to_string())
  }
  let expected = @xsh_core.Module::{ stmts: sorted }
  if @xsh_core.normalize_module(reparsed) !=
    @xsh_core.normalize_module(expected) {
    return Err("normalize: rendered source changed semantics")
  }
  Ok(formatted)
}

///|
fn normalize_select_stmts(ast : @xsh_core.Module) -> Array[@xsh_core.Stmt] {
  let export_names = normalize_collect_export_names(ast)
  if export_names.length() == 0 {
    return ast.stmts
  }
  let dced = @xsh_lib.dce_module_with_entry_names(ast, export_names)
  dced.stmts
}

///|
fn normalize_collect_export_names(ast : @xsh_core.Module) -> Array[String] {
  let entries : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::ExportLet(name~, ..)
      | @xsh_core.Stmt::ExportEnumDef(name~, ..)
      | @xsh_core.Stmt::ExportTypeAlias(name~, ..)
      | @xsh_core.Stmt::ExportStructDef(name~, ..) => entries[name] = true
      @xsh_core.Stmt::TraitDef(name~, exported~, ..) =>
        if exported {
          entries[name] = true
        }
      @xsh_core.Stmt::Export(names~, ..)
      | @xsh_core.Stmt::ReExport(names~, ..) =>
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
fn normalize_render_module_ref(source : @xsh_core.ModuleRef) -> String {
  match source {
    @xsh_core.ModuleRef::Path(path~) => path
    @xsh_core.ModuleRef::Hash(hash~) => "#" + hash
    @xsh_core.ModuleRef::Version(name~) => "version@" + name
    @xsh_core.ModuleRef::Symbol(name~) => "symbol@" + name
  }
}

///|
fn normalize_render_stmt_fallback(stmt : @xsh_core.Stmt) -> String? {
  match stmt {
    @xsh_core.Stmt::Export(names~, ..) =>
      Some("export { " + normalize_render_name_list(names) + " }")
    @xsh_core.Stmt::ReExport(names~, source~, ..) =>
      Some(
        "export { " +
        normalize_render_name_list(names) +
        " } from " +
        normalize_render_module_ref(source),
      )
    _ => None
  }
}

///|
fn normalize_render_source(
  source : String,
  stmts : Array[@xsh_core.Stmt],
) -> Result[String, String] {
  let out = StringBuilder::new()
  for stmt in stmts {
    match normalize_render_stmt_fallback(stmt) {
      Some(rendered) => {
        out.write_string(rendered)
        if not(rendered.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
      None => {
        let span = stmt.span()
        let snippet = normalize_source_slice_by_span(source, span.start, span.end)
        if snippet.trim().to_string().length() == 0 {
          continue
        }
        out.write_string(snippet)
        if not(snippet.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
    }
  }
  let result = out.to_string()
  if result.trim().to_string().length() == 0 {
    Err("normalize: no statements kept")
  } else {
    let _ = @parser.parse_ast(result) catch {
      e => return Err("normalize: rendered source parse failed: " + e.to_string())
    }
    Ok(result)
  }
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
fn normalize_source_slice_by_span(source : String, start : Int, end : Int) -> String {
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
fn normalize_sort_stmts(stmts : Array[@xsh_core.Stmt]) -> Array[@xsh_core.Stmt] {
  let use_stmts : Array[@xsh_core.Stmt] = []
  let type_stmts : Array[@xsh_core.Stmt] = []
  let trait_stmts : Array[@xsh_core.Stmt] = []
  let pure_fn_stmts : Array[@xsh_core.Stmt] = []
  let effectful_fn_stmts : Array[@xsh_core.Stmt] = []
  let other_stmts : Array[@xsh_core.Stmt] = []
  for stmt in stmts {
    match normalize_stmt_group(stmt) {
      NormalizeStmtGroup::Use => use_stmts.push(stmt)
      NormalizeStmtGroup::TypeDecl => type_stmts.push(stmt)
      NormalizeStmtGroup::TraitDecl => trait_stmts.push(stmt)
      NormalizeStmtGroup::PureFn => pure_fn_stmts.push(stmt)
      NormalizeStmtGroup::EffectfulFn => effectful_fn_stmts.push(stmt)
      NormalizeStmtGroup::Other => other_stmts.push(stmt)
    }
  }
  let pure_fn_sorted = normalize_sort_stmt_defs_topo_alpha(pure_fn_stmts)
  let effectful_fn_sorted = normalize_sort_stmt_defs_topo_alpha(
    effectful_fn_stmts,
  )
  let out : Array[@xsh_core.Stmt] = []
  for stmt in use_stmts {
    out.push(stmt)
  }
  for stmt in type_stmts {
    out.push(stmt)
  }
  for stmt in trait_stmts {
    out.push(stmt)
  }
  for stmt in pure_fn_sorted {
    out.push(stmt)
  }
  for stmt in effectful_fn_sorted {
    out.push(stmt)
  }
  for stmt in other_stmts {
    out.push(stmt)
  }
  out
}

///|
struct NormalizeStmtDef {
  name : String
  stmt : @xsh_core.Stmt
  refs : Map[String, Bool]
}

///|
fn normalize_sort_stmt_defs_topo_alpha(
  stmts : Array[@xsh_core.Stmt],
) -> Array[@xsh_core.Stmt] {
  let defs : Array[NormalizeStmtDef] = []
  for stmt in stmts {
    match normalize_stmt_def_name(stmt) {
      Some(name) =>
        defs.push({ name, stmt, refs: normalize_collect_stmt_refs(stmt) })
      None => ()
    }
  }
  if defs.length() <= 1 {
    return stmts
  }
  let names : Map[String, Bool] = {}
  for def in defs {
    if names.contains(def.name) {
      return stmts
    }
    names[def.name] = true
  }
  let indegree : Map[String, Int] = {}
  let dependents : Map[String, Map[String, Bool]] = {}
  let stmt_by_name : Map[String, @xsh_core.Stmt] = {}
  for def in defs {
    indegree[def.name] = 0
    dependents[def.name] = {}
    stmt_by_name[def.name] = def.stmt
  }
  for def in defs {
    let deps : Map[String, Bool] = {}
    for ref_name, _ in def.refs {
      if ref_name != def.name && names.contains(ref_name) {
        deps[ref_name] = true
      }
    }
    indegree[def.name] = deps.length()
    for dep_name, _ in deps {
      match dependents.get(dep_name) {
        Some(existing) => {
          let next = normalize_clone_bool_map(existing)
          next[def.name] = true
          dependents[dep_name] = next
        }
        None => {
          let next : Map[String, Bool] = {}
          next[def.name] = true
          dependents[dep_name] = next
        }
      }
    }
  }
  let ready : Array[String] = []
  for name, deg in indegree {
    if deg == 0 {
      ready.push(name)
    }
  }
  let ordered_names : Array[String] = []
  while ready.length() > 0 {
    let name = match normalize_pop_smallest_name(ready) {
      Some(v) => v
      None => break
    }
    ordered_names.push(name)
    match dependents.get(name) {
      Some(outgoing) =>
        for dependent_name, _ in outgoing {
          match indegree.get(dependent_name) {
            Some(deg) => {
              let next = deg - 1
              indegree[dependent_name] = next
              if next == 0 {
                ready.push(dependent_name)
              }
            }
            None => ()
          }
        }
      None => ()
    }
  }
  if ordered_names.length() < defs.length() {
    let emitted : Map[String, Bool] = {}
    for name in ordered_names {
      emitted[name] = true
    }
    let unresolved : Array[String] = []
    for def in defs {
      if not(emitted.contains(def.name)) {
        unresolved.push(def.name)
        emitted[def.name] = true
      }
    }
    unresolved.sort()
    for name in unresolved {
      ordered_names.push(name)
    }
  }
  let sorted_defs : Array[@xsh_core.Stmt] = []
  for name in ordered_names {
    match stmt_by_name.get(name) {
      Some(stmt) => sorted_defs.push(stmt)
      None => ()
    }
  }
  if sorted_defs.length() != defs.length() {
    return stmts
  }
  let out : Array[@xsh_core.Stmt] = []
  let mut def_cursor = 0
  for stmt in stmts {
    match normalize_stmt_def_name(stmt) {
      Some(_) =>
        if def_cursor < sorted_defs.length() {
          out.push(sorted_defs[def_cursor])
          def_cursor += 1
        } else {
          out.push(stmt)
        }
      None => out.push(stmt)
    }
  }
  out
}

///|
fn normalize_stmt_def_name(stmt : @xsh_core.Stmt) -> String? {
  match stmt {
    @xsh_core.Stmt::Let(name~, ..)
    | @xsh_core.Stmt::ExportLet(name~, ..)
    | @xsh_core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn normalize_collect_stmt_refs(stmt : @xsh_core.Stmt) -> Map[String, Bool] {
  let refs : Map[String, Bool] = {}
  let bound : Map[String, Bool] = {}
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, expr~, ..)
    | @xsh_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
      if rec {
        bound[name] = true
      }
      normalize_collect_refs_expr(expr, bound, refs)
    }
    @xsh_core.Stmt::LetMut(expr~, ..) =>
      normalize_collect_refs_expr(expr, bound, refs)
    _ => ()
  }
  refs
}

///|
fn normalize_collect_refs_expr(
  expr : @xsh_core.Expr,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  match expr {
    @xsh_core.Expr::Int(..)
    | @xsh_core.Expr::Float(..)
    | @xsh_core.Expr::Double(..)
    | @xsh_core.Expr::Bool(..)
    | @xsh_core.Expr::String(..)
    | @xsh_core.Expr::Placeholder(..)
    | @xsh_core.Expr::Break(..)
    | @xsh_core.Expr::Continue(..) => ()
    @xsh_core.Expr::Ident(name~, ..) =>
      normalize_add_ref_name(name, bound, refs)
    @xsh_core.Expr::Call(name~, args~, ..) => {
      normalize_add_ref_name(name, bound, refs)
      for arg in args {
        normalize_collect_refs_expr(arg.expr, bound, refs)
      }
    }
    @xsh_core.Expr::Tuple(items~, ..) =>
      for item in items {
        normalize_collect_refs_expr(item, bound, refs)
      }
    @xsh_core.Expr::TupleIndex(expr~, ..)
    | @xsh_core.Expr::Await(expr~, ..)
    | @xsh_core.Expr::Yield(expr~, ..) =>
      normalize_collect_refs_expr(expr, bound, refs)
    @xsh_core.Expr::Record(fields~, ..)
    | @xsh_core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        normalize_collect_refs_expr(field.expr, bound, refs)
      }
    @xsh_core.Expr::Array(items~, ..) =>
      for item in items {
        normalize_collect_refs_expr(item, bound, refs)
      }
    @xsh_core.Expr::Map(fields~, ..) =>
      for field in fields {
        normalize_collect_refs_expr(field.expr, bound, refs)
      }
    @xsh_core.Expr::If(cond~, then_body~, else_body~, ..) => {
      normalize_collect_refs_expr(cond, bound, refs)
      normalize_collect_refs_block(then_body, bound, refs)
      normalize_collect_refs_block(else_body, bound, refs)
    }
    @xsh_core.Expr::Block(body~, ..) | @xsh_core.Expr::Do(body~, ..) =>
      normalize_collect_refs_block(body, bound, refs)
    @xsh_core.Expr::Try(try_body~, catch_body~, ..) => {
      normalize_collect_refs_block(try_body, bound, refs)
      normalize_collect_refs_block(catch_body, bound, refs)
    }
    @xsh_core.Expr::Match(scrutinee~, arms~, ..) => {
      normalize_collect_refs_expr(scrutinee, bound, refs)
      for arm in arms {
        let arm_bound = normalize_clone_bool_map(bound)
        normalize_bind_pattern_names(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) => normalize_collect_refs_expr(cond, arm_bound, refs)
          None => ()
        }
        normalize_collect_refs_expr(arm.expr, arm_bound, refs)
      }
    }
    @xsh_core.Expr::Fn(params~, body~, ..) => {
      let fn_bound = normalize_clone_bool_map(bound)
      for param in params {
        fn_bound[param.name] = true
      }
      normalize_collect_refs_block(body, fn_bound, refs)
    }
    @xsh_core.Expr::While(cond~, body~, ..) => {
      normalize_collect_refs_expr(cond, bound, refs)
      normalize_collect_refs_block(body, bound, refs)
    }
    @xsh_core.Expr::Raise(value~, ..) =>
      normalize_collect_refs_expr(value, bound, refs)
  }
}

///|
fn normalize_collect_refs_block(
  body : @xsh_core.Module,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  let scope = normalize_clone_bool_map(bound)
  for stmt in body.stmts {
    match stmt {
      @xsh_core.Stmt::Let(rec~, name~, expr~, ..)
      | @xsh_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        if rec {
          scope[name] = true
        }
        normalize_collect_refs_expr(expr, scope, refs)
        if not(rec) {
          scope[name] = true
        }
      }
      @xsh_core.Stmt::LetMut(name~, expr~, ..) => {
        normalize_collect_refs_expr(expr, scope, refs)
        scope[name] = true
      }
      @xsh_core.Stmt::Assign(name~, expr~, ..) => {
        normalize_add_ref_name(name, scope, refs)
        normalize_collect_refs_expr(expr, scope, refs)
      }
      @xsh_core.Stmt::IndexAssign(target~, index~, value~, ..) => {
        normalize_collect_refs_expr(target, scope, refs)
        normalize_collect_refs_expr(index, scope, refs)
        normalize_collect_refs_expr(value, scope, refs)
      }
      @xsh_core.Stmt::LetPat(pat~, expr~, ..) => {
        normalize_collect_refs_expr(expr, scope, refs)
        normalize_bind_pattern_names(scope, pat)
      }
      @xsh_core.Stmt::Expr(expr~, ..) =>
        normalize_collect_refs_expr(expr, scope, refs)
      @xsh_core.Stmt::Test(body~, ..) | @xsh_core.Stmt::Bench(body~, ..) =>
        normalize_collect_refs_block(body, scope, refs)
      @xsh_core.Stmt::Import(..)
      | @xsh_core.Stmt::EnumDef(..)
      | @xsh_core.Stmt::ExportEnumDef(..)
      | @xsh_core.Stmt::TypeAlias(..)
      | @xsh_core.Stmt::ExportTypeAlias(..)
      | @xsh_core.Stmt::TraitDef(..)
      | @xsh_core.Stmt::TraitImpl(..)
      | @xsh_core.Stmt::Export(..)
      | @xsh_core.Stmt::ReExport(..)
      | @xsh_core.Stmt::StructDef(..)
      | @xsh_core.Stmt::ExportStructDef(..) => ()
    }
  }
}

///|
fn normalize_add_ref_name(
  name : String,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  refs[name] = true
}

///|
fn normalize_bind_pattern_names(
  bound : Map[String, Bool],
  pat : @xsh_core.Pat,
) -> Unit {
  match pat {
    @xsh_core.Pat::Wildcard(..) => ()
    @xsh_core.Pat::Bind(name~, ..) => bound[name] = true
    @xsh_core.Pat::Ctor(args~, ..) =>
      for item in args {
        normalize_bind_pattern_names(bound, item)
      }
    @xsh_core.Pat::Tuple(items~, ..) =>
      for item in items {
        normalize_bind_pattern_names(bound, item)
      }
    @xsh_core.Pat::Or(pats~, ..) =>
      for item in pats {
        normalize_bind_pattern_names(bound, item)
      }
    @xsh_core.Pat::Record(fields~, ..) | @xsh_core.Pat::Struct(fields~, ..) =>
      for field in fields {
        normalize_bind_pattern_names(bound, field.pat)
      }
    @xsh_core.Pat::Int(..)
    | @xsh_core.Pat::Float(..)
    | @xsh_core.Pat::Double(..)
    | @xsh_core.Pat::Bool(..)
    | @xsh_core.Pat::String(..) => ()
  }
}

///|
fn normalize_clone_bool_map(m : Map[String, Bool]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn normalize_pop_smallest_name(names : Array[String]) -> String? {
  if names.length() == 0 {
    return None
  }
  names.sort_by(fn(a, b) { String::compare(b, a) })
  names.pop()
}

///|
fn normalize_stmt_group(stmt : @xsh_core.Stmt) -> NormalizeStmtGroup {
  match stmt {
    @xsh_core.Stmt::Import(..) | @xsh_core.Stmt::ReExport(..) =>
      NormalizeStmtGroup::Use
    @xsh_core.Stmt::TypeAlias(..)
    | @xsh_core.Stmt::ExportTypeAlias(..)
    | @xsh_core.Stmt::EnumDef(..)
    | @xsh_core.Stmt::ExportEnumDef(..)
    | @xsh_core.Stmt::StructDef(..)
    | @xsh_core.Stmt::ExportStructDef(..) => NormalizeStmtGroup::TypeDecl
    @xsh_core.Stmt::TraitDef(..) | @xsh_core.Stmt::TraitImpl(..) =>
      NormalizeStmtGroup::TraitDecl
    @xsh_core.Stmt::Let(expr~, ..) | @xsh_core.Stmt::ExportLet(expr~, ..) =>
      if normalize_expr_is_effectful_fn(expr) {
        NormalizeStmtGroup::EffectfulFn
      } else {
        NormalizeStmtGroup::PureFn
      }
    @xsh_core.Stmt::LetMut(..)
    | @xsh_core.Stmt::Assign(..)
    | @xsh_core.Stmt::IndexAssign(..)
    | @xsh_core.Stmt::LetPat(..)
    | @xsh_core.Stmt::Expr(..) => NormalizeStmtGroup::EffectfulFn
    @xsh_core.Stmt::Test(..)
    | @xsh_core.Stmt::Bench(..)
    | @xsh_core.Stmt::Export(..) => NormalizeStmtGroup::Other
  }
}

///|
fn normalize_expr_is_effectful_fn(expr : @xsh_core.Expr) -> Bool {
  match expr {
    @xsh_core.Expr::Fn(effects~, ..) => effects.length() > 0
    _ => false
  }
}
