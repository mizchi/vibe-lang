///|
fn std_layer_name(layer : StdModuleLayer) -> String {
  match layer {
    StdModuleLayer::TraitContract => "trait-contract"
    StdModuleLayer::PurePrimitive => "pure-primitive"
    StdModuleLayer::PureData => "pure-data"
    StdModuleLayer::RefModel => "ref-model"
    StdModuleLayer::EffectBoundary => "effect-boundary"
  }
}

///|
fn std_layer_for_path(path : String) -> StdModuleLayer? {
  let normalized = @vibe_fs.normalize_path(path)
  if (
      not(normalized.contains("/vibe/prelude/")) &&
      not(normalized.contains("/vibe/path/"))
    ) ||
    not(normalized.has_suffix(".vibe")) ||
    normalized.has_suffix("_test.vibe") ||
    normalized.has_suffix("_type_import_test.vibe") ||
    normalized.has_suffix("/test_import.vibe") {
    return None
  }
  if normalized.has_suffix("/vibe/prelude/builtin_traits.vibe") {
    return Some(StdModuleLayer::TraitContract)
  }
  if normalized.has_suffix("/vibe/prelude/bool.vibe") ||
    normalized.has_suffix("/vibe/prelude/cmp.vibe") ||
    normalized.has_suffix("/vibe/prelude/char.vibe") ||
    normalized.has_suffix("/vibe/prelude/int.vibe") ||
    normalized.has_suffix("/vibe/prelude/float.vibe") ||
    normalized.has_suffix("/vibe/prelude/double.vibe") ||
    normalized.has_suffix("/vibe/prelude/string.vibe") {
    return Some(StdModuleLayer::PurePrimitive)
  }
  if normalized.has_suffix("/vibe/prelude/array.vibe") ||
    normalized.has_suffix("/vibe/prelude/option.vibe") ||
    normalized.has_suffix("/vibe/prelude/result.vibe") ||
    normalized.has_suffix("/vibe/prelude/bytes.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads/spec.vibe") {
    return Some(StdModuleLayer::PureData)
  }
  if normalized.has_suffix("/vibe/path/ref.vibe") {
    return Some(StdModuleLayer::RefModel)
  }
  if normalized.has_suffix("/vibe/prelude/io.vibe") ||
    normalized.has_suffix("/vibe/path/runtime.vibe") ||
    normalized.has_suffix("/vibe/path/index.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads/runtime.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads.vibe") {
    return Some(StdModuleLayer::EffectBoundary)
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
    StdModuleLayer::EffectBoundary => true
  }
}

///|
fn std_collect_direct_import_paths(
  ast : @vibe_core.Module,
  base_dir : String,
) -> Array[String] {
  let imports : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(source~, ..)
      | @vibe_core.Stmt::ReExport(source~, ..) =>
        match source {
          @vibe_core.ModuleRef::Path(path=raw_path) =>
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
  let base_dir = @vibe_fs.parent_path(path)
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
fn railway_is_unwrap_call(name : String) -> Bool {
  name == "unwrap" || name.has_suffix("::unwrap")
}

///|
fn railway_collect_module_boundaries(
  m : @vibe_core.Module,
  stats : Array[Int],
) -> Unit {
  for stmt in m.stmts {
    railway_collect_stmt_boundaries(stmt, stats)
  }
}

///|
fn railway_collect_stmt_boundaries(
  stmt : @vibe_core.Stmt,
  stats : Array[Int],
) -> Unit {
  match stmt {
    @vibe_core.Stmt::Expr(expr~, ..) =>
      railway_collect_expr_boundaries(expr, stats)
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..) =>
      railway_collect_expr_boundaries(expr, stats)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      railway_collect_expr_boundaries(expr, stats)
      railway_collect_module_boundaries(else_body, stats)
    }
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      railway_collect_expr_boundaries(target, stats)
      railway_collect_expr_boundaries(index, stats)
      railway_collect_expr_boundaries(value, stats)
    }
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      railway_collect_module_boundaries(body, stats)
    _ => ()
  }
}

///|
fn railway_collect_expr_boundaries(
  expr : @vibe_core.Expr,
  stats : Array[Int],
) -> Unit {
  match expr {
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      stats[0] = stats[0] + 1
      railway_collect_module_boundaries(body, stats)
      for arm in arms {
        match arm.cond {
          Some(c) => railway_collect_expr_boundaries(c, stats)
          None => ()
        }
        railway_collect_expr_boundaries(arm.expr, stats)
      }
    }
    @vibe_core.Expr::Perform(effect_name="Error", op_name="Throw", args~, ..) => {
      stats[1] = stats[1] + 1
      for arg in args {
        railway_collect_expr_boundaries(arg.expr, stats)
      }
    }
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if railway_is_unwrap_call(name) {
        stats[2] = stats[2] + 1
      }
      for arg in args {
        railway_collect_expr_boundaries(arg.expr, stats)
      }
    }
    @vibe_core.Expr::Fn(body~, ..) =>
      railway_collect_module_boundaries(body, stats)
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) => {
      railway_collect_expr_boundaries(cond, stats)
      railway_collect_module_boundaries(then_body, stats)
      railway_collect_module_boundaries(else_body, stats)
    }
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      railway_collect_expr_boundaries(scrutinee, stats)
      for arm in arms {
        match arm.cond {
          Some(c) => railway_collect_expr_boundaries(c, stats)
          None => ()
        }
        railway_collect_expr_boundaries(arm.expr, stats)
      }
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) => {
      railway_collect_expr_boundaries(iterable, stats)
      railway_collect_module_boundaries(body, stats)
    }
    @vibe_core.Expr::While(cond~, body~, ..) => {
      railway_collect_expr_boundaries(cond, stats)
      railway_collect_module_boundaries(body, stats)
    }
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        railway_collect_expr_boundaries(p.init, stats)
      }
      railway_collect_module_boundaries(body, stats)
    }
    @vibe_core.Expr::Tuple(items~, ..) | @vibe_core.Expr::Array(items~, ..) =>
      for item in items {
        railway_collect_expr_boundaries(item, stats)
      }
    @vibe_core.Expr::TupleIndex(expr=inner, ..)
    | @vibe_core.Expr::Yield(expr=inner, ..) =>
      railway_collect_expr_boundaries(inner, stats)
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => railway_collect_expr_boundaries(v, stats)
        None => ()
      }
    @vibe_core.Expr::Continue(args~, ..) =>
      for a in args {
        railway_collect_expr_boundaries(a, stats)
      }
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        railway_collect_expr_boundaries(f.expr, stats)
      }
    @vibe_core.Expr::Map(fields~, ..) =>
      for f in fields {
        railway_collect_expr_boundaries(f.expr, stats)
      }
    @vibe_core.Expr::Block(body~, ..) =>
      railway_collect_module_boundaries(body, stats)
    _ => ()
  }
}

///|
pub fn railway_boundary_notes_for_source(source : String) -> Array[String] {
  let ast = @parser.parse_ast(source) catch { _ => return [] }
  let stats : Array[Int] = [0, 0, 0]
  railway_collect_module_boundaries(ast, stats)
  let handle_count = stats[0]
  let throw_count = stats[1]
  let unwrap_count = stats[2]
  let notes : Array[String] = []
  if handle_count == 0 && throw_count == 0 && unwrap_count == 0 {
    return notes
  }
  notes.push(
    "railway boundaries: handle=" +
    handle_count.to_string() +
    " throw=" +
    throw_count.to_string() +
    " unwrap=" +
    unwrap_count.to_string(),
  )
  if unwrap_count > 0 {
    notes.push(
      "railway warning: unwrap is a terminal boundary; keep pipeline core in Result composition and isolate unwrap at edges",
    )
  }
  if throw_count > 0 && handle_count == 0 {
    notes.push(
      "railway warning: throw appears without local handle; make boundary explicit at caller with handle",
    )
  }
  notes
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
  let formatted = @parser.format_script(normalized)
  let stripped = strip_redundant_blocks_source(formatted)
  Ok(@parser.format_script(stripped))
}

///|
fn normalize_next_non_trivia_token_index(
  tokens : Array[@parser.Token],
  start : Int,
) -> Int? {
  let mut i = start
  while i < tokens.length() {
    if not(@parser.is_trivia(tokens[i].kind())) {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
fn normalize_trim_label_arg_suffix(label : String) -> String? {
  let chars = label.to_array()
  if chars.length() <= 1 {
    return None
  }
  let last = chars[chars.length() - 1]
  if last != '~' && last != '?' {
    return None
  }
  let out = StringBuilder::new()
  for i in 0..<(chars.length() - 1) {
    out.write_char(chars[i])
  }
  let base = out.to_string()
  if base.is_empty() {
    None
  } else {
    Some(base)
  }
}

///|
fn normalize_kind_can_start_call(kind : @cst.SyntaxKind?) -> Bool {
  match kind {
    Some(k) =>
      k == @parser.name() ||
      k == @parser.rparen() ||
      k == @parser.rbracket() ||
      k == @parser.rbrace() ||
      k == @parser.int_lit() ||
      k == @parser.string_lit() ||
      k == @parser.string_interp_lit() ||
      k == @parser.char_lit() ||
      k == @parser.float_lit() ||
      k == @parser.bool_lit()
    None => false
  }
}

///|
fn normalize_apply_grammar_quickfixes(source : String) -> String {
  let tokens = @parser.tokenize(source)
  if tokens.length() == 0 {
    return source
  }
  let out = StringBuilder::new()
  let mut cursor = 0
  let call_paren_stack : Array[Bool] = []
  let mut prev_non_trivia_kind : @cst.SyntaxKind? = None
  let mut decl_pending = false
  let mut decl_brace_depth = 0
  let mut decl_paren_depth = 0
  let mut decl_bracket_depth = 0
  for i, tok in tokens {
    let kind = tok.kind()
    let text = tok.text()
    let width = tok.width()
    let end = if cursor + width > source.length() {
      source.length()
    } else {
      cursor + width
    }
    let raw_text = source.unsafe_substring(start=cursor, end~)
    let mut rewritten = raw_text
    let in_decl_block = decl_brace_depth > 0
    if in_decl_block &&
      kind == @parser.comma() &&
      decl_brace_depth == 1 &&
      decl_paren_depth == 0 &&
      decl_bracket_depth == 0 {
      rewritten = ";"
    }
    let in_call_args = call_paren_stack.length() > 0 &&
      call_paren_stack[call_paren_stack.length() - 1]
    if in_call_args && kind == @parser.name() {
      match normalize_next_non_trivia_token_index(tokens, i + 1) {
        Some(next_idx) if tokens[next_idx].kind() == @parser.eq() =>
          match normalize_trim_label_arg_suffix(text) {
            Some(base) => rewritten = base
            None => ()
          }
        _ => ()
      }
    }
    out.write_string(rewritten)
    if decl_brace_depth == 0 {
      if decl_pending {
        if kind == @parser.lbrace() {
          decl_brace_depth = 1
          decl_paren_depth = 0
          decl_bracket_depth = 0
          decl_pending = false
        } else if kind == @parser.lparen() ||
          kind == @parser.semicolon() ||
          kind == @parser.eof() {
          decl_pending = false
        }
      } else if kind == @parser.enum_kw() ||
        kind == @parser.struct_kw() ||
        (kind == @parser.name() && text == "suberror") {
        decl_pending = true
      }
    } else if kind == @parser.lbrace() {
      decl_brace_depth += 1
    } else if kind == @parser.rbrace() {
      decl_brace_depth -= 1
    } else if kind == @parser.lparen() {
      decl_paren_depth += 1
    } else if kind == @parser.rparen() {
      if decl_paren_depth > 0 {
        decl_paren_depth -= 1
      }
    } else if kind == @parser.lbracket() {
      decl_bracket_depth += 1
    } else if kind == @parser.rbracket() {
      if decl_bracket_depth > 0 {
        decl_bracket_depth -= 1
      }
    }
    if kind == @parser.lparen() {
      call_paren_stack.push(normalize_kind_can_start_call(prev_non_trivia_kind))
    } else if kind == @parser.rparen() {
      if call_paren_stack.length() > 0 {
        let _ = call_paren_stack.pop()
      }
    }
    if not(@parser.is_trivia(kind)) {
      prev_non_trivia_kind = Some(kind)
    }
    cursor = end
  }
  out.to_string()
}

///|
struct RedundantBlockSpan {
  block_start : Int
  block_end : Int
  inner_start : Int
  inner_end : Int
}

///|
fn collect_rb_module(
  m : @vibe_core.Module,
  out : Array[RedundantBlockSpan],
) -> Unit {
  for stmt in m.stmts {
    collect_rb_stmt(stmt, out)
  }
}

///|
fn collect_rb_stmt(
  stmt : @vibe_core.Stmt,
  out : Array[RedundantBlockSpan],
) -> Unit {
  match stmt {
    @vibe_core.Stmt::Expr(expr~, ..) => collect_rb_expr(expr, out)
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..) => collect_rb_expr(expr, out)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      collect_rb_expr(expr, out)
      collect_rb_module(else_body, out)
    }
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      collect_rb_expr(target, out)
      collect_rb_expr(index, out)
      collect_rb_expr(value, out)
    }
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      collect_rb_module(body, out)
    _ => ()
  }
}

///|
fn collect_rb_expr(
  expr : @vibe_core.Expr,
  out : Array[RedundantBlockSpan],
) -> Unit {
  match expr {
    @vibe_core.Expr::Block(body~, span~) => {
      collect_rb_module(body, out)
      match body.stmts {
        [@vibe_core.Stmt::Expr(span=stmt_span, ..)] =>
          out.push({
            block_start: span.start,
            block_end: span.end,
            inner_start: stmt_span.start,
            inner_end: stmt_span.end,
          })
        _ => ()
      }
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_rb_expr(cond, out)
      collect_rb_module(then_body, out)
      collect_rb_module(else_body, out)
    }
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_rb_expr(scrutinee, out)
      for arm in arms {
        match arm.cond {
          Some(c) => collect_rb_expr(c, out)
          None => ()
        }
        collect_rb_expr(arm.expr, out)
      }
    }
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      collect_rb_module(body, out)
      for arm in arms {
        match arm.cond {
          Some(c) => collect_rb_expr(c, out)
          None => ()
        }
        collect_rb_expr(arm.expr, out)
      }
    }
    @vibe_core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_rb_expr(arg.expr, out)
      }
    @vibe_core.Expr::Fn(body~, ..) => collect_rb_module(body, out)
    @vibe_core.Expr::ForIn(iterable~, body~, ..) => {
      collect_rb_expr(iterable, out)
      collect_rb_module(body, out)
    }
    @vibe_core.Expr::While(cond~, body~, ..) => {
      collect_rb_expr(cond, out)
      collect_rb_module(body, out)
    }
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        collect_rb_expr(p.init, out)
      }
      collect_rb_module(body, out)
    }
    @vibe_core.Expr::Tuple(items~, ..) | @vibe_core.Expr::Array(items~, ..) =>
      for item in items {
        collect_rb_expr(item, out)
      }
    @vibe_core.Expr::TupleIndex(expr=inner, ..)
    | @vibe_core.Expr::Yield(expr=inner, ..) => collect_rb_expr(inner, out)
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => collect_rb_expr(v, out)
        None => ()
      }
    @vibe_core.Expr::Continue(args~, ..) =>
      for a in args {
        collect_rb_expr(a, out)
      }
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        collect_rb_expr(f.expr, out)
      }
    @vibe_core.Expr::Map(fields~, ..) =>
      for f in fields {
        collect_rb_expr(f.expr, out)
      }
    _ => ()
  }
}

///|
fn strip_redundant_blocks_once(source : String) -> String {
  let ast = @parser.parse_ast(source) catch { _ => return source }
  let blocks : Array[RedundantBlockSpan] = []
  collect_rb_module(ast, blocks)
  if blocks.is_empty() {
    return source
  }
  blocks.sort_by(fn(a, b) { a.block_start - b.block_start })
  let out = StringBuilder::new()
  let mut cursor = 0
  for b in blocks {
    if b.block_start < cursor {
      continue
    }
    out.write_string(source.unsafe_substring(start=cursor, end=b.block_start))
    out.write_string(
      source.unsafe_substring(start=b.inner_start, end=b.inner_end),
    )
    cursor = b.block_end
  }
  if cursor < source.length() {
    out.write_string(source.unsafe_substring(start=cursor, end=source.length()))
  }
  out.to_string()
}

///|
fn strip_redundant_blocks_source(source : String) -> String {
  let mut current = source
  let mut i = 0
  while i < 10 {
    let next = strip_redundant_blocks_once(current)
    if next == current {
      break
    }
    current = next
    i += 1
  }
  current
}
