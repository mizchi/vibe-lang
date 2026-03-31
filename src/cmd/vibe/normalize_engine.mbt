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
  normalize_source_text_with_entry_names(source, [])
}

///|
fn normalize_source_text_with_entry_names(
  source : String,
  entry_names : Array[String],
) -> Result[String, String] {
  normalize_source_text_with_entry_names_internal(source, entry_names, false)
}

///|
fn normalize_source_text_with_entry_names_internal(
  source : String,
  entry_names : Array[String],
  drop_effectful_expr_stmts : Bool,
) -> Result[String, String] {
  let engine = NormalizeEngine::new()
  engine.set_source("__source__", source)
  let normalized = engine.normalize("__source__")
  match normalized {
    Ok(_) =>
      // Entry-based normalize has custom selection and cannot be served by cache output.
      normalize_source_text_flat_with_entry_names_internal(
        source, entry_names, drop_effectful_expr_stmts,
      )
    Err(err) => Err(err)
  }
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
  normalize_source_text_flat_with_entry_names(out.to_string(), [])
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
fn normalize_filter_top_level_expr_stmts(
  stmts : Array[@vibe_core.Stmt],
  env : @checker.TypeEnv,
  drop_effectful_expr_stmts : Bool,
) -> Array[@vibe_core.Stmt] {
  let out : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::Expr(expr~, ..) =>
        if @checker.purity_expr(env, expr) {
          ()
        } else if not(drop_effectful_expr_stmts) {
          out.push(stmt)
        }
      _ => out.push(stmt)
    }
  }
  out
}

///|
fn normalize_source_text_flat(source : String) -> Result[String, String] {
  normalize_source_text_flat_with_entry_names_internal(source, [], false)
}

///|
fn normalize_source_text_flat_with_entry_names(
  source : String,
  entry_names : Array[String],
) -> Result[String, String] {
  normalize_source_text_flat_with_entry_names_internal(
    source, entry_names, false,
  )
}

///|
fn pass_parse(source : String) -> Result[@vibe_core.Module, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("normalize: parse failed: " + e.to_string())
  }
  Ok(ast)
}

///|
fn pass_select_and_dedup(
  mod_ : @vibe_core.Module,
  entry_names : Array[String],
) -> Array[@vibe_core.Stmt] {
  let selected = normalize_select_stmts(mod_, entry_names)
  let entry_roots = normalize_collect_normalize_entry_names(mod_, entry_names)
  let selected_with_export = normalize_append_entry_export_stmt(
    selected, entry_roots,
  )
  merge_dedup_stmts(selected_with_export)
}

///|
fn pass_typecheck_and_filter(
  sorted : Array[@vibe_core.Stmt],
  entry_names : Array[String],
  drop_effectful_expr_stmts : Bool,
) -> Array[@vibe_core.Stmt] {
  let mod_ = @vibe_core.Module::{ stmts: sorted }
  let env = @checker.type_check(mod_) catch { _ => @checker.TypeEnv::new() }
  let filtered = normalize_filter_top_level_expr_stmts(
    sorted, env, drop_effectful_expr_stmts,
  )
  if filtered.length() == sorted.length() {
    sorted
  } else {
    let filtered_module = @vibe_core.Module::{ stmts: filtered }
    let reselected = pass_select_and_dedup(filtered_module, entry_names)
    normalize_sort_stmts(reselected)
  }
}

///|
fn pass_annotate(
  stmts : Array[@vibe_core.Stmt],
) -> (@checker.TypeEnv, Map[String, String]) {
  let mod_ = @vibe_core.Module::{ stmts, }
  let env = @checker.type_check(mod_) catch { _ => @checker.TypeEnv::new() }
  let annotations = normalize_collect_inferred_annotations(mod_, env)
  (env, annotations)
}

///|
fn pass_render(
  quickfixed_source : String,
  sorted : Array[@vibe_core.Stmt],
  rewritten_exprs : Map[String, @vibe_core.Expr],
  inferred_annotations : Map[String, String],
  env : @checker.TypeEnv,
) -> Result[String, String] {
  normalize_render_source(
    quickfixed_source, sorted, rewritten_exprs, inferred_annotations, env,
  )
}

///|
fn normalize_is_synthetic_trait_impl(
  source : String,
  stmt : @vibe_core.Stmt,
) -> Bool {
  match stmt {
    @vibe_core.Stmt::TraitImpl(span~, ..) => {
      let snippet = normalize_source_slice_by_span(source, span.start, span.end)
        .trim()
        .to_string()
      not(snippet.has_prefix("impl "))
    }
    _ => false
  }
}

///|
fn normalize_filter_synthetic_trait_impls(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> Array[@vibe_core.Stmt] {
  let out : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    if not(normalize_is_synthetic_trait_impl(source, stmt)) {
      out.push(stmt)
    }
  }
  out
}

///|
fn pass_validate(
  source : String,
  rendered : String,
  expected_stmts : Array[@vibe_core.Stmt],
) -> Result[Unit, String] {
  let formatted = @parser.format_script(rendered)
  let reparsed_raw = @parser.parse_ast(formatted) catch {
    e => return Err("normalize: rendered parse failed: " + e.to_string())
  }
  let reparsed = @vibe_core.Module::{
    stmts: normalize_filter_synthetic_trait_impls(formatted, reparsed_raw.stmts),
  }
  let expected = @vibe_core.Module::{
    stmts: normalize_filter_synthetic_trait_impls(source, expected_stmts),
  }
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
  let reparsed_param_stripped = normalize_strip_all_fn_param_types_module(
    reparsed_canonical,
  )
  let expected_param_stripped = normalize_strip_all_fn_param_types_module(
    expected_canonical,
  )
  let reparsed_semantic = normalize_strip_fn_return_annotations_module(
    reparsed_param_stripped,
  )
  let expected_semantic = normalize_strip_fn_return_annotations_module(
    expected_param_stripped,
  )
  let reparsed_import_canonical = normalize_canonicalize_import_surface_module(
    reparsed_semantic,
  )
  let expected_import_canonical = normalize_canonicalize_import_surface_module(
    expected_semantic,
  )
  let norm_reparsed = @vibe_core.normalize_module(reparsed_import_canonical)
  let norm_expected = @vibe_core.normalize_module(expected_import_canonical)
  if norm_reparsed != norm_expected {
    println("=== REPARSED ===")
    println(norm_reparsed)
    println("=== EXPECTED ===")
    println(norm_expected)
    println("=== FORMATTED ===")
    println(formatted)
    println("=== END ===")
    return Err("normalize: rendered source changed semantics")
  }
  Ok(())
}

///|
fn normalize_source_text_flat_with_entry_names_internal(
  source : String,
  entry_names : Array[String],
  drop_effectful_expr_stmts : Bool,
) -> Result[String, String] {
  // Pass 1: Grammar quickfix
  let quickfixed = normalize_apply_grammar_quickfixes(source)
  // Pass 2: Parse
  let ast = match pass_parse(quickfixed) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Pass 3: Optimize
  let optimized = normalize_optimize_module(ast)
  // Pass 4: Select + dedup
  let selected = pass_select_and_dedup(optimized.normalized_module, entry_names)
  // Pass 5: Sort
  let sorted = normalize_sort_stmts(selected)
  if sorted.length() == 0 {
    return Ok("")
  }
  // Pass 6: Typecheck + filter + re-sort
  let final_sorted = pass_typecheck_and_filter(
    sorted, entry_names, drop_effectful_expr_stmts,
  )
  if final_sorted.length() == 0 {
    return Ok("")
  }
  // Pass 7: Annotate
  let (env, annotations) = pass_annotate(final_sorted)
  let render_sorted = normalize_filter_synthetic_trait_impls(
    quickfixed, final_sorted,
  )
  // Pass 8: Render
  let rendered = match
    pass_render(
      quickfixed,
      render_sorted,
      optimized.rewritten_exprs,
      annotations,
      env,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Pass 9: Validate
  match pass_validate(quickfixed, rendered, final_sorted) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // Pass 10: Signature comments
  let with_comments = normalize_inject_signature_comments(rendered, env)
  Ok(with_comments)
}

///|
/// Strip all Fn parameter types in Let/ExportLet for semantic comparison.
/// This ensures old-style `(x: Int) -> Int { ... }` and new-style
/// `(x, y) -> { ... }` (with separate type annotation) compare as equal.
fn normalize_strip_all_fn_param_types_module(
  m : @vibe_core.Module,
) -> @vibe_core.Module {
  let next : Array[@vibe_core.Stmt] = []
  for stmt in m.stmts {
    next.push(normalize_strip_all_fn_param_types_stmt(stmt))
  }
  @vibe_core.Module::{ stmts: next }
}

///|
fn normalize_strip_all_fn_param_types_stmt(
  stmt : @vibe_core.Stmt,
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::Let(
        rec~,
        name~,
        expr=normalize_strip_all_fn_param_types_expr(expr),
        span~,
      )
    @vibe_core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::ExportLet(
        rec~,
        name~,
        expr=normalize_strip_all_fn_param_types_expr(expr),
        span~,
      )
    _ => stmt
  }
}

///|
fn normalize_strip_all_fn_param_types_expr(
  expr : @vibe_core.Expr,
) -> @vibe_core.Expr {
  match expr {
    @vibe_core.Expr::Fn(type_params~, type_bounds~, params~, body~, span~, ..) =>
      if type_params.length() > 0 || type_bounds.length() > 0 {
        expr
      } else {
        let next_params : Array[@vibe_core.FuncParam] = []
        for param in params {
          next_params.push(@vibe_core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: @vibe_core.Type::Unit,
            bounds: [],
          })
        }
        @vibe_core.Expr::Fn(
          type_params~,
          type_bounds~,
          params=next_params,
          ret=None,
          effects=[],
          body~,
          span~,
        )
      }
    _ => expr
  }
}

///|
fn normalize_strip_fn_return_annotations_module(
  m : @vibe_core.Module,
) -> @vibe_core.Module {
  let next : Array[@vibe_core.Stmt] = []
  for stmt in m.stmts {
    next.push(normalize_strip_fn_return_annotations_stmt(stmt))
  }
  @vibe_core.Module::{ stmts: next }
}

///|
fn normalize_strip_fn_return_annotations_stmt(
  stmt : @vibe_core.Stmt,
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::Let(
        rec~,
        name~,
        expr=normalize_strip_fn_return_annotations_expr(expr),
        span~,
      )
    @vibe_core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::ExportLet(
        rec~,
        name~,
        expr=normalize_strip_fn_return_annotations_expr(expr),
        span~,
      )
    @vibe_core.Stmt::LetMut(name~, expr~, span~) =>
      @vibe_core.Stmt::LetMut(
        name~,
        expr=normalize_strip_fn_return_annotations_expr(expr),
        span~,
      )
    _ => stmt
  }
}

///|
fn normalize_strip_fn_return_annotations_expr(
  expr : @vibe_core.Expr,
) -> @vibe_core.Expr {
  match expr {
    @vibe_core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret=_,
      effects~,
      body~,
      span~
    ) =>
      if type_params.length() > 0 || type_bounds.length() > 0 {
        expr
      } else {
        @vibe_core.Expr::Fn(
          type_params~,
          type_bounds~,
          params~,
          ret=None,
          effects~,
          body~,
          span~,
        )
      }
    _ => expr
  }
}

///|
fn normalize_canonicalize_import_surface_module(
  m : @vibe_core.Module,
) -> @vibe_core.Module {
  let next : Array[@vibe_core.Stmt] = []
  for stmt in m.stmts {
    next.push(normalize_canonicalize_import_surface_stmt(stmt))
  }
  @vibe_core.Module::{ stmts: next }
}

///|
fn normalize_canonicalize_import_surface_stmt(
  stmt : @vibe_core.Stmt,
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::Import(spec~, source~, span~) =>
      @vibe_core.Stmt::Import(
        spec=normalize_canonicalize_import_spec(spec),
        source=normalize_canonicalize_module_ref(source),
        span~,
      )
    @vibe_core.Stmt::ReExport(spec~, source~, span~) =>
      @vibe_core.Stmt::ReExport(
        spec=normalize_canonicalize_import_spec(spec),
        source=normalize_canonicalize_module_ref(source),
        span~,
      )
    @vibe_core.Stmt::Test(name~, body~, span~) =>
      @vibe_core.Stmt::Test(
        name~,
        body=normalize_canonicalize_import_surface_module(body),
        span~,
      )
    @vibe_core.Stmt::Bench(name~, body~, span~) =>
      @vibe_core.Stmt::Bench(
        name~,
        body=normalize_canonicalize_import_surface_module(body),
        span~,
      )
    _ => stmt
  }
}

///|
fn normalize_canonicalize_import_spec(
  spec : @vibe_core.ImportSpec,
) -> @vibe_core.ImportSpec {
  let items : Array[@vibe_core.ImportItem] = []
  for item in spec.items {
    let rename = match item.rename {
      Some(v) => if v == item.name { None } else { Some(v) }
      None => None
    }
    items.push(@vibe_core.ImportItem::{
      kind: item.kind,
      name: item.name,
      rename,
    })
  }
  items.sort_by(fn(a, b) { normalize_import_item_compare(a, b) })
  @vibe_core.ImportSpec::{ items: normalize_disambiguate_import_items(items) }
}

///|
fn normalize_string_compare(a : String, b : String) -> Int {
  let min_len = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < min_len; i = i + 1 {
    let ac = a[i].to_int()
    let bc = b[i].to_int()
    if ac != bc {
      return ac - bc
    }
  }
  a.length() - b.length()
}

///|
fn normalize_import_kind_rank(kind : @vibe_core.ImportKind) -> Int {
  match kind {
    @vibe_core.ImportKind::Value => 0
    @vibe_core.ImportKind::Type => 1
    @vibe_core.ImportKind::Trait => 2
    @vibe_core.ImportKind::Module => 3
    @vibe_core.ImportKind::Struct => 4
    @vibe_core.ImportKind::Effect => 5
    @vibe_core.ImportKind::Suberror => 6
  }
}

///|
fn normalize_import_item_compare(
  left : @vibe_core.ImportItem,
  right : @vibe_core.ImportItem,
) -> Int {
  let kind_cmp = normalize_import_kind_rank(left.kind) -
    normalize_import_kind_rank(right.kind)
  if kind_cmp != 0 {
    return kind_cmp
  }
  let name_cmp = normalize_string_compare(left.name, right.name)
  if name_cmp != 0 {
    return name_cmp
  }
  let left_local = match left.rename {
    Some(name) => name
    None => left.name
  }
  let right_local = match right.rename {
    Some(name) => name
    None => right.name
  }
  normalize_string_compare(left_local, right_local)
}

///|
fn normalize_import_item_local_name(item : @vibe_core.ImportItem) -> String {
  match item.rename {
    Some(name) => name
    None => item.name
  }
}

///|
fn normalize_import_item_accepts_value(item : @vibe_core.ImportItem) -> Bool {
  item.kind == @vibe_core.ImportKind::Value ||
  (item.kind == @vibe_core.ImportKind::Type && item.name.contains("::"))
}

///|
fn normalize_disambiguate_import_items(
  items : Array[@vibe_core.ImportItem],
) -> Array[@vibe_core.ImportItem] {
  let used : Map[String, Int] = {}
  let out : Array[@vibe_core.ImportItem] = []
  for item in items {
    if not(normalize_import_item_accepts_value(item)) {
      out.push(item)
      continue
    }
    let local_name = normalize_import_item_local_name(item)
    match used.get(local_name) {
      None => {
        used[local_name] = 1
        out.push(item)
      }
      Some(existing_count) => {
        let mut next_index = existing_count + 1
        let mut next_alias = local_name + "_" + next_index.to_string()
        while used.contains(next_alias) {
          next_index += 1
          next_alias = local_name + "_" + next_index.to_string()
        }
        used[local_name] = next_index
        used[next_alias] = 1
        out.push(@vibe_core.ImportItem::{
          kind: item.kind,
          name: item.name,
          rename: Some(next_alias),
        })
      }
    }
  }
  out
}

///|
fn normalize_canonicalize_import_path(path : String) -> String {
  let is_abs = path.has_prefix("/")
  let had_dot_prefix = path.has_prefix("./")
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if not(is_abs) {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let joined = parts.join("/")
  let normalized = if is_abs { "/" + joined } else { joined }
  let without_index = if normalized.has_suffix("/index.vibe") {
    normalized.unsafe_substring(
      start=0,
      end=normalized.length() - "/index.vibe".length(),
    )
  } else {
    normalized
  }
  if had_dot_prefix &&
    not(without_index.has_prefix("./")) &&
    not(without_index.has_prefix("../")) &&
    not(without_index.has_prefix("/")) {
    "./" + without_index
  } else {
    without_index
  }
}

///|
fn normalize_canonicalize_module_ref(
  source : @vibe_core.ModuleRef,
) -> @vibe_core.ModuleRef {
  match source {
    @vibe_core.ModuleRef::Path(path~) =>
      @vibe_core.ModuleRef::Path(path=normalize_canonicalize_import_path(path))
    _ => source
  }
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
fn merge_dedup_stmts(stmts : Array[@vibe_core.Stmt]) -> Array[@vibe_core.Stmt] {
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
    @vibe_core.Stmt::Export(names~, ..) =>
      Some("export { " + names.join(", ") + " }")
    @vibe_core.Stmt::ReExport(spec~, source~, ..) => {
      let canonical_spec = normalize_canonicalize_import_spec(spec)
      let src = match source {
        @vibe_core.ModuleRef::Path(path~) => path
        @vibe_core.ModuleRef::Hash(hash~) => "#" + hash
        @vibe_core.ModuleRef::Version(name~) => "version@" + name
        @vibe_core.ModuleRef::Symbol(name~) => "symbol@" + name
        @vibe_core.ModuleRef::Alias(name~) => "@" + name
        @vibe_core.ModuleRef::PinnedPath(path~, hash~) => path + "#" + hash
      }
      let rendered_items : Array[String] = []
      for item in canonical_spec.items {
        let rendered = StringBuilder::new()
        match item.kind {
          @vibe_core.ImportKind::Value => ()
          @vibe_core.ImportKind::Type => rendered.write_string("type ")
          @vibe_core.ImportKind::Trait => rendered.write_string("trait ")
          @vibe_core.ImportKind::Module => rendered.write_string("module ")
          @vibe_core.ImportKind::Struct => rendered.write_string("struct ")
          @vibe_core.ImportKind::Effect => rendered.write_string("effect ")
          @vibe_core.ImportKind::Suberror => rendered.write_string("suberror ")
        }
        rendered.write_string(item.name)
        match item.rename {
          Some(rename_name) =>
            if rename_name != item.name {
              rendered.write_string(" as ")
              rendered.write_string(rename_name)
            }
          None => ()
        }
        rendered_items.push(rendered.to_string())
      }
      Some("export " + src + " { " + rendered_items.join(", ") + " }")
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
  out.to_string()
}

///|
pub fn normalize_merge_sources(
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
