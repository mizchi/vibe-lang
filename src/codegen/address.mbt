///|
/// Address computation for normalized expressions.
pub fn expr_address(
  expr : @core.Expr,
  env : Map[String, String],
  self_name : String?,
) -> String {
  let ctx = AddrCtx::new(env, self_name)
  let sexp = expr_to_addr_sexp(ctx, expr)
  @core.git_blob_hash_string(sexp)
}

///|
priv struct AddrCtx {
  global_env : Map[String, String]
  locals : Map[String, String]
  mut next_local : Int
  self_name : String?
}

///|
fn AddrCtx::new(env : Map[String, String], self_name : String?) -> AddrCtx {
  {
    global_env: addr_clone_string_map(env),
    locals: {},
    next_local: 0,
    self_name,
  }
}

///|
fn AddrCtx::clone(self : AddrCtx) -> AddrCtx {
  {
    global_env: addr_clone_string_map(self.global_env),
    locals: addr_clone_string_map(self.locals),
    next_local: self.next_local,
    self_name: self.self_name,
  }
}

///|
fn addr_bind_local(ctx : AddrCtx, name : String) -> String {
  let id = "v" + ctx.next_local.to_string()
  ctx.next_local += 1
  ctx.locals[name] = id
  id
}

///|
fn local_ref(ctx : AddrCtx, name : String) -> String? {
  ctx.locals.get(name)
}

///|
fn resolve_ref(ctx : AddrCtx, name : String) -> String {
  match local_ref(ctx, name) {
    Some(id) => return "local:" + id
    None => ()
  }
  match ctx.self_name {
    Some(n) => if n == name { return "$self" }
    None => ()
  }
  match ctx.global_env.get(name) {
    Some(addr) => addr
    None => if is_builtin(name) { "builtin:" + name } else { "name:" + name }
  }
}

///|
fn expr_to_addr_sexp(ctx : AddrCtx, expr : @core.Expr) -> String {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      "(lit (int " + n.to_string() + "))"
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      "(lit (float " + n.to_string() + "))"
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      "(lit (double " + n.to_string() + "))"
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      "(lit (bool " + (if b { "true" } else { "false" }) + "))"
    }
    @core.Expr::Char(value=c, span~) => {
      let _ = span
      "(lit (char " + c.to_int().to_string() + "))"
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      "(lit (string " + addr_escape_string(s) + "))"
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      "(ref " + addr_escape_string(resolve_ref(ctx, name)) + ")"
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before codegen
      "(placeholder)"
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(call ")
      buf.write_string(addr_escape_string(resolve_ref(ctx, name)))
      buf.write_string(" (args")
      for arg in args {
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, arg.expr))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      "(tuple-index " +
      expr_to_addr_sexp(ctx, expr) +
      " " +
      index.to_string() +
      ")"
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let ordered = addr_sort_record_fields_expr(fields)
      let buf = StringBuilder::new()
      buf.write_string("(record")
      for field in ordered {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(addr_escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, field.expr))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(array")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let ordered = addr_sort_map_fields_expr(fields)
      let buf = StringBuilder::new()
      buf.write_string("(map")
      for field in ordered {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(addr_escape_string(field.key))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, field.expr))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(if ")
      buf.write_string(expr_to_addr_sexp(ctx, cond))
      buf.write_char(' ')
      buf.write_string(block_to_addr_sexp(ctx, then_body))
      buf.write_char(' ')
      buf.write_string(block_to_addr_sexp(ctx, else_body))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      block_to_addr_sexp(ctx, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(match ")
      buf.write_string(expr_to_addr_sexp(ctx, scrutinee))
      buf.write_string(" (arms")
      for arm in arms {
        buf.write_char(' ')
        buf.write_string(addr_match_arm_to_sexp(ctx, arm))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      "(block " + block_to_addr_sexp(ctx, desugared) + ")"
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(handle ")
      buf.write_string(block_to_addr_sexp(ctx, body))
      buf.write_string(" (arms")
      for arm in arms {
        buf.write_char(' ')
        buf.write_string(addr_match_arm_to_sexp(ctx, arm))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = span
      let fn_ctx = ctx.clone()
      let param_ids : Array[String] = []
      for param in params {
        let id = addr_bind_local(fn_ctx, param.name)
        param_ids.push(id)
      }
      let buf = StringBuilder::new()
      buf.write_string("(fn (params")
      for i in 0..<params.length() {
        buf.write_char(' ')
        buf.write_string(addr_param_to_sexp(params[i], param_ids[i]))
      }
      buf.write_string(") (ret ")
      match ret {
        Some(r) => buf.write_string(addr_type_to_sexp(r))
        None => buf.write_string("_")
      }
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(addr_effect_to_sexp(effect))
      }
      buf.write_string(") ")
      buf.write_string(block_to_addr_sexp(fn_ctx, body))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      "(while " +
      expr_to_addr_sexp(ctx, cond) +
      " " +
      block_to_addr_sexp(ctx, body) +
      ")"
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(loop (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string("(")
        buf.write_string(addr_escape_string(param.name))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, param.init))
        buf.write_char(')')
      }
      buf.write_string(") ")
      buf.write_string(block_to_addr_sexp(ctx, body))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Break(span~, ..) => {
      let _ = span
      "(break)"
    }
    @core.Expr::Continue(span~, ..) => {
      let _ = span
      "(continue)"
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      "(throw " + expr_to_addr_sexp(ctx, value) + ")"
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      "(yield " + expr_to_addr_sexp(ctx, expr) + ")"
    }
    @core.Expr::StructLit(name~, fields~, span~, ..) => {
      let _ = span
      let ordered = addr_sort_record_fields_expr(fields)
      let buf = StringBuilder::new()
      buf.write_string("(struct ")
      buf.write_string(addr_escape_string(name))
      for field in ordered {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(addr_escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(ctx, field.expr))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
  }
}

///|
fn block_to_addr_sexp(ctx : AddrCtx, body : @core.Module) -> String {
  let block_ctx = ctx.clone()
  let buf = StringBuilder::new()
  buf.write_string("(block")
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        if rec {
          let _ = span
          let _ = addr_bind_local(block_ctx, name)
          buf.write_string(" (let-rec ")
          buf.write_string(expr_to_addr_sexp(block_ctx, expr))
          buf.write_char(')')
        } else {
          let _ = span
          buf.write_string(" (let ")
          buf.write_string(expr_to_addr_sexp(block_ctx, expr))
          buf.write_char(')')
          let _ = addr_bind_local(block_ctx, name)
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = span
        buf.write_string(" (enum ")
        buf.write_string(addr_escape_string(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(addr_escape_string(param))
        }
        buf.write_string(") (ctors")
        let sorted = addr_sort_type_ctors(ctors)
        for ctor in sorted {
          buf.write_string(" (ctor ")
          buf.write_string(addr_escape_string(ctor.name))
          buf.write_char(' ')
          buf.write_string(addr_type_to_sexp(addr_type_ctor_payload(ctor)))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        let _ = span
        buf.write_string(" (type-alias ")
        buf.write_string(addr_escape_string(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(addr_escape_string(param))
        }
        buf.write_string(") ")
        buf.write_string(addr_type_to_sexp(target))
        buf.write_char(')')
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        buf.write_string(" (expr ")
        buf.write_string(expr_to_addr_sexp(block_ctx, expr))
        buf.write_char(')')
      }
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = spec
        let _ = source
        let _ = span
        buf.write_string(" (import)")
      }
      @core.Stmt::ExternLet(name~, ty~, span~) => {
        let _ = name
        let _ = ty
        let _ = span
        buf.write_string(" (extern)")
      }
      @core.Stmt::ExportLet(..)
      | @core.Stmt::InternalExportLet(..)
      | @core.Stmt::ExportEnumDef(..)
      | @core.Stmt::InternalExportEnumDef(..)
      | @core.Stmt::ExportTypeAlias(..)
      | @core.Stmt::InternalExportTypeAlias(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::InternalTraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::StructDef(..)
      | @core.Stmt::ExportStructDef(..)
      | @core.Stmt::InternalExportStructDef(..) => buf.write_string(" (export)")
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        buf.write_string(" (test ")
        buf.write_string(block_to_addr_sexp(block_ctx, body))
        buf.write_char(')')
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = span
        buf.write_string(" (bench ")
        buf.write_string(block_to_addr_sexp(block_ctx, body))
        buf.write_char(')')
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (let-mut ")
        buf.write_string(expr_to_addr_sexp(block_ctx, expr))
        buf.write_char(')')
        let _ = addr_bind_local(block_ctx, name)
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (assign ")
        buf.write_string(addr_escape_string(resolve_ref(block_ctx, name)))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(block_ctx, expr))
        buf.write_char(')')
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        buf.write_string(" (index-assign ")
        buf.write_string(expr_to_addr_sexp(block_ctx, target))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(block_ctx, index))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(block_ctx, value))
        buf.write_char(')')
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        bind_pattern(block_ctx, pat)
        buf.write_string(" (let-pat ")
        buf.write_string(addr_pat_to_sexp(block_ctx, pat))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(block_ctx, expr))
        buf.write_char(')')
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        bind_pattern(block_ctx, pat)
        buf.write_string(" (let-pat-else ")
        buf.write_string(addr_pat_to_sexp(block_ctx, pat))
        buf.write_char(' ')
        buf.write_string(expr_to_addr_sexp(block_ctx, expr))
        buf.write_char(' ')
        buf.write_string(block_to_addr_sexp(block_ctx, else_body))
        buf.write_char(')')
      }
    }
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn addr_match_arm_to_sexp(ctx : AddrCtx, arm : @core.MatchArm) -> String {
  let arm_ctx = ctx.clone()
  bind_pattern(arm_ctx, arm.pat)
  let buf = StringBuilder::new()
  buf.write_string("(arm ")
  buf.write_string(addr_pat_to_sexp(arm_ctx, arm.pat))
  match arm.cond {
    Some(c) => {
      buf.write_string(" (guard ")
      buf.write_string(expr_to_addr_sexp(arm_ctx, c))
      buf.write_char(')')
    }
    None => ()
  }
  buf.write_char(' ')
  buf.write_string(expr_to_addr_sexp(arm_ctx, arm.expr))
  buf.write_char(')')
  buf.to_string()
}

///|
fn bind_pattern(ctx : AddrCtx, pat : @core.Pat) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let _ = addr_bind_local(ctx, name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        bind_pattern(ctx, arg)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        bind_pattern(ctx, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        bind_pattern(ctx, field.pat)
      }
    }
    @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      for field in fields {
        bind_pattern(ctx, field.pat)
      }
    }
    _ => ()
  }
}

///|
fn addr_pat_to_sexp(ctx : AddrCtx, pat : @core.Pat) -> String {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      "(pat _)"
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      match local_ref(ctx, name) {
        Some(id) => "(pat (bind " + addr_escape_string("local:" + id) + "))"
        None => "(pat (bind " + addr_escape_string(name) + "))"
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (ctor ")
      buf.write_string(addr_escape_string(name))
      for arg in args {
        buf.write_char(' ')
        buf.write_string(addr_pat_to_sexp(ctx, arg))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(addr_pat_to_sexp(ctx, item))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (record")
      for field in fields {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(addr_escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(addr_pat_to_sexp(ctx, field.pat))
        buf.write_char(')')
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      "(pat (int " + n.to_string() + "))"
    }
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      "(pat (float " + n.to_string() + "))"
    }
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      "(pat (double " + n.to_string() + "))"
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      "(pat (bool " + (if b { "true" } else { "false" }) + "))"
    }
    @core.Pat::Char(value=c, span~) => {
      let _ = span
      "(pat (char " + c.to_int().to_string() + "))"
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      "(pat (string " + addr_escape_string(s) + "))"
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (or")
      for p in pats {
        buf.write_char(' ')
        buf.write_string(addr_pat_to_sexp(ctx, p))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (struct ")
      buf.write_string(addr_escape_string(name))
      for field in fields {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(addr_escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(addr_pat_to_sexp(ctx, field.pat))
        buf.write_char(')')
      }
      buf.write_string("))")
      buf.to_string()
    }
  }
}

///|
fn addr_param_to_sexp(param : @core.FuncParam, id : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(param ")
  buf.write_string(addr_escape_string(id))
  buf.write_char(' ')
  buf.write_string(addr_label_to_sexp(param.label))
  buf.write_char(' ')
  buf.write_string(addr_type_to_sexp(param.ty))
  buf.write_char(')')
  buf.to_string()
}

///|
fn addr_label_to_sexp(label : @core.ParamLabel) -> String {
  match label {
    @core.ParamLabel::Positional => "pos"
    @core.ParamLabel::Variadic => "var"
    @core.ParamLabel::Required => "req"
    @core.ParamLabel::Optional => "opt"
  }
}

///|
fn addr_type_to_sexp(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "Int"
    @core.Type::Float => "Float"
    @core.Type::Double => "Double"
    @core.Type::Bool => "Bool"
    @core.Type::Char => "Char"
    @core.Type::String => "String"
    @core.Type::Path => "@core.Path"
    @core.Type::PromptText => "PromptText"
    @core.Type::Unit => "Unit"
    @core.Type::Named(name~, args~) =>
      match name {
        "Int" | "i32" if args.is_empty() => "Int"
        "Float" | "f32" if args.is_empty() => "Float"
        "Double" | "f64" if args.is_empty() => "Double"
        "Bool" if args.is_empty() => "Bool"
        "Char" if args.is_empty() => "Char"
        "String" if args.is_empty() => "String"
        "@core.Path" if args.is_empty() => "@core.Path"
        "PromptText" if args.is_empty() => "PromptText"
        "Unit" if args.is_empty() => "Unit"
        "StringBuilder" if args.is_empty() => "StringBuilder"
        "Bytes" if args.is_empty() => "Bytes"
        "Array" if args.length() == 1 =>
          "(Array " + addr_type_to_sexp(args[0]) + ")"
        "Map" if args.length() == 1 =>
          "(Map " + addr_type_to_sexp(args[0]) + ")"
        "ArrayBuilder" if args.length() == 1 =>
          "(ArrayBuilder " + addr_type_to_sexp(args[0]) + ")"
        "MapBuilder" if args.length() == 1 =>
          "(MapBuilder " + addr_type_to_sexp(args[0]) + ")"
        _ => {
          let buf = StringBuilder::new()
          buf.write_string("(Named ")
          buf.write_string(addr_escape_string(name))
          for arg in args {
            buf.write_char(' ')
            buf.write_string(addr_type_to_sexp(arg))
          }
          buf.write_char(')')
          buf.to_string()
        }
      }
    @core.Type::Param(name) => "(Param " + addr_escape_string(name) + ")"
    @core.Type::Var(id) => "(Var " + id.to_string() + ")"
    @core.Type::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(Tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(addr_type_to_sexp(item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Record(fields) => {
      let keys = addr_sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Record")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(field ")
            buf.write_string(addr_escape_string(key))
            buf.write_char(' ')
            buf.write_string(addr_type_to_sexp(field_ty))
            buf.write_char(')')
          }
          None => ()
        }
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Array(inner) => "(Array " + addr_type_to_sexp(inner) + ")"
    @core.Type::Map(_key, inner) => "(Map " + addr_type_to_sexp(inner) + ")"
    @core.Type::ArrayBuilder(inner) =>
      "(ArrayBuilder " + addr_type_to_sexp(inner) + ")"
    @core.Type::MapBuilder(_key, inner) =>
      "(MapBuilder " + addr_type_to_sexp(inner) + ")"
    @core.Type::StringBuilder => "StringBuilder"
    @core.Type::Bytes => "Bytes"
    @core.Type::Variant(fields) => {
      let keys = addr_sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Variant")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(ctor ")
            buf.write_string(addr_escape_string(key))
            buf.write_char(' ')
            buf.write_string(addr_type_to_sexp(field_ty))
            buf.write_char(')')
          }
          None => ()
        }
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let buf = StringBuilder::new()
      buf.write_string("(Func (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(addr_param_to_sexp(param, "_"))
      }
      buf.write_string(") (ret ")
      buf.write_string(addr_type_to_sexp(ret))
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(addr_effect_to_sexp(effect))
      }
      buf.write_char(')')
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Never => "Never"
  }
}

///|
fn addr_effect_to_sexp(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => addr_escape_string(name)
    @core.EffectAtom::Var(name) => addr_escape_string(name)
  }
}

///|
fn addr_type_ctor_payload(ctor : @core.TypeCtor) -> @core.Type {
  if ctor.args.length() == 0 {
    @core.Type::Unit
  } else if ctor.args.length() == 1 {
    ctor.args[0]
  } else {
    @core.Type::Tuple(ctor.args)
  }
}

///|
fn addr_sort_record_type_keys(
  fields : Map[String, @core.Type],
) -> Array[String] {
  let out : Array[String] = []
  for name, _ in fields {
    out.push(name)
    let mut i = out.length() - 1
    while i > 0 && addr_string_lt(out[i], out[i - 1]) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn addr_sort_type_ctors(ctors : Array[@core.TypeCtor]) -> Array[@core.TypeCtor] {
  let out : Array[@core.TypeCtor] = []
  for ctor in ctors {
    out.push(ctor)
    let mut i = out.length() - 1
    while i > 0 && addr_string_lt(out[i].name, out[i - 1].name) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn addr_sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && addr_string_lt(out[i].name, out[i - 1].name) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn addr_sort_map_fields_expr(
  fields : Array[@core.MapFieldExpr],
) -> Array[@core.MapFieldExpr] {
  let out : Array[@core.MapFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && addr_string_lt(out[i].key, out[i - 1].key) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn addr_string_lt(a : String, b : String) -> Bool {
  let ac : Array[Char] = []
  for c in a {
    ac.push(c)
  }
  let bc : Array[Char] = []
  for c in b {
    bc.push(c)
  }
  let min = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<min {
    if ac[i] < bc[i] {
      return true
    }
    if ac[i] > bc[i] {
      return false
    }
  }
  ac.length() < bc.length()
}

///|
fn addr_escape_string(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\"')
  for ch in s {
    match ch {
      '\"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(ch)
    }
  }
  buf.write_char('\"')
  buf.to_string()
}

///|
fn addr_clone_string_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

///|
fn is_builtin(name : String) -> Bool {
  name == "path" ||
  name == "path_ref" ||
  name == "path_to_string" ||
  name == "path_is_absolute" ||
  name == "dynamic_path_resolve" ||
  name == "addr" ||
  name == "sh" ||
  name == "stdout_write_char" ||
  name == "stdout_write_stream" ||
  name == "stdin_read_char" ||
  name == "stdin_read_stream" ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__mod" ||
  name == "__index" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__assert" ||
  name == "array_builder" ||
  name == "array_builder_push" ||
  name == "array_builder_freeze" ||
  name == "array_push" ||
  name == "array_set" ||
  name == "array_new" ||
  name == "array_truncate" ||
  name == "array_contains_str" ||
  name == "double_to_i64_bits" ||
  name == "i64_bits_to_double" ||
  name == "string_to_data" ||
  name == "fs_write_bytes" ||
  name == "bytes_from_array" ||
  name == "bytes_length" ||
  name == "bytes_get" ||
  name == "map_builder" ||
  name == "map_builder_set" ||
  name == "map_builder_freeze" ||
  name == "map_keys" ||
  name == "map_values" ||
  name == "map_has_key" ||
  name == "array_slice" ||
  name == "int_to_float" ||
  name == "int_to_double" ||
  name == "float_to_int" ||
  name == "float_to_double" ||
  name == "double_to_int" ||
  name == "double_to_float" ||
  name == "__to_string" ||
  name == "fs_read_file" ||
  name == "fs_write_file" ||
  name == "fs_exists" ||
  name == "socket_tcp_connect" ||
  name == "socket_tcp_read" ||
  name == "socket_tcp_write" ||
  name == "socket_tcp_close" ||
  name == "http_request" ||
  name == "http_response_status" ||
  name == "http_response_header" ||
  name == "http_response_body" ||
  name == "http_close" ||
  name == "http_listen" ||
  name == "http_accept" ||
  name == "http_request_method" ||
  name == "http_request_url" ||
  name == "http_request_header" ||
  name == "http_request_body" ||
  name == "http_respond"
}
