///| AST Deserialization from JSON

///|
pub(all) suberror DeserializeError {
  DeserializeError(String)
} derive(Show)

///|
let deser_zero_span : Span = Span::{ start: 0, end: 0 }

///|
/// Deserialize a module from JSON string
pub fn deserialize_module(json_str : String) -> Module raise DeserializeError {
  let json = @json.parse(json_str) catch {
    e => raise DeserializeError("JSON parse error: " + e.to_string())
  }
  parse_module(json)
}

///|
fn parse_module(json : Json) -> Module raise DeserializeError {
  let obj = expect_object(json)
  let stmts_json = get_field(obj, "stmts")
  let stmts_arr = expect_array(stmts_json)
  let stmts : Array[Stmt] = []
  for item in stmts_arr {
    stmts.push(parse_stmt(item))
  }
  Module::{ stmts, }
}

///|
fn parse_stmt(json : Json) -> Stmt raise DeserializeError {
  let obj = expect_object(json)
  let zero = deser_zero_span
  // Find the single key
  for entry in obj.iter() {
    let (key, value) = entry
    match key {
      "Let" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let rec = get_bool(inner, "rec")
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::Let(rec~, name~, expr~, span=zero)
      }
      "LetMut" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::LetMut(name~, expr~, span=zero)
      }
      "ExternLet" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let ty = parse_type(get_field(inner, "ty"))
        return Stmt::ExternLet(name~, ty~, span=zero)
      }
      "LetPat" => {
        let inner = expect_object(value)
        let pat = parse_pat(get_field(inner, "pat"))
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::LetPat(pat~, expr~, span=zero)
      }
      "LetPatElse" => {
        let inner = expect_object(value)
        let pat = parse_pat(get_field(inner, "pat"))
        let expr = parse_expr(get_field(inner, "expr"))
        let else_body = parse_module(get_field(inner, "else_body"))
        return Stmt::LetPatElse(pat~, expr~, else_body~, span=zero)
      }
      "Assign" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::Assign(name~, expr~, span=zero)
      }
      "IndexAssign" => {
        let inner = expect_object(value)
        let target = parse_expr(get_field(inner, "target"))
        let index = parse_expr(get_field(inner, "index"))
        let val = parse_expr(get_field(inner, "value"))
        return Stmt::IndexAssign(target~, index~, value=val, span=zero)
      }
      "Expr" => {
        let expr = parse_expr(value)
        return Stmt::Expr(expr~, span=zero)
      }
      "Test" => {
        let inner = expect_object(value)
        let name = get_string_opt(inner, "name")
        let body = parse_module(get_field(inner, "body"))
        return Stmt::Test(name~, body~, span=zero)
      }
      "Bench" => {
        let inner = expect_object(value)
        let name = get_string_opt(inner, "name")
        let body = parse_module(get_field(inner, "body"))
        return Stmt::Bench(name~, body~, span=zero)
      }
      "EnumDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let ctors = parse_ctors(get_field(inner, "ctors"))
        return Stmt::EnumDef(name~, params~, ctors~, span=zero)
      }
      "TypeAlias" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let target = parse_type(get_field(inner, "target"))
        return Stmt::TypeAlias(name~, params~, target~, span=zero)
      }
      "TraitDef" =>
        match value {
          Json::String(name) =>
            return Stmt::TraitDef(
              name~,
              supertraits=[],
              open_impl=false,
              exported=false,
              span=zero,
            )
          _ => {
            let inner = expect_object(value)
            let name = get_string(inner, "name")
            let supertraits = match inner.get("supertraits") {
              Some(v) => parse_strings(v)
              None => []
            }
            let open_impl = match inner.get("open_impl") {
              Some(v) => expect_bool(v)
              None => false
            }
            let exported = match inner.get("exported") {
              Some(v) => expect_bool(v)
              None => false
            }
            return Stmt::TraitDef(
              name~,
              supertraits~,
              open_impl~,
              exported~,
              span=zero,
            )
          }
        }
      "TraitImpl" => {
        let inner = expect_object(value)
        let type_params = parse_type_params(inner.get("type_params"))
        let type_bounds = parse_type_bounds(inner.get("type_bounds"))
        let trait_name = get_string(inner, "trait_name")
        let target = parse_type(get_field(inner, "target"))
        return Stmt::TraitImpl(
          type_params~,
          type_bounds~,
          trait_name~,
          target~,
          span=zero,
        )
      }
      "Import" => {
        let inner = expect_object(value)
        let source = parse_module_ref(get_field(inner, "source"))
        let spec = parse_import_spec(get_field(inner, "spec"))
        return Stmt::Import(spec~, source~, span=zero)
      }
      "ExportLet" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let rec = get_bool(inner, "rec")
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::ExportLet(rec~, name~, expr~, span=zero)
      }
      "InternalExportLet" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let rec = get_bool(inner, "rec")
        let expr = parse_expr(get_field(inner, "expr"))
        return Stmt::InternalExportLet(rec~, name~, expr~, span=zero)
      }
      "ExportEnumDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let ctors = parse_ctors(get_field(inner, "ctors"))
        return Stmt::ExportEnumDef(name~, params~, ctors~, span=zero)
      }
      "InternalExportEnumDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let ctors = parse_ctors(get_field(inner, "ctors"))
        return Stmt::InternalExportEnumDef(name~, params~, ctors~, span=zero)
      }
      "ExportTypeAlias" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let target = parse_type(get_field(inner, "target"))
        return Stmt::ExportTypeAlias(name~, params~, target~, span=zero)
      }
      "InternalExportTypeAlias" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let target = parse_type(get_field(inner, "target"))
        return Stmt::InternalExportTypeAlias(name~, params~, target~, span=zero)
      }
      "InternalTraitDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let supertraits = get_strings(inner, "supertraits")
        let open_impl = match inner.get("open_impl") {
          Some(v) => expect_bool(v)
          None => false
        }
        return Stmt::InternalTraitDef(
          name~,
          supertraits~,
          open_impl~,
          span=zero,
        )
      }
      "Export" => {
        let names = parse_strings(value)
        return Stmt::Export(names~, span=zero)
      }
      "ReExport" => {
        let inner = expect_object(value)
        let spec = match inner.get("spec") {
          Some(spec_json) => parse_import_spec(spec_json)
          None => {
            let names = get_strings(inner, "names")
            let items : Array[ImportItem] = []
            for name in names {
              items.push(
                ImportItem::{
                  kind: ImportKind::Value,
                  name,
                  rename: None,
                },
              )
            }
            ImportSpec::{ items }
          }
        }
        let source = parse_module_ref(get_field(inner, "source"))
        return Stmt::ReExport(spec~, source~, span=zero)
      }
      "StructDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let fields = parse_struct_fields(get_field(inner, "fields"))
        return Stmt::StructDef(name~, params~, fields~, span=zero)
      }
      "ExportStructDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let fields = parse_struct_fields(get_field(inner, "fields"))
        return Stmt::ExportStructDef(name~, params~, fields~, span=zero)
      }
      "InternalExportStructDef" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let params = get_strings(inner, "params")
        let fields = parse_struct_fields(get_field(inner, "fields"))
        return Stmt::InternalExportStructDef(name~, params~, fields~, span=zero)
      }
      _ => raise DeserializeError("Unknown stmt type: " + key)
    }
  }
  raise DeserializeError("Empty stmt object")
}

///|
fn parse_expr(json : Json) -> Expr raise DeserializeError {
  let obj = expect_object(json)
  let zero = deser_zero_span
  for entry in obj.iter() {
    let (key, value) = entry
    match key {
      "Int" => {
        let v = expect_int64(value)
        return Expr::Int(value=v, span=zero)
      }
      "Float" => {
        let v = expect_double(value)
        return Expr::Float(value=Float::from_double(v), span=zero)
      }
      "Double" => {
        let v = expect_double(value)
        return Expr::Double(value=v, span=zero)
      }
      "Bool" => {
        let v = expect_bool(value)
        return Expr::Bool(value=v, span=zero)
      }
      "Char" => {
        let v = expect_char(value)
        return Expr::Char(value=v, span=zero)
      }
      "String" => {
        let v = expect_string(value)
        return Expr::String(value=v, span=zero)
      }
      "Ident" => {
        let name = expect_string(value)
        return Expr::Ident(name~, span=zero)
      }
      "Placeholder" => {
        let index = expect_int(value)
        return Expr::Placeholder(index~, span=zero)
      }
      "Call" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let type_args = parse_type_args(inner.get("type_args"))
        let args = parse_call_args(get_field(inner, "args"))
        return Expr::Call(name~, type_args~, args~, span=zero)
      }
      "Fn" => {
        let inner = expect_object(value)
        let type_params = parse_type_params(inner.get("type_params"))
        let type_bounds = parse_type_bounds(inner.get("type_bounds"))
        let params = parse_params(get_field(inner, "params"))
        let ret = parse_type_opt(inner.get("ret"))
        let effects = parse_effects(get_field(inner, "effects"))
        let body = parse_module(get_field(inner, "body"))
        return Expr::Fn(
          type_params~,
          type_bounds~,
          params~,
          ret~,
          effects~,
          body~,
          span=zero,
        )
      }
      "If" => {
        let inner = expect_object(value)
        let cond = parse_expr(get_field(inner, "cond"))
        let then_body = parse_module(get_field(inner, "then"))
        let else_body = parse_module(get_field(inner, "else"))
        return Expr::If(cond~, then_body~, else_body~, span=zero)
      }
      "Match" => {
        let inner = expect_object(value)
        let scrutinee = parse_expr(get_field(inner, "expr"))
        let arms = parse_arms(get_field(inner, "arms"))
        return Expr::Match(scrutinee~, arms~, span=zero)
      }
      "Block" => {
        let body = parse_module(value)
        return Expr::Block(body~, span=zero)
      }
      "Tuple" => {
        let items = parse_exprs(value)
        return Expr::Tuple(items~, span=zero)
      }
      "TupleIndex" => {
        let inner = expect_object(value)
        let expr = parse_expr(get_field(inner, "expr"))
        let index = expect_int(get_field(inner, "index"))
        return Expr::TupleIndex(expr~, index~, span=zero)
      }
      "Array" => {
        let items = parse_exprs(value)
        return Expr::Array(items~, span=zero)
      }
      "Record" => {
        let fields = parse_record_fields(value)
        return Expr::Record(fields~, span=zero)
      }
      "Map" => {
        let fields = parse_map_fields(value)
        return Expr::Map(fields~, span=zero)
      }
      "ForIn" => {
        let inner = expect_object(value)
        let value_name = get_string(inner, "value_name")
        let index_name = get_string_opt(inner, "index_name")
        let iterable = parse_expr(get_field(inner, "iterable"))
        let body = parse_module(get_field(inner, "body"))
        return Expr::ForIn(
          value_name~,
          index_name~,
          iterable~,
          body~,
          span=zero,
        )
      }
      "Do" => {
        // Legacy fallback: Do was removed, deserialize as Block
        let body = parse_module(value)
        return Expr::Block(body~, span=zero)
      }
      "While" => {
        let inner = expect_object(value)
        let cond = parse_expr(get_field(inner, "cond"))
        let body = parse_module(get_field(inner, "body"))
        return Expr::While(cond~, body~, span=zero)
      }
      "Loop" => {
        let inner = expect_object(value)
        let params = parse_loop_params(get_field(inner, "params"))
        let body = parse_module(get_field(inner, "body"))
        return Expr::Loop(params~, body~, span=zero)
      }
      "Break" => return Expr::Break(value=None, span=zero)
      "Continue" => return Expr::Continue(args=[], span=zero)
      "Handle" => {
        let inner = expect_object(value)
        let body = parse_module(get_field(inner, "body"))
        let arms = parse_arms(get_field(inner, "arms"))
        return Expr::Handle(body~, arms~, span=zero)
      }
      "Raise" => {
        let v = parse_expr(value)
        return Expr::Raise(value=v, span=zero)
      }
      "Yield" => {
        let expr = parse_expr(value)
        return Expr::Yield(expr~, span=zero)
      }
      "StructLit" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let type_args = parse_type_args(inner.get("type_args"))
        let fields = parse_record_fields(get_field(inner, "fields"))
        return Expr::StructLit(name~, type_args~, fields~, span=zero)
      }
      _ => raise DeserializeError("Unknown expr type: " + key)
    }
  }
  raise DeserializeError("Empty expr object")
}

///|
fn parse_pat(json : Json) -> Pat raise DeserializeError {
  let obj = expect_object(json)
  let zero = deser_zero_span
  for entry in obj.iter() {
    let (key, value) = entry
    match key {
      "Wildcard" => return Pat::Wildcard(span=zero)
      "Bind" => {
        let name = expect_string(value)
        return Pat::Bind(name~, span=zero)
      }
      "Int" => {
        let v = expect_int64(value)
        return Pat::Int(value=v, span=zero)
      }
      "Float" => {
        let v = expect_double(value)
        return Pat::Float(value=Float::from_double(v), span=zero)
      }
      "Double" => {
        let v = expect_double(value)
        return Pat::Double(value=v, span=zero)
      }
      "String" => {
        let v = expect_string(value)
        return Pat::String(value=v, span=zero)
      }
      "Bool" => {
        let v = expect_bool(value)
        return Pat::Bool(value=v, span=zero)
      }
      "Char" => {
        let v = expect_char(value)
        return Pat::Char(value=v, span=zero)
      }
      "Ctor" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let args = parse_pats(get_field(inner, "args"))
        return Pat::Ctor(name~, args~, span=zero)
      }
      "Tuple" => {
        let items = parse_pats(value)
        return Pat::Tuple(items~, span=zero)
      }
      "Record" => {
        let fields = parse_record_field_pats(value)
        return Pat::Record(fields~, span=zero)
      }
      "Or" => {
        let pats = parse_pats(value)
        return Pat::Or(pats~, span=zero)
      }
      "Struct" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let fields = parse_record_field_pats(get_field(inner, "fields"))
        return Pat::Struct(name~, fields~, span=zero)
      }
      _ => raise DeserializeError("Unknown pat type: " + key)
    }
  }
  raise DeserializeError("Empty pat object")
}

///|
fn parse_type(json : Json) -> Type raise DeserializeError {
  let obj = expect_object(json)
  for entry in obj.iter() {
    let (key, value) = entry
    match key {
      "Int" => return Type::Int
      "Float" => return Type::Float
      "Double" => return Type::Double
      "Bool" => return Type::Bool
      "Char" => return Type::Char
      "String" => return Type::String
      "Path" => return Type::Path
      "PromptText" => return Type::PromptText
      "Unit" => return Type::Unit
      "Never" => return Type::Never
      "Named" => {
        let inner = expect_object(value)
        let name = get_string(inner, "name")
        let args = parse_types(get_field(inner, "args"))
        return Type::Named(name~, args~)
      }
      "Array" => {
        let elem = parse_type(value)
        return Type::Array(elem)
      }
      "Map" => {
        let elem = parse_type(value)
        return Type::Map(elem)
      }
      "ArrayBuilder" => {
        let elem = parse_type(value)
        return Type::ArrayBuilder(elem)
      }
      "MapBuilder" => {
        let elem = parse_type(value)
        return Type::MapBuilder(elem)
      }
      "StringBuilder" => return Type::StringBuilder
      "Tuple" => {
        let items = parse_types(value)
        return Type::Tuple(items)
      }
      "Record" => {
        let fields = parse_type_map(value)
        return Type::Record(fields)
      }
      "Variant" => {
        let ctors = parse_type_map(value)
        return Type::Variant(ctors)
      }
      "Func" => {
        let inner = expect_object(value)
        let params = parse_func_params(get_field(inner, "params"))
        let ret = parse_type(get_field(inner, "ret"))
        let effects = parse_effects(get_field(inner, "effects"))
        return Type::Func(params~, ret~, effects~)
      }
      "Param" => {
        let name = expect_string(value)
        return Type::Param(name)
      }
      "Var" => {
        let id = expect_int(value)
        return Type::Var(id)
      }
      _ => raise DeserializeError("Unknown type: " + key)
    }
  }
  raise DeserializeError("Empty type object")
}

///|
fn parse_type_map(json : Json) -> Map[String, Type] raise DeserializeError {
  let obj = expect_object(json)
  let out : Map[String, Type] = {}
  for entry in obj.iter() {
    let (key, value) = entry
    out.set(key, parse_type(value))
  }
  out
}

///|
fn parse_func_params(json : Json) -> Array[FuncParam] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[FuncParam] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let label = parse_param_label(get_field(obj, "label"))
    let ty = parse_type(get_field(obj, "ty"))
    let bounds = parse_strings_opt(obj.get("bounds"))
    out.push(FuncParam::{ name, label, ty, bounds })
  }
  out
}

///|
fn parse_type_opt(json : Json?) -> Type? raise DeserializeError {
  match json {
    None => None
    Some(Json::Null) => None
    Some(j) => Some(parse_type(j))
  }
}

///|
fn parse_types(json : Json) -> Array[Type] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[Type] = []
  for item in arr {
    out.push(parse_type(item))
  }
  out
}

///|
fn parse_type_args(json : Json?) -> Array[Type] raise DeserializeError {
  match json {
    None | Some(Json::Null) => []
    Some(j) => parse_types(j)
  }
}

///|
fn parse_type_params(json : Json?) -> Array[String] raise DeserializeError {
  match json {
    None | Some(Json::Null) => []
    Some(j) => {
      let arr = expect_array(j)
      let out : Array[String] = []
      for item in arr {
        out.push(expect_string(item))
      }
      out
    }
  }
}

///|
fn parse_type_bounds(
  json : Json?,
) -> Map[String, Array[String]] raise DeserializeError {
  match json {
    None | Some(Json::Null) => {}
    Some(j) => {
      let obj = expect_object(j)
      let out : Map[String, Array[String]] = {}
      for entry in obj.iter() {
        let (key, value) = entry
        out[key] = parse_strings(value)
      }
      out
    }
  }
}

///|
fn parse_strings_opt(json : Json?) -> Array[String] raise DeserializeError {
  match json {
    None | Some(Json::Null) => []
    Some(j) => parse_strings(j)
  }
}

///|
fn parse_exprs(json : Json) -> Array[Expr] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[Expr] = []
  for item in arr {
    out.push(parse_expr(item))
  }
  out
}

///|
fn parse_pats(json : Json) -> Array[Pat] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[Pat] = []
  for item in arr {
    out.push(parse_pat(item))
  }
  out
}

///|
fn parse_call_args(json : Json) -> Array[CallArg] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[CallArg] = []
  for item in arr {
    let obj = expect_object(item)
    let expr = parse_expr(get_field(obj, "expr"))
    let label = get_string_opt(obj, "label")
    out.push(CallArg::{ expr, label, span: deser_zero_span })
  }
  out
}

///|
fn parse_params(json : Json) -> Array[FuncParam] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[FuncParam] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let label = parse_param_label(get_field(obj, "label"))
    let ty = parse_type(get_field(obj, "ty"))
    let bounds = parse_strings_opt(obj.get("bounds"))
    out.push(FuncParam::{ name, label, ty, bounds })
  }
  out
}

///|
fn parse_param_label(json : Json) -> ParamLabel raise DeserializeError {
  match json {
    Json::String(s) =>
      match s {
        "Positional" => return ParamLabel::Positional
        "Variadic" => return ParamLabel::Variadic
        "Required" => return ParamLabel::Required
        "Optional" => return ParamLabel::Optional
        _ => raise DeserializeError("Invalid param label: " + s)
      }
    _ => raise DeserializeError("Invalid param label")
  }
}

///|
fn parse_effects(json : Json) -> Array[EffectAtom] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[EffectAtom] = []
  for item in arr {
    let obj = expect_object(item)
    for entry in obj.iter() {
      let (key, value) = entry
      match key {
        "Const" => {
          let name = expect_string(value)
          out.push(EffectAtom::Const(name))
        }
        "Var" => {
          let name = expect_string(value)
          out.push(EffectAtom::Var(name))
        }
        _ => ()
      }
    }
  }
  out
}

///|
fn parse_arms(json : Json) -> Array[MatchArm] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[MatchArm] = []
  for item in arr {
    let obj = expect_object(item)
    let pat = parse_pat(get_field(obj, "pat"))
    let cond = match obj.get("cond") {
      Some(Json::Null) | None => None
      Some(j) => Some(parse_expr(j))
    }
    let expr = parse_expr(get_field(obj, "expr"))
    out.push(MatchArm::{ pat, cond, expr, span: deser_zero_span })
  }
  out
}

///|
fn parse_loop_params(json : Json) -> Array[LoopParam] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[LoopParam] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let init = parse_expr(get_field(obj, "init"))
    out.push(LoopParam::{ name, init, span: deser_zero_span })
  }
  out
}

///|
fn parse_ctors(json : Json) -> Array[TypeCtor] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[TypeCtor] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let args = parse_types(get_field(obj, "args"))
    out.push(TypeCtor::{ name, args, span: deser_zero_span })
  }
  out
}

///|
fn parse_record_fields(
  json : Json,
) -> Array[RecordFieldExpr] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[RecordFieldExpr] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let expr = parse_expr(get_field(obj, "expr"))
    out.push(RecordFieldExpr::{ name, expr, span: deser_zero_span })
  }
  out
}

///|
fn parse_map_fields(json : Json) -> Array[MapFieldExpr] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[MapFieldExpr] = []
  for item in arr {
    let obj = expect_object(item)
    let key = get_string(obj, "key")
    let expr = parse_expr(get_field(obj, "expr"))
    out.push(MapFieldExpr::{ key, expr, span: deser_zero_span })
  }
  out
}

///|
fn parse_struct_fields(
  json : Json,
) -> Array[StructField] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[StructField] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let ty = parse_type(get_field(obj, "ty"))
    out.push(StructField::{ name, ty, span: deser_zero_span })
  }
  out
}

///|
fn parse_record_field_pats(
  json : Json,
) -> Array[RecordFieldPat] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[RecordFieldPat] = []
  for item in arr {
    let obj = expect_object(item)
    let name = get_string(obj, "name")
    let pat = parse_pat(get_field(obj, "pat"))
    out.push(RecordFieldPat::{ name, pat, span: deser_zero_span })
  }
  out
}

///|
fn parse_strings(json : Json) -> Array[String] raise DeserializeError {
  let arr = expect_array(json)
  let out : Array[String] = []
  for item in arr {
    out.push(expect_string(item))
  }
  out
}

///|
fn parse_module_ref(json : Json) -> ModuleRef raise DeserializeError {
  let obj = expect_object(json)
  for entry in obj.iter() {
    let (key, value) = entry
    match key {
      "Path" => {
        let path = expect_string(value)
        return ModuleRef::Path(path~)
      }
      "Hash" => {
        let hash = expect_string(value)
        return ModuleRef::Hash(hash~)
      }
      "Version" => {
        let name = expect_string(value)
        return ModuleRef::Version(name~)
      }
      "Symbol" => {
        let name = expect_string(value)
        return ModuleRef::Symbol(name~)
      }
      _ => ()
    }
  }
  raise DeserializeError("Invalid module ref")
}

///|
fn parse_import_spec(json : Json) -> ImportSpec raise DeserializeError {
  let arr = expect_array(json)
  let items : Array[ImportItem] = []
  for item in arr {
    let obj = expect_object(item)
    let kind = parse_import_kind(get_string_opt(obj, "kind"))
    let name = get_string(obj, "name")
    let rename = get_string_opt(obj, "rename")
    items.push(ImportItem::{ kind, name, rename })
  }
  ImportSpec::{ items, }
}

///|
fn parse_import_kind(kind : String?) -> ImportKind raise DeserializeError {
  match kind {
    None => ImportKind::Value
    Some("value") => ImportKind::Value
    Some("type") => ImportKind::Type
    Some("trait") => ImportKind::Trait
    Some("module") => ImportKind::Module
    Some(other) => raise DeserializeError("Unknown import kind: " + other)
  }
}

///|
// Helper functions

///|
fn expect_object(json : Json) -> Map[String, Json] raise DeserializeError {
  match json {
    Json::Object(obj) => obj
    _ => raise DeserializeError("Expected object, got: " + json.to_string())
  }
}

///|
fn expect_array(json : Json) -> Array[Json] raise DeserializeError {
  match json {
    Json::Array(arr) => arr
    _ => raise DeserializeError("Expected array")
  }
}

///|
fn expect_string(json : Json) -> String raise DeserializeError {
  match json {
    Json::String(s) => s
    _ => raise DeserializeError("Expected string")
  }
}

///|
fn expect_int(json : Json) -> Int raise DeserializeError {
  match json {
    Json::Number(n, ..) => n.to_int()
    _ => raise DeserializeError("Expected number")
  }
}

///|
fn expect_int64(json : Json) -> Int64 raise DeserializeError {
  match json {
    Json::Number(n, ..) => n.to_int64()
    _ => raise DeserializeError("Expected number")
  }
}

///|
fn expect_double(json : Json) -> Double raise DeserializeError {
  match json {
    Json::Number(n, ..) => n
    _ => raise DeserializeError("Expected number")
  }
}

///|
fn expect_bool(json : Json) -> Bool raise DeserializeError {
  match json {
    Json::True => true
    Json::False => false
    _ => raise DeserializeError("Expected boolean")
  }
}

///|
fn expect_char(json : Json) -> Char raise DeserializeError {
  let raw = expect_string(json)
  let chars = raw.to_array()
  if chars.length() == 1 {
    chars[0]
  } else {
    raise DeserializeError("Expected single-char string")
  }
}

///|
fn get_field(
  obj : Map[String, Json],
  key : String,
) -> Json raise DeserializeError {
  match obj.get(key) {
    Some(v) => v
    None => raise DeserializeError("Missing field: " + key)
  }
}

///|
fn get_string(
  obj : Map[String, Json],
  key : String,
) -> String raise DeserializeError {
  expect_string(get_field(obj, key))
}

///|
fn get_string_opt(
  obj : Map[String, Json],
  key : String,
) -> String? raise DeserializeError {
  match obj.get(key) {
    Some(Json::Null) | None => None
    Some(j) => Some(expect_string(j))
  }
}

///|
fn get_bool(
  obj : Map[String, Json],
  key : String,
) -> Bool raise DeserializeError {
  expect_bool(get_field(obj, key))
}

///|
fn get_strings(
  obj : Map[String, Json],
  key : String,
) -> Array[String] raise DeserializeError {
  parse_strings(get_field(obj, key))
}
