///|
/// Formatter for xsh based on CST

///|
enum ContainerKind {
  BraceBlock
  BraceRecord
  BraceMap
  BraceMatch
  BracketArray
  BracketTypeArgs
  BracketIndex
} derive(Show, Eq)

///|
struct MatchPending {
  paren : Int
  brace : Int
  bracket : Int
} derive(Show, Eq)

///|
enum TypeDeclMode {
  DeclNone
  DeclTypeAlias
  DeclEnum
} derive(Show, Eq)

///|
struct TypeContext {
  paren : Int
  brace : Int
  bracket : Int
} derive(Show, Eq)

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
  let mut paren_depth = 0
  let mut brace_depth = 0
  let mut bracket_depth = 0
  let pending_match : Array[MatchPending] = []
  let type_context_stack : Array[TypeContext] = []
  let mut type_decl_header = TypeDeclMode::DeclNone
  let mut type_decl_rhs_active = false
  let mut saw_newline = false
  let mut prev_kind : @cst.SyntaxKind? = None
  let mut prev_prefix = false
  let mut prev_pipe = false
  let mut i = 0
  while i < tokens.length() {
    let tok = tokens[i]
    let kind = tok.kind()
    if kind == whitespace() {
      i += 1
      continue
    }
    if kind == newline() {
      saw_newline = true
      if pending_newlines == 0 || container_stack.length() == 0 {
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
      prev_kind = None
      prev_prefix = false
      prev_pipe = false
    }
    let next_kind = next_non_trivia_kind(tokens, i)
    let curr_pipe = kind == pipe() &&
      (match next_kind {
        Some(k) => k == gt()
        None => false
      })
    let curr_prefix = is_prefix_op(kind, prev_kind)
    if needs_space(prev_kind, kind, prev_prefix, prev_pipe) {
      buf.write_char(' ')
    }
    buf.write_string(tok.text())
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
        let container = if is_match_brace(
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
        if container_indents(container) {
          indent += 1
          if pending_newlines == 0 {
            pending_newlines = 1
          }
        }
      } else {
        let container = container_kind_for_bracket(
          prev_kind,
          type_context_stack.length() > 0 || type_decl_rhs_active,
          type_decl_header != TypeDeclMode::DeclNone,
        )
        bracket_depth += 1
        container_stack.push(container)
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
            if container_indents(container) &&
              not(dedented_before) &&
              indent > 0 {
              indent -= 1
            }
          None => ()
        }
      }
      if container_stack.length() > 0 {
        ignore(container_stack.pop())
      }
    } else if kind == comma() || kind == semicolon() {
      if container_stack.length() > 0 &&
        container_forces_list_newlines(
          container_stack[container_stack.length() - 1],
        ) &&
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
    prev_kind = Some(kind)
    prev_prefix = curr_prefix
    prev_pipe = curr_pipe
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
) -> ContainerKind {
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
    ContainerKind::BracketArray => true
    _ => false
  }
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
  kind == test_kw() ||
  kind == if_kw() ||
  kind == while_kw() ||
  kind == match_kw() ||
  kind == do_kw() ||
  kind == try_kw() ||
  kind == raise_kw() ||
  kind == enum_kw() ||
  kind == type_kw() ||
  kind == struct_kw()
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
  if not(is_type_context_end(kind)) {
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
      prev != do_kw() &&
      prev != try_kw() &&
      prev != catch_kw() &&
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
    if kind == whitespace() || kind == newline() {
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
fn needs_space(
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
        if prev == lparen() || prev == lbracket() {
          return false
        }
      }
      if prev == lparen() || prev == lbracket() {
        return false
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
  kind == pipe()
}

///|
fn is_keyword_kind(kind : @cst.SyntaxKind) -> Bool {
  kind == let_kw() ||
  kind == rec_kw() ||
  kind == enum_kw() ||
  kind == type_kw() ||
  kind == alias_kw() ||
  kind == import_kw() ||
  kind == test_kw() ||
  kind == if_kw() ||
  kind == else_kw() ||
  kind == match_kw() ||
  kind == do_kw() ||
  kind == try_kw() ||
  kind == catch_kw() ||
  kind == record_kw() ||
  kind == map_kw() ||
  kind == fn_kw() ||
  kind == while_kw() ||
  kind == mut_kw() ||
  kind == raise_kw() ||
  kind == struct_kw()
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
