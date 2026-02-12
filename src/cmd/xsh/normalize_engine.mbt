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
struct NormalizeOptimizeResult {
  normalized_module : @xsh_core.Module
  rewritten_exprs : Map[String, @xsh_core.Expr]
}

///|
struct NormalizeInlineCandidate {
  stmt_index : Int
  name : String
  body_expr : @xsh_core.Expr
}

///|
enum StdModuleLayer {
  TraitContract
  PurePrimitive
  PureData
  RefModel
  EffectBoundary
  BackendSpecific
}

///|
fn std_layer_name(layer : StdModuleLayer) -> String {
  match layer {
    StdModuleLayer::TraitContract => "trait-contract"
    StdModuleLayer::PurePrimitive => "pure-primitive"
    StdModuleLayer::PureData => "pure-data"
    StdModuleLayer::RefModel => "ref-model"
    StdModuleLayer::EffectBoundary => "effect-boundary"
    StdModuleLayer::BackendSpecific => "backend-specific"
  }
}

///|
fn std_layer_for_path(path : String) -> StdModuleLayer? {
  let normalized = @xsh_fs.normalize_path(path)
  if not(normalized.contains("/vibe/std/")) ||
    not(normalized.has_suffix(".vibe")) ||
    normalized.has_suffix("_test.vibe") ||
    normalized.has_suffix("_type_import_test.vibe") ||
    normalized.has_suffix("/test_import.vibe") {
    return None
  }
  if normalized.has_suffix("/vibe/std/builtin_traits.vibe") {
    return Some(StdModuleLayer::TraitContract)
  }
  if normalized.has_suffix("/vibe/std/bool.vibe") ||
    normalized.has_suffix("/vibe/std/int.vibe") ||
    normalized.has_suffix("/vibe/std/float.vibe") ||
    normalized.has_suffix("/vibe/std/double.vibe") ||
    normalized.has_suffix("/vibe/std/string.vibe") {
    return Some(StdModuleLayer::PurePrimitive)
  }
  if normalized.has_suffix("/vibe/std/list.vibe") ||
    normalized.has_suffix("/vibe/std/option.vibe") {
    return Some(StdModuleLayer::PureData)
  }
  if normalized.has_suffix("/vibe/std/path.vibe") {
    return Some(StdModuleLayer::RefModel)
  }
  if normalized.has_suffix("/vibe/std/io.vibe") ||
    normalized.has_suffix("/vibe/std/threads.vibe") {
    return Some(StdModuleLayer::EffectBoundary)
  }
  if normalized.contains("/vibe/std/wasm/") {
    return Some(StdModuleLayer::BackendSpecific)
  }
  None
}

///|
fn std_layer_allows_import(
  source_layer : StdModuleLayer,
  imported_layer : StdModuleLayer,
) -> Bool {
  match source_layer {
    StdModuleLayer::TraitContract =>
      match imported_layer {
        StdModuleLayer::TraitContract => true
        _ => false
      }
    StdModuleLayer::PurePrimitive =>
      match imported_layer {
        StdModuleLayer::TraitContract | StdModuleLayer::PurePrimitive => true
        _ => false
      }
    StdModuleLayer::PureData =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData => true
        _ => false
      }
    StdModuleLayer::RefModel =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData
        | StdModuleLayer::RefModel => true
        _ => false
      }
    StdModuleLayer::EffectBoundary =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData
        | StdModuleLayer::RefModel
        | StdModuleLayer::EffectBoundary => true
        _ => false
      }
    StdModuleLayer::BackendSpecific =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData
        | StdModuleLayer::RefModel
        | StdModuleLayer::BackendSpecific => true
        _ => false
      }
  }
}

///|
fn std_collect_direct_import_paths(
  ast : @xsh_core.Module,
  base_dir : String,
) -> Array[String] {
  let imports : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Import(source~, ..)
      | @xsh_core.Stmt::ReExport(source~, ..) =>
        match source {
          @xsh_core.ModuleRef::Path(path=raw_path) =>
            imports.push(@loader.resolve_import_path(base_dir, raw_path))
          _ => ()
        }
      _ => ()
    }
  }
  imports
}

///|
pub fn std_layering_violations_for_source(
  path : String,
  source : String,
) -> Array[String] {
  let source_layer = match std_layer_for_path(path) {
    Some(v) => v
    None => return []
  }
  let ast = @parser.parse_ast(source) catch { _ => return [] }
  let base_dir = @xsh_fs.parent_path(path)
  let imports = std_collect_direct_import_paths(ast, base_dir)
  let violations : Array[String] = []
  for import_path in imports {
    match std_layer_for_path(import_path) {
      Some(imported_layer) =>
        if not(std_layer_allows_import(source_layer, imported_layer)) {
          violations.push(
            "std layering violation: " +
            std_layer_name(source_layer) +
            " module " +
            path +
            " must not import " +
            std_layer_name(imported_layer) +
            " module " +
            import_path,
          )
        }
      None => ()
    }
  }
  violations
}

///|
pub fn normalize_format_file_source(path : String) -> Result[String, String] {
  let src = @os_fs.read_file_to_string(path) catch {
    e => return Err("normalize: " + e.to_string())
  }
  normalize_format_source_text(src)
}

///|
pub fn normalize_format_source_text(source : String) -> Result[String, String] {
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok(@parser.format_script(normalized))
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
    out.write_string(
      normalize_source_slice_by_span(source, cursor, range.start),
    )
    let stmt_source = normalize_source_slice_by_span(
      source,
      range.start,
      range.end,
    )
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
  out.write_string(
    normalize_source_slice_by_span(source, cursor, source.length()),
  )
  Ok(@parser.format_script(out.to_string()))
}

///|
fn normalize_module_stmt_source(stmt_source : String) -> Result[String, String] {
  let (open_index, close_index) = match
    normalize_find_brace_bounds(stmt_source) {
    Some(v) => v
    None => return Err("normalize: malformed module block")
  }
  let head = normalize_source_slice_by_span(stmt_source, 0, open_index)
    .trim()
    .to_string()
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
  let optimized = normalize_optimize_module(ast)
  let selected = normalize_select_stmts(optimized.normalized_module)
  let sorted = normalize_sort_stmts(selected)
  if sorted.length() == 0 {
    return Ok("")
  }
  let inferred_annotations = normalize_collect_inferred_annotations(@xsh_core.Module::{
    stmts: sorted,
  })
  let rendered = match
    normalize_render_source(
      source,
      sorted,
      optimized.rewritten_exprs,
      inferred_annotations,
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let formatted = @parser.format_script(rendered)
  let reparsed = @parser.parse_ast(formatted) catch {
    e => return Err("normalize: rendered parse failed: " + e.to_string())
  }
  let expected = @xsh_core.Module::{ stmts: sorted }
  let reparsed_stripped = normalize_strip_local_type_assert_module(reparsed)
  let expected_stripped = normalize_strip_local_type_assert_module(expected)
  if @xsh_core.normalize_module(reparsed_stripped) !=
    @xsh_core.normalize_module(expected_stripped) {
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
fn normalize_render_stmt(
  source : String,
  stmt : @xsh_core.Stmt,
  rewritten_exprs : Map[String, @xsh_core.Expr],
  inferred_annotations : Map[String, String],
) -> String? {
  let key = normalize_stmt_key(stmt)
  let rewritten_expr = rewritten_exprs.get(key)
  let annotation = inferred_annotations.get(key)
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, expr~, span~) => {
      if rewritten_expr is None && annotation is None {
        let snippet = normalize_source_slice_by_span(
            source,
            span.start,
            span.end,
          )
          .trim()
          .to_string()
        if normalize_render_stmt_accept_raw_snippet(snippet) {
          return Some(snippet)
        }
      }
      normalize_render_let_stmt(
        source, false, rec, name, expr, rewritten_expr, annotation,
      )
    }
    @xsh_core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      if rewritten_expr is None && annotation is None {
        let snippet = normalize_source_slice_by_span(
            source,
            span.start,
            span.end,
          )
          .trim()
          .to_string()
        if normalize_render_stmt_accept_raw_snippet(snippet) {
          return Some(snippet)
        }
      }
      normalize_render_let_stmt(
        source, true, rec, name, expr, rewritten_expr, annotation,
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
fn normalize_render_let_stmt(
  source : String,
  exported : Bool,
  rec_flag : Bool,
  name : String,
  original_expr : @xsh_core.Expr,
  rewritten_expr : @xsh_core.Expr?,
  annotation : String?,
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
    return None
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
fn normalize_render_expr_for_stmt(
  source : String,
  expr : @xsh_core.Expr,
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
fn normalize_render_expr(expr : @xsh_core.Expr) -> String? {
  match expr {
    @xsh_core.Expr::Int(value~, ..) => Some(value.to_string())
    @xsh_core.Expr::Float(value~, ..) => Some(value.to_string())
    @xsh_core.Expr::Double(value~, ..) => Some(value.to_string())
    @xsh_core.Expr::Bool(value~, ..) =>
      Some(if value { "true" } else { "false" })
    @xsh_core.Expr::String(value~, ..) => Some(normalize_quote_string(value))
    @xsh_core.Expr::Ident(name~, ..) => Some(name)
    @xsh_core.Expr::Call(name~, type_args~, args~, ..) => {
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
    @xsh_core.Expr::Tuple(items~, ..) => {
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
    @xsh_core.Expr::Array(items~, ..) => {
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
fn normalize_render_source(
  source : String,
  stmts : Array[@xsh_core.Stmt],
  rewritten_exprs : Map[String, @xsh_core.Expr],
  inferred_annotations : Map[String, String],
) -> Result[String, String] {
  let out = StringBuilder::new()
  for stmt in stmts {
    match
      normalize_render_stmt(source, stmt, rewritten_exprs, inferred_annotations) {
      Some(rendered) => {
        out.write_string(rendered)
        if not(rendered.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
      None => {
        let span = stmt.span()
        let snippet = normalize_source_slice_by_span(
          source,
          span.start,
          span.end,
        )
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
      e =>
        return Err("normalize: rendered source parse failed: " + e.to_string())
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
fn normalize_stmt_key(stmt : @xsh_core.Stmt) -> String {
  let span = stmt.span()
  span.start.to_string() + ":" + span.end.to_string()
}

///|
fn normalize_optimize_module(ast : @xsh_core.Module) -> NormalizeOptimizeResult {
  let exported = normalize_collect_export_name_map(ast)
  let inlined = normalize_inline_single_use(ast, exported)
  normalize_fold_top_level_consts(
    inlined.normalized_module,
    inlined.rewritten_exprs,
  )
}

///|
fn normalize_collect_export_name_map(
  ast : @xsh_core.Module,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for name in normalize_collect_export_names(ast) {
    out[name] = true
  }
  out
}

///|
fn normalize_inline_single_use(
  ast : @xsh_core.Module,
  exported_names : Map[String, Bool],
) -> NormalizeOptimizeResult {
  let candidates : Map[String, NormalizeInlineCandidate] = {}
  for i, stmt in ast.stmts {
    match normalize_stmt_inline_candidate(stmt) {
      Some((name, body_expr)) =>
        if not(exported_names.contains(name)) {
          candidates[name] = { stmt_index: i, name, body_expr }
        }
      None => ()
    }
  }
  if candidates.length() == 0 {
    return { normalized_module: ast, rewritten_exprs: {} }
  }
  let ref_counts = normalize_count_candidate_refs_module(ast, candidates)
  let callsite_index_by_name : Map[String, Int] = {}
  for i, stmt in ast.stmts {
    match normalize_stmt_inline_call_name(stmt, candidates) {
      Some(name) =>
        match callsite_index_by_name.get(name) {
          Some(_) => callsite_index_by_name[name] = -1
          None => callsite_index_by_name[name] = i
        }
      None => ()
    }
  }
  let callsite_name_by_index : Map[Int, String] = {}
  let dropped_candidate_names : Map[String, Bool] = {}
  for name, candidate in candidates {
    let ref_count = match ref_counts.get(name) {
      Some(v) => v
      None => 0
    }
    match callsite_index_by_name.get(name) {
      Some(callsite_idx) =>
        if callsite_idx >= 0 && ref_count == 1 {
          callsite_name_by_index[callsite_idx] = name
          dropped_candidate_names[name] = true
          dropped_candidate_names[candidate.name] = true
        }
      None => ()
    }
  }
  if callsite_name_by_index.length() == 0 {
    return { normalized_module: ast, rewritten_exprs: {} }
  }
  let rewritten_exprs : Map[String, @xsh_core.Expr] = {}
  let out_stmts : Array[@xsh_core.Stmt] = []
  for i, stmt in ast.stmts {
    match callsite_name_by_index.get(i) {
      Some(name) =>
        match candidates.get(name) {
          Some(candidate) => {
            let rewritten = normalize_stmt_replace_expr(
              stmt,
              candidate.body_expr,
            )
            rewritten_exprs[normalize_stmt_key(stmt)] = candidate.body_expr
            out_stmts.push(rewritten)
          }
          None => out_stmts.push(stmt)
        }
      None => {
        let mut drop_stmt = false
        match normalize_stmt_def_name(stmt) {
          Some(name) =>
            if dropped_candidate_names.contains(name) {
              match candidates.get(name) {
                Some(candidate) =>
                  if candidate.stmt_index == i {
                    drop_stmt = true
                  }
                None => ()
              }
            }
          None => ()
        }
        if not(drop_stmt) {
          out_stmts.push(stmt)
        }
      }
    }
  }
  { normalized_module: @xsh_core.Module::{ stmts: out_stmts }, rewritten_exprs }
}

///|
fn normalize_stmt_inline_candidate(
  stmt : @xsh_core.Stmt,
) -> (String, @xsh_core.Expr)? {
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, expr~, ..) =>
      if rec {
        None
      } else {
        match expr {
          @xsh_core.Expr::Fn(type_params~, params~, effects~, body~, ..) =>
            if type_params.length() > 0 ||
              params.length() > 0 ||
              effects.length() > 0 ||
              body.stmts.length() != 1 {
              None
            } else {
              match body.stmts[0] {
                @xsh_core.Stmt::Expr(expr=body_expr, ..) =>
                  Some((name, body_expr))
                _ => None
              }
            }
          _ => None
        }
      }
    _ => None
  }
}

///|
fn normalize_stmt_inline_call_name(
  stmt : @xsh_core.Stmt,
  candidates : Map[String, NormalizeInlineCandidate],
) -> String? {
  let expr = match stmt {
    @xsh_core.Stmt::Let(expr~, ..) | @xsh_core.Stmt::ExportLet(expr~, ..) =>
      Some(expr)
    _ => None
  }
  match expr {
    Some(@xsh_core.Expr::Call(name~, type_args~, args~, ..)) =>
      if candidates.contains(name) &&
        type_args.length() == 0 &&
        args.length() == 0 {
        Some(name)
      } else {
        None
      }
    _ => None
  }
}

///|
fn normalize_stmt_replace_expr(
  stmt : @xsh_core.Stmt,
  next_expr : @xsh_core.Expr,
) -> @xsh_core.Stmt {
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, span~, ..) =>
      @xsh_core.Stmt::Let(rec~, name~, expr=next_expr, span~)
    @xsh_core.Stmt::ExportLet(rec~, name~, span~, ..) =>
      @xsh_core.Stmt::ExportLet(rec~, name~, expr=next_expr, span~)
    _ => stmt
  }
}

///|
fn normalize_count_candidate_refs_module(
  mod : @xsh_core.Module,
  candidates : Map[String, NormalizeInlineCandidate],
) -> Map[String, Int] {
  let counts : Map[String, Int] = {}
  for stmt in mod.stmts {
    let bound : Map[String, Bool] = {}
    normalize_count_candidate_refs_stmt(stmt, bound, candidates, counts)
  }
  counts
}

///|
fn normalize_count_candidate_refs_stmt(
  stmt : @xsh_core.Stmt,
  bound : Map[String, Bool],
  candidates : Map[String, NormalizeInlineCandidate],
  counts : Map[String, Int],
) -> Unit {
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, expr~, ..)
    | @xsh_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
      if rec {
        bound[name] = true
      }
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
      if not(rec) {
        bound[name] = true
      }
    }
    @xsh_core.Stmt::LetMut(name~, expr~, ..) => {
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
      bound[name] = true
    }
    @xsh_core.Stmt::Assign(name~, expr~, ..) => {
      normalize_count_candidate_ref_name(name, bound, candidates, counts)
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
    }
    @xsh_core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      normalize_count_candidate_refs_expr(target, bound, candidates, counts)
      normalize_count_candidate_refs_expr(index, bound, candidates, counts)
      normalize_count_candidate_refs_expr(value, bound, candidates, counts)
    }
    @xsh_core.Stmt::LetPat(pat~, expr~, ..) => {
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
      normalize_bind_pattern_names(bound, pat)
    }
    @xsh_core.Stmt::Expr(expr~, ..) =>
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
    @xsh_core.Stmt::Test(body~, ..) | @xsh_core.Stmt::Bench(body~, ..) =>
      normalize_count_candidate_refs_block(body, bound, candidates, counts)
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

///|
fn normalize_count_candidate_refs_block(
  body : @xsh_core.Module,
  bound : Map[String, Bool],
  candidates : Map[String, NormalizeInlineCandidate],
  counts : Map[String, Int],
) -> Unit {
  let scope = normalize_clone_bool_map(bound)
  for stmt in body.stmts {
    normalize_count_candidate_refs_stmt(stmt, scope, candidates, counts)
  }
}

///|
fn normalize_count_candidate_refs_expr(
  expr : @xsh_core.Expr,
  bound : Map[String, Bool],
  candidates : Map[String, NormalizeInlineCandidate],
  counts : Map[String, Int],
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
      normalize_count_candidate_ref_name(name, bound, candidates, counts)
    @xsh_core.Expr::Call(name~, args~, ..) => {
      normalize_count_candidate_ref_name(name, bound, candidates, counts)
      for arg in args {
        normalize_count_candidate_refs_expr(arg.expr, bound, candidates, counts)
      }
    }
    @xsh_core.Expr::Tuple(items~, ..) =>
      for item in items {
        normalize_count_candidate_refs_expr(item, bound, candidates, counts)
      }
    @xsh_core.Expr::TupleIndex(expr~, ..)
    | @xsh_core.Expr::Await(expr~, ..)
    | @xsh_core.Expr::Yield(expr~, ..) =>
      normalize_count_candidate_refs_expr(expr, bound, candidates, counts)
    @xsh_core.Expr::Record(fields~, ..)
    | @xsh_core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        normalize_count_candidate_refs_expr(
          field.expr,
          bound,
          candidates,
          counts,
        )
      }
    @xsh_core.Expr::Array(items~, ..) =>
      for item in items {
        normalize_count_candidate_refs_expr(item, bound, candidates, counts)
      }
    @xsh_core.Expr::Map(fields~, ..) =>
      for field in fields {
        normalize_count_candidate_refs_expr(
          field.expr,
          bound,
          candidates,
          counts,
        )
      }
    @xsh_core.Expr::If(cond~, then_body~, else_body~, ..) => {
      normalize_count_candidate_refs_expr(cond, bound, candidates, counts)
      normalize_count_candidate_refs_block(then_body, bound, candidates, counts)
      normalize_count_candidate_refs_block(else_body, bound, candidates, counts)
    }
    @xsh_core.Expr::Block(body~, ..) | @xsh_core.Expr::Do(body~, ..) =>
      normalize_count_candidate_refs_block(body, bound, candidates, counts)
    @xsh_core.Expr::Try(try_body~, catch_body~, ..) => {
      normalize_count_candidate_refs_block(try_body, bound, candidates, counts)
      normalize_count_candidate_refs_block(
        catch_body, bound, candidates, counts,
      )
    }
    @xsh_core.Expr::Match(scrutinee~, arms~, ..) => {
      normalize_count_candidate_refs_expr(scrutinee, bound, candidates, counts)
      for arm in arms {
        let arm_bound = normalize_clone_bool_map(bound)
        normalize_bind_pattern_names(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) =>
            normalize_count_candidate_refs_expr(
              cond, arm_bound, candidates, counts,
            )
          None => ()
        }
        normalize_count_candidate_refs_expr(
          arm.expr,
          arm_bound,
          candidates,
          counts,
        )
      }
    }
    @xsh_core.Expr::Fn(params~, body~, ..) => {
      let fn_bound = normalize_clone_bool_map(bound)
      for param in params {
        fn_bound[param.name] = true
      }
      normalize_count_candidate_refs_block(body, fn_bound, candidates, counts)
    }
    @xsh_core.Expr::While(cond~, body~, ..) => {
      normalize_count_candidate_refs_expr(cond, bound, candidates, counts)
      normalize_count_candidate_refs_block(body, bound, candidates, counts)
    }
    @xsh_core.Expr::Raise(value~, ..) =>
      normalize_count_candidate_refs_expr(value, bound, candidates, counts)
  }
}

///|
fn normalize_count_candidate_ref_name(
  name : String,
  bound : Map[String, Bool],
  candidates : Map[String, NormalizeInlineCandidate],
  counts : Map[String, Int],
) -> Unit {
  if bound.contains(name) || not(candidates.contains(name)) {
    return
  }
  match counts.get(name) {
    Some(v) => counts[name] = v + 1
    None => counts[name] = 1
  }
}

///|
fn normalize_fold_top_level_consts(
  mod : @xsh_core.Module,
  rewritten_exprs : Map[String, @xsh_core.Expr],
) -> NormalizeOptimizeResult {
  let out_rewrites = normalize_clone_expr_map(rewritten_exprs)
  let out_stmts : Array[@xsh_core.Stmt] = []
  for stmt in mod.stmts {
    let next_stmt = match stmt {
      @xsh_core.Stmt::Let(expr~, ..) | @xsh_core.Stmt::ExportLet(expr~, ..) =>
        match normalize_fold_const_expr(expr) {
          Some(folded) =>
            match normalize_render_expr(folded) {
              Some(_) => {
                out_rewrites[normalize_stmt_key(stmt)] = folded
                normalize_stmt_replace_expr(stmt, folded)
              }
              None => stmt
            }
          None => stmt
        }
      _ => stmt
    }
    out_stmts.push(next_stmt)
  }
  {
    normalized_module: @xsh_core.Module::{ stmts: out_stmts },
    rewritten_exprs: out_rewrites,
  }
}

///|
fn normalize_clone_expr_map(
  m : Map[String, @xsh_core.Expr],
) -> Map[String, @xsh_core.Expr] {
  let out : Map[String, @xsh_core.Expr] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn normalize_fold_const_expr(expr : @xsh_core.Expr) -> @xsh_core.Expr? {
  match normalize_eval_const_expr(expr) {
    Some(value) =>
      if normalize_expr_is_literal(expr) {
        None
      } else {
        Some(value)
      }
    None => None
  }
}

///|
fn normalize_expr_is_literal(expr : @xsh_core.Expr) -> Bool {
  match expr {
    @xsh_core.Expr::Int(..)
    | @xsh_core.Expr::Float(..)
    | @xsh_core.Expr::Double(..)
    | @xsh_core.Expr::Bool(..)
    | @xsh_core.Expr::String(..) => true
    _ => false
  }
}

///|
fn normalize_eval_const_expr(expr : @xsh_core.Expr) -> @xsh_core.Expr? {
  match expr {
    @xsh_core.Expr::Int(..)
    | @xsh_core.Expr::Float(..)
    | @xsh_core.Expr::Double(..)
    | @xsh_core.Expr::Bool(..)
    | @xsh_core.Expr::String(..) => Some(expr)
    @xsh_core.Expr::Call(name~, type_args~, args~, span~) => {
      if type_args.length() > 0 {
        return None
      }
      let values : Array[@xsh_core.Expr] = []
      for arg in args {
        if arg.label is Some(_) {
          return None
        }
        match normalize_eval_const_expr(arg.expr) {
          Some(v) => values.push(v)
          None => return None
        }
      }
      normalize_fold_builtin_call(name, values, span)
    }
    _ => None
  }
}

///|
fn normalize_fold_builtin_call(
  name : String,
  args : Array[@xsh_core.Expr],
  span : @xsh_core.Span,
) -> @xsh_core.Expr? {
  match name {
    "__add" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Int(value=left + right, span~))
          _ => None
        }
      } else {
        None
      }
    "__sub" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Int(value=left - right, span~))
          _ => None
        }
      } else {
        None
      }
    "__mul" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Int(value=left * right, span~))
          _ => None
        }
      } else {
        None
      }
    "__div" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(_), Some(0)) => None
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Int(value=left / right, span~))
          _ => None
        }
      } else {
        None
      }
    "__mod" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(_), Some(0)) => None
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Int(value=left % right, span~))
          _ => None
        }
      } else {
        None
      }
    "__eq" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Bool(value=left == right, span~))
          _ =>
            match
              (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
              (Some(left), Some(right)) =>
                Some(@xsh_core.Expr::Bool(value=left == right, span~))
              _ =>
                match
                  (
                    normalize_expr_as_string(args[0]),
                    normalize_expr_as_string(args[1]),
                  ) {
                  (Some(left), Some(right)) =>
                    Some(@xsh_core.Expr::Bool(value=left == right, span~))
                  _ => None
                }
            }
        }
      } else {
        None
      }
    "__lt" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Bool(value=left < right, span~))
          _ => None
        }
      } else {
        None
      }
    "and" =>
      if args.length() == 2 {
        match
          (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Bool(value=left && right, span~))
          _ => None
        }
      } else {
        None
      }
    "or" =>
      if args.length() == 2 {
        match
          (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
          (Some(left), Some(right)) =>
            Some(@xsh_core.Expr::Bool(value=left || right, span~))
          _ => None
        }
      } else {
        None
      }
    "not" =>
      if args.length() == 1 {
        match normalize_expr_as_bool(args[0]) {
          Some(value) => Some(@xsh_core.Expr::Bool(value=not(value), span~))
          None => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn normalize_expr_as_int(expr : @xsh_core.Expr) -> Int? {
  match expr {
    @xsh_core.Expr::Int(value~, ..) => Some(value)
    _ => None
  }
}

///|
fn normalize_expr_as_bool(expr : @xsh_core.Expr) -> Bool? {
  match expr {
    @xsh_core.Expr::Bool(value~, ..) => Some(value)
    _ => None
  }
}

///|
fn normalize_expr_as_string(expr : @xsh_core.Expr) -> String? {
  match expr {
    @xsh_core.Expr::String(value~, ..) => Some(value)
    _ => None
  }
}

///|
fn normalize_collect_inferred_annotations(
  ast : @xsh_core.Module,
) -> Map[String, String] {
  let env = @checker.type_check(ast) catch { _ => return {} }
  let out : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Let(rec~, name~, expr~, ..)
      | @xsh_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        if rec || normalize_stmt_has_explicit_type_assert(expr) {
          continue
        }
        match expr {
          @xsh_core.Expr::Fn(..) => continue
          _ => ()
        }
        let ty = match env.get(name) {
          Some(v) => v
          None => continue
        }
        if not(normalize_type_annotation_allowed(ty)) {
          continue
        }
        let rendered = normalize_render_type_annotation(ty)
        if rendered.length() == 0 {
          continue
        }
        let probe = "let __normalize_probe: " + rendered + " = 0"
        let _ = @parser.parse_ast(probe) catch { _ => continue }
        out[normalize_stmt_key(stmt)] = rendered
      }
      _ => ()
    }
  }
  out
}

///|
fn normalize_stmt_has_explicit_type_assert(expr : @xsh_core.Expr) -> Bool {
  normalize_unwrap_local_type_assert(expr) is Some(_)
}

///|
fn normalize_unwrap_local_type_assert(
  expr : @xsh_core.Expr,
) -> (@xsh_core.Type, @xsh_core.Expr)? {
  match expr {
    @xsh_core.Expr::Block(body~, ..) => {
      if body.stmts.length() != 2 {
        return None
      }
      let helper_stmt = body.stmts[0]
      let call_stmt = body.stmts[1]
      let (helper_name, helper_ty) = match helper_stmt {
        @xsh_core.Stmt::Let(
          rec~,
          name~,
          expr=@xsh_core.Expr::Fn(params~, ret~, body=helper_body, ..),
          ..
        ) =>
          if rec ||
            not(name.has_prefix("__xsh_local_type_assert_")) ||
            params.length() != 1 ||
            helper_body.stmts.length() != 1 {
            return None
          } else {
            match helper_body.stmts[0] {
              @xsh_core.Stmt::Expr(
                expr=@xsh_core.Expr::Ident(name=returned_name, ..),
                ..
              ) => if returned_name != params[0].name { return None }
              _ => return None
            }
            let ret_ty = match ret {
              Some(v) => v
              None => return None
            }
            if params[0].ty != ret_ty {
              return None
            }
            (name, ret_ty)
          }
        _ => return None
      }
      match call_stmt {
        @xsh_core.Stmt::Expr(expr=@xsh_core.Expr::Call(name~, args~, ..), ..) =>
          if name != helper_name || args.length() != 1 {
            None
          } else {
            Some((helper_ty, args[0].expr))
          }
        _ => None
      }
    }
    _ => None
  }
}

///|
fn normalize_type_annotation_allowed(ty : @xsh_core.Type) -> Bool {
  match ty {
    @xsh_core.Type::Int
    | @xsh_core.Type::Float
    | @xsh_core.Type::Double
    | @xsh_core.Type::Bool
    | @xsh_core.Type::String
    | @xsh_core.Type::Path
    | @xsh_core.Type::Unit
    | @xsh_core.Type::Never => true
    @xsh_core.Type::Tuple(items) => {
      for item in items {
        if not(normalize_type_annotation_allowed(item)) {
          return false
        }
      }
      true
    }
    @xsh_core.Type::Array(inner)
    | @xsh_core.Type::Map(inner)
    | @xsh_core.Type::ArrayBuilder(inner)
    | @xsh_core.Type::MapBuilder(inner) =>
      normalize_type_annotation_allowed(inner)
    @xsh_core.Type::Named(args~, ..) => {
      for arg in args {
        if not(normalize_type_annotation_allowed(arg)) {
          return false
        }
      }
      true
    }
    @xsh_core.Type::Func(params~, ret~, effects~) => {
      for param in params {
        if not(normalize_type_annotation_allowed(param.ty)) {
          return false
        }
      }
      if not(normalize_type_annotation_allowed(ret)) {
        return false
      }
      for effect in effects {
        match effect {
          @xsh_core.EffectAtom::Const(_) => ()
          @xsh_core.EffectAtom::Var(_) => return false
        }
      }
      true
    }
    @xsh_core.Type::Record(_)
    | @xsh_core.Type::Variant(_)
    | @xsh_core.Type::Param(_)
    | @xsh_core.Type::Var(_) => false
  }
}

///|
fn normalize_render_type_annotation(ty : @xsh_core.Type) -> String {
  match ty {
    @xsh_core.Type::Int => "Int"
    @xsh_core.Type::Float => "Float"
    @xsh_core.Type::Double => "Double"
    @xsh_core.Type::Bool => "Bool"
    @xsh_core.Type::String => "String"
    @xsh_core.Type::Path => "@core.Path"
    @xsh_core.Type::Unit => "Unit"
    @xsh_core.Type::Never => "Never"
    @xsh_core.Type::Tuple(items) => {
      let out = StringBuilder::new()
      out.write_char('(')
      for i, item in items {
        if i > 0 {
          out.write_string(", ")
        }
        out.write_string(normalize_render_type_annotation(item))
      }
      out.write_char(')')
      out.to_string()
    }
    @xsh_core.Type::Array(inner) =>
      "Array[" + normalize_render_type_annotation(inner) + "]"
    @xsh_core.Type::Map(inner) =>
      "Map[" + normalize_render_type_annotation(inner) + "]"
    @xsh_core.Type::ArrayBuilder(inner) =>
      "ArrayBuilder[" + normalize_render_type_annotation(inner) + "]"
    @xsh_core.Type::MapBuilder(inner) =>
      "MapBuilder[" + normalize_render_type_annotation(inner) + "]"
    @xsh_core.Type::Named(name~, args~) =>
      if args.length() == 0 {
        name
      } else {
        let out = StringBuilder::new()
        out.write_string(name)
        out.write_char('[')
        for i, arg in args {
          if i > 0 {
            out.write_string(", ")
          }
          out.write_string(normalize_render_type_annotation(arg))
        }
        out.write_char(']')
        out.to_string()
      }
    @xsh_core.Type::Func(params~, ret~, effects~) => {
      let out = StringBuilder::new()
      out.write_char('(')
      for i, param in params {
        if i > 0 {
          out.write_string(", ")
        }
        out.write_string(normalize_render_type_annotation(param.ty))
      }
      out.write_string(") -> ")
      out.write_string(normalize_render_type_annotation(ret))
      if effects.length() > 0 {
        out.write_string(" with {")
        for i, effect in effects {
          if i > 0 {
            out.write_string(", ")
          }
          match effect {
            @xsh_core.EffectAtom::Const(name) => out.write_string(name)
            @xsh_core.EffectAtom::Var(name) => out.write_string(name)
          }
        }
        out.write_char('}')
      }
      out.to_string()
    }
    @xsh_core.Type::Record(_)
    | @xsh_core.Type::Variant(_)
    | @xsh_core.Type::Param(_)
    | @xsh_core.Type::Var(_) => ""
  }
}

///|
fn normalize_strip_local_type_assert_module(
  mod : @xsh_core.Module,
) -> @xsh_core.Module {
  let out : Array[@xsh_core.Stmt] = []
  for stmt in mod.stmts {
    out.push(normalize_strip_local_type_assert_stmt(stmt))
  }
  @xsh_core.Module::{ stmts: out }
}

///|
fn normalize_strip_local_type_assert_stmt(
  stmt : @xsh_core.Stmt,
) -> @xsh_core.Stmt {
  match stmt {
    @xsh_core.Stmt::Let(rec~, name~, expr~, span~) =>
      @xsh_core.Stmt::Let(
        rec~,
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @xsh_core.Stmt::ExportLet(
        rec~,
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::Expr(expr~, span~) =>
      @xsh_core.Stmt::Expr(
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::LetMut(name~, expr~, span~) =>
      @xsh_core.Stmt::LetMut(
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::Assign(name~, expr~, span~) =>
      @xsh_core.Stmt::Assign(
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @xsh_core.Stmt::IndexAssign(
        target=normalize_strip_local_type_assert_expr(target),
        index=normalize_strip_local_type_assert_expr(index),
        value=normalize_strip_local_type_assert_expr(value),
        span~,
      )
    @xsh_core.Stmt::LetPat(pat~, expr~, span~) =>
      @xsh_core.Stmt::LetPat(
        pat~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @xsh_core.Stmt::Test(name~, body~, span~) =>
      @xsh_core.Stmt::Test(
        name~,
        body=normalize_strip_local_type_assert_module(body),
        span~,
      )
    @xsh_core.Stmt::Bench(name~, body~, span~) =>
      @xsh_core.Stmt::Bench(
        name~,
        body=normalize_strip_local_type_assert_module(body),
        span~,
      )
    _ => stmt
  }
}

///|
fn normalize_strip_local_type_assert_expr(
  expr : @xsh_core.Expr,
) -> @xsh_core.Expr {
  match normalize_unwrap_local_type_assert(expr) {
    Some((_, unwrapped)) => normalize_strip_local_type_assert_expr(unwrapped)
    None =>
      match expr {
        @xsh_core.Expr::Call(name~, type_args~, args~, span~) => {
          let next_args : Array[@xsh_core.CallArg] = []
          for arg in args {
            next_args.push(@xsh_core.CallArg::{
              label: arg.label,
              expr: normalize_strip_local_type_assert_expr(arg.expr),
              span: arg.span,
            })
          }
          @xsh_core.Expr::Call(name~, type_args~, args=next_args, span~)
        }
        @xsh_core.Expr::Tuple(items~, span~) => {
          let next_items : Array[@xsh_core.Expr] = []
          for item in items {
            next_items.push(normalize_strip_local_type_assert_expr(item))
          }
          @xsh_core.Expr::Tuple(items=next_items, span~)
        }
        @xsh_core.Expr::TupleIndex(expr~, index~, span~) =>
          @xsh_core.Expr::TupleIndex(
            expr=normalize_strip_local_type_assert_expr(expr),
            index~,
            span~,
          )
        @xsh_core.Expr::Record(fields~, span~) => {
          let next_fields : Array[@xsh_core.RecordFieldExpr] = []
          for field in fields {
            next_fields.push(@xsh_core.RecordFieldExpr::{
              name: field.name,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @xsh_core.Expr::Record(fields=next_fields, span~)
        }
        @xsh_core.Expr::Array(items~, span~) => {
          let next_items : Array[@xsh_core.Expr] = []
          for item in items {
            next_items.push(normalize_strip_local_type_assert_expr(item))
          }
          @xsh_core.Expr::Array(items=next_items, span~)
        }
        @xsh_core.Expr::Map(fields~, span~) => {
          let next_fields : Array[@xsh_core.MapFieldExpr] = []
          for field in fields {
            next_fields.push(@xsh_core.MapFieldExpr::{
              key: field.key,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @xsh_core.Expr::Map(fields=next_fields, span~)
        }
        @xsh_core.Expr::If(cond~, then_body~, else_body~, span~) =>
          @xsh_core.Expr::If(
            cond=normalize_strip_local_type_assert_expr(cond),
            then_body=normalize_strip_local_type_assert_module(then_body),
            else_body=normalize_strip_local_type_assert_module(else_body),
            span~,
          )
        @xsh_core.Expr::Block(body~, span~) =>
          @xsh_core.Expr::Block(
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @xsh_core.Expr::Match(scrutinee~, arms~, span~) => {
          let next_arms : Array[@xsh_core.MatchArm] = []
          for arm in arms {
            next_arms.push(@xsh_core.MatchArm::{
              pat: arm.pat,
              cond: match arm.cond {
                Some(cond) => Some(normalize_strip_local_type_assert_expr(cond))
                None => None
              },
              expr: normalize_strip_local_type_assert_expr(arm.expr),
              span: arm.span,
            })
          }
          @xsh_core.Expr::Match(
            scrutinee=normalize_strip_local_type_assert_expr(scrutinee),
            arms=next_arms,
            span~,
          )
        }
        @xsh_core.Expr::Do(body~, span~) =>
          @xsh_core.Expr::Do(
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @xsh_core.Expr::Try(try_body~, catch_body~, span~) =>
          @xsh_core.Expr::Try(
            try_body=normalize_strip_local_type_assert_module(try_body),
            catch_body=normalize_strip_local_type_assert_module(catch_body),
            span~,
          )
        @xsh_core.Expr::Fn(
          type_params~,
          type_bounds~,
          params~,
          ret~,
          effects~,
          body~,
          span~
        ) =>
          @xsh_core.Expr::Fn(
            type_params~,
            type_bounds~,
            params~,
            ret~,
            effects~,
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @xsh_core.Expr::While(cond~, body~, span~) =>
          @xsh_core.Expr::While(
            cond=normalize_strip_local_type_assert_expr(cond),
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @xsh_core.Expr::Raise(value~, span~) =>
          @xsh_core.Expr::Raise(
            value=normalize_strip_local_type_assert_expr(value),
            span~,
          )
        @xsh_core.Expr::Await(expr~, span~) =>
          @xsh_core.Expr::Await(
            expr=normalize_strip_local_type_assert_expr(expr),
            span~,
          )
        @xsh_core.Expr::Yield(expr~, span~) =>
          @xsh_core.Expr::Yield(
            expr=normalize_strip_local_type_assert_expr(expr),
            span~,
          )
        @xsh_core.Expr::StructLit(name~, type_args~, fields~, span~) => {
          let next_fields : Array[@xsh_core.RecordFieldExpr] = []
          for field in fields {
            next_fields.push(@xsh_core.RecordFieldExpr::{
              name: field.name,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @xsh_core.Expr::StructLit(
            name~,
            type_args~,
            fields=next_fields,
            span~,
          )
        }
        _ => expr
      }
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
    unresolved.sort_by(fn(a, b) { normalize_name_compare(a, b) })
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
  names.sort_by(fn(a, b) { normalize_name_compare(b, a) })
  names.pop()
}

///|
fn normalize_name_is_member(name : String) -> Bool {
  let mut i = 0
  while i + 1 < name.length() {
    let c = name[i].to_int().unsafe_to_char()
    let next = name[i + 1].to_int().unsafe_to_char()
    if c == ':' && next == ':' {
      return true
    }
    i += 1
  }
  false
}

///|
fn normalize_name_compare(a : String, b : String) -> Int {
  let a_member = normalize_name_is_member(a)
  let b_member = normalize_name_is_member(b)
  if a_member && not(b_member) {
    1
  } else if not(a_member) && b_member {
    -1
  } else {
    String::compare(a, b)
  }
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
