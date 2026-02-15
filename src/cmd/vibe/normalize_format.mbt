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
  let normalized = @vibe_fs.normalize_path(path)
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
    normalized.has_suffix("/vibe/std/cmp.vibe") ||
    normalized.has_suffix("/vibe/std/char.vibe") ||
    normalized.has_suffix("/vibe/std/int.vibe") ||
    normalized.has_suffix("/vibe/std/float.vibe") ||
    normalized.has_suffix("/vibe/std/double.vibe") ||
    normalized.has_suffix("/vibe/std/string.vibe") {
    return Some(StdModuleLayer::PurePrimitive)
  }
  if normalized.has_suffix("/vibe/std/array.vibe") ||
    normalized.has_suffix("/vibe/std/option.vibe") ||
    normalized.has_suffix("/vibe/std/result.vibe") ||
    normalized.has_suffix("/vibe/std/bytes.vibe") ||
    normalized.has_suffix("/vibe/std/threads/spec.vibe") {
    return Some(StdModuleLayer::PureData)
  }
  if normalized.has_suffix("/vibe/std/path/ref.vibe") ||
    normalized.has_suffix("/vibe/std/path.vibe") {
    return Some(StdModuleLayer::RefModel)
  }
  if normalized.has_suffix("/vibe/std/io.vibe") ||
    normalized.has_suffix("/vibe/std/path/runtime.vibe") ||
    normalized.has_suffix("/vibe/std/threads/runtime.vibe") ||
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
