///|
/// Desugar method-call syntax (t.foo(...)) into foo(t, ...)
pub fn desugar_method_calls(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  let scope = DesugarScope::new()
  desugar_block(ast, scope, aliases)
}

///|
/// Desugar vibe command heads in PosixMode:
/// unresolved bare identifiers like `ls` become `sh_lines("ls")`.
pub fn desugar_vibe_commands(ast : @core.Module) -> @core.Module {
  let (desugared, _) = desugar_vibe_commands_with_notes(ast)
  desugared
}

///|
/// Same as `desugar_vibe_commands` but also returns note messages
/// for each unresolved bare identifier command-head rewrite.
pub fn desugar_vibe_commands_with_notes(
  ast : @core.Module,
) -> (@core.Module, Array[String]) {
  let scope = DesugarScope::new()
  let known_non_cmd = known_vibe_non_command_names()
  let notes : Array[String] = []
  let desugared = desugar_vibe_block(ast, scope, known_non_cmd, notes)
  (desugared, notes)
}

///|
fn known_vibe_non_command_names() -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for name in @checker.prelude_names() {
    out[name] = true
  }
  let builtins = [
    "path", "addr", "sh", "sh_lines", "sleep", "select", "Stdin::read_char", "Stdin::read_stream",
    "Stdout::write_char", "Stdout::write_stream", "String::from_char_code", "String::length",
    "String::utf8_length", "String::utf16_length", "String::unicode_length", "String::char_code_at",
    "String::substring", "String::concat", "String::equals", "String::split", "String::index_of",
    "String::contains", "String::trim", "Array::length", "Array::get", "Array::slice",
    "ArrayBuilder::new", "ArrayBuilder::push", "ArrayBuilder::freeze", "MapBuilder::new",
    "MapBuilder::set", "MapBuilder::freeze", "map_builder", "map_builder_set", "map_builder_freeze",
    "Map::keys", "Map::values", "Map::has_key", "record_set", "Char::to_int", "Char::from_int",
    "Fs::read_file", "Fs::write_file", "Fs::exists", "Socket::tcp_connect", "Socket::tcp_read",
    "Socket::tcp_write", "Socket::tcp_close", "Http::request", "Http::response_status",
    "Http::response_header", "Http::response_body", "Http::close", "Http::listen",
    "Http::accept", "Http::request_method", "Http::request_url", "Http::request_header",
    "Http::request_body", "Http::respond",
  ]
  for name in builtins {
    out[name] = true
  }
  out
}

///|
fn is_command_like_name(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  let first = chars[0]
  if first < 'a' || first > 'z' {
    return false
  }
  for c in chars {
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
      continue
    }
    return false
  }
  true
}

///|
fn is_vibe_command_candidate(
  name : String,
  scope : DesugarScope,
  known_non_cmd : Map[String, Bool],
) -> Bool {
  not(scope.contains(name)) &&
  not(known_non_cmd.contains(name)) &&
  is_command_like_name(name)
}

///|
fn sh_lines_expr(name : String, span : @core.Span) -> @core.Expr {
  let cmd_expr = @core.Expr::String(value=name, span~)
  let cmd_arg = @core.CallArg::{ label: None, expr: cmd_expr, span }
  @core.Expr::Call(name="sh_lines", type_args=[], args=[cmd_arg], span~)
}

///|
/// Check if all args are labeled (for command-call desugar).
/// Type checking of arg values is deferred to the type checker.
fn try_all_labeled_args(args : Array[@core.CallArg]) -> Bool {
  if args.length() == 0 {
    return false
  }
  for arg in args {
    match arg.label {
      None => return false
      Some(_) => ()
    }
  }
  true
}

///|
/// Build `sh_lines("cmd", a=true, l=true, ...)` AST with sorted labels.
fn sh_lines_with_flags_expr(
  cmd : String,
  flags : Array[String],
  span : @core.Span,
) -> @core.Expr {
  flags.sort_by(fn(a, b) { a.compare(b) })
  let args : Array[@core.CallArg] = []
  let cmd_expr = @core.Expr::String(value=cmd, span~)
  args.push(@core.CallArg::{ label: None, expr: cmd_expr, span })
  for flag in flags {
    let bool_expr = @core.Expr::Bool(value=true, span~)
    args.push(@core.CallArg::{ label: Some(flag), expr: bool_expr, span })
  }
  @core.Expr::Call(name="sh_lines", type_args=[], args~, span~)
}

///|
/// Try to extract a POSIX command with flags from a `__sub`/`__neg` chain.
/// Returns `Some((cmd_name, flags))` if the expression is a chain like:
///   `__sub(__sub(Ident("ls"), Ident("al")), __neg(Ident("all")))`
/// Otherwise returns `None`.
fn try_extract_posix_command(
  expr : @core.Expr,
  scope : DesugarScope,
  known_non_cmd : Map[String, Bool],
) -> (String, Array[String])? {
  match expr {
    @core.Expr::Call(name="__sub", args~, ..) => {
      if args.length() != 2 {
        return None
      }
      let lhs = args[0].expr
      let rhs = args[1].expr
      // Recurse on lhs
      let (cmd, flags) = match
        try_extract_posix_command(lhs, scope, known_non_cmd) {
        Some(result) => result
        None => return None
      }
      // rhs is either Ident (short flags) or __neg(Ident) (long flag)
      match rhs {
        @core.Expr::Ident(name~, ..) => {
          // Short flags: each char becomes a flag
          for ch in name {
            flags.push(ch.to_string())
          }
          Some((cmd, flags))
        }
        @core.Expr::Call(name="__neg", args=neg_args, ..) => {
          if neg_args.length() != 1 {
            return None
          }
          match neg_args[0].expr {
            @core.Expr::Ident(name~, ..) => {
              flags.push(name)
              Some((cmd, flags))
            }
            _ => None
          }
        }
        _ => None
      }
    }
    @core.Expr::Ident(name~, ..) =>
      if is_vibe_command_candidate(name, scope, known_non_cmd) {
        Some((name, []))
      } else {
        None
      }
    _ => None
  }
}

///|
fn desugar_vibe_block(
  body : @core.Module,
  scope : DesugarScope,
  known_non_cmd : Map[String, Bool],
  notes : Array[String],
) -> @core.Module {
  let scope_map = scope.child()
  let out : Array[@core.Stmt] = []
  for stmt in body.stmts {
    let next = desugar_vibe_stmt(stmt, scope_map, known_non_cmd, notes)
    out.push(next)
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) => scope_map.bindings[name] = true
      @core.Stmt::LetPat(pat~, ..) | @core.Stmt::LetPatElse(pat~, ..) => {
        let bindings : Array[String] = []
        collect_pat_bindings(pat, bindings)
        for name in bindings {
          scope_map.bindings[name] = true
        }
      }
      @core.Stmt::Import(spec~, ..) =>
        for item in spec.items {
          let binds_runtime = item.kind == @core.ImportKind::Value ||
            (item.kind == @core.ImportKind::Type && item.name.contains("::"))
          if binds_runtime {
            match item.rename {
              Some(local_name) => scope_map.bindings[local_name] = true
              None => scope_map.bindings[item.name] = true
            }
          }
        }
      _ => ()
    }
  }
  @core.Module::{ stmts: out }
}

///|
fn desugar_vibe_stmt(
  stmt : @core.Stmt,
  scope : DesugarScope,
  known_non_cmd : Map[String, Bool],
  notes : Array[String],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=desugar_vibe_block(body, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=desugar_vibe_block(body, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=desugar_vibe_expr(target, scope, known_non_cmd, notes),
        index=desugar_vibe_expr(index, scope, known_non_cmd, notes),
        value=desugar_vibe_expr(value, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(
        pat~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        else_body=desugar_vibe_block(
          else_body,
          scope.child(),
          known_non_cmd,
          notes,
        ),
        span~,
      )
    _ => stmt
  }
}

///|
fn desugar_vibe_expr(
  expr : @core.Expr,
  scope : DesugarScope,
  known_non_cmd : Map[String, Bool],
  notes : Array[String],
) -> @core.Expr {
  match expr {
    @core.Expr::Ident(name~, span~) =>
      if is_vibe_command_candidate(name, scope, known_non_cmd) {
        notes.push(
          "desugared bare identifier `" +
          name +
          "` (offset " +
          span.start.to_string() +
          ") to sh_lines(\"" +
          name +
          "\")",
        )
        sh_lines_expr(name, span)
      } else {
        expr
      }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      // Try POSIX flag extraction for __sub chains: ls -al → sh_lines("ls", a=true, l=true)
      if name == "__sub" {
        match try_extract_posix_command(expr, scope, known_non_cmd) {
          Some((cmd, flags)) => {
            let flag_desc = flags.iter().map(fn(f) { f + "=true" }).collect()
            let flag_str = flag_desc.join(", ")
            notes.push(
              "desugared `" +
              cmd +
              "` with flags (offset " +
              span.start.to_string() +
              ") to sh_lines(\"" +
              cmd +
              "\", " +
              flag_str +
              ")",
            )
            return sh_lines_with_flags_expr(cmd, flags, span)
          }
          None => ()
        }
      }
      // Try function-call style command: ls() or ls(l=true) → sh_lines("ls", ...)
      // Type checking of labeled args is deferred to the checker (Mismatch error).
      if is_vibe_command_candidate(name, scope, known_non_cmd) &&
        (args.length() == 0 || try_all_labeled_args(args)) {
        notes.push(
          "desugared `" +
          name +
          "(...)` (offset " +
          span.start.to_string() +
          ") to sh_lines(\"" +
          name +
          "\", ...)",
        )
        if args.length() == 0 {
          return sh_lines_expr(name, span)
        }
        // Pass labeled args through to sh_lines; checker validates types
        let sh_args : Array[@core.CallArg] = []
        let cmd_expr = @core.Expr::String(value=name, span~)
        sh_args.push(@core.CallArg::{ label: None, expr: cmd_expr, span })
        for arg in args {
          sh_args.push(arg)
        }
        return @core.Expr::Call(
          name="sh_lines",
          type_args=[],
          args=sh_args,
          span~,
        )
      }
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: desugar_vibe_expr(arg.expr, scope, known_non_cmd, notes),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=desugar_vibe_expr(cond, scope, known_non_cmd, notes),
        then_body=desugar_vibe_block(
          then_body,
          scope.child(),
          known_non_cmd,
          notes,
        ),
        else_body=desugar_vibe_block(
          else_body,
          scope.child(),
          known_non_cmd,
          notes,
        ),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=desugar_vibe_block(body, scope.child(), known_non_cmd, notes),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      let next_scrut = desugar_vibe_expr(scrutinee, scope, known_non_cmd, notes)
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let next_cond = match arm.cond {
          Some(c) => Some(desugar_vibe_expr(c, arm_scope, known_non_cmd, notes))
          None => None
        }
        let next_expr = desugar_vibe_expr(
          arm.expr,
          arm_scope,
          known_non_cmd,
          notes,
        )
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Match(scrutinee=next_scrut, arms=next_arms, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_vibe_expr(item, scope, known_non_cmd, notes))
      }
      @core.Expr::Tuple(items=out, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_vibe_expr(field.expr, scope, known_non_cmd, notes),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=out, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_vibe_expr(item, scope, known_non_cmd, notes))
      }
      @core.Expr::Array(items=out, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let out : Array[@core.MapFieldExpr] = []
      for field in fields {
        out.push(@core.MapFieldExpr::{
          key: field.key,
          expr: desugar_vibe_expr(field.expr, scope, known_non_cmd, notes),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=out, span~)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(fn(c) {
            desugar_vibe_expr(c, scope, known_non_cmd, notes)
          }),
          expr: desugar_vibe_expr(arm.expr, scope, known_non_cmd, notes),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=desugar_vibe_block(body, scope.child(), known_non_cmd, notes),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let next_scope = scope.child()
      for param in params {
        next_scope.bindings[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=desugar_vibe_block(body, next_scope, known_non_cmd, notes),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=desugar_vibe_expr(cond, scope, known_non_cmd, notes),
        body=desugar_vibe_block(body, scope.child(), known_non_cmd, notes),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: desugar_vibe_expr(param.init, scope, known_non_cmd, notes),
          span: param.span,
        })
      }
      let next_scope = scope.child()
      for param in params {
        next_scope.bindings[param.name] = true
      }
      @core.Expr::Loop(
        params=next_params,
        body=desugar_vibe_block(body, next_scope, known_non_cmd, notes),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) => {
      let next_value = match value {
        Some(e) => Some(desugar_vibe_expr(e, scope, known_non_cmd, notes))
        None => None
      }
      @core.Expr::Break(value=next_value, span~)
    }
    @core.Expr::Continue(args~, span~) => {
      let next_args : Array[@core.Expr] = []
      for arg in args {
        next_args.push(desugar_vibe_expr(arg, scope, known_non_cmd, notes))
      }
      @core.Expr::Continue(args=next_args, span~)
    }
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=desugar_vibe_expr(expr, scope, known_non_cmd, notes),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_vibe_expr(field.expr, scope, known_non_cmd, notes),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=out, span~)
    }
    _ => expr
  }
}

///|
fn desugar_block(
  body : @core.Module,
  scope : DesugarScope,
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  let scope_map = scope.child()
  let out : Array[@core.Stmt] = []
  for stmt in body.stmts {
    let next = desugar_stmt(stmt, scope_map, aliases)
    out.push(next)
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~)
      | @core.Stmt::ExportLet(rec~, name~, expr~, span~)
      | @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = expr
        let _ = span
        scope_map.bindings[name] = true
      }
      @core.Stmt::ExternLet(name~, ty~, span~) => {
        let _ = ty
        let _ = span
        scope_map.bindings[name] = true
      }
      _ => ()
    }
  }
  @core.Module::{ stmts: out }
}

///|
fn desugar_stmt(
  stmt : @core.Stmt,
  scope : DesugarScope,
  aliases : Map[String, @core.Ref],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=desugar_expr(expr, scope, aliases),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=desugar_block(body, scope, aliases), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=desugar_block(body, scope, aliases), span~)
    @core.Stmt::EnumDef(..) => stmt
    @core.Stmt::TypeAlias(..) => stmt
    @core.Stmt::TraitDef(..) => stmt
    @core.Stmt::InternalTraitDef(..) => stmt
    @core.Stmt::TraitImpl(..) => stmt
    @core.Stmt::Import(..) => stmt
    @core.Stmt::ExternLet(..) => stmt
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=desugar_expr(expr, scope, aliases),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=desugar_expr(expr, scope, aliases),
        span~,
      )
    @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::InternalExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::InternalExportTypeAlias(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..)
    | @core.Stmt::AliasDecl(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..) => stmt
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=desugar_expr(target, scope, aliases),
        index=desugar_expr(index, scope, aliases),
        value=desugar_expr(value, scope, aliases),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=desugar_expr(expr, scope, aliases),
        else_body=desugar_block(else_body, scope, aliases),
        span~,
      )
  }
}

///|
fn desugar_expr(
  expr : @core.Expr,
  scope : DesugarScope,
  aliases : Map[String, @core.Ref],
) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: desugar_expr(arg.expr, scope, aliases),
          span: arg.span,
        })
      }
      // Handle dot-access desugared by parser: Call("method", [Ident("recv"), ...])
      // If recv is an alias (imported module), convert to qualified name
      if next_args.length() >= 1 {
        match next_args[0].expr {
          @core.Expr::Ident(name=recv, ..) =>
            if aliases.contains(recv) && not(scope.contains(recv)) {
              let qualified = recv + "." + name
              if next_args.length() == 1 {
                // foo.bar → Ident("foo.bar")
                return @core.Expr::Ident(name=qualified, span~)
              } else {
                // foo.bar(args) → Call("foo.bar", args)
                let rest_args : Array[@core.CallArg] = []
                for i in 1..<next_args.length() {
                  rest_args.push(next_args[i])
                }
                return @core.Expr::Call(
                  name=qualified,
                  type_args~,
                  args=rest_args,
                  span~,
                )
              }
            }
          _ => ()
        }
      }
      match split_method_call_name(name) {
        Some((recv, method_name)) =>
          if scope.contains(recv) && not(aliases.contains(recv)) {
            let merged : Array[@core.CallArg] = []
            let recv_expr = @core.Expr::Ident(name=recv, span~)
            merged.push(@core.CallArg::{ label: None, expr: recv_expr, span })
            for arg in next_args {
              merged.push(arg)
            }
            @core.Expr::Call(name=method_name, type_args~, args=merged, span~)
          } else {
            @core.Expr::Call(name~, type_args~, args=next_args, span~)
          }
        None => @core.Expr::Call(name~, type_args~, args=next_args, span~)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=desugar_expr(cond, scope, aliases),
        then_body=desugar_block(then_body, scope, aliases),
        else_body=desugar_block(else_body, scope, aliases),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=desugar_block(body, scope, aliases), span~)
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      let scrut = desugar_expr(scrutinee, scope, aliases)
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let next_cond = match arm.cond {
          Some(c) => Some(desugar_expr(c, arm_scope, aliases))
          None => None
        }
        let next_expr = desugar_expr(arm.expr, arm_scope, aliases)
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Match(scrutinee=scrut, arms=next_arms, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      @core.Expr::Tuple(items=out, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_expr(field.expr, scope, aliases),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=out, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      @core.Expr::Array(items=out, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let out : Array[@core.MapFieldExpr] = []
      for field in fields {
        out.push(@core.MapFieldExpr::{
          key: field.key,
          expr: desugar_expr(field.expr, scope, aliases),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=out, span~)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(fn(c) { desugar_expr(c, scope, aliases) }),
          expr: desugar_expr(arm.expr, scope, aliases),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=desugar_block(body, scope.child(), aliases),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let next_scope = scope.child()
      for param in params {
        next_scope.bindings[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=desugar_block(body, next_scope, aliases),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=desugar_expr(cond, scope, aliases),
        body=desugar_block(body, scope, aliases),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: desugar_expr(param.init, scope, aliases),
          span: param.span,
        })
      }
      let next_scope = scope.child()
      for param in params {
        next_scope.bindings[param.name] = true
      }
      @core.Expr::Loop(
        params=next_params,
        body=desugar_block(body, next_scope, aliases),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) => {
      let next_value = match value {
        Some(e) => Some(desugar_expr(e, scope, aliases))
        None => None
      }
      @core.Expr::Break(value=next_value, span~)
    }
    @core.Expr::Continue(args~, span~) => {
      let next_args : Array[@core.Expr] = []
      for arg in args {
        next_args.push(desugar_expr(arg, scope, aliases))
      }
      @core.Expr::Continue(args=next_args, span~)
    }
    @core.Expr::StringInterp(parts~, span~) => {
      // Lower StringInterp to String::concat chain with __to_string calls
      let exprs : Array[@core.Expr] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(s) =>
            exprs.push(@core.Expr::String(value=s, span~))
          @core.StringInterpPart::Expr(e) =>
            exprs.push(
              @core.Expr::Call(
                name="__to_string",
                type_args=[],
                args=[
                  @core.CallArg::{
                    label: None,
                    expr: desugar_expr(e, scope, aliases),
                    span,
                  },
                ],
                span~,
              ),
            )
        }
      }
      let mut result = exprs[0]
      for j in 1..<exprs.length() {
        result = @core.Expr::Call(
          name="String::concat",
          type_args=[],
          args=[
            @core.CallArg::{ label: None, expr: result, span },
            @core.CallArg::{ label: None, expr: exprs[j], span },
          ],
          span~,
        )
      }
      result
    }
    _ => expr
  }
}

///|
fn split_method_call_name(name : String) -> (String, String)? {
  let chars = name.to_array()
  let mut dot = -1
  let mut count = 0
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      count += 1
    }
  }
  if count != 1 {
    return None
  }
  if dot <= 0 || dot >= chars.length() - 1 {
    return None
  }
  let left = name[0:dot].to_string()
  let right = name[dot + 1:chars.length()].to_string()
  if not(is_simple_ident(left)) || not(is_simple_ident(right)) {
    return None
  }
  Some((left, right))
}

///|
fn is_simple_ident(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  for c in chars {
    let code = c.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95
    if not(ok) {
      return false
    }
  }
  true
}

///|
fn collect_pat_bindings(pat : @core.Pat, out : Array[String]) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      out.push(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pat_bindings(arg, out)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pat_bindings(item, out)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pat_bindings(field.pat, out)
      }
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      if pats.length() > 0 {
        collect_pat_bindings(pats[0], out)
      }
    }
    _ => ()
  }
}

///|
priv struct DesugarScope {
  bindings : Map[String, Bool]
  parent : DesugarScope?
}

///|
fn DesugarScope::new() -> DesugarScope {
  { bindings: {}, parent: None }
}

///|
fn DesugarScope::child(self : DesugarScope) -> DesugarScope {
  { bindings: {}, parent: Some(self) }
}

///|
fn DesugarScope::contains(self : DesugarScope, name : String) -> Bool {
  if self.bindings.contains(name) {
    true
  } else {
    match self.parent {
      Some(p) => p.contains(name)
      None => false
    }
  }
}
