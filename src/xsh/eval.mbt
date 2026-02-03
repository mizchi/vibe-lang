///| Evaluation for xsh

pub enum Effect {
  ShellExec(String)
} derive(Show, Eq)

pub struct EvalResult {
  last : Value?
  effects : Array[Effect]
} derive(Show, Eq)

suberror EvalError {
  UnknownName(String)
  PermissionDenied(String)
  BadCall(String)
} derive(Show, Eq)

///|
pub fn Runtime::eval_module(self : Runtime, ast : Module) -> EvalResult raise EvalError {
  let effects : Array[Effect] = []
  let mut last : Value? = None
  for stmt in ast.stmts {
    match stmt {
      Stmt::Let(name~, expr~) => {
        let out = eval_expr(self, expr)
        for eff in out.effects {
          effects.push(eff)
        }
        self.bind(name, out.value) |> ignore
        last = Some(out.value)
      }
      Stmt::Expr(expr~) => {
        let out = eval_expr(self, expr)
        for eff in out.effects {
          effects.push(eff)
        }
        last = Some(out.value)
      }
      Stmt::Flake(_) => {
        last = Some(Value::Unit)
      }
      Stmt::Alias(name~, target~) => {
        self.set_alias(name, target)
        last = Some(Value::Unit)
      }
      Stmt::Import(_) => {
        last = Some(Value::Unit)
      }
      Stmt::Test(..) => {
        last = Some(Value::Unit)
      }
    }
  }
  { last, effects }
}

///|
priv struct EvalOutput {
  value : Value
  effects : Array[Effect]
}

///|
priv struct EvalArgsOutput {
  values : Array[Value]
  effects : Array[Effect]
}

///|
fn eval_expr(rt : Runtime, expr : Expr) -> EvalOutput raise EvalError {
  match expr {
    Expr::Int(n) => { value: Value::Int(n), effects: [] }
    Expr::Bool(b) => { value: Value::Bool(b), effects: [] }
    Expr::String(s) => { value: Value::String(s), effects: [] }
    Expr::Ident(name) =>
      match rt.get(name) {
        Some(v) => { value: v, effects: [] }
        None =>
          if has_alias_prefix_rt(rt, name) {
            { value: Value::Unit, effects: [] }
          } else {
            raise EvalError::UnknownName(name)
          }
      }
    Expr::Call(name~, args~) => eval_call(rt, name, args)
    Expr::Tuple(items) => {
      let values : Array[Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out = eval_expr(rt, item)
        values.push(out.value)
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: Value::Tuple(values), effects }
    }
    Expr::Record(fields) => {
      let map : Map[String, Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.name] = out.value
        for eff in out.effects {
          effects.push(eff)
        }
      }
      { value: Value::Record(map), effects }
    }
    Expr::If(cond~, then_body~, else_body~) => {
      let cond_out = eval_expr(rt, cond)
      let effects = cond_out.effects
      match cond_out.value {
        Value::Bool(b) => {
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
    Expr::Block(body~) => eval_block(rt, body)
    Expr::Match(scrutinee~, arms~) => {
      let scrutinee_out = eval_expr(rt, scrutinee)
      let effects = scrutinee_out.effects
      let mut matched : Value? = None
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
                  Value::Bool(b) => b
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
        None => { value: Value::Unit, effects }
      }
    }
    Expr::Do(body~) => eval_block(rt, body)
  }
}

fn match_pattern(pat : Pat, value : Value) -> Map[String, Value]? {
  match pat {
    Pat::Wildcard => {
      let bindings : Map[String, Value] = {}
      Some(bindings)
    }
    Pat::Bind(name) => {
      let bindings : Map[String, Value] = {}
      bindings[name] = value
      Some(bindings)
    }
    Pat::Int(n) =>
      match value {
        Value::Int(v) =>
          if v == n {
            let bindings : Map[String, Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    Pat::Bool(b) =>
      match value {
        Value::Bool(v) =>
          if v == b {
            let bindings : Map[String, Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    Pat::String(s) =>
      match value {
        Value::String(v) =>
          if v == s {
            let bindings : Map[String, Value] = {}
            Some(bindings)
          } else {
            None
          }
        _ => None
      }
    Pat::Tuple(items) =>
      match value {
        Value::Tuple(values) => {
          if items.length() != values.length() {
            None
          } else {
            let bindings : Map[String, Value] = {}
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
            if ok { Some(bindings) } else { None }
          }
        }
        _ => None
      }
    Pat::Record(fields) =>
      match value {
        Value::Record(map) => {
          let bindings : Map[String, Value] = {}
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
          if ok { Some(bindings) } else { None }
        }
        _ => None
      }
  }
}

fn eval_expr_with_bindings(
  rt : Runtime,
  expr : Expr,
  bindings : Map[String, Value]
) -> EvalOutput raise EvalError {
  let scope_rt = rt.fork_for_test()
  for name, value in bindings {
    scope_rt.bind(name, value) |> ignore
  }
  eval_expr(scope_rt, expr)
}

fn eval_block(rt : Runtime, body : Module) -> EvalOutput raise EvalError {
  let scope_rt = rt.fork_for_test()
  let res = scope_rt.eval_module(body)
  let value = match res.last {
    Some(v) => v
    None => Value::Unit
  }
  { value, effects: res.effects }
}

///|
fn eval_call(rt : Runtime, name : String, args : Array[Expr]) -> EvalOutput raise EvalError {
  if is_pure_builtin(name) {
    let out = eval_args(rt, args)
    let key = pure_call_key(name, out.values)
    match rt.pure_cache_get(key) {
      Some(v) => { value: v, effects: out.effects }
      None => {
        let value = eval_pure_builtin(name, out.values)
        rt.pure_cache_set(key, value)
        { value, effects: out.effects }
      }
    }
  } else {
    match name {
      "sh" => {
        if args.length() != 1 {
          raise EvalError::BadCall("sh")
        }
        let out = eval_expr(rt, args[0])
        match out.value {
          Value::String(cmd) => {
            if not(rt.caps().can_spawn("sh")) {
              raise EvalError::PermissionDenied("process_spawn")
            }
            let effects = out.effects
            effects.push(Effect::ShellExec(cmd))
            { value: Value::Unit, effects }
          }
          _ => raise EvalError::BadCall("sh")
        }
      }
      _ =>
        if has_alias_prefix_rt(rt, name) {
          { value: Value::Unit, effects: [] }
        } else {
          raise EvalError::BadCall(name)
        }
    }
  }
}

fn eval_args(rt : Runtime, args : Array[Expr]) -> EvalArgsOutput raise EvalError {
  let values : Array[Value] = []
  let effects : Array[Effect] = []
  for arg in args {
    let out = eval_expr(rt, arg)
    values.push(out.value)
    for eff in out.effects {
      effects.push(eff)
    }
  }
  { values, effects }
}

fn is_pure_builtin(name : String) -> Bool {
  name == "path" || name == "add" || name == "sub" || name == "eq" || name == "lt" || name == "not" || name == "and" || name == "or"
}

fn eval_pure_builtin(name : String, args : Array[Value]) -> Value raise EvalError {
  match name {
    "path" => {
      if args.length() != 1 {
        raise EvalError::BadCall("path")
      }
      match args[0] {
        Value::String(s) => Value::Path(Path::new(s))
        _ => raise EvalError::BadCall("path")
      }
    }
    "add" => {
      if args.length() != 2 {
        raise EvalError::BadCall("add")
      }
      match (args[0], args[1]) {
        (Value::Int(a), Value::Int(b)) => Value::Int(a + b)
        _ => raise EvalError::BadCall("add")
      }
    }
    "sub" => {
      if args.length() != 2 {
        raise EvalError::BadCall("sub")
      }
      match (args[0], args[1]) {
        (Value::Int(a), Value::Int(b)) => Value::Int(a - b)
        _ => raise EvalError::BadCall("sub")
      }
    }
    "eq" => {
      if args.length() != 2 {
        raise EvalError::BadCall("eq")
      }
      match (args[0], args[1]) {
        (Value::Int(a), Value::Int(b)) => Value::Bool(a == b)
        _ => raise EvalError::BadCall("eq")
      }
    }
    "lt" => {
      if args.length() != 2 {
        raise EvalError::BadCall("lt")
      }
      match (args[0], args[1]) {
        (Value::Int(a), Value::Int(b)) => Value::Bool(a < b)
        _ => raise EvalError::BadCall("lt")
      }
    }
    "not" => {
      if args.length() != 1 {
        raise EvalError::BadCall("not")
      }
      match args[0] {
        Value::Bool(b) => Value::Bool(not(b))
        _ => raise EvalError::BadCall("not")
      }
    }
    "and" => {
      if args.length() != 2 {
        raise EvalError::BadCall("and")
      }
      match (args[0], args[1]) {
        (Value::Bool(a), Value::Bool(b)) => Value::Bool(a && b)
        _ => raise EvalError::BadCall("and")
      }
    }
    "or" => {
      if args.length() != 2 {
        raise EvalError::BadCall("or")
      }
      match (args[0], args[1]) {
        (Value::Bool(a), Value::Bool(b)) => Value::Bool(a || b)
        _ => raise EvalError::BadCall("or")
      }
    }
    _ => raise EvalError::BadCall(name)
  }
}

fn pure_call_key(name : String, args : Array[Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("pure:")
  buf.write_string(name)
  for arg in args {
    buf.write_char('\n')
    buf.write_string(value_hash(arg))
  }
  git_blob_hash_string(buf.to_string())
}

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
