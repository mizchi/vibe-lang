///| AST Serialization to JSON for content-addressable hashing

///|

///| Produces canonical JSON (sorted keys, compact format)

///|
/// Serialize a module to canonical JSON
pub fn serialize_module(m : Module) -> String {
  let buf = StringBuilder::new()
  serialize_module_to(m, buf)
  buf.to_string()
}

///|
fn serialize_module_to(m : Module, buf : StringBuilder) -> Unit {
  buf.write_string("{\"stmts\":[")
  for i, stmt in m.stmts {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_stmt_to(stmt, buf)
  }
  buf.write_string("]}")
}

///|
fn serialize_stmt_to(stmt : Stmt, buf : StringBuilder) -> Unit {
  match stmt {
    Stmt::Let(rec~, name~, expr~, ..) => {
      buf.write_string("{\"Let\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"rec\":")
      buf.write_string(rec.to_string())
      buf.write_string("}}")
    }
    Stmt::LetMut(name~, expr~, ..) => {
      buf.write_string("{\"LetMut\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
    Stmt::LetPat(pat~, expr~, ..) => {
      buf.write_string("{\"LetPat\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"pat\":")
      serialize_pat_to(pat, buf)
      buf.write_string("}}")
    }
    Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      buf.write_string("{\"LetPatElse\":{\"else_body\":")
      serialize_module_to(else_body, buf)
      buf.write_string(",\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"pat\":")
      serialize_pat_to(pat, buf)
      buf.write_string("}}")
    }
    Stmt::Assign(name~, expr~, ..) => {
      buf.write_string("{\"Assign\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
    Stmt::IndexAssign(target~, index~, value~, ..) => {
      buf.write_string("{\"IndexAssign\":{\"target\":")
      serialize_expr_to(target, buf)
      buf.write_string(",\"index\":")
      serialize_expr_to(index, buf)
      buf.write_string(",\"value\":")
      serialize_expr_to(value, buf)
      buf.write_string("}}")
    }
    Stmt::Expr(expr~, ..) => {
      buf.write_string("{\"Expr\":")
      serialize_expr_to(expr, buf)
      buf.write_char('}')
    }
    Stmt::Test(name~, body~, ..) => {
      buf.write_string("{\"Test\":{\"body\":")
      serialize_module_to(body, buf)
      buf.write_string(",\"name\":")
      match name {
        Some(n) => serialize_string_to(n, buf)
        None => buf.write_string("null")
      }
      buf.write_string("}}")
    }
    Stmt::Bench(name~, body~, ..) => {
      buf.write_string("{\"Bench\":{\"body\":")
      serialize_module_to(body, buf)
      buf.write_string(",\"name\":")
      match name {
        Some(n) => serialize_string_to(n, buf)
        None => buf.write_string("null")
      }
      buf.write_string("}}")
    }
    Stmt::EnumDef(name~, params~, ctors~, ..) => {
      buf.write_string("{\"EnumDef\":{\"ctors\":")
      serialize_ctors_to(ctors, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string("}}")
    }
    Stmt::TypeAlias(name~, params~, target~, ..) => {
      buf.write_string("{\"TypeAlias\":{\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string(",\"target\":")
      serialize_type_to(target, buf)
      buf.write_string("}}")
    }
    Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, ..) => {
      buf.write_string("{\"TraitDef\":{\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"supertraits\":")
      serialize_strings_to(supertraits, buf)
      buf.write_string(",\"open_impl\":")
      buf.write_string(open_impl.to_string())
      buf.write_string(",\"exported\":")
      buf.write_string(exported.to_string())
      buf.write_string("}}")
    }
    Stmt::TraitImpl(type_params~, type_bounds~, trait_name~, target~, ..) => {
      buf.write_string("{\"TraitImpl\":{\"target\":")
      serialize_type_to(target, buf)
      buf.write_string(",\"trait_name\":")
      serialize_string_to(trait_name, buf)
      buf.write_string(",\"type_bounds\":")
      serialize_string_array_map_to(type_bounds, buf)
      buf.write_string(",\"type_params\":")
      serialize_strings_to(type_params, buf)
      buf.write_string("}}")
    }
    Stmt::Import(spec~, source~, ..) => {
      buf.write_string("{\"Import\":{\"source\":")
      serialize_module_ref_to(source, buf)
      buf.write_string(",\"spec\":")
      serialize_import_spec_to(spec, buf)
      buf.write_string("}}")
    }
    Stmt::ExportLet(rec~, name~, expr~, ..) => {
      buf.write_string("{\"ExportLet\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"rec\":")
      buf.write_string(rec.to_string())
      buf.write_string("}}")
    }
    Stmt::ExportEnumDef(name~, params~, ctors~, ..) => {
      buf.write_string("{\"ExportEnumDef\":{\"ctors\":")
      serialize_ctors_to(ctors, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string("}}")
    }
    Stmt::ExportTypeAlias(name~, params~, target~, ..) => {
      buf.write_string("{\"ExportTypeAlias\":{\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string(",\"target\":")
      serialize_type_to(target, buf)
      buf.write_string("}}")
    }
    Stmt::Export(names~, ..) => {
      buf.write_string("{\"Export\":")
      serialize_strings_to(names, buf)
      buf.write_char('}')
    }
    Stmt::ReExport(names~, source~, ..) => {
      buf.write_string("{\"ReExport\":{\"names\":")
      serialize_strings_to(names, buf)
      buf.write_string(",\"source\":")
      serialize_module_ref_to(source, buf)
      buf.write_string("}}")
    }
    Stmt::StructDef(name~, params~, fields~, ..) => {
      buf.write_string("{\"StructDef\":{\"fields\":")
      serialize_struct_fields_to(fields, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string("}}")
    }
    Stmt::ExportStructDef(name~, params~, fields~, ..) => {
      buf.write_string("{\"ExportStructDef\":{\"fields\":")
      serialize_struct_fields_to(fields, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"params\":")
      serialize_strings_to(params, buf)
      buf.write_string("}}")
    }
  }
}

///|
fn serialize_expr_to(expr : Expr, buf : StringBuilder) -> Unit {
  match expr {
    Expr::Int(value~, ..) => {
      buf.write_string("{\"Int\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Expr::Float(value~, ..) => {
      buf.write_string("{\"Float\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Expr::Double(value~, ..) => {
      buf.write_string("{\"Double\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Expr::Bool(value~, ..) => {
      buf.write_string("{\"Bool\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Expr::Char(value~, ..) => {
      buf.write_string("{\"Char\":")
      serialize_string_to(value.to_string(), buf)
      buf.write_char('}')
    }
    Expr::String(value~, ..) => {
      buf.write_string("{\"String\":")
      serialize_string_to(value, buf)
      buf.write_char('}')
    }
    Expr::Ident(name~, ..) => {
      buf.write_string("{\"Ident\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
    Expr::Placeholder(index~, ..) => {
      buf.write_string("{\"Placeholder\":")
      buf.write_string(index.to_string())
      buf.write_char('}')
    }
    Expr::Call(name~, args~, ..) => {
      buf.write_string("{\"Call\":{\"args\":")
      serialize_call_args_to(args, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
    Expr::Fn(type_params~, type_bounds~, params~, ret~, effects~, body~, ..) => {
      buf.write_string("{\"Fn\":{\"body\":")
      serialize_module_to(body, buf)
      buf.write_string(",\"effects\":")
      serialize_effects_to(effects, buf)
      buf.write_string(",\"params\":")
      serialize_params_to(params, buf)
      buf.write_string(",\"ret\":")
      match ret {
        Some(t) => serialize_type_to(t, buf)
        None => buf.write_string("null")
      }
      buf.write_string(",\"type_bounds\":")
      serialize_string_array_map_to(type_bounds, buf)
      buf.write_string(",\"type_params\":")
      serialize_strings_to(type_params, buf)
      buf.write_string("}}")
    }
    Expr::If(cond~, then_body~, else_body~, ..) => {
      buf.write_string("{\"If\":{\"cond\":")
      serialize_expr_to(cond, buf)
      buf.write_string(",\"else\":")
      serialize_module_to(else_body, buf)
      buf.write_string(",\"then\":")
      serialize_module_to(then_body, buf)
      buf.write_string("}}")
    }
    Expr::Match(scrutinee~, arms~, ..) => {
      buf.write_string("{\"Match\":{\"arms\":")
      serialize_arms_to(arms, buf)
      buf.write_string(",\"expr\":")
      serialize_expr_to(scrutinee, buf)
      buf.write_string("}}")
    }
    Expr::Block(body~, ..) => {
      buf.write_string("{\"Block\":")
      serialize_module_to(body, buf)
      buf.write_char('}')
    }
    Expr::Tuple(items~, ..) => {
      buf.write_string("{\"Tuple\":")
      serialize_exprs_to(items, buf)
      buf.write_char('}')
    }
    Expr::TupleIndex(expr~, index~, ..) => {
      buf.write_string("{\"TupleIndex\":{\"expr\":")
      serialize_expr_to(expr, buf)
      buf.write_string(",\"index\":")
      buf.write_string(index.to_string())
      buf.write_string("}}")
    }
    Expr::Array(items~, ..) => {
      buf.write_string("{\"Array\":")
      serialize_exprs_to(items, buf)
      buf.write_char('}')
    }
    Expr::Record(fields~, ..) => {
      buf.write_string("{\"Record\":")
      serialize_record_fields_to(fields, buf)
      buf.write_char('}')
    }
    Expr::Map(fields~, ..) => {
      buf.write_string("{\"Map\":")
      serialize_map_fields_to(fields, buf)
      buf.write_char('}')
    }
    Expr::Do(body~, ..) => {
      buf.write_string("{\"Do\":")
      serialize_module_to(body, buf)
      buf.write_char('}')
    }
    Expr::While(cond~, body~, ..) => {
      buf.write_string("{\"While\":{\"body\":")
      serialize_module_to(body, buf)
      buf.write_string(",\"cond\":")
      serialize_expr_to(cond, buf)
      buf.write_string("}}")
    }
    Expr::Break(..) => buf.write_string("{\"Break\":null}")
    Expr::Continue(..) => buf.write_string("{\"Continue\":null}")
    Expr::Loop(params~, body~, ..) => {
      buf.write_string("{\"Loop\":{\"body\":")
      serialize_module_to(body, buf)
      buf.write_string(",\"params\":")
      serialize_loop_params_to(params, buf)
      buf.write_string("}}")
    }
    Expr::Try(try_body~, catch_body~, ..) => {
      buf.write_string("{\"Try\":{\"catch\":")
      serialize_module_to(catch_body, buf)
      buf.write_string(",\"try\":")
      serialize_module_to(try_body, buf)
      buf.write_string("}}")
    }
    Expr::Raise(value~, ..) => {
      buf.write_string("{\"Raise\":")
      serialize_expr_to(value, buf)
      buf.write_char('}')
    }
    Expr::Await(expr=inner, ..) => {
      buf.write_string("{\"Await\":")
      serialize_expr_to(inner, buf)
      buf.write_char('}')
    }
    Expr::Yield(expr=inner, ..) => {
      buf.write_string("{\"Yield\":")
      serialize_expr_to(inner, buf)
      buf.write_char('}')
    }
    Expr::StructLit(name~, type_args~, fields~, ..) => {
      buf.write_string("{\"StructLit\":{\"fields\":")
      serialize_record_fields_to(fields, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string(",\"type_args\":")
      serialize_types_to(type_args, buf)
      buf.write_string("}}")
    }
  }
}

///|
fn serialize_string_to(s : String, buf : StringBuilder) -> Unit {
  buf.write_char('"')
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.write_char('"')
}

///|
fn serialize_strings_to(strs : Array[String], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, s in strs {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_string_to(s, buf)
  }
  buf.write_char(']')
}

///|
fn serialize_exprs_to(exprs : Array[Expr], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, e in exprs {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_expr_to(e, buf)
  }
  buf.write_char(']')
}

///|
fn serialize_call_args_to(args : Array[CallArg], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, arg in args {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"expr\":")
    serialize_expr_to(arg.expr, buf)
    buf.write_string(",\"label\":")
    match arg.label {
      Some(l) => serialize_string_to(l, buf)
      None => buf.write_string("null")
    }
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_params_to(params : Array[FuncParam], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, p in params {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"label\":")
    serialize_param_label_to(p.label, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(p.name, buf)
    buf.write_string(",\"ty\":")
    serialize_type_to(p.ty, buf)
    buf.write_string(",\"bounds\":")
    serialize_strings_to(p.bounds, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_loop_params_to(
  params : Array[LoopParam],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, p in params {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"init\":")
    serialize_expr_to(p.init, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(p.name, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_param_label_to(label : ParamLabel, buf : StringBuilder) -> Unit {
  match label {
    ParamLabel::Positional => buf.write_string("\"Positional\"")
    ParamLabel::Required => buf.write_string("\"Required\"")
    ParamLabel::Optional => buf.write_string("\"Optional\"")
  }
}

///|
fn serialize_arms_to(arms : Array[MatchArm], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, arm in arms {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"cond\":")
    match arm.cond {
      Some(c) => serialize_expr_to(c, buf)
      None => buf.write_string("null")
    }
    buf.write_string(",\"expr\":")
    serialize_expr_to(arm.expr, buf)
    buf.write_string(",\"pat\":")
    serialize_pat_to(arm.pat, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_pat_to(pat : Pat, buf : StringBuilder) -> Unit {
  match pat {
    Pat::Wildcard(..) => buf.write_string("{\"Wildcard\":{}}")
    Pat::Bind(name~, ..) => {
      buf.write_string("{\"Bind\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
    Pat::Ctor(name~, args~, ..) => {
      buf.write_string("{\"Ctor\":{\"args\":")
      serialize_pats_to(args, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
    Pat::Tuple(items~, ..) => {
      buf.write_string("{\"Tuple\":")
      serialize_pats_to(items, buf)
      buf.write_char('}')
    }
    Pat::Record(fields~, ..) => {
      buf.write_string("{\"Record\":")
      serialize_record_field_pats_to(fields, buf)
      buf.write_char('}')
    }
    Pat::Int(value~, ..) => {
      buf.write_string("{\"Int\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Pat::Float(value~, ..) => {
      buf.write_string("{\"Float\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Pat::Double(value~, ..) => {
      buf.write_string("{\"Double\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Pat::Bool(value~, ..) => {
      buf.write_string("{\"Bool\":")
      buf.write_string(value.to_string())
      buf.write_char('}')
    }
    Pat::Char(value~, ..) => {
      buf.write_string("{\"Char\":")
      serialize_string_to(value.to_string(), buf)
      buf.write_char('}')
    }
    Pat::String(value~, ..) => {
      buf.write_string("{\"String\":")
      serialize_string_to(value, buf)
      buf.write_char('}')
    }
    Pat::Or(pats~, ..) => {
      buf.write_string("{\"Or\":")
      serialize_pats_to(pats, buf)
      buf.write_char('}')
    }
    Pat::Struct(name~, fields~, ..) => {
      buf.write_string("{\"Struct\":{\"fields\":")
      serialize_record_field_pats_to(fields, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
  }
}

///|
fn serialize_pats_to(pats : Array[Pat], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, p in pats {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_pat_to(p, buf)
  }
  buf.write_char(']')
}

///|
fn serialize_record_fields_to(
  fields : Array[RecordFieldExpr],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, f in fields {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"expr\":")
    serialize_expr_to(f.expr, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(f.name, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_map_fields_to(
  fields : Array[MapFieldExpr],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, f in fields {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"expr\":")
    serialize_expr_to(f.expr, buf)
    buf.write_string(",\"key\":")
    serialize_string_to(f.key, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_record_field_pats_to(
  fields : Array[RecordFieldPat],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, f in fields {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"name\":")
    serialize_string_to(f.name, buf)
    buf.write_string(",\"pat\":")
    serialize_pat_to(f.pat, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_type_to(ty : Type, buf : StringBuilder) -> Unit {
  match ty {
    Type::Int => buf.write_string("{\"Int\":{}}")
    Type::Float => buf.write_string("{\"Float\":{}}")
    Type::Double => buf.write_string("{\"Double\":{}}")
    Type::Bool => buf.write_string("{\"Bool\":{}}")
    Type::Char => buf.write_string("{\"Char\":{}}")
    Type::String => buf.write_string("{\"String\":{}}")
    Type::Path => buf.write_string("{\"Path\":{}}")
    Type::Unit => buf.write_string("{\"Unit\":{}}")
    Type::Never => buf.write_string("{\"Never\":{}}")
    Type::Tuple(items) => {
      buf.write_string("{\"Tuple\":")
      serialize_types_to(items, buf)
      buf.write_char('}')
    }
    Type::Record(fields) => {
      buf.write_string("{\"Record\":")
      serialize_type_map_to(fields, buf)
      buf.write_char('}')
    }
    Type::Array(elem) => {
      buf.write_string("{\"Array\":")
      serialize_type_to(elem, buf)
      buf.write_char('}')
    }
    Type::Map(elem) => {
      buf.write_string("{\"Map\":")
      serialize_type_to(elem, buf)
      buf.write_char('}')
    }
    Type::ArrayBuilder(elem) => {
      buf.write_string("{\"ArrayBuilder\":")
      serialize_type_to(elem, buf)
      buf.write_char('}')
    }
    Type::MapBuilder(elem) => {
      buf.write_string("{\"MapBuilder\":")
      serialize_type_to(elem, buf)
      buf.write_char('}')
    }
    Type::StringBuilder => buf.write_string("\"StringBuilder\"")
    Type::Variant(ctors) => {
      buf.write_string("{\"Variant\":")
      serialize_type_map_to(ctors, buf)
      buf.write_char('}')
    }
    Type::Named(name~, args~) => {
      buf.write_string("{\"Named\":{\"args\":")
      serialize_types_to(args, buf)
      buf.write_string(",\"name\":")
      serialize_string_to(name, buf)
      buf.write_string("}}")
    }
    Type::Param(name) => {
      buf.write_string("{\"Param\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
    Type::Var(id) => {
      buf.write_string("{\"Var\":")
      buf.write_string(id.to_string())
      buf.write_char('}')
    }
    Type::Func(params~, ret~, effects~) => {
      buf.write_string("{\"Func\":{\"effects\":")
      serialize_effects_to(effects, buf)
      buf.write_string(",\"params\":")
      serialize_func_params_to(params, buf)
      buf.write_string(",\"ret\":")
      serialize_type_to(ret, buf)
      buf.write_string("}}")
    }
  }
}

///|
fn serialize_types_to(types : Array[Type], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, t in types {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_type_to(t, buf)
  }
  buf.write_char(']')
}

///|
fn serialize_func_params_to(
  params : Array[FuncParam],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, p in params {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"label\":")
    serialize_param_label_to(p.label, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(p.name, buf)
    buf.write_string(",\"ty\":")
    serialize_type_to(p.ty, buf)
    buf.write_string(",\"bounds\":")
    serialize_strings_to(p.bounds, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_string_array_map_to(
  fields : Map[String, Array[String]],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('{')
  let keys = fields.keys().collect()
  keys.sort()
  for i, key in keys {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_string_to(key, buf)
    buf.write_char(':')
    match fields.get(key) {
      Some(values) => serialize_strings_to(values, buf)
      None => buf.write_string("[]")
    }
  }
  buf.write_char('}')
}

///|
fn serialize_type_map_to(
  fields : Map[String, Type],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('{')
  let keys = fields.keys().collect()
  keys.sort()
  for i, k in keys {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_string_to(k, buf)
    buf.write_char(':')
    match fields.get(k) {
      Some(t) => serialize_type_to(t, buf)
      None => buf.write_string("null")
    }
  }
  buf.write_char('}')
}

///|
fn serialize_effects_to(
  effects : Array[EffectAtom],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, e in effects {
    if i > 0 {
      buf.write_char(',')
    }
    serialize_effect_to(e, buf)
  }
  buf.write_char(']')
}

///|
fn serialize_effect_to(e : EffectAtom, buf : StringBuilder) -> Unit {
  match e {
    EffectAtom::Const(name) => {
      buf.write_string("{\"Const\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
    EffectAtom::Var(name) => {
      buf.write_string("{\"Var\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
  }
}

///|
fn serialize_ctors_to(ctors : Array[TypeCtor], buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, c in ctors {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"args\":")
    serialize_types_to(c.args, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(c.name, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_struct_fields_to(
  fields : Array[StructField],
  buf : StringBuilder,
) -> Unit {
  buf.write_char('[')
  for i, f in fields {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"name\":")
    serialize_string_to(f.name, buf)
    buf.write_string(",\"ty\":")
    serialize_type_to(f.ty, buf)
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_import_spec_to(spec : ImportSpec, buf : StringBuilder) -> Unit {
  buf.write_char('[')
  for i, item in spec.items {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string("{\"kind\":")
    serialize_import_kind_to(item.kind, buf)
    buf.write_string(",\"name\":")
    serialize_string_to(item.name, buf)
    buf.write_string(",\"rename\":")
    match item.rename {
      Some(r) => serialize_string_to(r, buf)
      None => buf.write_string("null")
    }
    buf.write_char('}')
  }
  buf.write_char(']')
}

///|
fn serialize_import_kind_to(kind : ImportKind, buf : StringBuilder) -> Unit {
  match kind {
    ImportKind::Value => serialize_string_to("value", buf)
    ImportKind::Type => serialize_string_to("type", buf)
    ImportKind::Trait => serialize_string_to("trait", buf)
    ImportKind::Module => serialize_string_to("module", buf)
  }
}

///|
fn serialize_module_ref_to(r : ModuleRef, buf : StringBuilder) -> Unit {
  match r {
    ModuleRef::Path(path~) => {
      buf.write_string("{\"Path\":")
      serialize_string_to(path, buf)
      buf.write_char('}')
    }
    ModuleRef::Hash(hash~) => {
      buf.write_string("{\"Hash\":")
      serialize_string_to(hash, buf)
      buf.write_char('}')
    }
    ModuleRef::Version(name~) => {
      buf.write_string("{\"Version\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
    ModuleRef::Symbol(name~) => {
      buf.write_string("{\"Symbol\":")
      serialize_string_to(name, buf)
      buf.write_char('}')
    }
  }
}
