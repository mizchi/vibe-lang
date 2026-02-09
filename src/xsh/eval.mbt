///|
/// Evaluation for xsh
pub enum Effect {
  ShellExec(String)
  StdoutWriteChar(Int)
  StdinReadChar(Int)
  StdoutWriteStream(String)
  StdinReadStream(Int, String)
} derive(Show, Eq)

///|
pub struct EvalResult {
  last : @core.Value?
  effects : Array[Effect]
} derive(Show, Eq)

///|
fn extend_effects(dest : Array[Effect], src : Array[Effect]) -> Unit {
  for eff in src {
    dest.push(eff)
  }
}

///|
/// Helper to update a function value with an address for recursive binding
fn attach_addr_to_fn(value : @core.Value, addr : String) -> @core.Value {
  match value {
    @core.Value::Fn(fn_val) =>
      @core.Value::Fn(@core.FnValue::{
        params: fn_val.params,
        body: fn_val.body,
        env: fn_val.env,
        addr: Some(addr),
        pure: fn_val.pure,
      })
    _ => value
  }
}

///|
suberror EvalError {
  UnknownName(String)
  PermissionDenied(String)
  BadCall(String)
  ImportError(String)
  LoopBreak
  LoopContinue
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
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
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
        let value = attach_addr_to_fn(out.value, addr)
        extend_effects(effects, out.effects)
        if use_addr {
          self.bind_with_addr(name, addr, value)
        } else {
          self.bind(name, value) |> ignore
        }
        last = Some(value)
      }
      @core.Stmt::EnumDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::TypeAlias(..) => last = Some(@core.Value::Unit)
      @core.Stmt::TraitDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::TraitImpl(..) => last = Some(@core.Value::Unit)
      @core.Stmt::Expr(expr~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        last = Some(out.value)
      }
      @core.Stmt::Import(spec~, source~, ..) => {
        // Get the module hash
        let hash = match source {
          @core.ModuleRef::Hash(hash~) => hash
          @core.ModuleRef::Path(path~) =>
            // Path should be resolved to hash before evaluation
            raise EvalError::ImportError(
              "Import path not resolved to hash: " + path,
            )
          @core.ModuleRef::Version(name~) =>
            raise EvalError::ImportError(
              "Import version ref not resolved to hash: " + name,
            )
          @core.ModuleRef::Symbol(name~) =>
            raise EvalError::ImportError(
              "Import symbol ref not resolved to hash: " + name,
            )
        }
        // Look up module in cache
        match self.get_module(hash) {
          None =>
            raise EvalError::ImportError("Module not found in cache: " + hash)
          Some(imported_module) => {
            // Evaluate imported module in an isolated fork so exported values can
            // reference internal helpers defined in the same module.
            let imported_rt = self.fork_for_test()
            let imported_result = imported_rt.eval_module(imported_module) catch {
              e =>
                raise EvalError::ImportError(
                  "Failed to evaluate imported module: " + e.to_string(),
                )
            }
            if imported_result.effects.length() > 0 {
              raise EvalError::ImportError("Cannot import effectful module")
            }
            let exports = @core.extract_exports(imported_module)
            let bind_import = fn(
              source_name : String,
              target_name : String,
            ) raise EvalError {
              match exports.get(source_name) {
                None =>
                  raise EvalError::ImportError(
                    "Symbol not exported: " + source_name,
                  )
                Some(stmt) =>
                  match imported_rt.get(source_name) {
                    Some(value) => self.bind(target_name, value) |> ignore
                    None =>
                      match stmt {
                        @core.Stmt::ExportLet(..) | @core.Stmt::Let(..) =>
                          raise EvalError::ImportError(
                            "Exported value not found: " + source_name,
                          )
                        _ =>
                          // For enum/type definitions, just register them
                          // (type checking should handle this)
                          ()
                      }
                  }
              }
            }
            // Bind each imported item
            let should_bind_runtime_value = fn(
              item : @core.ImportItem,
              symbol_name : String,
            ) -> Bool {
              item.kind == @core.ImportKind::Value ||
              (
                item.kind == @core.ImportKind::Type &&
                symbol_name.contains("::")
              )
            }
            for item in spec.items {
              let import_name = item.name
              let local_name = match item.rename {
                Some(n) => n
                None => import_name
              }
              match exports.get(import_name) {
                Some(_) =>
                  if should_bind_runtime_value(item, import_name) {
                    bind_import(import_name, local_name)
                  }
                None =>
                  if item.rename is None {
                    // Namespace import: `import { Int }` brings `Int::...`.
                    let prefix = import_name + "::"
                    let mut imported_any = false
                    for exported_name, _ in exports {
                      if exported_name.has_prefix(prefix) {
                        imported_any = true
                        if should_bind_runtime_value(item, exported_name) {
                          bind_import(exported_name, exported_name)
                        }
                      }
                    }
                    if not(imported_any) {
                      raise EvalError::ImportError(
                        "Symbol not exported: " + import_name,
                      )
                    }
                  } else {
                    raise EvalError::ImportError(
                      "Symbol not exported: " + import_name,
                    )
                  }
              }
            }
          }
        }
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
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
        let value = attach_addr_to_fn(out.value, addr)
        extend_effects(effects, out.effects)
        if use_addr {
          self.bind_with_addr(name, addr, value)
        } else {
          self.bind(name, value) |> ignore
        }
        last = Some(value)
      }
      @core.Stmt::ExportEnumDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::ExportTypeAlias(..) => last = Some(@core.Value::Unit)
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        last = Some(@core.Value::Unit)
      @core.Stmt::Test(..) => last = Some(@core.Value::Unit)
      @core.Stmt::LetMut(name~, expr~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        self.bind(name, out.value) |> ignore
        self.mut_vars[name] = true
        last = Some(out.value)
      }
      @core.Stmt::Assign(name~, expr~, ..) => {
        if not(self.mut_vars.contains(name)) {
          raise EvalError::BadCall("assign to immutable: " + name)
        }
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        self.bind(name, out.value) |> ignore
        last = Some(out.value)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
        let target_out = eval_expr(self, target)
        let index_out = eval_expr(self, index)
        let value_out = eval_expr(self, value)
        extend_effects(effects, target_out.effects)
        extend_effects(effects, index_out.effects)
        extend_effects(effects, value_out.effects)
        // Call __set_index builtin
        let args = [target_out.value, index_out.value, value_out.value]
        let result = eval_pure_builtin("__set_index", args)
        last = Some(result)
      }
      @core.Stmt::LetPat(pat~, expr~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        match match_pattern(pat, out.value) {
          Some(bindings) =>
            for name, value in bindings {
              self.bind(name, value) |> ignore
            }
          None => raise EvalError::BadCall("let-pat: pattern match failed")
        }
        last = Some(out.value)
      }
      @core.Stmt::StructDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::ExportStructDef(..) => last = Some(@core.Value::Unit)
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
    @core.Expr::Int(value=n, ..) => { value: @core.Value::Int(n), effects: [] }
    @core.Expr::Float(value=n, ..) =>
      { value: @core.Value::Float(n), effects: [] }
    @core.Expr::Double(value=n, ..) =>
      { value: @core.Value::Double(n), effects: [] }
    @core.Expr::Bool(value=b, ..) =>
      { value: @core.Value::Bool(b), effects: [] }
    @core.Expr::String(value=s, ..) =>
      { value: @core.Value::String(s), effects: [] }
    @core.Expr::Ident(name~, ..) =>
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
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before eval
      raise EvalError::UnknownName("_")
    @core.Expr::Call(name~, args~, ..) => eval_call(rt, name, args)
    @core.Expr::Tuple(items~, ..) => {
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out = eval_expr(rt, item)
        values.push(out.value)
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Tuple(values), effects }
    }
    @core.Expr::TupleIndex(expr~, index~, ..) => {
      let out = eval_expr(rt, expr)
      match out.value {
        @core.Value::Tuple(values) =>
          if index >= 0 && index < values.length() {
            { value: values[index], effects: out.effects }
          } else {
            raise EvalError::BadCall("tuple index \{index} out of bounds")
          }
        _ => raise EvalError::BadCall("expected tuple for index access")
      }
    }
    @core.Expr::Record(fields~, ..) => {
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.name] = out.value
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Record(map), effects }
    }
    @core.Expr::StructLit(fields~, ..) => {
      // Struct is evaluated as record
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.name] = out.value
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Record(map), effects }
    }
    @core.Expr::Array(items~, ..) => {
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out = eval_expr(rt, item)
        values.push(out.value)
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Array(values), effects }
    }
    @core.Expr::Map(fields~, ..) => {
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out = eval_expr(rt, field.expr)
        map[field.key] = out.value
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Map(map), effects }
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      let cond_out = eval_expr(rt, cond)
      let effects = cond_out.effects
      match cond_out.value {
        @core.Value::Bool(b) => {
          let branch_out = if b {
            eval_block(rt, then_body)
          } else {
            eval_block(rt, else_body)
          }
          extend_effects(effects, branch_out.effects)
          { value: branch_out.value, effects }
        }
        _ => raise EvalError::BadCall("if")
      }
    }
    @core.Expr::Block(body~, ..) => eval_block(rt, body)
    @core.Expr::Try(try_body~, catch_body~, ..) =>
      eval_block(rt, try_body) catch {
        _ => eval_block(rt, catch_body)
      }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      let scrutinee_out = eval_expr(rt, scrutinee)
      let effects = scrutinee_out.effects
      let mut matched : @core.Value? = None
      for arm in arms {
        match match_pattern(arm.pat, scrutinee_out.value) {
          Some(bindings) => {
            let guard_ok = match arm.cond {
              Some(c) => {
                let g_out = eval_expr_with_bindings(rt, c, bindings)
                extend_effects(effects, g_out.effects)
                match g_out.value {
                  @core.Value::Bool(b) => b
                  _ => raise EvalError::BadCall("guard")
                }
              }
              None => true
            }
            if guard_ok {
              let out = eval_expr_with_bindings(rt, arm.expr, bindings)
              extend_effects(effects, out.effects)
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
    @core.Expr::Do(body~, ..) => eval_block(rt, body)
    @core.Expr::Fn(
      type_params=_,
      type_bounds=_,
      params~,
      ret~,
      effects=fn_effects,
      body~,
      span~
    ) => {
      let _ = span
      let _ = ret
      let _ = fn_effects
      let purity = @checker.purity_for_let(
        rt.type_env,
        false,
        "_",
        @core.Expr::Fn(
          type_params=[],
          type_bounds={},
          params~,
          ret~,
          effects=fn_effects,
          body~,
          span~,
        ),
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
    @core.Expr::While(cond~, body~, ..) => eval_while_expr(rt, cond, body)
    @core.Expr::Break(..) => raise EvalError::LoopBreak
    @core.Expr::Continue(..) => raise EvalError::LoopContinue
    @core.Expr::Raise(value~, ..) => {
      let v = eval_expr(rt, value)
      raise EvalError::BadCall(
        match v.value {
          @core.Value::String(s) => s
          _ => "raise"
        },
      )
    }
    @core.Expr::Await(expr~, ..) =>
      // For now, await just evaluates the expression synchronously
      // Future: handle Future[T] values and suspend/resume
      eval_expr(rt, expr)
    @core.Expr::Yield(expr~, ..) =>
      // For now, yield just evaluates and returns the expression
      // Future: handle Stream[T] generation
      eval_expr(rt, expr)
  }
}

///|
fn eval_while_expr(
  rt : Runtime,
  cond : @core.Expr,
  body : @core.Module,
) -> EvalOutput raise EvalError {
  let effects : Array[Effect] = []
  while {
          let cond_out = eval_expr(rt, cond)
          extend_effects(effects, cond_out.effects)
          match cond_out.value {
            @core.Value::Bool(b) => b
            _ => raise EvalError::BadCall("while cond")
          }
        } {
    let body_result : Result[EvalResult, EvalError] = try? rt.eval_module(body)
    match body_result {
      Ok(body_res) => extend_effects(effects, body_res.effects)
      Err(EvalError::LoopBreak) => break
      Err(EvalError::LoopContinue) => continue
      Err(e) => raise e
    }
  }
  { value: @core.Value::Unit, effects }
}

///|
fn match_pattern(
  pat : @core.Pat,
  value : @core.Value,
) -> Map[String, @core.Value]? {
  match pat {
    @core.Pat::Wildcard(..) => Some({})
    @core.Pat::Bind(name~, ..) => {
      let bindings : Map[String, @core.Value] = {}
      bindings[name] = value
      Some(bindings)
    }
    @core.Pat::Ctor(name~, args~, ..) =>
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
    @core.Pat::Int(value=n, ..) =>
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
    @core.Pat::Float(value=n, ..) =>
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
    @core.Pat::Double(value=n, ..) =>
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
    @core.Pat::Bool(value=b, ..) =>
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
    @core.Pat::String(value=s, ..) =>
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
    @core.Pat::Tuple(items~, ..) =>
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
    @core.Pat::Record(fields~, ..) =>
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
    @core.Pat::Struct(fields~, ..) =>
      // Struct pattern is matched against a record value
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
    @core.Pat::Or(pats~, ..) => {
      let mut result : Map[String, @core.Value]? = None
      for p in pats {
        match match_pattern(p, value) {
          Some(bindings) => {
            result = Some(bindings)
            break
          }
          None => ()
        }
      }
      result
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
fn namespace_root_from_runtime_type(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Named(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn resolve_type_member_call_name_rt(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> String? {
  if name.contains("::") || name.contains(".") {
    return None
  }
  let mut recv_expr : @core.Expr? = None
  for arg in args {
    match arg.label {
      Some(_) => ()
      None => if recv_expr is None { recv_expr = Some(arg.expr) }
    }
  }
  match recv_expr {
    None => None
    Some(expr) =>
      match rt.type_env.get_expr_type(expr.span()) {
        Some(recv_ty) =>
          match namespace_root_from_runtime_type(recv_ty) {
            Some(root) => {
              let candidate = root + "::" + name
              match rt.get(candidate) {
                Some(_) => Some(candidate)
                None => None
              }
            }
            None => None
          }
        None => None
      }
  }
}

///|
fn eval_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> EvalOutput raise EvalError {
  let name = match resolve_type_member_call_name_rt(rt, name, args) {
    Some(candidate) => candidate
    None => name
  }
  if has_alias_prefix_rt(rt, name) {
    { value: @core.Value::Unit, effects: [] }
  } else {
    match rt.get(name) {
      Some(@core.Value::Fn(fn_val)) => eval_user_call(rt, fn_val, args)
      Some(_) => {
        // Name exists but isn't a function - try field access first
        let field_args_out = eval_args(rt, args)
        let field_pos = extract_positional_values(field_args_out.args, name)
        if field_pos.length() == 1 {
          match field_pos[0] {
            @core.Value::Record(record_fields) =>
              match record_fields.get(name) {
                Some(v) => { value: v, effects: field_args_out.effects }
                None => raise EvalError::BadCall(name)
              }
            _ => raise EvalError::BadCall(name)
          }
        } else {
          raise EvalError::BadCall(name)
        }
      }
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
            "sleep" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, "sleep")
              if pos_args.length() != 1 {
                raise EvalError::BadCall("sleep")
              }
              match pos_args[0] {
                @core.Value::Int(ms) => {
                  sleep_ms(ms.to_int64())
                  { value: @core.Value::Unit, effects: out.effects }
                }
                _ => raise EvalError::BadCall("sleep")
              }
            }
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
            "sh_lines" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, "sh_lines")
              if pos_args.length() != 1 {
                raise EvalError::BadCall("sh_lines")
              }
              match pos_args[0] {
                @core.Value::String(cmd) => {
                  if not(rt.caps().can_spawn("sh")) {
                    raise EvalError::PermissionDenied("process_spawn")
                  }
                  let effects = out.effects
                  effects.push(Effect::ShellExec(cmd))
                  let lines = execute_shell_lines(cmd) catch {
                    _ => raise EvalError::BadCall("sh_lines")
                  }
                  let values : Array[@core.Value] = []
                  for line in lines {
                    values.push(@core.Value::String(line))
                  }
                  { value: @core.Value::Array(values), effects }
                }
                _ => raise EvalError::BadCall("sh_lines")
              }
            }
            "stdout_write_char" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "stdout_write_char",
              )
              if pos_args.length() != 1 {
                raise EvalError::BadCall("stdout_write_char")
              }
              match pos_args[0] {
                @core.Value::Int(code) => {
                  let effects = out.effects
                  effects.push(Effect::StdoutWriteChar(code))
                  { value: @core.Value::Unit, effects }
                }
                _ => raise EvalError::BadCall("stdout_write_char")
              }
            }
            "stdin_read_char" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "stdin_read_char",
              )
              if pos_args.length() != 0 {
                raise EvalError::BadCall("stdin_read_char")
              }
              let code = -1
              let effects = out.effects
              effects.push(Effect::StdinReadChar(code))
              { value: @core.Value::Int(code), effects }
            }
            "stdout_write_stream" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "stdout_write_stream",
              )
              if pos_args.length() != 1 {
                raise EvalError::BadCall("stdout_write_stream")
              }
              match pos_args[0] {
                @core.Value::String(text) => {
                  let effects = out.effects
                  effects.push(Effect::StdoutWriteStream(text))
                  { value: @core.Value::Unit, effects }
                }
                _ => raise EvalError::BadCall("stdout_write_stream")
              }
            }
            "stdin_read_stream" => {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(
                out.args,
                "stdin_read_stream",
              )
              if pos_args.length() != 1 {
                raise EvalError::BadCall("stdin_read_stream")
              }
              match pos_args[0] {
                @core.Value::Int(len) => {
                  if len < 0 {
                    raise EvalError::BadCall("stdin_read_stream")
                  }
                  let chunk = ""
                  let effects = out.effects
                  effects.push(Effect::StdinReadStream(len, chunk))
                  { value: @core.Value::String(chunk), effects }
                }
                _ => raise EvalError::BadCall("stdin_read_stream")
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
            _ => {
              // Try field access: field_name(value) where value is a record
              let field_args_out = eval_args(rt, args)
              let field_pos = extract_positional_values(
                field_args_out.args,
                name,
              )
              if field_pos.length() == 1 {
                match field_pos[0] {
                  @core.Value::Record(record_fields) =>
                    match record_fields.get(name) {
                      Some(v) => { value: v, effects: field_args_out.effects }
                      None => raise EvalError::BadCall(name)
                    }
                  _ => raise EvalError::BadCall(name)
                }
              } else {
                raise EvalError::BadCall(name)
              }
            }
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
    extend_effects(effects, out.effects)
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
  extend_effects(effects, body_out.effects)
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
  name == "__mod" ||
  name == "__index" ||
  name == "__set_index" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__neg" ||
  name == "__assert" ||
  name == "record_set" ||
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
  name == "string_split" ||
  name == "string_index_of" ||
  name == "string_contains" ||
  name == "string_trim" ||
  name == "string_from_char_code" ||
  name == "__lshift" ||
  name == "__rshift" ||
  name == "__bit_and" ||
  name == "__bit_or" ||
  name == "__bit_xor"
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
    "string_split" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_split")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sep)) => {
          let parts : Array[@core.Value] = []
          for part in String::split(s, sep[:]) {
            parts.push(@core.Value::String(part.to_string()))
          }
          @core.Value::Array(parts)
        }
        _ => raise EvalError::BadCall("string_split")
      }
    }
    "string_index_of" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_index_of")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          match String::find(s, sub[:]) {
            Some(idx) => @core.Value::Int(idx)
            None => @core.Value::Int(-1)
          }
        _ => raise EvalError::BadCall("string_index_of")
      }
    }
    "string_contains" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_contains")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          @core.Value::Bool(String::contains(s, sub[:]))
        _ => raise EvalError::BadCall("string_contains")
      }
    }
    "string_trim" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_trim")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(trim_whitespace(s))
        _ => raise EvalError::BadCall("string_trim")
      }
    }
    "string_from_char_code" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_from_char_code")
      }
      match args[0] {
        @core.Value::Int(code) =>
          if code < 0 || code > 1114111 {
            raise EvalError::BadCall("string_from_char_code")
          } else {
            match Int::to_char(code) {
              Some(ch) => @core.Value::String(ch.to_string())
              None => raise EvalError::BadCall("string_from_char_code")
            }
          }
        _ => raise EvalError::BadCall("string_from_char_code")
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
    "__mod" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__mod")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__mod")
          } else {
            @core.Value::Int(a % b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(Float::mod(a, b))
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(Double::mod(a, b))
        _ => raise EvalError::BadCall("__mod")
      }
    }
    "__index" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__index")
      }
      match (args[0], args[1]) {
        (@core.Value::Array(arr), @core.Value::Int(i)) =>
          if i >= 0 && i < arr.length() {
            arr[i]
          } else {
            raise EvalError::BadCall("__index: out of bounds")
          }
        (@core.Value::Record(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        (@core.Value::Map(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        (@core.Value::MapBuilder(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        _ => raise EvalError::BadCall("__index")
      }
    }
    "__set_index" => {
      if args.length() != 3 {
        raise EvalError::BadCall("__set_index")
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::Array(arr), @core.Value::Int(i), value) =>
          if i >= 0 && i < arr.length() {
            arr[i] = value
            value
          } else {
            raise EvalError::BadCall("__set_index: out of bounds")
          }
        (@core.Value::Record(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        (@core.Value::Map(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        (@core.Value::MapBuilder(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        _ => raise EvalError::BadCall("__set_index")
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
        (@core.Value::Bool(a), @core.Value::Bool(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::String(a), @core.Value::String(b)) =>
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
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::Bool(String::compare(a, b) < 0)
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
    "__lshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__lshift")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a << b)
        _ => raise EvalError::BadCall("__lshift")
      }
    }
    "__rshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__rshift")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a >> b)
        _ => raise EvalError::BadCall("__rshift")
      }
    }
    "__bit_and" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_and")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a & b)
        _ => raise EvalError::BadCall("__bit_and")
      }
    }
    "__bit_or" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_or")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a | b)
        _ => raise EvalError::BadCall("__bit_or")
      }
    }
    "__bit_xor" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_xor")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a ^ b)
        _ => raise EvalError::BadCall("__bit_xor")
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
    "map_keys" => {
      if args.length() != 1 {
        raise EvalError::BadCall("map_keys")
      }
      match args[0] {
        @core.Value::Map(items) => {
          let keys : Array[@core.Value] = []
          for k, _ in items {
            keys.push(@core.Value::String(k))
          }
          @core.Value::Array(keys)
        }
        _ => raise EvalError::BadCall("map_keys")
      }
    }
    "map_values" => {
      if args.length() != 1 {
        raise EvalError::BadCall("map_values")
      }
      match args[0] {
        @core.Value::Map(items) => {
          let values : Array[@core.Value] = []
          for _, v in items {
            values.push(v)
          }
          @core.Value::Array(values)
        }
        _ => raise EvalError::BadCall("map_values")
      }
    }
    "map_has_key" => {
      if args.length() != 2 {
        raise EvalError::BadCall("map_has_key")
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          @core.Value::Bool(items.contains(key))
        _ => raise EvalError::BadCall("map_has_key")
      }
    }
    "array_slice" => {
      if args.length() != 3 {
        raise EvalError::BadCall("array_slice")
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::Array(items),
          @core.Value::Int(start),
          @core.Value::Int(end),
        ) => {
          let len = items.length()
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
          if a > b {
            a = b
          }
          let out : Array[@core.Value] = []
          for i in a..<b {
            out.push(items[i])
          }
          @core.Value::Array(out)
        }
        _ => raise EvalError::BadCall("array_slice")
      }
    }
    "int_to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_to_float")
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Float(Float::from_int(n))
        _ => raise EvalError::BadCall("int_to_float")
      }
    }
    "int_to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_to_double")
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Double(n.to_double())
        _ => raise EvalError::BadCall("int_to_double")
      }
    }
    "float_to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("float_to_int")
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Int(f.to_int())
        _ => raise EvalError::BadCall("float_to_int")
      }
    }
    "float_to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall("float_to_double")
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Double(f.to_double())
        _ => raise EvalError::BadCall("float_to_double")
      }
    }
    "double_to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_to_int")
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Int(d.to_int())
        _ => raise EvalError::BadCall("double_to_int")
      }
    }
    "double_to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_to_float")
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Float(Float::from_double(d))
        _ => raise EvalError::BadCall("double_to_float")
      }
    }
    "__to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__to_string")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s)
        @core.Value::Int(n) => @core.Value::String(n.to_string())
        @core.Value::Float(f) => @core.Value::String(f.to_string())
        @core.Value::Double(d) => @core.Value::String(d.to_string())
        @core.Value::Bool(b) =>
          @core.Value::String(if b { "true" } else { "false" })
        @core.Value::Unit => @core.Value::String("()")
        _ => raise EvalError::BadCall("__to_string")
      }
    }
    _ => raise EvalError::BadCall(name)
  }
}

///|
fn split_shell_args(cmd : String) -> Array[String] {
  let out : Array[String] = []
  let trimmed = trim_whitespace(cmd)
  for part in trimmed.split(" ") {
    let token = part.trim().to_string()
    if token.length() > 0 {
      out.push(token)
    }
  }
  out
}

///|
fn join_shell_args(parts : Array[String], start : Int) -> String {
  let out = StringBuilder::new()
  for i in start..<parts.length() {
    if i > start {
      out.write_char(' ')
    }
    out.write_string(parts[i])
  }
  out.to_string()
}

///|
fn split_output_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for part in text.split("\n") {
    out.push(part.to_string())
  }
  if out.length() > 0 && out[out.length() - 1] == "" {
    ignore(out.pop())
  }
  out
}

///|
fn execute_shell_lines(cmd : String) -> Array[String] raise EvalError {
  let parts = split_shell_args(cmd)
  if parts.length() == 0 {
    raise EvalError::BadCall("sh_lines")
  }
  match parts[0] {
    "ls" => {
      if parts.length() > 2 {
        raise EvalError::BadCall("sh_lines")
      }
      let dir = if parts.length() == 2 { parts[1] } else { "." }
      @os_fs.read_dir(dir) catch {
        _ => raise EvalError::BadCall("sh_lines")
      }
    }
    "cat" => {
      if parts.length() != 2 {
        raise EvalError::BadCall("sh_lines")
      }
      let content = @os_fs.read_file_to_string(parts[1]) catch {
        _ => raise EvalError::BadCall("sh_lines")
      }
      split_output_lines(content)
    }
    "echo" =>
      if parts.length() <= 1 {
        [""]
      } else {
        [join_shell_args(parts, 1)]
      }
    _ => raise EvalError::BadCall("sh_lines")
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

///|
fn is_whitespace(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn trim_whitespace(s : String) -> String {
  let len = s.length()
  let mut start = 0
  while start < len &&
        is_whitespace(s.unsafe_get(start).to_int().unsafe_to_char()) {
    start = start + 1
  }
  let mut end = len
  while end > start &&
        is_whitespace(s.unsafe_get(end - 1).to_int().unsafe_to_char()) {
    end = end - 1
  }
  if start == 0 && end == len {
    s
  } else {
    s.unsafe_substring(start~, end~)
  }
}
