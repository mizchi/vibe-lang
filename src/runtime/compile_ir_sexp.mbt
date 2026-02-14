///|
/// Convert module to canonical S-expression for hashing.
fn module_to_sexp(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> String {
  "(module " + stmts_to_sexp(ast.stmts, aliases) + ")"
}

///|
fn stmts_to_sexp(
  stmts : Array[@core.Stmt],
  aliases : Map[String, @core.Ref],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(stmts")
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          buf.write_string(" (let-rec ")
        } else {
          buf.write_string(" (let ")
        }
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = span
        buf.write_string(" (enum ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") (ctors")
        let sorted = sort_type_ctors(ctors)
        for ctor in sorted {
          buf.write_string(" (ctor ")
          buf.write_string(escape_atom(ctor.name))
          buf.write_char(' ')
          buf.write_string(type_to_sexp(type_ctor_payload(ctor)))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        let _ = span
        buf.write_string(" (type-alias ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") ")
        buf.write_string(type_to_sexp(target))
        buf.write_char(')')
      }
      @core.Stmt::TraitDef(..) => ()
      @core.Stmt::TraitImpl(..) => ()
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        buf.write_string(" (expr ")
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = spec
        let _ = source
        let _ = span
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          buf.write_string(" (export-let-rec ")
        } else {
          buf.write_string(" (export-let ")
        }
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        let _ = span
        buf.write_string(" (export-enum ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") (ctors")
        let sorted = sort_type_ctors(ctors)
        for ctor in sorted {
          buf.write_string(" (ctor ")
          buf.write_string(escape_atom(ctor.name))
          buf.write_char(' ')
          buf.write_string(type_to_sexp(type_ctor_payload(ctor)))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
        let _ = span
        buf.write_string(" (export-type-alias ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") ")
        buf.write_string(type_to_sexp(target))
        buf.write_char(')')
      }
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) => ()
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (let-mut ")
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (assign ")
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        buf.write_string(" (index-assign ")
        buf.write_string(expr_to_sexp(target, aliases))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(index, aliases))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(value, aliases))
        buf.write_char(')')
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        buf.write_string(" (let-pat ")
        buf.write_string(pat_to_sexp(pat))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        buf.write_string(" (let-pat-else ")
        buf.write_string(pat_to_sexp(pat))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(' ')
        buf.write_string(block_to_sexp(else_body, aliases))
        buf.write_char(')')
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) => {
        let _ = span
        buf.write_string(" (struct ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") (fields")
        for field in fields {
          buf.write_string(" (field ")
          buf.write_string(escape_atom(field.name))
          buf.write_char(' ')
          buf.write_string(type_to_sexp(field.ty))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
        let _ = span
        buf.write_string(" (export-struct ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") (fields")
        for field in fields {
          buf.write_string(" (field ")
          buf.write_string(escape_atom(field.name))
          buf.write_char(' ')
          buf.write_string(type_to_sexp(field.ty))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
    }
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn block_to_sexp(
  body : @core.Module,
  aliases : Map[String, @core.Ref],
) -> String {
  "(block " + stmts_to_sexp(body.stmts, aliases) + ")"
}

///|
/// Convert expression to S-expression.
fn expr_to_sexp(expr : @core.Expr, aliases : Map[String, @core.Ref]) -> String {
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
      "(lit (string " + escape_string(s) + "))"
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      let resolved = @core.resolve_qualified(name, aliases)
      "(ref " + escape_string(resolved) + ")"
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before compile
      "(placeholder)"
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let resolved = @core.resolve_qualified(name, aliases)
      let buf = StringBuilder::new()
      buf.write_string("(call ")
      buf.write_string(escape_string(resolved))
      buf.write_char(' ')
      buf.write_string(call_args_to_sexp(args, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(if ")
      buf.write_string(expr_to_sexp(cond, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(then_body, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(else_body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      block_to_sexp(body, aliases)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(match ")
      buf.write_string(expr_to_sexp(scrutinee, aliases))
      buf.write_string(" (arms")
      for arm in arms {
        buf.write_char(' ')
        buf.write_string(match_arm_to_sexp(arm, aliases))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      "(do " + block_to_sexp(body, aliases) + ")"
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      "(tuple-index " +
      expr_to_sexp(expr, aliases) +
      " " +
      index.to_string() +
      ")"
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(record")
      let sorted = sort_record_fields_expr(fields)
      for field in sorted {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(field.expr, aliases))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let _ = span
      let _ = type_args // Type args are inferred, not needed in sexp
      let buf = StringBuilder::new()
      buf.write_string("(struct-lit ")
      buf.write_string(escape_string(name))
      let sorted = sort_record_fields_expr(fields)
      for field in sorted {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(field.expr, aliases))
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
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(map")
      let sorted = sort_map_fields_expr(fields)
      for field in sorted {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.key))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(field.expr, aliases))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(try ")
      buf.write_string(block_to_sexp(try_body, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(catch_body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(fn (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(param_to_sexp(param))
      }
      buf.write_string(") (ret ")
      match ret {
        Some(r) => buf.write_string(type_to_sexp(r))
        None => buf.write_string("_")
      }
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(effect_atom_to_sexp(effect))
      }
      buf.write_string(") ")
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(while ")
      buf.write_string(expr_to_sexp(cond, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Break(..) => "(break)"
    @core.Expr::Continue(..) => "(continue)"
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(loop (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(escape_atom(param.name))
      }
      buf.write_string(") ")
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      "(raise " + expr_to_sexp(value, aliases) + ")"
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      "(await " + expr_to_sexp(expr, aliases) + ")"
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      "(yield " + expr_to_sexp(expr, aliases) + ")"
    }
  }
}

///|
fn call_args_to_sexp(
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(args")
  for arg in args {
    buf.write_string(" (arg ")
    match arg.label {
      Some(label) => buf.write_string(escape_atom(label))
      None => buf.write_string("_")
    }
    buf.write_char(' ')
    buf.write_string(expr_to_sexp(arg.expr, aliases))
    buf.write_char(')')
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn param_to_sexp(param : @core.FuncParam) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(param ")
  buf.write_string(escape_atom(param.name))
  buf.write_char(' ')
  buf.write_string(label_to_sexp(param.label))
  buf.write_char(' ')
  buf.write_string(type_to_sexp(param.ty))
  buf.write_char(')')
  buf.to_string()
}

///|
fn label_to_sexp(label : @core.ParamLabel) -> String {
  match label {
    @core.ParamLabel::Positional => "pos"
    @core.ParamLabel::Required => "req"
    @core.ParamLabel::Optional => "opt"
  }
}

///|
fn type_to_sexp(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "Int"
    @core.Type::Float => "Float"
    @core.Type::Double => "Double"
    @core.Type::Bool => "Bool"
    @core.Type::Char => "Char"
    @core.Type::String => "String"
    @core.Type::Path => "@core.Path"
    @core.Type::Unit => "Unit"
    @core.Type::Named(name~, args~) => {
      let buf = StringBuilder::new()
      buf.write_string("(Named ")
      buf.write_string(escape_atom(name))
      for arg in args {
        buf.write_char(' ')
        buf.write_string(type_to_sexp(arg))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Param(name) => "(Param " + escape_atom(name) + ")"
    @core.Type::Var(id) => "(Var " + id.to_string() + ")"
    @core.Type::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(Tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(type_to_sexp(item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Record(fields) => {
      let keys = sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Record")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(field ")
            buf.write_string(escape_atom(key))
            buf.write_char(' ')
            buf.write_string(type_to_sexp(field_ty))
            buf.write_char(')')
          }
          None => ()
        }
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Array(inner) => "(Array " + type_to_sexp(inner) + ")"
    @core.Type::Map(inner) => "(Map " + type_to_sexp(inner) + ")"
    @core.Type::ArrayBuilder(inner) =>
      "(ArrayBuilder " + type_to_sexp(inner) + ")"
    @core.Type::MapBuilder(inner) => "(MapBuilder " + type_to_sexp(inner) + ")"
    @core.Type::StringBuilder => "StringBuilder"
    @core.Type::Variant(fields) => {
      let keys = sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Variant")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(ctor ")
            buf.write_string(escape_atom(key))
            buf.write_char(' ')
            buf.write_string(type_to_sexp(field_ty))
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
        buf.write_string(param_to_sexp(param))
      }
      buf.write_string(") (ret ")
      buf.write_string(type_to_sexp(ret))
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(effect_atom_to_sexp(effect))
      }
      buf.write_char(')')
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Never => "Never"
  }
}

///|
fn effect_atom_to_sexp(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => escape_atom(name)
    @core.EffectAtom::Var(name) => escape_atom(name)
  }
}

///|
fn type_ctor_payload(ctor : @core.TypeCtor) -> @core.Type {
  if ctor.args.length() == 0 {
    @core.Type::Unit
  } else if ctor.args.length() == 1 {
    ctor.args[0]
  } else {
    @core.Type::Tuple(ctor.args)
  }
}

///|
fn sort_record_type_keys(fields : Map[String, @core.Type]) -> Array[String] {
  let out : Array[String] = []
  for name, _ in fields {
    out.push(name)
    let mut i = out.length() - 1
    while i > 0 && out[i] < out[i - 1] {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_map_fields_expr(
  fields : Array[@core.MapFieldExpr],
) -> Array[@core.MapFieldExpr] {
  let out : Array[@core.MapFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].key < out[i - 1].key {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_type_ctors(ctors : Array[@core.TypeCtor]) -> Array[@core.TypeCtor] {
  let out : Array[@core.TypeCtor] = []
  for ctor in ctors {
    out.push(ctor)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn match_arm_to_sexp(
  arm : @core.MatchArm,
  aliases : Map[String, @core.Ref],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(arm ")
  buf.write_string(pat_to_sexp(arm.pat))
  match arm.cond {
    Some(c) => {
      buf.write_string(" (guard ")
      buf.write_string(expr_to_sexp(c, aliases))
      buf.write_char(')')
    }
    None => ()
  }
  buf.write_char(' ')
  buf.write_string(expr_to_sexp(arm.expr, aliases))
  buf.write_char(')')
  buf.to_string()
}

///|
fn pat_to_sexp(pat : @core.Pat) -> String {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      "(pat _)"
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      "(pat (bind " + escape_string(name) + "))"
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (ctor ")
      buf.write_string(escape_string(name))
      for arg in args {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(arg))
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
        buf.write_string(pat_to_sexp(item))
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
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(field.pat))
        buf.write_char(')')
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (struct ")
      buf.write_string(escape_string(name))
      for field in fields {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(field.pat))
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
      "(pat (string " + escape_string(s) + "))"
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (or")
      for p in pats {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(p))
      }
      buf.write_string("))")
      buf.to_string()
    }
  }
}

///|
/// Escape a string literal for S-expr.
fn escape_string(s : String) -> String {
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
/// Escape atom when used as name.
fn escape_atom(s : String) -> String {
  if s.is_empty() {
    "\"\""
  } else {
    escape_string(s)
  }
}
