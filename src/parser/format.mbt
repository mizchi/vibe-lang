///|
/// Formatter for vibe based on CST

///|
enum ContainerKind {
  BraceBlock
  BraceRecord
  BraceMap
  BraceMatch
  BraceEnum
  BraceEffects
  BracketArray
  BracketTypeArgs
  BracketIndex
} derive(Debug, Eq)

///|
struct MatchPending {
  paren : Int
  brace : Int
  bracket : Int
} derive(Debug, Eq)

///|
enum TypeDeclMode {
  DeclNone
  DeclTypeAlias
  DeclEnum
} derive(Debug, Eq)

///|
struct TypeContext {
  paren : Int
  brace : Int
  bracket : Int
} derive(Debug, Eq)

///|
pub fn format_script(script : String) -> String {
  format_script_with_indent(script, 2)
}

///|
pub fn format_script_with_indent(script : String, indent_size : Int) -> String {
  let root = parse_cst(script)
  let tokens : Array[@cst.SyntaxToken] = []
  collect_tokens(root, tokens)
  format_tokens(tokens, indent_size)
}

///|
fn collect_tokens(
  node : @cst.SyntaxNode,
  out : Array[@cst.SyntaxToken],
) -> Unit {
  for child in node.children() {
    match child.as_token() {
      Some(tok) => out.push(tok)
      None =>
        match child.as_node() {
          Some(next) => collect_tokens(next, out)
          None => ()
        }
    }
  }
}

///|
fn format_tokens(tokens : Array[@cst.SyntaxToken], indent_size : Int) -> String {
  let buf = StringBuilder::new()
  let mut indent = 0
  let mut pending_newlines = 0
  let container_stack : Array[ContainerKind] = []
  let container_paren_base_stack : Array[Int] = []
  let mut paren_depth = 0
  let mut brace_depth = 0
  let mut bracket_depth = 0
  let pending_match : Array[MatchPending] = []
  let type_context_stack : Array[TypeContext] = []
  let mut type_decl_header = TypeDeclMode::DeclNone
  let mut type_decl_rhs_active = false
  let mut saw_newline = false
  let mut line_has_content = false
  let mut prev_prev_kind : @cst.SyntaxKind? = None
  let mut prev_prev_text : String? = None
  let mut prev_kind : @cst.SyntaxKind? = None
  let mut prev_text : String? = None
  let mut prev_prefix = false
  let mut prev_pipe = false
  let mut prev_line_comment = false
  let mut i = 0
  while i < tokens.length() {
    let tok = tokens[i]
    let kind = tok.kind()
    if kind == whitespace() {
      i += 1
      continue
    }
    if kind == comment() {
      let comment_text = trim_ascii_whitespace(tok.text())
      if pending_newlines == 0 && line_has_content {
        pending_newlines = 1
      }
      if pending_newlines > 0 {
        if kind == rbrace() || kind == rbracket() {
          ()
        }
        for _ in 0..<pending_newlines {
          buf.write_char('\n')
        }
        pending_newlines = 0
        format_write_indent(buf, indent, indent_size)
        line_has_content = false
      }
      buf.write_string(comment_text)
      line_has_content = true
      prev_prev_kind = None
      prev_prev_text = None
      prev_kind = None
      prev_text = None
      prev_prefix = false
      prev_pipe = false
      prev_line_comment = comment_text.has_prefix("//")
      i += 1
      continue
    }
    if kind == newline() {
      saw_newline = true
      if prev_line_comment {
        let max_nl = if brace_depth == 0 { 2 } else { 1 }
        if pending_newlines < max_nl {
          pending_newlines += 1
        }
        prev_line_comment = false
        i += 1
        continue
      }
      let next_kind = next_non_trivia_kind(tokens, i)
      let collapse_generic_break = match (prev_kind, next_kind) {
        (Some(prev), Some(next)) =>
          (prev == impl_kw() || prev == eq()) && next == lbracket()
        _ => false
      }
      let in_effects_brace = container_stack.length() > 0 &&
        container_stack[container_stack.length() - 1] ==
        ContainerKind::BraceEffects
      if paren_depth > 0 ||
        bracket_depth > 0 ||
        collapse_generic_break ||
        in_effects_brace {
        i += 1
        continue
      }
      let max_nl = if brace_depth == 0 { 2 } else { 1 }
      if pending_newlines < max_nl {
        pending_newlines += 1
      }
      i += 1
      continue
    }
    if kind == eof() {
      i += 1
      continue
    }
    if kind == match_kw() {
      pending_match.push(MatchPending::{
        paren: paren_depth,
        brace: brace_depth,
        bracket: bracket_depth,
      })
    }
    if saw_newline &&
      paren_depth == 0 &&
      brace_depth == 0 &&
      bracket_depth == 0 &&
      is_statement_start(kind) {
      while type_context_stack.length() > 0 {
        ignore(type_context_stack.pop())
      }
      type_decl_rhs_active = false
      type_decl_header = TypeDeclMode::DeclNone
    }
    saw_newline = false
    if pending_newlines == 0 &&
      should_force_newline_before(kind, container_stack) {
      pending_newlines = 1
    }
    let mut dedented_before = false
    if pending_newlines > 0 {
      if kind == rbrace() || kind == rbracket() {
        if container_stack.length() > 0 {
          match container_stack.get(container_stack.length() - 1) {
            Some(container) =>
              if container_indents(container) && indent > 0 {
                indent -= 1
                dedented_before = true
              }
            None => ()
          }
        }
      }
      for _ in 0..<pending_newlines {
        buf.write_char('\n')
      }
      pending_newlines = 0
      format_write_indent(buf, indent, indent_size)
      prev_prev_kind = None
      prev_prev_text = None
      prev_kind = None
      prev_text = None
      prev_prefix = false
      prev_pipe = false
      line_has_content = false
    }
    let next_kind = next_non_trivia_kind(tokens, i)
    let curr_pipe = kind == pipe() &&
      (match next_kind {
        Some(k) => k == gt()
        None => false
      })
    let in_type_context = type_context_stack.length() > 0 ||
      type_decl_header != TypeDeclMode::DeclNone ||
      type_decl_rhs_active
    let in_enum_container = container_stack.length() > 0 &&
      container_stack[container_stack.length() - 1] == ContainerKind::BraceEnum
    let enum_top_level = in_enum_container &&
      container_paren_base_stack.length() > 0 &&
      paren_depth ==
      container_paren_base_stack[container_paren_base_stack.length() - 1]
    let rendered_text = if kind == comma() && enum_top_level {
      ";"
    } else {
      token_text_for_output(tok)
    }
    if rendered_text.length() == 0 {
      i += 1
      continue
    }
    let curr_prefix = is_prefix_op(kind, prev_kind)
    let insert_struct_double_colon = should_insert_struct_double_colon(
      prev_prev_kind, prev_prev_text, prev_kind, prev_text, kind, in_type_context,
    )
    let effects_rbrace = kind == rbrace() &&
      container_stack.length() > 0 &&
      container_stack[container_stack.length() - 1] ==
      ContainerKind::BraceEffects
    if line_has_content &&
      !insert_struct_double_colon &&
      (
        effects_rbrace ||
        needs_space(prev_prev_kind, prev_kind, kind, prev_prefix, prev_pipe)
      ) {
      buf.write_char(' ')
    }
    if insert_struct_double_colon {
      buf.write_string("::")
    }
    buf.write_string(rendered_text)
    line_has_content = true
    if kind == type_kw() {
      type_decl_header = TypeDeclMode::DeclTypeAlias
    } else if kind == enum_kw() {
      type_decl_header = TypeDeclMode::DeclEnum
    }
    if kind == colon() && should_start_type_context_on_colon(container_stack) {
      type_context_stack.push(TypeContext::{
        paren: paren_depth,
        brace: brace_depth,
        bracket: bracket_depth,
      })
    } else if kind == thin_arrow() {
      type_context_stack.push(TypeContext::{
        paren: paren_depth,
        brace: brace_depth,
        bracket: bracket_depth,
      })
    }
    if kind == lparen() {
      paren_depth += 1
    } else if kind == rparen() {
      if paren_depth > 0 {
        paren_depth -= 1
      }
    }
    if kind == lbrace() || kind == lbracket() {
      if kind == lbrace() {
        let is_effects_brace = match prev_text {
          Some(t) => t == "with"
          None => false
        }
        let container = if type_decl_header == TypeDeclMode::DeclEnum {
          ContainerKind::BraceEnum
        } else if is_effects_brace {
          ContainerKind::BraceEffects
        } else if is_match_brace(
            pending_match, paren_depth, brace_depth, bracket_depth, prev_kind,
          ) {
          ignore(pending_match.pop())
          ContainerKind::BraceMatch
        } else {
          container_kind_for_brace(prev_kind)
        }
        brace_depth += 1
        if type_decl_header == TypeDeclMode::DeclEnum {
          type_decl_header = TypeDeclMode::DeclNone
        }
        container_stack.push(container)
        container_paren_base_stack.push(paren_depth)
        if container_indents(container) {
          indent += 1
          if pending_newlines == 0 {
            pending_newlines = 1
          }
        }
      } else {
        let generic_hint = (match prev_kind {
            Some(prev) => prev == impl_kw()
            None => false
          }) ||
          is_generic_param_bracket(tokens, i)
        let container = container_kind_for_bracket(
          prev_kind,
          type_context_stack.length() > 0 || type_decl_rhs_active,
          type_decl_header != TypeDeclMode::DeclNone,
          generic_hint,
        )
        bracket_depth += 1
        container_stack.push(container)
        container_paren_base_stack.push(paren_depth)
        if container_indents(container) {
          indent += 1
          if pending_newlines == 0 {
            pending_newlines = 1
          }
        }
      }
    } else if kind == rbrace() || kind == rbracket() {
      if kind == rbrace() && brace_depth > 0 {
        brace_depth -= 1
      }
      if kind == rbracket() && bracket_depth > 0 {
        bracket_depth -= 1
      }
      if container_stack.length() > 0 {
        match container_stack.get(container_stack.length() - 1) {
          Some(container) =>
            if container_indents(container) && !dedented_before && indent > 0 {
              indent -= 1
            }
          None => ()
        }
      }
      if container_stack.length() > 0 {
        if container_paren_base_stack.length() > 0 {
          ignore(container_paren_base_stack.pop())
        }
        match container_stack.pop() {
          Some(_) => ()
          None => ()
        }
      }
    } else if kind == comma() || kind == semicolon() {
      if container_stack.length() > 0 &&
        container_paren_base_stack.length() > 0 &&
        container_forces_list_newlines(
          container_stack[container_stack.length() - 1],
        ) &&
        paren_depth ==
        container_paren_base_stack[container_paren_base_stack.length() - 1] &&
        pending_newlines == 0 {
        pending_newlines = 1
      }
    }
    if kind == eq() && type_decl_header == TypeDeclMode::DeclTypeAlias {
      type_decl_header = TypeDeclMode::DeclNone
      type_decl_rhs_active = true
    } else if kind == semicolon() {
      type_decl_rhs_active = false
      type_decl_header = TypeDeclMode::DeclNone
    }
    maybe_end_type_context(
      kind, type_context_stack, paren_depth, brace_depth, bracket_depth,
    )
    prev_prev_kind = prev_kind
    prev_prev_text = prev_text
    prev_kind = Some(kind)
    prev_text = Some(tok.text())
    prev_prefix = curr_prefix
    prev_pipe = curr_pipe
    prev_line_comment = false
    i += 1
  }
  if pending_newlines > 0 {
    for _ in 0..<pending_newlines {
      buf.write_char('\n')
    }
  }
  buf.to_string()
}

///|
fn bracket_tokens_look_like_type_params(
  tokens : Array[@cst.SyntaxToken],
  start_idx : Int,
  close_idx : Int,
) -> Bool {
  let mut saw_name = false
  let mut i = start_idx + 1
  while i < close_idx {
    let kind = tokens[i].kind()
    if kind == whitespace() ||
      kind == newline() ||
      kind == comment() ||
      kind == eof() {
      i += 1
      continue
    }
    if kind == name() {
      saw_name = true
      i += 1
      continue
    }
    if kind == comma() ||
      kind == colon() ||
      kind == plus() ||
      kind == lbracket() ||
      kind == rbracket() {
      i += 1
      continue
    }
    return false
  }
  saw_name
}

///|
fn is_generic_param_bracket(
  tokens : Array[@cst.SyntaxToken],
  start_idx : Int,
) -> Bool {
  let close_idx = match find_matching_rbracket_token_index(tokens, start_idx) {
    Some(v) => v
    None => return false
  }
  if !bracket_tokens_look_like_type_params(tokens, start_idx, close_idx) {
    return false
  }
  match next_non_trivia_kind(tokens, close_idx) {
    Some(next_kind) => next_kind == lparen() || next_kind == name()
    None => false
  }
}

///|
fn token_text_for_output(tok : @cst.SyntaxToken) -> String {
  let kind = tok.kind()
  if kind == string_lit() {
    quote_string_literal(tok.text())
  } else if kind == string_interp_lit() {
    quote_string_interp_literal(tok.text())
  } else if kind == char_lit() {
    quote_char_literal(tok.text())
  } else if kind == name() {
    let trimmed = trim_ascii_whitespace(tok.text())
    if should_escape_identifier_text(trimmed) {
      "r#" + trimmed
    } else {
      trimmed
    }
  } else {
    trim_ascii_whitespace(tok.text())
  }
}

///|
fn should_escape_identifier_text(text : String) -> Bool {
  text == "let" ||
  text == "import" ||
  text == "use" ||
  text == "declare" ||
  text == "test" ||
  text == "if" ||
  text == "else" ||
  text == "match" ||
  text == "record" ||
  text == "map" ||
  text == "fn" ||
  text == "rec" ||
  text == "type" ||
  text == "enum" ||
  text == "while" ||
  text == "loop" ||
  text == "bench" ||
  text == "mut" ||
  text == "raise" ||
  text == "yield" ||
  text == "break" ||
  text == "continue" ||
  text == "export" ||
  text == "from" ||
  text == "as" ||
  text == "struct" ||
  text == "trait" ||
  text == "impl" ||
  text == "true" ||
  text == "false"
}

///|
fn trim_ascii_whitespace(text : String) -> String {
  let len = text.length()
  if len == 0 {
    return ""
  }
  let mut start = 0
  while start < len {
    let c = text[start].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  let mut end = len
  while end > start {
    let c = text[end - 1].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == len {
    text
  } else {
    text.unsafe_substring(start~, end~)
  }
}

///|
fn quote_string_literal(text : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in text {
    write_escaped_char(buf, c, false)
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn quote_string_interp_literal(raw_text : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  buf.write_string(raw_text)
  buf.write_char('"')
  buf.to_string()
}

///|
fn quote_char_literal(text : String) -> String {
  let chars = text.to_array()
  let buf = StringBuilder::new()
  buf.write_char('\'')
  if chars.length() > 0 {
    write_escaped_char(buf, chars[0], true)
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
fn write_escaped_char(
  buf : StringBuilder,
  c : Char,
  for_char_literal : Bool,
) -> Unit {
  match c {
    '\n' => buf.write_string("\\n")
    '\t' => buf.write_string("\\t")
    '\r' => buf.write_string("\\r")
    '\\' => buf.write_string("\\\\")
    '"' =>
      if for_char_literal {
        buf.write_char('"')
      } else {
        buf.write_string("\\\"")
      }
    '\'' =>
      if for_char_literal {
        buf.write_string("\\'")
      } else {
        buf.write_char('\'')
      }
    _ => buf.write_char(c)
  }
}

///|
fn should_force_newline_before(
  kind : @cst.SyntaxKind,
  container_stack : Array[ContainerKind],
) -> Bool {
  if kind != rbrace() && kind != rbracket() {
    return false
  }
  if container_stack.length() == 0 {
    return false
  }
  match container_stack.get(container_stack.length() - 1) {
    Some(container) => container_indents(container)
    None => false
  }
}

///|
fn container_kind_for_brace(prev_kind : @cst.SyntaxKind?) -> ContainerKind {
  match prev_kind {
    Some(prev) =>
      if prev == record_kw() {
        ContainerKind::BraceRecord
      } else if prev == map_kw() {
        ContainerKind::BraceMap
      } else {
        ContainerKind::BraceBlock
      }
    None => ContainerKind::BraceBlock
  }
}

///|
fn container_kind_for_bracket(
  prev_kind : @cst.SyntaxKind?,
  in_type_context : Bool,
  in_type_decl_header : Bool,
  generic_param_hint : Bool,
) -> ContainerKind {
  if generic_param_hint {
    return ContainerKind::BracketTypeArgs
  }
  match prev_kind {
    Some(prev) =>
      if (prev == name() || prev == rbracket()) &&
        (in_type_context || in_type_decl_header) {
        ContainerKind::BracketTypeArgs
      } else if is_index_receiver_kind(prev) {
        ContainerKind::BracketIndex
      } else {
        ContainerKind::BracketArray
      }
    None => ContainerKind::BracketArray
  }
}

///|
fn container_indents(kind : ContainerKind) -> Bool {
  match kind {
    ContainerKind::BraceBlock => true
    ContainerKind::BraceRecord => true
    ContainerKind::BraceMap => true
    ContainerKind::BraceMatch => true
    ContainerKind::BraceEnum => true
    ContainerKind::BraceEffects => false
    ContainerKind::BracketArray => true
    ContainerKind::BracketTypeArgs => false
    ContainerKind::BracketIndex => false
  }
}

///|
fn container_forces_list_newlines(kind : ContainerKind) -> Bool {
  match kind {
    ContainerKind::BraceRecord => true
    ContainerKind::BraceMap => true
    ContainerKind::BraceMatch => true
    ContainerKind::BraceEnum => true
    ContainerKind::BracketArray => true
    _ => false
  }
}

///|
fn find_matching_rbracket_token_index(
  tokens : Array[@cst.SyntaxToken],
  start_idx : Int,
) -> Int? {
  if start_idx < 0 || start_idx >= tokens.length() {
    return None
  }
  if tokens[start_idx].kind() != lbracket() {
    return None
  }
  let mut depth = 0
  let mut i = start_idx
  while i < tokens.length() {
    let kind = tokens[i].kind()
    if kind == lbracket() {
      depth += 1
    } else if kind == rbracket() {
      depth -= 1
      if depth == 0 {
        return Some(i)
      }
    }
    i += 1
  }
  None
}

///|
fn is_index_receiver_kind(kind : @cst.SyntaxKind) -> Bool {
  kind == name() ||
  kind == rparen() ||
  kind == rbracket() ||
  kind == rbrace() ||
  is_literal_kind(kind)
}

///|
fn should_start_type_context_on_colon(
  container_stack : Array[ContainerKind],
) -> Bool {
  if container_stack.length() == 0 {
    return true
  }
  match container_stack.get(container_stack.length() - 1) {
    Some(ContainerKind::BraceRecord) => false
    Some(ContainerKind::BraceMap) => false
    _ => true
  }
}

///|
fn is_statement_start(kind : @cst.SyntaxKind) -> Bool {
  kind == let_kw() ||
  kind == flake_kw() ||
  kind == alias_kw() ||
  kind == import_kw() ||
  kind == use_kw() ||
  kind == test_kw() ||
  kind == bench_kw() ||
  kind == if_kw() ||
  kind == while_kw() ||
  kind == loop_kw() ||
  kind == match_kw() ||
  kind == break_kw() ||
  kind == continue_kw() ||
  kind == return_kw() ||
  kind == raise_kw() ||
  kind == enum_kw() ||
  kind == type_kw() ||
  kind == struct_kw() ||
  kind == trait_kw() ||
  kind == impl_kw() ||
  kind == export_kw()
}

///|
fn is_type_context_end(kind : @cst.SyntaxKind) -> Bool {
  kind == comma() ||
  kind == semicolon() ||
  kind == eq() ||
  kind == arrow() ||
  kind == lbrace() ||
  kind == rparen() ||
  kind == rbrace() ||
  kind == rbracket()
}

///|
fn maybe_end_type_context(
  kind : @cst.SyntaxKind,
  type_context_stack : Array[TypeContext],
  paren_depth : Int,
  brace_depth : Int,
  bracket_depth : Int,
) -> Unit {
  if type_context_stack.length() == 0 {
    return
  }
  if !is_type_context_end(kind) {
    return
  }
  let effective_brace = if kind == lbrace() && brace_depth > 0 {
    brace_depth - 1
  } else {
    brace_depth
  }
  let effective_bracket = if kind == lbracket() && bracket_depth > 0 {
    bracket_depth - 1
  } else {
    bracket_depth
  }
  while type_context_stack.length() > 0 {
    match type_context_stack.get(type_context_stack.length() - 1) {
      Some(ctx) =>
        if ctx.paren == paren_depth &&
          ctx.brace == effective_brace &&
          ctx.bracket == effective_bracket {
          ignore(type_context_stack.pop())
        } else {
          break
        }
      None => break
    }
  }
}

///|
fn is_match_brace(
  pending_match : Array[MatchPending],
  paren_depth : Int,
  brace_depth : Int,
  bracket_depth : Int,
  prev_kind : @cst.SyntaxKind?,
) -> Bool {
  if pending_match.length() == 0 {
    return false
  }
  let last = pending_match[pending_match.length() - 1]
  if paren_depth != last.paren ||
    brace_depth != last.brace ||
    bracket_depth != last.bracket {
    return false
  }
  match prev_kind {
    Some(prev) =>
      prev != match_kw() &&
      prev != record_kw() &&
      prev != map_kw() &&
      prev != if_kw() &&
      prev != else_kw()
    None => false
  }
}

///|
fn format_write_indent(
  buf : StringBuilder,
  indent : Int,
  indent_size : Int,
) -> Unit {
  let total = if indent <= 0 || indent_size <= 0 {
    0
  } else {
    indent * indent_size
  }
  for _ in 0..<total {
    buf.write_char(' ')
  }
}

///|
fn next_non_trivia_kind(
  tokens : Array[@cst.SyntaxToken],
  start : Int,
) -> @cst.SyntaxKind? {
  let mut i = start + 1
  while i < tokens.length() {
    let kind = tokens[i].kind()
    if kind == whitespace() || kind == newline() || kind == comment() {
      i += 1
      continue
    }
    if kind == eof() {
      return None
    }
    return Some(kind)
  }
  None
}

///|
fn should_insert_struct_double_colon(
  prev_prev_kind : @cst.SyntaxKind?,
  prev_prev_text : String?,
  prev_kind : @cst.SyntaxKind?,
  prev_text : String?,
  curr_kind : @cst.SyntaxKind,
  in_type_context : Bool,
) -> Bool {
  if curr_kind != lbrace() || in_type_context {
    return false
  }
  match prev_prev_kind {
    Some(prev_prev) =>
      if prev_prev == struct_kw() ||
        prev_prev == enum_kw() ||
        prev_prev == type_kw() {
        return false
      }
    None => ()
  }
  match prev_prev_text {
    Some("effect") => return false
    Some("suberror") => return false
    Some("with") => return false
    _ => ()
  }
  if prev_prev_kind == Some(thin_arrow()) {
    return false
  }
  match prev_kind {
    Some(prev) =>
      if prev != name() {
        false
      } else {
        match prev_text {
          Some(text) => @core.is_ctor_name(text)
          None => false
        }
      }
    None => false
  }
}

///|
fn needs_space(
  prev_prev_kind : @cst.SyntaxKind?,
  prev_kind : @cst.SyntaxKind?,
  curr_kind : @cst.SyntaxKind,
  prev_prefix : Bool,
  prev_pipe : Bool,
) -> Bool {
  match prev_kind {
    None => false
    Some(prev) => {
      if prev_prefix {
        return false
      }
      if prev_pipe && curr_kind == gt() {
        return false
      }
      // `let*` railway bind: keep the `*` attached to `let` (no space before it).
      // The space after `*` (before the bound name) is handled normally.
      if prev == let_kw() && curr_kind == star() {
        return false
      }
      if curr_kind == rparen() ||
        curr_kind == rbracket() ||
        curr_kind == rbrace() ||
        curr_kind == comma() ||
        curr_kind == semicolon() {
        return false
      }
      if curr_kind == colon() {
        return false
      }
      if prev == name() && curr_kind == name() {
        return true
      }
      if prev == rbracket() && curr_kind == name() {
        return true
      }
      if curr_kind == lparen() || curr_kind == lbracket() {
        if prev == name() ||
          is_literal_kind(prev) ||
          prev == rparen() ||
          prev == rbracket() ||
          prev == rbrace() {
          return false
        }
      }
      if curr_kind == lbrace() {
        if prev == lparen() || prev == lbracket() || prev == double_colon() {
          return false
        }
      }
      if prev == lparen() || prev == lbracket() {
        return false
      }
      if (prev == import_kw() || prev == export_kw()) &&
        (curr_kind == dot() || curr_kind == slash()) {
        return true
      }
      if prev == slash() && curr_kind == name() {
        match prev_prev_kind {
          Some(pp) =>
            if pp == dot() || pp == import_kw() || pp == export_kw() {
              return false
            }
          None => ()
        }
      }
      if prev == dot() || curr_kind == dot() {
        return false
      }
      if prev == lbrace() {
        return true
      }
      if prev == comma() || prev == semicolon() || prev == colon() {
        return true
      }
      if curr_kind == lbrace() {
        return true
      }
      if is_keyword_kind(curr_kind) {
        return true
      }
      if is_operator_kind(prev) || is_operator_kind(curr_kind) {
        return true
      }
      if is_keyword_kind(prev) {
        return true
      }
      false
    }
  }
}

///|
fn is_prefix_op(kind : @cst.SyntaxKind, prev_kind : @cst.SyntaxKind?) -> Bool {
  if kind != minus() && kind != bang() {
    return false
  }
  match prev_kind {
    None => true
    Some(prev) =>
      if is_operator_kind(prev) ||
        is_keyword_kind(prev) ||
        prev == lparen() ||
        prev == lbracket() ||
        prev == lbrace() ||
        prev == comma() ||
        prev == colon() ||
        prev == semicolon() {
        true
      } else {
        false
      }
  }
}

///|
fn is_operator_kind(kind : @cst.SyntaxKind) -> Bool {
  kind == eq() ||
  kind == plus() ||
  kind == minus() ||
  kind == star() ||
  kind == slash() ||
  kind == percent() ||
  kind == plus_eq() ||
  kind == minus_eq() ||
  kind == star_eq() ||
  kind == slash_eq() ||
  kind == percent_eq() ||
  kind == eqeq() ||
  kind == neq() ||
  kind == lt() ||
  kind == lte() ||
  kind == gt() ||
  kind == gte() ||
  kind == and_and() ||
  kind == or_or() ||
  kind == arrow() ||
  kind == thin_arrow() ||
  kind == pipe() ||
  kind == pipe_gt()
}

///|
fn is_keyword_kind(kind : @cst.SyntaxKind) -> Bool {
  kind == let_kw() ||
  kind == rec_kw() ||
  kind == enum_kw() ||
  kind == type_kw() ||
  kind == alias_kw() ||
  kind == import_kw() ||
  kind == use_kw() ||
  kind == declare_kw() ||
  kind == export_kw() ||
  kind == from_kw() ||
  kind == as_kw() ||
  kind == test_kw() ||
  kind == bench_kw() ||
  kind == if_kw() ||
  kind == else_kw() ||
  kind == match_kw() ||
  kind == record_kw() ||
  kind == for_kw() ||
  kind == in_kw() ||
  kind == with_kw() ||
  kind == is_kw() ||
  kind == derive_kw() ||
  kind == fn_kw() ||
  kind == while_kw() ||
  kind == loop_kw() ||
  kind == break_kw() ||
  kind == continue_kw() ||
  kind == mut_kw() ||
  kind == raise_kw() ||
  kind == yield_kw() ||
  kind == struct_kw() ||
  kind == trait_kw() ||
  kind == impl_kw() ||
  kind == flake_kw()
}

///|
fn is_literal_kind(kind : @cst.SyntaxKind) -> Bool {
  kind == int_lit() ||
  kind == float_lit() ||
  kind == string_lit() ||
  kind == string_interp_lit() ||
  kind == bool_lit() ||
  kind == char_lit()
}
