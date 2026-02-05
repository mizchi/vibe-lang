///|
/// Evaluation for xsh
pub enum Effect {
  ShellExec(String)
} derive(Show, Eq)

///|
pub struct EvalResult {
  last : @core.Value?
  effects : Array[Effect]
} derive(Show, Eq)

///|
suberror EvalError {
  UnknownName(String)
  PermissionDenied(String)
  BadCall(String)
} derive(Show, Eq)

///|
pub fn Runtime::eval_module(
  self : Runtime,
  ast : @core.Module,
) -> EvalResult raise EvalError {
  let effects : Array[Effect] = []
  let mut last : @core.Value? = None
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let info = @checker.purity_for_let(self.type_env, rec, name, expr)
        let use_addr = rec || info.expr
        let addr = @codegen.expr_address(
          expr,
          self.addr_env,
          if rec {
            Some(name)
          } else {
            None
          },
        )
        if rec {
          self.env[name] = addr
          self.addr_env[name] = addr
        }
        if use_addr {
          match self.type_env.get(name) {
            Some(ty) => self.type_env.set_addr_type(addr, ty)
            None => ()
          }
        }
        let out = eval_expr(self, expr)
        let value = match out.value {
          @core.Value::Fn(fn_val) => {
            let updated = @core.FnValue::{
              params: fn_val.params,
              body: fn_val.body,
              env: fn_val.env,
              addr: Some(addr),
              pure: fn_val.pure,
            }
            @core.Value::Fn(updated)
          }
          _ => out.value
        }
        for eff in out.effects {
          effects.push(eff)
        }
        if use_addr {
          self.bind_with_addr(name, addr, value)
        } else {
          self.bind(name, value) |> ignore
        }
        last = Some(value)
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = name
        let _ = params
        let _ = ctors
        let _ = span
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        let _ = name
        let _ = params
        let _ = target
        let _ = span
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        let out = eval_expr(self, expr)
        for eff in out.effects {
          effects.push(eff)
        }
        last = Some(out.value)
      }
      @core.Stmt::Flake(raw~, span~) => {
        let _ = raw
        let _ = span
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::Alias(name~, target~, span~) => {
        let _ = span
        match target {
          @core.AliasTarget::Module(r) => self.set_alias(name, r)
          @core.AliasTarget::Name(target_name) =>
            match self.addr_env.get(target_name) {
              Some(addr) => self.set_name_alias(name, addr)
              None => raise EvalError::UnknownName(target_name)
            }
        }
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::Import(path~, span~) => {
        let _ = path
        let _ = span
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
        last = Some(@core.Value::Unit)
      }
    }
  }
  { last, effects }
}

///|
priv struct EvalOutput {
  value : @core.Value
  effects : Array[Effect]
}

///|
priv struct EvalArgsOutput {
  args : Array[EvalArgValue]
  effects : Array[Effect]
}

///|
priv struct EvalArgValue {
  label : String?
  value : @core.Value
}

///|
fn eval_expr(rt : Runtime, expr : @core.Expr) -> EvalOutput raise EvalError {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      { value: @core.Value::Int(n), effects: [] }
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      { value: @core.Value::Float(n), effects: [] }
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      { value: @core.Value::Double(n), effects: [] }
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      { value: @core.Value::Bool(b), effects: [] }
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      { value: @core.Value::String(s), effects: [] }
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match rt.get(name) {
        Some(v) => { value: v, effects: [] }
        None =>
          if has_alias_prefix_rt(rt, name) {
            { value: @core.Value::Unit, effects: [] }
          } else if @core.is_ctor_name(name) {
            let map : Map[String, @core.Value] = {}
            map[name] = @core.Value::Unit
            { value: @core.Value::Record(map), effects: [] }
          } else {
            raise EvalError::UnknownName(name)
          }
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      eval_call(rt, name, args)
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out = eval_expr(rt, item)
        values.push(out.value)
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: @core.Value::Tuple(values), effects }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.name] = out.value
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: @core.Value::Record(map), effects }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out = eval_expr(rt, item)
        values.push(out.value)
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: @core.Value::Array(values), effects }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.key] = out.value
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: @core.Value::Map(map), effects }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let cond_out = eval_expr(rt, cond)
      let effects = cond_out.effects
      match cond_out.value {
        @core.Value::Bool(b) => {
          let branch_out = if b {
            eval_block(rt, then_body)
          } else {
            eval_block(rt, else_body)
          }
          for eff in branch_out.effects {
            effects.push(eff)
          }
          { value: branch_out.value, effects }
        }
        _ => raise EvalError::BadCall("if")
      }
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      eval_block(rt, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      eval_block(rt, try_body) catch {
        _ => eval_block(rt, catch_body)
      }
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let scrutinee_out = eval_expr(rt, scrutinee)
      let effects = scrutinee_out.effects
      let mut matched : @core.Value? = None
      for arm in arms {
        match match_pattern(arm.pat, scrutinee_out.value) {
          Some(bindings) => {
            let guard_ok = match arm.cond {
              Some(c) => {
                let g_out = eval_expr_with_bindings(rt, c, bindings)
                for eff in g_out.effects {
                  effects.push(eff)
                }
                match g_out.value {
                  @core.Value::Bool(b) => b
                  _ => raise EvalError::BadCall("guard")
                }
              }
              None => true
            }
            if guard_ok {
              let out = eval_expr_with_bindings(rt, arm.expr, bindings)
              for eff in out.effects {
                effects.push(eff)
              }
              matched = Some(out.value)
              break
            }
          }
          None => ()
        }
      }
      match matched {
        Some(v) => { value: v, effects }
        None => { value: @core.Value::Unit, effects }
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      eval_block(rt, body)
    }
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~) => {
      let _ = span
      let _ = ret
      let _ = fn_effects
      let purity = @checker.purity_for_let(
        rt.type_env,
        false,
        "_",
        @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~),
      )
      let closure = @core.FnValue::{
        params,
        body,
        env: rt.env_snapshot(),
        addr: None,
        pure: purity.value,
      }
      { value: @core.Value::Fn(closure), effects: [] }
    }
  }
}

///|
fn match_pattern(
  pat : @core.Pat,
  value : @core.Value,
) -> Map[String, @core.Value]? {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      let bindings : Map[String, @core.Value] = {}
      Some(bindings)
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let bindings : Map[String, @core.Value] = {}
      bindings[name] = value
      Some(bindings)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      match value {
        @core.Value::Record(map) =>
          match map.get(name) {
            Some(field_val) =>
              if args.length() == 0 {
                let bindings : Map[String, @core.Value] = {}
                Some(bindings)
              } else if args.length() == 1 {
                match match_pattern(args[0], field_val) {
                  Some(map) => Some(map)
                  None => None
                }
              } else {
                match field_val {
                  @core.Value::Tuple(values) =>
                    if values.length() != args.length() {
                      None
                    } else {
                      let bindings : Map[String, @core.Value] = {}
                      let mut ok = true
                      for i in 0..<args.length() {
                        match match_pattern(args[i], values[i]) {
                          Some(map) =>
                            for k, v in map {
                              bindings[k] = v
                            }
                          None => {
                            ok = false
                            break
                          }
                        }
                      }
                      if ok {
                        Some(bindings)
                      } else {
                        None
                      }
                    }
                  _ => None
                }
              }
            None => None
          }
        _ => None
      }
    }
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      match value {
        @core.Value::Int(v) =>
          if v == n {
            let bindings : Map[String, @core.Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    }
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      match value {
        @core.Value::Float(v) =>
          if v == n {
            let bindings : Map[String, @core.Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    }
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      match value {
        @core.Value::Double(v) =>
          if v == n {
            let bindings : Map[String, @core.Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      match value {
        @core.Value::Bool(v) =>
          if v == b {
            let bindings : Map[String, @core.Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      match value {
        @core.Value::String(v) =>
          if v == s {
            let bindings : Map[String, @core.Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      match value {
        @core.Value::Tuple(values) =>
          if items.length() != values.length() {
            None
          } else {
            let bindings : Map[String, @core.Value] = {}
            let mut ok = true
            for i in 0..<items.length() {
              match match_pattern(items[i], values[i]) {
                Some(map) =>
                  for k, v in map {
                    bindings[k] = v
                  }
                None => {
                  ok = false
                  break
                }
              }
            }
            if ok {
              Some(bindings)
            } else {
              None
            }
          }
        _ => None
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      match value {
        @core.Value::Record(map) => {
          let bindings : Map[String, @core.Value] = {}
          let mut ok = true
          for field in fields {
            match map.get(field.name) {
              Some(field_val) =>
                match match_pattern(field.pat, field_val) {
                  Some(field_bindings) =>
                    for k, v in field_bindings {
                      bindings[k] = v
                    }
                  None => {
                    ok = false
                    break
                  }
                }
              None => {
                ok = false
                break
              }
            }
          }
          if ok {
            Some(bindings)
          } else {
            None
          }
        }
        _ => None
      }
    }
  }
}

///|
fn eval_expr_with_bindings(
  rt : Runtime,
  expr : @core.Expr,
  bindings : Map[String, @core.Value],
) -> EvalOutput raise EvalError {
  let scope_rt = rt.fork_for_test()
  for name, value in bindings {
    scope_rt.bind(name, value) |> ignore
  }
  eval_expr(scope_rt, expr)
}

///|
fn eval_block(rt : Runtime, body : @core.Module) -> EvalOutput raise EvalError {
  let scope_rt = rt.fork_for_test()
  let res = scope_rt.eval_module(body)
  let value = match res.last {
    Some(v) => v
    None => @core.Value::Unit
  }
  { value, effects: res.effects }
}

///|
fn eval_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> EvalOutput raise EvalError {
  if has_alias_prefix_rt(rt, name) {
    { value: @core.Value::Unit, effects: [] }
  } else {
    match rt.get(name) {
      Some(@core.Value::Fn(fn_val)) => eval_user_call(rt, fn_val, args)
      Some(_) => raise EvalError::BadCall(name)
      None =>
        if @core.is_ctor_name(name) {
          let out = eval_args(rt, args)
          let pos_args = extract_positional_values(out.args, name)
          let value = ctor_value_from_args(name, pos_args)
          { value, effects: out.effects }
        } else if is_pure_builtin(name) {
          let out = eval_args(rt, args)
          let pos_args = extract_positional_values(out.args, name)
          let key = pure_call_key(name, pos_args)
          match rt.pure_cache_get(key) {
            Some(v) => { value: v, effects: out.effects }
            None => {
              let value = eval_pure_builtin(name, pos_args)
              rt.pure_cache_set(key, value)
              { value, effects: out.effects }
            }
          }
        } else {
          match name {
            "sh" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, "sh")
              if pos_args.length() != 1 {
                raise EvalError::BadCall("sh")
              }
              match pos_args[0] {
                @core.Value::String(cmd) => {
                  if not(rt.caps().can_spawn("sh")) {
                    raise EvalError::PermissionDenied("process_spawn")
                  }
                  let effects = out.effects
                  effects.push(Effect::ShellExec(cmd))
                  { value: @core.Value::Unit, effects }
                }
                _ => raise EvalError::BadCall("sh")
              }
            }
            "addr" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, "addr")
              if pos_args.length() != 1 {
                raise EvalError::BadCall("addr")
              }
              match pos_args[0] {
                @core.Value::String(addr) =>
                  match rt.get_by_addr(addr) {
                    Some(v) => { value: v, effects: out.effects }
                    None => raise EvalError::BadCall("addr")
                  }
                _ => raise EvalError::BadCall("addr")
              }
            }
            "array_builder" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "array_builder",
              )
              if pos_args.length() != 0 {
                raise EvalError::BadCall("array_builder")
              }
              { value: @core.Value::ArrayBuilder([]), effects: out.effects }
            }
            "array_builder_push" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "array_builder_push",
              )
              if pos_args.length() != 2 {
                raise EvalError::BadCall("array_builder_push")
              }
              match pos_args[0] {
                @core.Value::ArrayBuilder(items) => {
                  items.push(pos_args[1])
                  { value: @core.Value::Unit, effects: out.effects }
                }
                _ => raise EvalError::BadCall("array_builder_push")
              }
            }
            "array_builder_freeze" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "array_builder_freeze",
              )
              if pos_args.length() != 1 {
                raise EvalError::BadCall("array_builder_freeze")
              }
              match pos_args[0] {
                @core.Value::ArrayBuilder(items) => {
                  let snapshot = clone_value_array(items)
                  { value: @core.Value::Array(snapshot), effects: out.effects }
                }
                _ => raise EvalError::BadCall("array_builder_freeze")
              }
            }
            "map_builder" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, "map_builder")
              if pos_args.length() != 0 {
                raise EvalError::BadCall("map_builder")
              }
              { value: @core.Value::MapBuilder({}), effects: out.effects }
            }
            "map_builder_set" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "map_builder_set",
              )
              if pos_args.length() != 3 {
                raise EvalError::BadCall("map_builder_set")
              }
              match (pos_args[0], pos_args[1]) {
                (@core.Value::MapBuilder(items), @core.Value::String(key)) => {
                  items[key] = pos_args[2]
                  { value: @core.Value::Unit, effects: out.effects }
                }
                _ => raise EvalError::BadCall("map_builder_set")
              }
            }
            "map_builder_freeze" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "map_builder_freeze",
              )
              if pos_args.length() != 1 {
                raise EvalError::BadCall("map_builder_freeze")
              }
              match pos_args[0] {
                @core.Value::MapBuilder(items) => {
                  let snapshot = clone_value_map(items)
                  { value: @core.Value::Map(snapshot), effects: out.effects }
                }
                _ => raise EvalError::BadCall("map_builder_freeze")
              }
            }
            _ => raise EvalError::BadCall(name)
          }
        }
    }
  }
}

///|
fn ctor_value_from_args(
  name : String,
  args : Array[@core.Value],
) -> @core.Value {
  let field_value = if args.length() == 0 {
    @core.Value::Unit
  } else if args.length() == 1 {
    args[0]
  } else {
    @core.Value::Tuple(args)
  }
  let map : Map[String, @core.Value] = {}
  map[name] = field_value
  @core.Value::Record(map)
}

///|
fn clone_value_array(items : Array[@core.Value]) -> Array[@core.Value] {
  items.copy()
}

///|
fn clone_value_map(
  items : Map[String, @core.Value],
) -> Map[String, @core.Value] {
  items.copy()
}

///|
fn eval_args(
  rt : Runtime,
  args : Array[@core.CallArg],
) -> EvalArgsOutput raise EvalError {
  let out_args : Array[EvalArgValue] = []
  let effects : Array[Effect] = []
  for arg in args {
    let out = eval_expr(rt, arg.expr)
    out_args.push(EvalArgValue::{ label: arg.label, value: out.value })
    for eff in out.effects {
      effects.push(eff)
    }
  }
  { args: out_args, effects }
}

///|
fn extract_positional_values(
  args : Array[EvalArgValue],
  name : String,
) -> Array[@core.Value] raise EvalError {
  let out : Array[@core.Value] = []
  for arg in args {
    match arg.label {
      Some(_) => raise EvalError::BadCall(name)
      None => out.push(arg.value)
    }
  }
  out
}

///|
fn eval_user_call(
  rt : Runtime,
  fn_val : @core.FnValue,
  args : Array[@core.CallArg],
) -> EvalOutput raise EvalError {
  let out = eval_args(rt, args)
  let mut use_cache = false
  let mut cache_key = ""
  match fn_val.addr {
    Some(addr) =>
      if fn_val.pure {
        let values = values_from_eval_args(out.args)
        cache_key = fn_call_key(addr, values)
        match rt.pure_cache_get(cache_key) {
          Some(v) => return { value: v, effects: out.effects }
          None => use_cache = true
        }
      }
    None => ()
  }
  let bound = bind_call_values(fn_val.params, out.args)
  let scope = rt.fork_with_env(fn_val.env)
  for name, value in bound {
    scope.bind(name, value) |> ignore
  }
  let body_out = eval_block(scope, fn_val.body)
  let effects = out.effects
  for eff in body_out.effects {
    effects.push(eff)
  }
  if use_cache {
    rt.pure_cache_set(cache_key, body_out.value)
  }
  { value: body_out.value, effects }
}

///|
fn bind_call_values(
  params : Array[@core.FuncParam],
  args : Array[EvalArgValue],
) -> Map[String, @core.Value] raise EvalError {
  let positional : Array[@core.FuncParam] = []
  for param in params {
    if param.label == @core.ParamLabel::Positional {
      positional.push(param)
    }
  }
  let mut pos_index = 0
  let bound : Map[String, @core.Value] = {}
  let used_labels : Map[String, Bool] = {}
  for arg in args {
    match arg.label {
      None => {
        if pos_index >= positional.length() {
          raise EvalError::BadCall("too many positional args")
        }
        let param = positional[pos_index]
        pos_index += 1
        bound[param.name] = arg.value
      }
      Some(label) => {
        if used_labels.contains(label) {
          raise EvalError::BadCall("duplicate label: " + label)
        }
        let mut found : @core.FuncParam? = None
        for param in params {
          if param.label != @core.ParamLabel::Positional && param.name == label {
            found = Some(param)
            break
          }
        }
        match found {
          Some(param) => {
            used_labels[label] = true
            bound[param.name] = arg.value
          }
          None => raise EvalError::BadCall("unknown label: " + label)
        }
      }
    }
  }
  if pos_index != positional.length() {
    raise EvalError::BadCall("missing positional args")
  }
  for param in params {
    if param.label == @core.ParamLabel::Required &&
      not(bound.contains(param.name)) {
      raise EvalError::BadCall("missing label: " + param.name)
    }
  }
  for param in params {
    if param.label == @core.ParamLabel::Optional {
      match bound.get(param.name) {
        Some(v) => bound[param.name] = ctor_value_from_args("Some", [v])
        None => bound[param.name] = ctor_value_from_args("None", [])
      }
    }
  }
  bound
}

///|
fn values_from_eval_args(args : Array[EvalArgValue]) -> Array[@core.Value] {
  let out : Array[@core.Value] = []
  for arg in args {
    out.push(arg.value)
  }
  out
}

///|
fn is_pure_builtin(name : String) -> Bool {
  name == "path" ||
  name == "addr" ||
  name == "array_length" ||
  name == "array_get" ||
  name == "map_get" ||
  name == "string_length" ||
  name == "string_char_code_at" ||
  name == "string_substring" ||
  name == "string_concat" ||
  name == "string_equals" ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__neg" ||
  name == "__assert" ||
  name == "record_set"
}

///|
fn eval_pure_builtin(
  name : String,
  args : Array[@core.Value],
) -> @core.Value raise EvalError {
  match name {
    "path" => {
      if args.length() != 1 {
        raise EvalError::BadCall("path")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Path(@core.Path::new(s))
        _ => raise EvalError::BadCall("path")
      }
    }
    "array_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("array_length")
      }
      match args[0] {
        @core.Value::Array(items) => @core.Value::Int(items.length())
        _ => raise EvalError::BadCall("array_length")
      }
    }
    "array_get" => {
      if args.length() != 2 {
        raise EvalError::BadCall("array_get")
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0 || index >= items.length() {
            raise EvalError::BadCall("array_get")
          }
          items[index]
        }
        _ => raise EvalError::BadCall("array_get")
      }
    }
    "map_get" => {
      if args.length() != 2 {
        raise EvalError::BadCall("map_get")
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          match items.get(key) {
            Some(value) => value
            None => raise EvalError::BadCall("map_get")
          }
        _ => raise EvalError::BadCall("map_get")
      }
    }
    "string_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_length")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Int(String::length(s))
        _ => raise EvalError::BadCall("string_length")
      }
    }
    "string_char_code_at" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_char_code_at")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::Int(index)) => {
          if index < 0 || index >= String::length(s) {
            raise EvalError::BadCall("string_char_code_at")
          }
          let code = String::code_unit_at(s, index)
          @core.Value::Int(UInt16::to_int(code))
        }
        _ => raise EvalError::BadCall("string_char_code_at")
      }
    }
    "string_substring" => {
      if args.length() != 3 {
        raise EvalError::BadCall("string_substring")
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::String(s), @core.Value::Int(start), @core.Value::Int(end)) => {
          let len = String::length(s)
          let mut a = start
          let mut b = end
          if a < 0 {
            a = 0
          }
          if b < 0 {
            b = 0
          }
          if a > len {
            a = len
          }
          if b > len {
            b = len
          }
          let (from, to) = if a <= b { (a, b) } else { (b, a) }
          @core.Value::String(String::unsafe_substring(s, start=from, end=to))
        }
        _ => raise EvalError::BadCall("string_substring")
      }
    }
    "string_concat" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_concat")
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::String(String::add(a, b))
        _ => raise EvalError::BadCall("string_concat")
      }
    }
    "string_equals" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_equals")
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::Bool(String::equal(a, b))
        _ => raise EvalError::BadCall("string_equals")
      }
    }
    "__add" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__add")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a + b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a + b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a + b)
        _ => raise EvalError::BadCall("__add")
      }
    }
    "__sub" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__sub")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a - b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a - b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a - b)
        _ => raise EvalError::BadCall("__sub")
      }
    }
    "__mul" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__mul")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a * b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a * b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a * b)
        _ => raise EvalError::BadCall("__mul")
      }
    }
    "__div" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__div")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__div")
          } else {
            @core.Value::Int(a / b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a / b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a / b)
        _ => raise EvalError::BadCall("__div")
      }
    }
    "__eq" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__eq")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Bool(a == b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Bool(a == b)
        _ => raise EvalError::BadCall("__eq")
      }
    }
    "__lt" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__lt")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Bool(a < b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Bool(a < b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Bool(a < b)
        _ => raise EvalError::BadCall("__lt")
      }
    }
    "__neg" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__neg")
      }
      match args[0] {
        @core.Value::Int(a) => @core.Value::Int(-a)
        @core.Value::Float(a) => @core.Value::Float(-a)
        @core.Value::Double(a) => @core.Value::Double(-a)
        _ => raise EvalError::BadCall("__neg")
      }
    }
    "__assert" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__assert")
      }
      match args[0] {
        @core.Value::Bool(b) =>
          if b {
            @core.Value::Unit
          } else {
            raise EvalError::BadCall("assert")
          }
        _ => raise EvalError::BadCall("__assert")
      }
    }
    "record_set" => {
      if args.length() != 3 {
        raise EvalError::BadCall("record_set")
      }
      match (args[0], args[1]) {
        (@core.Value::Record(map), @core.Value::String(name)) => {
          if not(map.contains(name)) {
            raise EvalError::BadCall("record_set")
          }
          let out : Map[String, @core.Value] = {}
          for k, v in map {
            out[k] = v
          }
          out[name] = args[2]
          @core.Value::Record(out)
        }
        _ => raise EvalError::BadCall("record_set")
      }
    }
    _ => raise EvalError::BadCall(name)
  }
}

///|
fn pure_call_key(name : String, args : Array[@core.Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("pure:")
  buf.write_string(name)
  for arg in args {
    buf.write_char('\n')
    buf.write_string(value_hash(arg))
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn fn_call_key(addr : String, args : Array[@core.Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("fn:")
  buf.write_string(addr)
  for arg in args {
    buf.write_char('\n')
    buf.write_string(value_hash(arg))
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn has_alias_prefix_rt(rt : Runtime, name : String) -> Bool {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  let buf = StringBuilder::new()
  for i in 0..<dot {
    buf.write_char(chars[i])
  }
  let prefix = buf.to_string()
  rt.get_alias(prefix) is Some(_)
}
