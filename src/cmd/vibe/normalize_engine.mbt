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
  FnDef
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
  normalized_module : @vibe_core.Module
  rewritten_exprs : Map[String, @vibe_core.Expr]
}

///|
struct NormalizeInlineCandidate {
  stmt_index : Int
  name : String
  body_expr : @vibe_core.Expr
}

///|
struct NormalizeRenderedBlock {
  group : NormalizeStmtGroup
  text : String
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
  let quickfixed_source = normalize_apply_grammar_quickfixes(source)
  let ast = @parser.parse_ast(quickfixed_source) catch {
    e => return Err("normalize: parse failed: " + e.to_string())
  }
  let optimized = normalize_optimize_module(ast)
  let selected = normalize_select_stmts(optimized.normalized_module)
  let sorted = normalize_sort_stmts(selected)
  if sorted.length() == 0 {
    return Ok("")
  }
  let sorted_module = @vibe_core.Module::{ stmts: sorted }
  let env = @checker.type_check(sorted_module) catch {
    _ => @checker.TypeEnv::new()
  }
  let inferred_annotations = normalize_collect_inferred_annotations(
    sorted_module, env,
  )
  let rendered = match
    normalize_render_source(
      quickfixed_source,
      sorted,
      optimized.rewritten_exprs,
      inferred_annotations,
      env,
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let formatted = @parser.format_script(rendered)
  let reparsed = @parser.parse_ast(formatted) catch {
    e => return Err("normalize: rendered parse failed: " + e.to_string())
  }
  let expected = @vibe_core.Module::{ stmts: sorted }
  let expected_decl_assign_names = normalize_collect_decl_assign_stmt_names(
    expected,
  )
  let reparsed_stripped = normalize_strip_local_type_assert_module(reparsed)
  let expected_stripped = normalize_strip_local_type_assert_module(expected)
  let reparsed_canonical = normalize_strip_decl_assign_fn_param_types(
    reparsed_stripped, expected_decl_assign_names,
  )
  let expected_canonical = normalize_strip_decl_assign_fn_param_types(
    expected_stripped, expected_decl_assign_names,
  )
  if @vibe_core.normalize_module(reparsed_canonical) !=
    @vibe_core.normalize_module(expected_canonical) {
    return Err("normalize: rendered source changed semantics")
  }
  Ok(rendered)
}

///|
fn merge_stmt_def_name(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::LetMut(name~, ..)
    | @vibe_core.Stmt::EnumDef(name~, ..)
    | @vibe_core.Stmt::ExportEnumDef(name~, ..)
    | @vibe_core.Stmt::TypeAlias(name~, ..)
    | @vibe_core.Stmt::ExportTypeAlias(name~, ..)
    | @vibe_core.Stmt::StructDef(name~, ..)
    | @vibe_core.Stmt::ExportStructDef(name~, ..)
    | @vibe_core.Stmt::TraitDef(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn merge_dedup_stmts(
  stmts : Array[@vibe_core.Stmt],
) -> Array[@vibe_core.Stmt] {
  let len = stmts.length()
  let seen : Map[String, Unit] = {}
  let keep : Array[Bool] = Array::make(len, false)
  // Reverse scan: mark the LAST definition for each name
  for j = 0; j < len; j = j + 1 {
    let i = len - 1 - j
    let stmt = stmts[i]
    match merge_stmt_def_name(stmt) {
      Some(name) =>
        if not(seen.contains(name)) {
          seen[name] = ()
          keep[i] = true
        }
      None => keep[i] = true
    }
  }
  let result : Array[@vibe_core.Stmt] = []
  for i = 0; i < len; i = i + 1 {
    if keep[i] {
      result.push(stmts[i])
    }
  }
  result
}

///|
fn merge_render_stmt_fallback(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Export(names~, ..) => {
      Some("export { " + names.join(", ") + " }")
    }
    @vibe_core.Stmt::ReExport(names~, source~, ..) => {
      let src = match source {
        @vibe_core.ModuleRef::Path(path~) => path
        @vibe_core.ModuleRef::Hash(hash~) => "#" + hash
        @vibe_core.ModuleRef::Version(name~) => "version@" + name
        @vibe_core.ModuleRef::Symbol(name~) => "symbol@" + name
      }
      Some("export { " + names.join(", ") + " } from " + src)
    }
    _ => None
  }
}

///|
fn merge_prefilter_stmts(
  stmts : Array[@vibe_core.Stmt],
  library_mode : Bool,
) -> Array[@vibe_core.Stmt] {
  let out : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::Test(..) | @vibe_core.Stmt::Bench(..) => ()
      @vibe_core.Stmt::Expr(..)
      | @vibe_core.Stmt::Assign(..)
      | @vibe_core.Stmt::IndexAssign(..)
      | @vibe_core.Stmt::LetPat(..)
      | @vibe_core.Stmt::LetPatElse(..) =>
        if not(library_mode) {
          out.push(stmt)
        }
      _ => out.push(stmt)
    }
  }
  out
}

///|
fn merge_render_deduped(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> String {
  let out = StringBuilder::new()
  for stmt in stmts {
    match merge_render_stmt_fallback(stmt) {
      Some(rendered) => {
        out.write_string(rendered)
        if not(rendered.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
      None => {
        let span = stmt.span()
        let snippet = normalize_source_slice_by_span(
          source, span.start, span.end,
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
  out.to_string()
}

///|
fn normalize_merge_sources(
  sources : Array[String],
  library_mode : Bool,
) -> Result[String, String] {
  // [1] Concatenate all sources
  let buf = StringBuilder::new()
  for i, src in sources {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(src)
  }
  let combined = buf.to_string()
  // [2] Parse
  let ast = @parser.parse_ast(combined) catch {
    e => return Err("merge: parse failed: " + e.to_string())
  }
  // [3] Dedup (last wins)
  let deduped = merge_dedup_stmts(ast.stmts)
  // [4] Prefilter (library mode)
  let filtered = merge_prefilter_stmts(deduped, library_mode)
  // [5] Render from source spans
  let rendered = merge_render_deduped(combined, filtered)
  if rendered.trim().to_string().length() == 0 {
    return Err("merge: no statements kept after dedup")
  }
  // [6] Normalize
  normalize_source_text(rendered)
}
