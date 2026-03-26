///|
fn instantiate_ctor(env : TypeEnv, info : CtorInfo) -> CtorInstance {
  let mapping : Map[String, @core.Type] = {}
  let args : Array[@core.Type] = []
  for param in info.params {
    let ty_var = fresh_type_var(env)
    mapping[param] = ty_var
    args.push(ty_var)
  }
  let payload = substitute_type(info.payload, mapping)
  let ret = @core.Type::Named(name=info.type_name, args~)
  { payload, ret }
}

///|
fn has_num_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        true
      } else {
        let mut found = false
        for arg in args {
          if has_num_type(arg) {
            found = true
            break
          }
        }
        found
      }
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) => has_num_type(inner)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      has_num_type(inner)
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, ..) => {
      let mut found = false
      for param in params {
        if has_num_type(param.ty) {
          found = true
          break
        }
      }
      if found {
        true
      } else {
        has_num_type(ret)
      }
    }
    _ => false
  }
}

///|
fn replace_num_type(ty : @core.Type, num_var : @core.Type) -> @core.Type {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        num_var
      } else {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(replace_num_type(arg, num_var))
        }
        @core.Type::Named(name~, args=out)
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(replace_num_type(item, num_var))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(replace_num_type(inner, num_var))
    @core.Type::Set(inner) => @core.Type::Set(replace_num_type(inner, num_var))
    @core.Type::Map(key, inner) =>
      @core.Type::Map(
        replace_num_type(key, num_var),
        replace_num_type(inner, num_var),
      )
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_num_type(inner, num_var))
    @core.Type::MapBuilder(key, inner) =>
      @core.Type::MapBuilder(
        replace_num_type(key, num_var),
        replace_num_type(inner, num_var),
      )
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_num_type(param.ty, num_var),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(params=out, ret=replace_num_type(ret, num_var), effects~)
    }
    _ => ty
  }
}

///|
/// Substitute type parameters (Type::Param) with their corresponding type variables
fn substitute_type_params(
  ty : @core.Type,
  mapping : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match mapping.get(name) {
        Some(var_ty) => var_ty
        None => ty // Keep as is if not in mapping
      }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type_params(arg, mapping))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type_params(item, mapping))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_params(inner, mapping))
    @core.Type::Set(inner) =>
      @core.Type::Set(substitute_type_params(inner, mapping))
    @core.Type::Map(key, inner) =>
      @core.Type::Map(
        substitute_type_params(key, mapping),
        substitute_type_params(inner, mapping),
      )
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type_params(inner, mapping))
    @core.Type::MapBuilder(key, inner) =>
      @core.Type::MapBuilder(
        substitute_type_params(key, mapping),
        substitute_type_params(inner, mapping),
      )
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_params(param.ty, mapping),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=substitute_type_params(ret, mapping),
        effects~,
      )
    }
    _ => ty
  }
}
