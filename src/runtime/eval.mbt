///|
/// Evaluation for vibe
pub enum Effect {
  PosixDesugar(String)
  ShellExec(String)
  StdoutWriteChar(Int)
  StdinReadChar(Int)
  StdoutWriteStream(String)
  StdinReadStream(Int, String)
  FsReadFile(String, String)
  FsWriteFile(String, String)
  FsExists(String, Bool)
  SocketTcpConnect(String, Int64, Int64)
  SocketTcpRead(Int64, Int64, String)
  SocketTcpWrite(Int64, String)
  SocketTcpClose(Int64)
  HttpRequest(String, String, String, String, Int64)
  HttpResponseStatus(Int64, Int)
  HttpResponseHeader(Int64, String, String)
  HttpResponseBody(Int64, String)
  HttpClose(Int64)
  HttpListen(Int, Int64)
  HttpAccept(Int64, Int64)
  HttpRequestMethod(Int64, String)
  HttpRequestUrl(Int64, String)
  HttpRequestHeader(Int64, String, String)
  HttpRequestBody(Int64, String)
  HttpRespond(Int64, Int, String, String)
  LlmComplete(String, String, String) // (model, prompt_preview, response_preview)
  RlmTrace(String) // JSON trace event
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
  FeatureDisabled(feature~ : String, operation~ : String, flag~ : String)
  LoopBreak(@core.Value?)
  LoopContinue(Array[@core.Value])
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
      @core.Stmt::Let(rec~, name~, expr~, ..) =>
        if name == "_" {
          let out = eval_expr(self, expr)
          extend_effects(effects, out.effects)
          last = Some(out.value)
        } else {
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
      @core.Stmt::ReExport(names~, source~, ..) => {
        let hash = match source {
          @core.ModuleRef::Hash(hash~) => hash
          @core.ModuleRef::Path(path~) =>
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
        match self.get_module(hash) {
          None =>
            raise EvalError::ImportError("Module not found in cache: " + hash)
          Some(imported_module) => {
            let imported_rt = self.fork_for_test()
            let _imported_result = imported_rt.eval_module(imported_module) catch {
              e =>
                raise EvalError::ImportError(
                  "Failed to evaluate imported module: " + e.to_string(),
                )
            }
            let exports = @core.extract_exports(imported_module)
            for name in names {
              match exports.get(name) {
                None =>
                  raise EvalError::ImportError("Symbol not exported: " + name)
                Some(_) =>
                  match imported_rt.get(name) {
                    Some(value) => self.bind(name, value) |> ignore
                    None => () // type/enum only, no runtime value
                  }
              }
            }
          }
        }
        last = Some(@core.Value::Unit)
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
            let bind_namespace_members = fn(
              item : @core.ImportItem,
              source_root : String,
              target_root : String,
            ) -> Bool raise EvalError {
              let source_prefix = source_root + "::"
              let target_prefix = target_root + "::"
              let mut imported_any = false
              for exported_name, _ in exports {
                if exported_name.has_prefix(source_prefix) {
                  let suffix = exported_name.unsafe_substring(
                    start=source_prefix.length(),
                    end=exported_name.length(),
                  )
                  let target_name = target_prefix + suffix
                  imported_any = true
                  if should_bind_runtime_value(item, exported_name) {
                    bind_import(exported_name, target_name)
                  }
                }
              }
              // Auto-forward receiver-first exported functions as namespace members.
              // Runtime side uses the type environment prepared at compile time
              // (`Runtime::run_compiled` sets it) to mirror type import behavior.
              for exported_name, _ in exports {
                if exported_name.contains("::") {
                  continue
                }
                if exported_name == source_root {
                  continue
                }
                let target_name = target_prefix + exported_name
                if not(should_bind_runtime_value(item, target_name)) {
                  continue
                }
                if self.type_env.get(target_name) is Some(_) {
                  imported_any = true
                  bind_import(exported_name, target_name)
                }
              }
              imported_any
            }
            for item in spec.items {
              let import_name = item.name
              if item.kind == @core.ImportKind::Module {
                let source_prefix = import_name + "::"
                let local_ns = match item.rename {
                  Some(rename_name) => rename_name
                  None => import_name
                }
                let target_prefix = local_ns + "::"
                let mut imported_any = false
                for exported_name, _ in exports {
                  if exported_name.has_prefix(source_prefix) {
                    let suffix = exported_name.unsafe_substring(
                      start=source_prefix.length(),
                      end=exported_name.length(),
                    )
                    let target_name = target_prefix + suffix
                    imported_any = true
                    bind_import(exported_name, target_name)
                  }
                }
                if not(imported_any) {
                  raise EvalError::ImportError(
                    "Symbol not exported: " + import_name,
                  )
                }
                continue
              }
              let local_name = match item.rename {
                Some(n) => n
                None => import_name
              }
              match exports.get(import_name) {
                Some(_) => {
                  if should_bind_runtime_value(item, import_name) {
                    bind_import(import_name, local_name)
                  }
                  bind_namespace_members(item, import_name, local_name)
                  |> ignore
                }
                None =>
                  if item.rename is None {
                    // Namespace import: `use <ref> { Int }` brings `Int::...`.
                    let imported_any = bind_namespace_members(
                      item, import_name, import_name,
                    )
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
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) =>
        if name == "_" {
          let out = eval_expr(self, expr)
          extend_effects(effects, out.effects)
          last = Some(out.value)
        } else {
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
      @core.Stmt::Export(..) => last = Some(@core.Value::Unit)
      @core.Stmt::Test(..) => last = Some(@core.Value::Unit)
      @core.Stmt::Bench(..) => last = Some(@core.Value::Unit)
      @core.Stmt::LetMut(name~, expr~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        if name != "_" {
          self.bind(name, out.value) |> ignore
          self.mut_vars[name] = true
        }
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
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        match match_pattern(pat, out.value) {
          Some(bindings) =>
            for name, value in bindings {
              self.bind(name, value) |> ignore
            }
          None => {
            let else_out = eval_block(self, else_body)
            extend_effects(effects, else_out.effects)
          }
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
    @core.Expr::Char(value=c, ..) =>
      { value: @core.Value::Char(c), effects: [] }
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
    @core.Expr::Break(value~, span~) => {
      let _ = span
      let val : @core.Value? = match value {
        Some(expr) => Some(eval_expr(rt, expr).value)
        None => None
      }
      raise EvalError::LoopBreak(val)
    }
    @core.Expr::Continue(args~, span~) => {
      let _ = span
      let vals : Array[@core.Value] = []
      for arg in args {
        vals.push(eval_expr(rt, arg).value)
      }
      raise EvalError::LoopContinue(vals)
    }
    @core.Expr::Loop(params~, body~, ..) => eval_loop_expr(rt, params, body)
    @core.Expr::Raise(value~, ..) => {
      let v = eval_expr(rt, value)
      raise EvalError::BadCall(
        match v.value {
          @core.Value::String(s) => s
          _ => "raise"
        },
      )
    }
    @core.Expr::Await(expr~, ..) => {
      require_unstable_async(rt, "await")
      // For now, await just evaluates the expression synchronously
      // Future: handle Future[T] values and suspend/resume
      eval_expr(rt, expr)
    }
    @core.Expr::Yield(expr~, ..) => {
      require_unstable_async(rt, "yield")
      // For now, yield just evaluates and returns the expression
      // Future: handle Stream[T] generation
      eval_expr(rt, expr)
    }
  }
}

///|
fn require_unstable_async(
  rt : Runtime,
  operation : String,
) -> Unit raise EvalError {
  let flags = rt.feature_flags()
  if flags.is_unstable_async_enabled() {
    ()
  } else {
    raise EvalError::FeatureDisabled(
      feature="async",
      operation~,
      flag="--unstable-async",
    )
  }
}

///|
fn require_unstable_threads(
  rt : Runtime,
  operation : String,
) -> Unit raise EvalError {
  let flags = rt.feature_flags()
  if flags.is_unstable_threads_enabled() {
    ()
  } else {
    raise EvalError::FeatureDisabled(
      feature="threads",
      operation~,
      flag="--unstable-threads",
    )
  }
}

///|
fn eval_while_expr(
  rt : Runtime,
  cond : @core.Expr,
  body : @core.Module,
) -> EvalOutput raise EvalError {
  let effects : Array[Effect] = []
  while ({
          let cond_out = eval_expr(rt, cond)
          extend_effects(effects, cond_out.effects)
          match cond_out.value {
            @core.Value::Bool(b) => b
            _ => raise EvalError::BadCall("while cond")
          }
        }) {
    let body_result : Result[EvalResult, EvalError] = try? rt.eval_module(body)
    match body_result {
      Ok(body_res) => extend_effects(effects, body_res.effects)
      Err(EvalError::LoopBreak(_)) => break
      Err(EvalError::LoopContinue(_)) => continue
      Err(e) => raise e
    }
  }
  { value: @core.Value::Unit, effects }
}

///|
fn eval_loop_expr(
  rt : Runtime,
  params : Array[@core.LoopParam],
  body : @core.Module,
) -> EvalOutput raise EvalError {
  let effects : Array[Effect] = []
  // Initialize loop params
  for param in params {
    let init_out = eval_expr(rt, param.init)
    extend_effects(effects, init_out.effects)
    rt.bind(param.name, init_out.value) |> ignore
  }
  // Loop
  let mut result : @core.Value = @core.Value::Unit
  while true {
    let body_result : Result[EvalResult, EvalError] = try? rt.eval_module(body)
    match body_result {
      Ok(body_res) => {
        extend_effects(effects, body_res.effects)
        // If body falls through without break, loop continues
        continue
      }
      Err(EvalError::LoopBreak(val)) => {
        result = match val {
          Some(v) => v
          None => @core.Value::Unit
        }
        break
      }
      Err(EvalError::LoopContinue(args)) => {
        // Re-bind loop params
        for i in 0..<args.length() {
          if i < params.length() {
            rt.bind(params[i].name, args[i]) |> ignore
          }
        }
        continue
      }
      Err(e) => raise e
    }
  }
  { value: result, effects }
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
    @core.Pat::Char(value=c, ..) =>
      match value {
        @core.Value::Char(v) =>
          if v == c {
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
          match rt.type_env.namespace_root(recv_ty) {
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
          eval_builtin_call(rt, name, args)
        }
    }
  }
}

///|
fn eval_builtin_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> EvalOutput raise EvalError {
  match name {
    "sleep" => {
      require_unstable_async(rt, "sleep")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "sleep")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("sleep")
      }
      if not(rt.caps().can_read_clock()) {
        raise EvalError::PermissionDenied("clock_read")
      }
      match pos_args[0] {
        @core.Value::Int(ms) => {
          @io.sleep_ms(ms)
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ => raise EvalError::BadCall("sleep")
      }
    }
    "dynamic_path_resolve" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "dynamic_path_resolve")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("dynamic_path_resolve")
      }
      match pos_args[0] {
        @core.Value::String(raw_path) => {
          let cwd = @io.current_dir_or_root()
          let resolved = if raw_path.has_prefix("/") {
            @path.Path(raw_path).normalize().to_string()
          } else {
            @path.Path(cwd).join(@path.Path(raw_path)).normalize().to_string()
          }
          {
            value: @core.Value::Path(@core.Path::new(resolved)),
            effects: out.effects,
          }
        }
        _ => raise EvalError::BadCall("dynamic_path_resolve")
      }
    }
    "threads_probe_wat" => {
      require_unstable_threads(rt, "threads_probe_wat")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_probe_wat")
      if pos_args.length() != 0 {
        raise EvalError::BadCall("threads_probe_wat")
      }
      {
        value: @core.Value::String(@x_threads.probe_wat()),
        effects: out.effects,
      }
    }
    "threads_runtime_hints" => {
      require_unstable_threads(rt, "threads_runtime_hints")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "threads_runtime_hints",
      )
      if pos_args.length() != 0 {
        raise EvalError::BadCall("threads_runtime_hints")
      }
      let wasm_flags = @x_threads.recommended_wasm_flags()
      let wasi_flags = @x_threads.recommended_wasi_flags()
      let wasm_values : Array[@core.Value] = []
      for flag in wasm_flags {
        wasm_values.push(@core.Value::String(flag))
      }
      let wasi_values : Array[@core.Value] = []
      for flag in wasi_flags {
        wasi_values.push(@core.Value::String(flag))
      }
      let fields : Map[String, @core.Value] = {}
      fields["wasm_flags"] = @core.Value::Array(wasm_values)
      fields["wasi_flags"] = @core.Value::Array(wasi_values)
      fields["wasm_env"] = @core.Value::String(
        @x_threads.flags_to_env_value(wasm_flags),
      )
      fields["wasi_env"] = @core.Value::String(
        @x_threads.flags_to_env_value(wasi_flags),
      )
      { value: @core.Value::Record(fields), effects: out.effects }
    }
    "threads_channel_new" => {
      require_unstable_threads(rt, "threads_channel_new")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_channel_new")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("threads_channel_new")
      }
      match pos_args[0] {
        @core.Value::Int(capacity) =>
          {
            value: @core.Value::Int(
              rt.threads_channel_new(capacity.to_int()).to_int64(),
            ),
            effects: out.effects,
          }
        _ => raise EvalError::BadCall("threads_channel_new")
      }
    }
    "threads_send" => {
      require_unstable_threads(rt, "threads_send")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_send")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("threads_send")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(channel_id), @core.Value::String(message)) =>
          match rt.threads_send(channel_id.to_int(), message) {
            Some(ok) => { value: @core.Value::Bool(ok), effects: out.effects }
            None => raise EvalError::BadCall("threads_send")
          }
        _ => raise EvalError::BadCall("threads_send")
      }
    }
    "threads_recv" => {
      require_unstable_threads(rt, "threads_recv")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_recv")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("threads_recv")
      }
      match pos_args[0] {
        @core.Value::Int(channel_id) =>
          match rt.threads_recv(channel_id.to_int()) {
            Some(message) =>
              { value: @core.Value::String(message), effects: out.effects }
            None => raise EvalError::BadCall("threads_recv")
          }
        _ => raise EvalError::BadCall("threads_recv")
      }
    }
    "threads_spawn" => {
      require_unstable_threads(rt, "threads_spawn")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_spawn")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("threads_spawn")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(name), @core.Value::Int(mailbox)) =>
          match rt.threads_spawn(name, mailbox.to_int()) {
            Some(task_id) =>
              {
                value: @core.Value::Int(task_id.to_int64()),
                effects: out.effects,
              }
            None => raise EvalError::BadCall("threads_spawn")
          }
        _ => raise EvalError::BadCall("threads_spawn")
      }
    }
    "threads_wait" => {
      require_unstable_threads(rt, "threads_wait")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "threads_wait")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("threads_wait")
      }
      match pos_args[0] {
        @core.Value::Int(task_id) =>
          match rt.threads_wait(task_id.to_int()) {
            Some(status) =>
              {
                value: @core.Value::Int(status.to_int64()),
                effects: out.effects,
              }
            None => raise EvalError::BadCall("threads_wait")
          }
        _ => raise EvalError::BadCall("threads_wait")
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
      let pos_args = extract_positional_values(out.args, "stdout_write_char")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("stdout_write_char")
      }
      match pos_args[0] {
        @core.Value::Int(code) => {
          let effects = out.effects
          effects.push(Effect::StdoutWriteChar(code.to_int()))
          { value: @core.Value::Unit, effects }
        }
        _ => raise EvalError::BadCall("stdout_write_char")
      }
    }
    "stdin_read_char" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "stdin_read_char")
      if pos_args.length() != 0 {
        raise EvalError::BadCall("stdin_read_char")
      }
      let code = -1
      let effects = out.effects
      effects.push(Effect::StdinReadChar(code))
      { value: @core.Value::Int(code.to_int64()), effects }
    }
    "stdout_write_stream" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "stdout_write_stream")
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
      let pos_args = extract_positional_values(out.args, "stdin_read_stream")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("stdin_read_stream")
      }
      match pos_args[0] {
        @core.Value::Int(len) => {
          if len < 0L {
            raise EvalError::BadCall("stdin_read_stream")
          }
          let chunk = ""
          let effects = out.effects
          effects.push(Effect::StdinReadStream(len.to_int(), chunk))
          { value: @core.Value::String(chunk), effects }
        }
        _ => raise EvalError::BadCall("stdin_read_stream")
      }
    }
    "fs_read_file" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "fs_read_file")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("fs_read_file")
      }
      match pos_args[0] {
        @core.Value::String(path) =>
          match @io.read_string(path) {
            Ok(content) => {
              let effects = out.effects
              effects.push(Effect::FsReadFile(path, content))
              { value: @core.Value::String(content), effects }
            }
            Err(err) => raise EvalError::BadCall("fs_read_file: " + err)
          }
        _ => raise EvalError::BadCall("fs_read_file")
      }
    }
    "fs_write_file" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "fs_write_file")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("fs_write_file")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(path), @core.Value::String(content)) =>
          match @io.write_string(path, content) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::FsWriteFile(path, content))
              { value: @core.Value::Unit, effects }
            }
            Err(err) => raise EvalError::BadCall("fs_write_file: " + err)
          }
        _ => raise EvalError::BadCall("fs_write_file")
      }
    }
    "fs_exists" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "fs_exists")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("fs_exists")
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let exists = @io.path_exists(path)
          let effects = out.effects
          effects.push(Effect::FsExists(path, exists))
          { value: @core.Value::Bool(exists), effects }
        }
        _ => raise EvalError::BadCall("fs_exists")
      }
    }
    "socket_tcp_connect" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "socket_tcp_connect")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("socket_tcp_connect")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(host), @core.Value::Int(port)) =>
          match @backend.tcp_connect(host, port.to_int()) {
            Ok(fd) => {
              let effects = out.effects
              let fd64 = fd.to_int64()
              effects.push(Effect::SocketTcpConnect(host, port, fd64))
              { value: @core.Value::Int(fd64), effects }
            }
            Err(err) => raise EvalError::BadCall("socket_tcp_connect: " + err)
          }
        _ => raise EvalError::BadCall("socket_tcp_connect")
      }
    }
    "socket_tcp_read" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "socket_tcp_read")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("socket_tcp_read")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(fd), @core.Value::Int(max_bytes)) =>
          match @backend.tcp_read(fd.to_int(), max_bytes.to_int()) {
            Ok(data) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpRead(fd, max_bytes, data))
              { value: @core.Value::String(data), effects }
            }
            Err(err) => raise EvalError::BadCall("socket_tcp_read: " + err)
          }
        _ => raise EvalError::BadCall("socket_tcp_read")
      }
    }
    "socket_tcp_write" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "socket_tcp_write")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("socket_tcp_write")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(fd), @core.Value::String(data)) =>
          match @backend.tcp_write(fd.to_int(), data) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpWrite(fd, data))
              { value: @core.Value::Unit, effects }
            }
            Err(err) => raise EvalError::BadCall("socket_tcp_write: " + err)
          }
        _ => raise EvalError::BadCall("socket_tcp_write")
      }
    }
    "socket_tcp_close" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "socket_tcp_close")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("socket_tcp_close")
      }
      match pos_args[0] {
        @core.Value::Int(fd) =>
          match @backend.tcp_close(fd.to_int()) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpClose(fd))
              { value: @core.Value::Unit, effects }
            }
            Err(err) => raise EvalError::BadCall("socket_tcp_close: " + err)
          }
        _ => raise EvalError::BadCall("socket_tcp_close")
      }
    }
    // --- HTTP Client builtins ---
    "http_request" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_request")
      if pos_args.length() != 4 {
        raise EvalError::BadCall("http_request")
      }
      let meth = match pos_args[0] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_request")
      }
      let url = match pos_args[1] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_request")
      }
      let headers = match pos_args[2] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_request")
      }
      let body = match pos_args[3] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_request")
      }
      match @backend.http_request(meth, url, headers, body) {
        Ok(handle) => {
          let effects = out.effects
          let h64 = handle.to_int64()
          effects.push(Effect::HttpRequest(meth, url, headers, body, h64))
          { value: @core.Value::Int(h64), effects }
        }
        Err(err) => raise EvalError::BadCall("http_request: " + err)
      }
    }
    "http_response_status" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_response_status")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_response_status")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_response_status(handle.to_int()) {
            Ok(status) => {
              let effects = out.effects
              effects.push(Effect::HttpResponseStatus(handle, status))
              { value: @core.Value::Int(status.to_int64()), effects }
            }
            Err(err) => raise EvalError::BadCall("http_response_status: " + err)
          }
        _ => raise EvalError::BadCall("http_response_status")
      }
    }
    "http_response_header" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_response_header")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("http_response_header")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(handle), @core.Value::String(hdr_name)) =>
          match @backend.http_response_header(handle.to_int(), hdr_name) {
            Ok(hdr_val) => {
              let effects = out.effects
              effects.push(
                Effect::HttpResponseHeader(handle, hdr_name, hdr_val),
              )
              { value: @core.Value::String(hdr_val), effects }
            }
            Err(err) => raise EvalError::BadCall("http_response_header: " + err)
          }
        _ => raise EvalError::BadCall("http_response_header")
      }
    }
    "http_response_body" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_response_body")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_response_body")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_response_body(handle.to_int()) {
            Ok(body) => {
              let effects = out.effects
              effects.push(Effect::HttpResponseBody(handle, body))
              { value: @core.Value::String(body), effects }
            }
            Err(err) => raise EvalError::BadCall("http_response_body: " + err)
          }
        _ => raise EvalError::BadCall("http_response_body")
      }
    }
    "http_close" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_close")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_close")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_close(handle.to_int()) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::HttpClose(handle))
              { value: @core.Value::Unit, effects }
            }
            Err(err) => raise EvalError::BadCall("http_close: " + err)
          }
        _ => raise EvalError::BadCall("http_close")
      }
    }
    // --- HTTP Server builtins ---
    "http_listen" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_listen")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_listen")
      }
      match pos_args[0] {
        @core.Value::Int(port) =>
          match @backend.http_listen(port.to_int()) {
            Ok(handle) => {
              let effects = out.effects
              let h64 = handle.to_int64()
              effects.push(Effect::HttpListen(port.to_int(), h64))
              { value: @core.Value::Int(h64), effects }
            }
            Err(err) => raise EvalError::BadCall("http_listen: " + err)
          }
        _ => raise EvalError::BadCall("http_listen")
      }
    }
    "http_accept" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_accept")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_accept")
      }
      match pos_args[0] {
        @core.Value::Int(server_handle) =>
          match @backend.http_accept(server_handle.to_int()) {
            Ok(req_handle) => {
              let effects = out.effects
              let rh64 = req_handle.to_int64()
              effects.push(Effect::HttpAccept(server_handle, rh64))
              { value: @core.Value::Int(rh64), effects }
            }
            Err(err) => raise EvalError::BadCall("http_accept: " + err)
          }
        _ => raise EvalError::BadCall("http_accept")
      }
    }
    "http_request_method" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_request_method")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_request_method")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_request_method(handle.to_int()) {
            Ok(meth) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestMethod(handle, meth))
              { value: @core.Value::String(meth), effects }
            }
            Err(err) => raise EvalError::BadCall("http_request_method: " + err)
          }
        _ => raise EvalError::BadCall("http_request_method")
      }
    }
    "http_request_url" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_request_url")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_request_url")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_request_url(handle.to_int()) {
            Ok(url) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestUrl(handle, url))
              { value: @core.Value::String(url), effects }
            }
            Err(err) => raise EvalError::BadCall("http_request_url: " + err)
          }
        _ => raise EvalError::BadCall("http_request_url")
      }
    }
    "http_request_header" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_request_header")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("http_request_header")
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(handle), @core.Value::String(hdr_name)) =>
          match @backend.http_request_header(handle.to_int(), hdr_name) {
            Ok(hdr_val) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestHeader(handle, hdr_name, hdr_val))
              { value: @core.Value::String(hdr_val), effects }
            }
            Err(err) => raise EvalError::BadCall("http_request_header: " + err)
          }
        _ => raise EvalError::BadCall("http_request_header")
      }
    }
    "http_request_body" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_request_body")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("http_request_body")
      }
      match pos_args[0] {
        @core.Value::Int(handle) =>
          match @backend.http_request_body(handle.to_int()) {
            Ok(body) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestBody(handle, body))
              { value: @core.Value::String(body), effects }
            }
            Err(err) => raise EvalError::BadCall("http_request_body: " + err)
          }
        _ => raise EvalError::BadCall("http_request_body")
      }
    }
    "http_respond" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "http_respond")
      if pos_args.length() != 4 {
        raise EvalError::BadCall("http_respond")
      }
      let handle = match pos_args[0] {
        @core.Value::Int(v) => v
        _ => raise EvalError::BadCall("http_respond")
      }
      let status = match pos_args[1] {
        @core.Value::Int(v) => v
        _ => raise EvalError::BadCall("http_respond")
      }
      let headers = match pos_args[2] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_respond")
      }
      let body = match pos_args[3] {
        @core.Value::String(s) => s
        _ => raise EvalError::BadCall("http_respond")
      }
      match
        @backend.http_respond(handle.to_int(), status.to_int(), headers, body) {
        Ok(_) => {
          let effects = out.effects
          effects.push(
            Effect::HttpRespond(handle, status.to_int(), headers, body),
          )
          { value: @core.Value::Unit, effects }
        }
        Err(err) => raise EvalError::BadCall("http_respond: " + err)
      }
    }
    "llm_complete" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "llm_complete")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("llm_complete")
      }
      let system = match pos_args[0] {
        @core.Value::String(s) => s
        @core.Value::PromptText(pt) => pt.as_string()
        _ => raise EvalError::BadCall("llm_complete")
      }
      let user = match pos_args[1] {
        @core.Value::String(s) => s
        @core.Value::PromptText(pt) => pt.as_string()
        _ => raise EvalError::BadCall("llm_complete")
      }
      let config = match LlmConfig::from_env() {
        Some(c) => c
        None =>
          raise EvalError::BadCall(
            "llm_complete: VIBE_LLM_PROVIDER env var not set",
          )
      }
      if not(rt.caps().can_call_llm(config.model)) {
        raise EvalError::PermissionDenied("llm_call:" + config.model)
      }
      let response = llm_complete(config, system, user)
      let effects = out.effects
      effects.push(
        Effect::LlmComplete(
          config.model,
          truncate_preview(user, 80),
          truncate_preview(response, 80),
        ),
      )
      { value: @core.Value::String(response), effects }
    }
    "rlm_run" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "rlm_run")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("rlm_run")
      }
      let task = match pos_args[0] {
        @core.Value::String(s) => s
        @core.Value::PromptText(pt) => pt.as_string()
        _ => raise EvalError::BadCall("rlm_run")
      }
      let prompt = match pos_args[1] {
        @core.Value::String(s) => s
        @core.Value::PromptText(pt) => pt.as_string()
        _ => raise EvalError::BadCall("rlm_run")
      }
      let budget = RlmBudget::default()
      let result = rlm_run_loop(rt, task, prompt, budget)
      let effects = out.effects
      effects.push(
        Effect::RlmTrace(
          "{\"task\":" +
          json_escape_string(truncate_preview(task, 80)) +
          ",\"steps\":" +
          budget.steps_used.to_string() +
          "}",
        ),
      )
      { value: @core.Value::String(result), effects }
    }
    "rlm_finalize" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "rlm_finalize")
      if pos_args.length() != 1 {
        raise EvalError::BadCall("rlm_finalize")
      }
      match pos_args[0] {
        @core.Value::String(s) =>
          { value: @core.Value::String(s), effects: out.effects }
        _ => raise EvalError::BadCall("rlm_finalize")
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
    "string_builder" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "string_builder")
      if pos_args.length() != 0 {
        raise EvalError::BadCall("string_builder")
      }
      { value: @core.Value::StringBuilder([]), effects: out.effects }
    }
    "string_builder_push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "string_builder_push")
      if pos_args.length() != 2 {
        raise EvalError::BadCall("string_builder_push")
      }
      match pos_args[0] {
        @core.Value::StringBuilder(chunks) =>
          match pos_args[1] {
            @core.Value::String(s) => {
              chunks.push(s)
              { value: @core.Value::Unit, effects: out.effects }
            }
            _ => raise EvalError::BadCall("string_builder_push")
          }
        _ => raise EvalError::BadCall("string_builder_push")
      }
    }
    "string_builder_freeze" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "string_builder_freeze",
      )
      if pos_args.length() != 1 {
        raise EvalError::BadCall("string_builder_freeze")
      }
      match pos_args[0] {
        @core.Value::StringBuilder(chunks) => {
          let mut result = ""
          for chunk in chunks {
            result = result + chunk
          }
          { value: @core.Value::String(result), effects: out.effects }
        }
        _ => raise EvalError::BadCall("string_builder_freeze")
      }
    }
    "array_builder" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "array_builder")
      if pos_args.length() != 0 {
        raise EvalError::BadCall("array_builder")
      }
      { value: @core.Value::ArrayBuilder([]), effects: out.effects }
    }
    "array_builder_push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "array_builder_push")
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
      let pos_args = extract_positional_values(out.args, "array_builder_freeze")
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
      let pos_args = extract_positional_values(out.args, "map_builder_set")
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
      let pos_args = extract_positional_values(out.args, "map_builder_freeze")
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
