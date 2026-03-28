///|
/// Evaluation for vibe
pub enum Effect {
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
  FsReadDir(String, Int) // (path, entry_count)
  FsIsDir(String, Bool) // (path, result)
  FsMkdir(String) // (path)
  FsGetCwd(String) // (cwd)
  FsChdir(String) // (new_cwd)
  FsRemove(String) // (path)
  FsIsFile(String, Bool) // (path, result)
  FsCopy(String, String) // (src, dst)
  FsRename(String, String) // (old, new)
  FsAppend(String, String) // (path, content_preview)
  EnvGet(String, String) // (name, value)
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
fn[T] rethrow_with_prior_effects(
  e : EvalError,
  has_effects : Bool,
) -> T raise EvalError {
  match e {
    EvalError::Performed(performed_value, site_key, has_prior_effect) =>
      raise EvalError::Performed(
        performed_value,
        site_key,
        has_prior_effect || has_effects,
      )
    _ => raise e
  }
}

///|
fn mkdir_recursive(path : String) -> Unit {
  if @io.path_exists(path) {
    return
  }
  let parent = @path.Path(path).dirname().normalize().to_string()
  if parent != path && parent != "/" && parent != "." {
    mkdir_recursive(parent)
  }
  if not(@io.path_exists(path)) {
    @io.create_dir(path) |> ignore
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
  BadCall(ErrorCode)
  ImportError(String)
  FeatureDisabled(feature~ : String, operation~ : String, flag~ : String)
  Performed(@core.Value, String, Bool)
  Resume(@core.Value)
  LoopBreak(@core.Value?)
  LoopContinue(Array[@core.Value])
  LoopFuelExhausted
} derive(Show, Eq)

///|
pub fn EvalError::user_message(self : EvalError) -> String {
  match self {
    EvalError::BadCall(code) => format_error(code)
    EvalError::UnknownName(name) => "undefined: " + name
    EvalError::PermissionDenied(msg) => "permission denied: " + msg
    EvalError::ImportError(msg) => "import error: " + msg
    EvalError::FeatureDisabled(feature~, operation~, flag~) =>
      operation +
      " requires feature '" +
      feature +
      "' (enable with " +
      flag +
      ")"
    EvalError::LoopFuelExhausted =>
      "loop fuel exhausted (possible infinite loop)"
    _ => self.to_string()
  }
}

///|
fn wrap_error_effect(payload : @core.Value) -> @core.Value {
  let fields : Map[String, @core.Value] = {}
  fields["Error"] = payload
  @core.Value::Record(fields)
}

///|
fn normalize_performed_value(value : @core.Value) -> @core.Value {
  match value {
    @core.Value::Record(_) => value
    _ => wrap_error_effect(value)
  }
}

///|
fn parse_connect_port(port_text : String) -> Int? {
  if port_text.length() == 0 {
    return None
  }
  let mut value = 0
  for ch in port_text.to_array() {
    if ch < '0' || ch > '9' {
      return None
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
    if value > 65535 {
      return None
    }
  }
  if value <= 0 {
    return None
  }
  Some(value)
}

///|
fn parse_http_connect_target(url : String) -> (String, Int)? {
  let (rest, default_port) = if url.has_prefix("https://") {
    (url.unsafe_substring(start=8, end=url.length()), 443)
  } else if url.has_prefix("http://") {
    (url.unsafe_substring(start=7, end=url.length()), 80)
  } else {
    return None
  }
  if rest.length() == 0 {
    return None
  }
  let rest_chars = rest.to_array()
  let mut authority_end = rest_chars.length()
  for i in 0..<rest_chars.length() {
    let ch = rest_chars[i]
    if ch == '/' || ch == '?' || ch == '#' {
      authority_end = i
      break
    }
  }
  if authority_end == 0 {
    return None
  }
  let authority = rest.unsafe_substring(start=0, end=authority_end)
  let authority_chars = authority.to_array()
  let mut last_at : Int? = None
  for i in 0..<authority_chars.length() {
    if authority_chars[i] == '@' {
      last_at = Some(i)
    }
  }
  let host_port = match last_at {
    Some(i) => authority.unsafe_substring(start=i + 1, end=authority.length())
    None => authority
  }
  if host_port.length() == 0 {
    return None
  }
  if host_port.has_prefix("[") {
    let chars = host_port.to_array()
    let mut close_idx : Int? = None
    for i in 1..<chars.length() {
      if chars[i] == ']' {
        close_idx = Some(i)
        break
      }
    }
    match close_idx {
      None => None
      Some(i) => {
        if i <= 1 {
          return None
        }
        let host = host_port.unsafe_substring(start=1, end=i)
        if i + 1 >= chars.length() {
          return Some((host, default_port))
        }
        if chars[i + 1] != ':' {
          return None
        }
        let port_text = host_port.unsafe_substring(
          start=i + 2,
          end=host_port.length(),
        )
        match parse_connect_port(port_text) {
          Some(port) => Some((host, port))
          None => None
        }
      }
    }
  } else {
    let chars = host_port.to_array()
    let mut colon_count = 0
    let mut last_colon = -1
    for i in 0..<chars.length() {
      if chars[i] == ':' {
        colon_count = colon_count + 1
        last_colon = i
      }
    }
    if colon_count == 0 {
      return Some((host_port, default_port))
    }
    if colon_count > 1 || last_colon <= 0 || last_colon + 1 >= chars.length() {
      return None
    }
    let host = host_port.unsafe_substring(start=0, end=last_colon)
    let port_text = host_port.unsafe_substring(
      start=last_colon + 1,
      end=host_port.length(),
    )
    match parse_connect_port(port_text) {
      Some(port) => Some((host, port))
      None => None
    }
  }
}

///|
fn fs_stat_token_from_text(source : String) -> Int {
  let mod1 = 2147483647
  let mod2 = 2147483629
  let step1 = 131
  let step2 = 65599
  let len = source.length()
  let mut h1 = 17
  let mut h2 = 29
  let mut i = 0
  while i < len {
    let c = source[i].to_int()
    h1 = (h1 * step1 + c + 1) % mod1
    h2 = (h2 * step2 + c + i + 1) % mod2
    i += 1
  }
  (len % mod1 * step1 + h1 + h2) % mod1
}

///|
/// Generate a site identification key for perform/resume matching.
/// The key must be deterministic for the same source location because
/// resume re-evaluates the body and needs to find the stored value.
/// It is namespaced by active handle scope hash to reduce cross-module
/// collisions for same-span calls.
fn perform_site_key(rt : Runtime, span : @core.Span) -> String {
  let local_key = span.start.to_string() + ":" + span.end.to_string()
  match rt.active_handle_scope {
    Some(scope_hash) => scope_hash + ":" + local_key
    None => "global:" + local_key
  }
}

///|
fn eval_handle_expr(
  rt : Runtime,
  body : @core.Module,
  arms : Array[@core.MatchArm],
) -> EvalOutput raise EvalError {
  let prev_scope = rt.active_handle_scope
  rt.active_handle_scope = Some(@core.hash_module(body))
  let handled_result : Result[EvalOutput, EvalError] = try? (eval_block(
    rt, body,
  ) catch {
    e =>
      match e {
        EvalError::Performed(performed_value, site_key, has_prior_effect) => {
          let mut matched_out : EvalOutput? = None
          for arm in arms {
            if matched_out is Some(_) {
              continue
            }
            match match_pattern(arm.pat, performed_value) {
              Some(bindings) => {
                let guard_ok = match arm.cond {
                  Some(c) =>
                    match eval_expr_with_bindings(rt, c, bindings).value {
                      @core.Value::Bool(b) => b
                      _ =>
                        raise EvalError::BadCall(
                          CondNotBool(ctx="handle guard", got="unknown"),
                        )
                    }
                  None => true
                }
                if guard_ok {
                  let arm_result : Result[EvalOutput, EvalError] = try? eval_expr_with_bindings(
                    rt,
                    arm.expr,
                    bindings,
                  )
                  match arm_result {
                    Ok(out) => matched_out = Some(out)
                    Err(EvalError::Resume(resume_value)) => {
                      if has_prior_effect {
                        raise EvalError::BadCall(
                          E("resume cannot continue after prior effects"),
                        )
                      }
                      rt.perform_resume_overrides[site_key] = resume_value
                      let resumed : Result[EvalOutput, EvalError] = try? eval_handle_expr(
                        rt, body, arms,
                      )
                      match resumed {
                        Ok(out) => matched_out = Some(out)
                        Err(EvalError::BadCall(_)) =>
                          raise EvalError::BadCall(
                            E("resume value type mismatch"),
                          )
                        Err(err) => raise err
                      }
                    }
                    Err(err) => raise err
                  }
                }
              }
              None => ()
            }
          }
          match matched_out {
            Some(out) => out
            None =>
              raise EvalError::Performed(
                performed_value, site_key, has_prior_effect,
              )
          }
        }
        _ => raise e
      }
  })
  rt.active_handle_scope = prev_scope
  match handled_result {
    Ok(out) => out
    Err(err) => raise err
  }
}

///|
pub fn Runtime::eval_module(
  self : Runtime,
  ast : @core.Module,
) -> EvalResult raise EvalError {
  // Topologically sort let-binding statements so that forward references
  // to type-annotated values are resolved before use.
  // Only apply when there are no interleaved side-effect statements,
  // because reordering let-bindings can change the meaning of interleaved effects.
  // Topologically sort let-binding statements so that forward references
  // to type-annotated values are resolved before use.
  // Only apply when there are no interleaved side-effect statements.
  let sorted_ast = {
    let mut has_side_effects = false
    let len = ast.stmts.length()
    for idx = 0; idx < len; idx = idx + 1 {
      match ast.stmts[idx] {
        @core.Stmt::LetMut(..)
        | @core.Stmt::Assign(..)
        | @core.Stmt::IndexAssign(..) => {
          has_side_effects = true
          break
        }
        @core.Stmt::Expr(..) =>
          if idx < len - 1 {
            has_side_effects = true
            break
          }
        _ => ()
      }
    }
    if has_side_effects {
      ast
    } else {
      @core.Module::{ stmts: @core.topo_sort_let_stmts(ast.stmts) }
    }
  }
  let effects : Array[Effect] = []
  let mut last : @core.Value? = None
  let local_value_decl_names : Map[String, Bool] = {}
  for stmt in sorted_ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::ExternLet(name~, ..) =>
        if name != "_" {
          local_value_decl_names[name] = true
        }
      _ => ()
    }
  }
  // Pre-scan: identify forward-declarable functions and compute stable
  // addresses. All forward function addresses are computed here so that
  // closures capture a consistent addr_env for mutual references.
  let forward_fn_addrs : Map[String, String] = {} // name → pre-computed addr
  for stmt in sorted_ast.stmts {
    match stmt {
      @core.Stmt::Let(rec=false, name~, expr~, ..)
      | @core.Stmt::ExportLet(rec=false, name~, expr~, ..)
      | @core.Stmt::InternalExportLet(rec=false, name~, expr~, ..) =>
        if name != "_" {
          match expr {
            @core.Expr::Fn(ret=Some(_), ..) => {
              let addr = @codegen.expr_address(expr, self.addr_env, Some(name))
              self.env[name] = addr
              self.addr_env[name] = addr
              forward_fn_addrs[name] = addr
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  for stmt in sorted_ast.stmts {
    let stmt_result : Result[Unit, EvalError] = try? (match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) =>
        if name == "_" {
          let out = eval_expr(self, expr)
          extend_effects(effects, out.effects)
          last = Some(out.value)
        } else {
          let is_forward = forward_fn_addrs.contains(name)
          let effective_rec = rec || is_forward
          let info = @checker.purity_for_let(
            self.type_env,
            effective_rec,
            name,
            expr,
          )
          let use_addr = effective_rec || info.expr
          // For forward functions, reuse the pre-computed address to stay
          // consistent with what other closures captured.
          let addr = match forward_fn_addrs.get(name) {
            Some(pre_addr) => pre_addr
            None =>
              @codegen.expr_address(
                expr,
                self.addr_env,
                if effective_rec {
                  Some(name)
                } else {
                  None
                },
              )
          }
          if effective_rec && not(is_forward) {
            // Forward functions already registered in pre-scan
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
      @core.Stmt::InternalTraitDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::TraitImpl(..) => last = Some(@core.Value::Unit)
      @core.Stmt::Expr(expr~, ..) => {
        let out = eval_expr(self, expr)
        extend_effects(effects, out.effects)
        last = Some(out.value)
      }
      @core.Stmt::ReExport(spec~, source~, ..) => {
        let hash = match source {
          @core.ModuleRef::Hash(hash~) => hash
          @core.ModuleRef::PinnedPath(path=_, hash~) => hash
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
          @core.ModuleRef::Alias(name~) =>
            raise EvalError::ImportError(
              "Import alias ref not resolved to hash: " + name,
            )
        }
        match self.get_module(hash) {
          None =>
            raise EvalError::ImportError("Module not found in cache: " + hash)
          Some(imported_module) => {
            let imported_rt = match self.import_eval_cache.get(hash) {
              Some(cached_rt) => cached_rt
              None => {
                let rt = self.fork_for_test()
                let _ = rt.eval_module(imported_module) catch {
                  e =>
                    raise EvalError::ImportError(
                      "Failed to evaluate imported module: " + e.to_string(),
                    )
                }
                self.import_eval_cache[hash] = rt
                rt
              }
            }
            let exports = @core.extract_exports(imported_module)
            for item in spec.items {
              let source_name = item.name
              let export_name = @core.import_item_local_name(item)
              match exports.get(source_name) {
                None =>
                  raise EvalError::ImportError(
                    "Symbol not exported: " + source_name,
                  )
                Some(_) =>
                  match imported_rt.get(source_name) {
                    Some(value) => self.bind(export_name, value) |> ignore
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
          @core.ModuleRef::PinnedPath(path=_, hash~) => hash
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
          @core.ModuleRef::Alias(name~) =>
            raise EvalError::ImportError(
              "Import alias ref not resolved to hash: " + name,
            )
        }
        // Look up module in cache
        match self.get_module(hash) {
          None =>
            raise EvalError::ImportError("Module not found in cache: " + hash)
          Some(imported_module) => {
            // Check if this module has already been evaluated
            let imported_rt = match self.import_eval_cache.get(hash) {
              Some(cached_rt) => cached_rt
              None => {
                // Evaluate imported module in an isolated fork so exported values can
                // reference internal helpers defined in the same module.
                let rt = self.fork_for_test()
                let result = rt.eval_module(imported_module) catch {
                  e =>
                    raise EvalError::ImportError(
                      "Failed to evaluate imported module: " + e.to_string(),
                    )
                }
                if result.effects.length() > 0 {
                  raise EvalError::ImportError("Cannot import effectful module")
                }
                self.import_eval_cache[hash] = rt
                rt
              }
            }
            let exports = @core.extract_exports(imported_module)
            let bind_import = fn(
              source_name : String,
              target_name : String,
            ) raise EvalError {
              if target_name != "_" &&
                local_value_decl_names.contains(target_name) {
                return
              }
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
                        @core.Stmt::ExportLet(..)
                        | @core.Stmt::InternalExportLet(..)
                        | @core.Stmt::Let(..) =>
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
            let explicit_targets : Map[String, Bool] = {}
            for explicit_item in spec.items {
              let local_name = match explicit_item.rename {
                Some(rename_name) => rename_name
                None => explicit_item.name
              }
              explicit_targets[local_name] = true
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
                  if explicit_targets.contains(target_name) {
                    continue
                  }
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
                if explicit_targets.contains(target_name) {
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
                    // Namespace import: `import <ref> { Int }` brings `Int::...`.
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
      @core.Stmt::ExternLet(name~, ty~, ..) => {
        let _ = name
        let _ = ty
        last = Some(@core.Value::Unit)
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..)
      | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) =>
        if name == "_" {
          let out = eval_expr(self, expr)
          extend_effects(effects, out.effects)
          last = Some(out.value)
        } else {
          let is_forward = forward_fn_addrs.contains(name)
          let effective_rec = rec || is_forward
          let info = @checker.purity_for_let(
            self.type_env,
            effective_rec,
            name,
            expr,
          )
          let use_addr = effective_rec || info.expr
          let addr = match forward_fn_addrs.get(name) {
            Some(pre_addr) => pre_addr
            None =>
              @codegen.expr_address(
                expr,
                self.addr_env,
                if effective_rec {
                  Some(name)
                } else {
                  None
                },
              )
          }
          if effective_rec && not(is_forward) {
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
      @core.Stmt::InternalExportEnumDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::ExportTypeAlias(..) => last = Some(@core.Value::Unit)
      @core.Stmt::InternalExportTypeAlias(..) => last = Some(@core.Value::Unit)
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
          raise EvalError::BadCall(AssignImm(name~))
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
          None => raise EvalError::BadCall(LetPatFail)
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
      @core.Stmt::InternalExportStructDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::EffectDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::ExportEffectDef(..) => last = Some(@core.Value::Unit)
      @core.Stmt::AliasDecl(..) => last = Some(@core.Value::Unit)
    })
    match stmt_result {
      Ok(_) => ()
      Err(e) => rethrow_with_prior_effects(e, effects.length() > 0)
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
    @core.Expr::Call(name~, args~, span~, ..) => eval_call(rt, name, args, span)
    @core.Expr::Tuple(items~, ..) => {
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        let out : EvalOutput = eval_expr(rt, item) catch {
          e => rethrow_with_prior_effects(e, effects.length() > 0)
        }
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
            raise EvalError::BadCall(TupleOOB(index~))
          }
        _ => raise EvalError::BadCall(TupleType)
      }
    }
    @core.Expr::Record(fields~, ..) => {
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out : EvalOutput = eval_expr(rt, field.expr) catch {
          e => rethrow_with_prior_effects(e, effects.length() > 0)
        }
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
        let out : EvalOutput = eval_expr(rt, field.expr) catch {
          e => rethrow_with_prior_effects(e, effects.length() > 0)
        }
        map[field.name] = out.value
        extend_effects(effects, out.effects)
      }
      { value: @core.Value::Record(map), effects }
    }
    @core.Expr::Array(items~, ..) => {
      let values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for item in items {
        match item {
          @core.Expr::Spread(expr~, ..) => {
            let out : EvalOutput = eval_expr(rt, expr) catch {
              e => rethrow_with_prior_effects(e, effects.length() > 0)
            }
            match out.value {
              @core.Value::Array(spread_items) =>
                for si in spread_items {
                  values.push(si)
                }
              _ => raise EvalError::BadCall(E("spread requires an array value"))
            }
            extend_effects(effects, out.effects)
          }
          _ => {
            let out : EvalOutput = eval_expr(rt, item) catch {
              e => rethrow_with_prior_effects(e, effects.length() > 0)
            }
            values.push(out.value)
            extend_effects(effects, out.effects)
          }
        }
      }
      { value: @core.Value::Array(values), effects }
    }
    @core.Expr::Map(fields~, ..) => {
      let map : Map[String, @core.Value] = {}
      let effects : Array[Effect] = []
      for field in fields {
        let out : EvalOutput = eval_expr(rt, field.expr) catch {
          e => rethrow_with_prior_effects(e, effects.length() > 0)
        }
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
          let branch_out : EvalOutput = try {
            if b {
              eval_block_shared_mut(rt, then_body)
            } else {
              eval_block_shared_mut(rt, else_body)
            }
          } catch {
            e => rethrow_with_prior_effects(e, effects.length() > 0)
          }
          extend_effects(effects, branch_out.effects)
          { value: branch_out.value, effects }
        }
        _ as v =>
          raise EvalError::BadCall(
            E("if condition must be Bool, got " + value_type_name(v)),
          )
      }
    }
    @core.Expr::Block(body~, ..) => eval_block(rt, body)
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, ..) => {
      let v = if args.length() >= 1 {
        eval_expr(rt, args[0].expr)
      } else {
        { value: @core.Value::String(""), effects: [] }
      }
      raise EvalError::Performed(
        wrap_error_effect(v.value),
        "__throw",
        v.effects.length() > 0,
      )
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, ..) => {
      // Evaluate arguments
      let arg_values : Array[@core.Value] = []
      let effects : Array[Effect] = []
      for arg in args {
        let out = eval_expr(rt, arg.expr)
        arg_values.push(out.value)
        extend_effects(effects, out.effects)
      }
      // Encode as Ctor value for handle arm pattern matching
      let key = effect_name + "::" + op_name
      let performed_value = ctor_value_from_args(key, arg_values)
      raise EvalError::Performed(performed_value, key, effects.length() > 0)
    }
    @core.Expr::Handle(body~, arms~, ..) => eval_handle_expr(rt, body, arms)
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
                  _ as v =>
                    raise EvalError::BadCall(
                      E(
                        "guard condition must be Bool, got " +
                        value_type_name(v),
                      ),
                    )
                }
              }
              None => true
            }
            if guard_ok {
              let out : EvalOutput = eval_expr_with_bindings(
                rt,
                arm.expr,
                bindings,
              ) catch {
                e => rethrow_with_prior_effects(e, effects.length() > 0)
              }
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
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let iter_val = eval_expr(rt, iterable)
      let is_string = match iter_val.value {
        @core.Value::String(_) => true
        _ => false
      }
      let desugared = if is_string {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      eval_block_shared_mut(rt, desugared)
    }
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
    @core.Expr::Yield(expr~, ..) => {
      require_unstable_async(rt, "yield")
      // For now, yield just evaluates and returns the expression
      // Future: handle Stream[T] generation
      eval_expr(rt, expr)
    }
    @core.Expr::Spread(..) =>
      raise EvalError::UnknownName(
        "eval: spread operator should only appear inside array literals",
      )
    @core.Expr::StringInterp(parts~, ..) => {
      let buf = StringBuilder::new()
      let effects : Array[Effect] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(s) => buf.write_string(s)
          @core.StringInterpPart::Expr(e) => {
            let out = eval_expr(rt, e)
            extend_effects(effects, out.effects)
            match out.value {
              @core.Value::String(s) => buf.write_string(s)
              v => buf.write_string(v.to_string())
            }
          }
        }
      }
      { value: @core.Value::String(buf.to_string()), effects }
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
            _ as v =>
              raise EvalError::BadCall(
                E("while condition must be Bool, got " + value_type_name(v)),
              )
          }
        }) {
    rt.loop_fuel -= 1
    if rt.loop_fuel <= 0 {
      raise EvalError::LoopFuelExhausted
    }
    let body_result : Result[EvalResult, EvalError] = try? rt.eval_module(body)
    match body_result {
      Ok(body_res) => extend_effects(effects, body_res.effects)
      Err(EvalError::LoopBreak(_)) => break
      Err(EvalError::LoopContinue(_)) => continue
      Err(e) => rethrow_with_prior_effects(e, effects.length() > 0)
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
    rt.loop_fuel -= 1
    if rt.loop_fuel <= 0 {
      raise EvalError::LoopFuelExhausted
    }
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
      Err(e) => rethrow_with_prior_effects(e, effects.length() > 0)
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
  // Propagate cwd changes back (cd semantics)
  rt.cwd = scope_rt.cwd
  let value = match res.last {
    Some(v) => v
    None => @core.Value::Unit
  }
  { value, effects: res.effects }
}

///|
/// Evaluate block with shared mut_vars (for if/while branches).
/// New let bindings are scoped, but mutations to existing mut vars propagate.
/// Check if a block contains any binding statements (let, let mut, etc.)
/// that would require env snapshot/restore.
fn block_has_bindings(body : @core.Module) -> Bool {
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(..)
      | @core.Stmt::LetMut(..)
      | @core.Stmt::ExportLet(..)
      | @core.Stmt::InternalExportLet(..)
      | @core.Stmt::ExternLet(..) => return true
      _ => ()
    }
  }
  false
}

///|
fn eval_block_shared_mut(
  rt : Runtime,
  body : @core.Module,
) -> EvalOutput raise EvalError {
  // Fast path: if block has no bindings, no env snapshot needed.
  // Mutations to existing mutable vars propagate via rt.store directly.
  if not(block_has_bindings(body)) {
    let res = rt.eval_module(body)
    let value = match res.last {
      Some(v) => v
      None => @core.Value::Unit
    }
    return { value, effects: res.effects }
  }
  // Snapshot existing env (key -> hash) and mut_vars before evaluating
  let pre_env : Map[String, String] = {}
  for k, v in rt.env {
    pre_env[k] = v
  }
  let pre_mut : Map[String, Bool] = {}
  for k, v in rt.mut_vars {
    pre_mut[k] = v
  }
  // Evaluate directly on rt so mutations propagate
  let res = rt.eval_module(body)
  // Remove new bindings and restore shadowed ones
  let to_remove : Array[String] = []
  for k, _ in rt.env {
    if not(pre_env.contains(k)) {
      to_remove.push(k)
    }
  }
  for k in to_remove {
    rt.env.remove(k)
  }
  // Restore any bindings that were shadowed (value changed by a new let, not by mutation)
  for k, old_hash in pre_env {
    // Only restore if the variable is NOT mutable (mutable vars should keep their mutated value)
    if not(pre_mut.contains(k)) {
      rt.env[k] = old_hash
    }
  }
  // Restore mut_vars: remove entries added by the block
  let mut_to_remove : Array[String] = []
  for k, _ in rt.mut_vars {
    if not(pre_mut.contains(k)) {
      mut_to_remove.push(k)
    }
  }
  for k in mut_to_remove {
    rt.mut_vars.remove(k)
  }
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
  match @core.first_positional_expr(args) {
    None => None
    Some(expr) =>
      match rt.type_env.get_expr_type(expr.span()) {
        Some(recv_ty) =>
          match rt.type_env.build_type_member_candidate(recv_ty, name) {
            Some(candidate) =>
              match rt.get(candidate) {
                Some(_) => Some(candidate)
                None => None
              }
            None => None
          }
        None => None
      }
  }
}

///|
/// Map a resolved type to its builtin namespace root for UFCS dispatch.
fn builtin_ufcs_namespace_rt(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::Char => Some("Char")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Array(_) => Some("Array")
    @core.Type::Map(_, _) => Some("Map")
    @core.Type::Set(_) => Some("Set")
    @core.Type::ArrayBuilder(_) => Some("ArrayBuilder")
    @core.Type::MapBuilder(_, _) => Some("MapBuilder")
    @core.Type::Bytes => Some("Bytes")
    @core.Type::PromptText => Some("PromptText")
    _ => None
  }
}

///|
/// UFCS fallback for builtins at runtime: resolve unqualified name via first
/// argument's type recorded by the checker. Returns "Array::push" etc.
fn resolve_builtin_ufcs_name_rt(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> String? {
  match @core.first_positional_expr(args) {
    None => None
    Some(expr) =>
      match rt.type_env.get_expr_type(expr.span()) {
        Some(recv_ty) =>
          match builtin_ufcs_namespace_rt(recv_ty) {
            Some(ns) => Some(ns + "::" + name)
            None => None
          }
        None => None
      }
  }
}

///|
fn try_eval_hot_builtin_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
) -> EvalOutput? raise EvalError {
  let is_hot = name == "String::length" ||
    name == "String::char_code_at" ||
    name == "String::substring" ||
    name == "String::concat" ||
    name == "array_new" ||
    name == "Array::length" ||
    name == "Array::get" ||
    name == "FixedArray::make" ||
    name == "FixedArray::length" ||
    name == "FixedArray::get"
  if not(is_hot) {
    return None
  }
  let values : Array[@core.Value] = []
  let effects : Array[Effect] = []
  for arg in args {
    match arg.label {
      Some(_) => return None
      None => ()
    }
    let out : EvalOutput = eval_expr(rt, arg.expr) catch {
      e => rethrow_with_prior_effects(e, effects.length() > 0)
    }
    values.push(out.value)
    extend_effects(effects, out.effects)
  }
  let value = match name {
    "array_new" => {
      if values.length() != 0 {
        raise EvalError::BadCall(
          E(
            "array_new: expected 0 arguments, got " +
            values.length().to_string(),
          ),
        )
      }
      @core.Value::Array([])
    }
    "String::length" => {
      if values.length() != 1 {
        raise EvalError::BadCall(
          E(
            "String::length: expected 1 argument, got " +
            values.length().to_string(),
          ),
        )
      }
      match values[0] {
        @core.Value::String(s) => @core.Value::Int(String::length(s).to_int64())
        _ as v =>
          raise EvalError::BadCall(
            E("String::length: got " + value_type_name(v)),
          )
      }
    }
    "String::char_code_at" => {
      if values.length() != 2 {
        raise EvalError::BadCall(E("String::char_code_at"))
      }
      match (values[0], values[1]) {
        (@core.Value::String(s), @core.Value::Int(index)) => {
          if index < 0L || index >= String::length(s).to_int64() {
            raise EvalError::BadCall(E("String::char_code_at"))
          }
          let code = String::code_unit_at(s, index.to_int())
          @core.Value::Int(UInt16::to_int(code).to_int64())
        }
        _ => raise EvalError::BadCall(E("String::char_code_at"))
      }
    }
    "String::substring" => {
      if values.length() != 3 {
        raise EvalError::BadCall(E("String::substring"))
      }
      match (values[0], values[1], values[2]) {
        (@core.Value::String(s), @core.Value::Int(start), @core.Value::Int(end)) => {
          let len = String::length(s).to_int64()
          let mut a = start
          let mut b = end
          if a < 0L {
            a = 0L
          }
          if b < 0L {
            b = 0L
          }
          if a > len {
            a = len
          }
          if b > len {
            b = len
          }
          let (from, to) = if a <= b { (a, b) } else { (b, a) }
          @core.Value::String(
            String::unsafe_substring(s, start=from.to_int(), end=to.to_int()),
          )
        }
        _ => raise EvalError::BadCall(E("String::substring"))
      }
    }
    "String::concat" => {
      if values.length() != 2 {
        raise EvalError::BadCall(
          E(
            "String::concat: expected 2 arguments, got " +
            values.length().to_string(),
          ),
        )
      }
      match (values[0], values[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::String(String::add(a, b))
        _ =>
          raise EvalError::BadCall(
            E(
              "String::concat: expected (String, String), got (" +
              value_type_name(values[0]) +
              ", " +
              value_type_name(values[1]) +
              ")",
            ),
          )
      }
    }
    "Array::length" | "FixedArray::length" => {
      if values.length() != 1 {
        raise EvalError::BadCall(
          E(
            "Array::length: expected 1 argument, got " +
            values.length().to_string(),
          ),
        )
      }
      match values[0] {
        @core.Value::Array(items) => @core.Value::Int(items.length().to_int64())
        _ =>
          raise EvalError::BadCall(
            E(
              "expected Array, got " +
              value_type_name(values[0]) +
              " (for-in requires an iterable)",
            ),
          )
      }
    }
    "Array::get" | "FixedArray::get" => {
      if values.length() != 2 {
        raise EvalError::BadCall(
          E(
            "Array::get: expected 2 arguments, got " +
            values.length().to_string(),
          ),
        )
      }
      match (values[0], values[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall(
              E(
                "Array::get: index " +
                index.to_string() +
                " out of bounds (length " +
                items.length().to_string() +
                ")",
              ),
            )
          }
          items[index.to_int()]
        }
        _ =>
          raise EvalError::BadCall(
            E(
              "Array::get: expected (Array, Int), got (" +
              value_type_name(values[0]) +
              ", " +
              value_type_name(values[1]) +
              ")",
            ),
          )
      }
    }
    "FixedArray::make" => {
      if values.length() != 2 {
        raise EvalError::BadCall(
          E(
            "FixedArray::make: expected 2 arguments, got " +
            values.length().to_string(),
          ),
        )
      }
      match values[0] {
        @core.Value::Int(size) => {
          if size < 0L {
            raise EvalError::BadCall(E("FixedArray::make"))
          }
          let out : Array[@core.Value] = []
          for _ in 0..<size.to_int() {
            out.push(values[1])
          }
          @core.Value::Array(out)
        }
        _ => raise EvalError::BadCall(E("FixedArray::make"))
      }
    }
    _ => return None
  }
  Some({ value, effects })
}

///|
fn eval_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
  call_span : @core.Span,
) -> EvalOutput raise EvalError {
  // Full resolution path: type member resolution + alias checking
  let name = match resolve_type_member_call_name_rt(rt, name, args) {
    Some(candidate) => candidate
    None => name
  }
  // Guard: has_alias_prefix_rt allocates Array[Char] and scans for dot.
  // Skip when name has no dot (common case for builtins and user fns).
  if name.contains(".") && has_alias_prefix_rt(rt, name) {
    { value: @core.Value::Unit, effects: [] }
  } else {
    match rt.get(name) {
      Some(@core.Value::Fn(fn_val)) => eval_user_call(rt, fn_val, args)
      Some(val) => {
        // Name exists but isn't a function - try field access first
        let field_args_out = eval_args(rt, args)
        let field_pos = extract_positional_values(field_args_out.args, name)
        if field_pos.length() == 1 {
          match field_pos[0] {
            @core.Value::Record(record_fields) =>
              match record_fields.get(name) {
                Some(v) => { value: v, effects: field_args_out.effects }
                None =>
                  raise EvalError::BadCall(
                    NotFn(name~, got=value_type_name(val)),
                  )
              }
            _ =>
              raise EvalError::BadCall(NotFn(name~, got=value_type_name(val)))
          }
        } else {
          raise EvalError::BadCall(NotFn(name~, got=value_type_name(val)))
        }
      }
      None =>
        match try_eval_hot_builtin_call(rt, name, args) {
          Some(out) => out
          None =>
            if @core.is_ctor_name(name) {
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, name)
              let value = ctor_value_from_args(name, pos_args)
              { value, effects: out.effects }
            } else if is_cheap_pure_builtin(name) {
              // Cheap pure builtins: execute directly without cache.
              // Cache key computation (SHA hash) costs more than the operation itself.
              let out = eval_args(rt, args)
              let pos_args = extract_positional_values(out.args, name)
              let value = eval_pure_builtin(name, pos_args)
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
              // Try eval_builtin_call first with original name.
              // On failure, attempt UFCS resolution and retry all paths.
              eval_builtin_call(rt, name, args, call_span) catch {
                EvalError::BadCall(UnknownFn(_)) =>
                  if not(name.contains("::")) && not(name.has_prefix("__")) {
                    match resolve_builtin_ufcs_name_rt(rt, name, args) {
                      Some(qualified) =>
                        match try_eval_hot_builtin_call(rt, qualified, args) {
                          Some(out) => out
                          None =>
                            if is_cheap_pure_builtin(qualified) {
                              let out = eval_args(rt, args)
                              let pos_args = extract_positional_values(
                                out.args,
                                qualified,
                              )
                              let value = eval_pure_builtin(qualified, pos_args)
                              { value, effects: out.effects }
                            } else if is_pure_builtin(qualified) {
                              let out = eval_args(rt, args)
                              let pos_args = extract_positional_values(
                                out.args,
                                qualified,
                              )
                              let key = pure_call_key(qualified, pos_args)
                              match rt.pure_cache_get(key) {
                                Some(v) => { value: v, effects: out.effects }
                                None => {
                                  let value = eval_pure_builtin(
                                    qualified, pos_args,
                                  )
                                  rt.pure_cache_set(key, value)
                                  { value, effects: out.effects }
                                }
                              }
                            } else {
                              eval_builtin_call(rt, qualified, args, call_span)
                            }
                        }
                      None =>
                        raise EvalError::BadCall(
                          E("unknown function '" + name + "'"),
                        )
                    }
                  } else {
                    raise EvalError::BadCall(
                      E("unknown function '" + name + "'"),
                    )
                  }
                e => raise e
              }
            }
        }
    }
  }
}

///|
fn eval_builtin_call(
  rt : Runtime,
  name : String,
  args : Array[@core.CallArg],
  call_span : @core.Span,
) -> EvalOutput raise EvalError {
  match name {
    "__perform" => {
      let site_key = perform_site_key(rt, call_span)
      match rt.perform_resume_overrides.get(site_key) {
        Some(v) => {
          rt.perform_resume_overrides.remove(site_key)
          { value: v, effects: [] }
        }
        None => {
          let out = eval_args(rt, args)
          let pos_args = extract_positional_values(out.args, "__perform")
          if pos_args.length() != 1 {
            raise EvalError::BadCall(
              BuiltinDetail(fn_name="__perform", detail="bad call"),
            )
          }
          raise EvalError::Performed(
            normalize_performed_value(pos_args[0]),
            site_key,
            out.effects.length() > 0,
          )
        }
      }
    }
    "__resume" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "__resume")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="__resume", detail="bad call"),
        )
      }
      raise EvalError::Resume(pos_args[0])
    }
    "sleep" => {
      require_unstable_async(rt, "sleep")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "sleep")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="sleep", detail="bad call"),
        )
      }
      if not(rt.caps().can_read_clock()) {
        raise EvalError::PermissionDenied("clock_read")
      }
      match pos_args[0] {
        @core.Value::Int(ms) => {
          @io.sleep_ms(ms)
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="sleep", detail="bad call"),
          )
      }
    }
    "Path::resolve" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Path::resolve")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Path::resolve", detail="bad call"),
        )
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
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Path::resolve", detail="bad call"),
          )
      }
    }
    "Threads::probe_wat" => {
      require_unstable_threads(rt, "Threads::probe_wat")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::probe_wat")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::probe_wat", detail="bad call"),
        )
      }
      {
        value: @core.Value::String(@x_threads.probe_wat()),
        effects: out.effects,
      }
    }
    "Threads::runtime_hints" => {
      require_unstable_threads(rt, "Threads::runtime_hints")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "Threads::runtime_hints",
      )
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::runtime_hints", detail="bad call"),
        )
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
    "Threads::channel_new" => {
      require_unstable_threads(rt, "Threads::channel_new")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::channel_new")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::channel_new", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(capacity) =>
          {
            value: @core.Value::Int(
              rt.threads_channel_new(capacity.to_int()).to_int64(),
            ),
            effects: out.effects,
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Threads::channel_new", detail="bad call"),
          )
      }
    }
    "Threads::send" => {
      require_unstable_threads(rt, "Threads::send")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::send")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::send", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(channel_id), @core.Value::String(message)) =>
          match rt.threads_send(channel_id.to_int(), message) {
            Some(ok) => { value: @core.Value::Bool(ok), effects: out.effects }
            None =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Threads::send", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Threads::send", detail="bad call"),
          )
      }
    }
    "Threads::recv" => {
      require_unstable_threads(rt, "Threads::recv")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::recv")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::recv", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(channel_id) =>
          match rt.threads_recv(channel_id.to_int()) {
            Some(message) =>
              { value: @core.Value::String(message), effects: out.effects }
            None =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Threads::recv", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Threads::recv", detail="bad call"),
          )
      }
    }
    "Threads::spawn" => {
      require_unstable_threads(rt, "Threads::spawn")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::spawn")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::spawn", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(name), @core.Value::Int(mailbox)) =>
          match rt.threads_spawn(name, mailbox.to_int()) {
            Some(task_id) =>
              {
                value: @core.Value::Int(task_id.to_int64()),
                effects: out.effects,
              }
            None =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Threads::spawn", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Threads::spawn", detail="bad call"),
          )
      }
    }
    "Threads::wait" => {
      require_unstable_threads(rt, "Threads::wait")
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Threads::wait")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Threads::wait", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(task_id) =>
          match rt.threads_wait(task_id.to_int()) {
            Some(status) =>
              {
                value: @core.Value::Int(status.to_int64()),
                effects: out.effects,
              }
            None =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Threads::wait", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Threads::wait", detail="bad call"),
          )
      }
    }
    "sh" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "sh")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(BuiltinDetail(fn_name="sh", detail="bad call"))
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
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="sh", detail="bad call"),
          )
      }
    }
    "sh_lines" => {
      let out = eval_args(rt, args)
      // Extract positional arg (cmd string) and optional labeled args (Bool flags)
      let mut cmd_value : @core.Value? = None
      let short_flags : Array[String] = []
      let long_flags : Array[String] = []
      for arg in out.args {
        match arg.label {
          None =>
            if cmd_value is None {
              cmd_value = Some(arg.value)
            } else {
              raise EvalError::BadCall(
                E(
                  "sh_lines: expected 1 positional argument (command string), got multiple",
                ),
              )
            }
          Some(label) =>
            match arg.value {
              @core.Value::Bool(true) =>
                if label.to_array().length() == 1 {
                  short_flags.push(label)
                } else {
                  long_flags.push(label)
                }
              @core.Value::Bool(false) => () // false flags are omitted
              _ =>
                raise EvalError::BadCall(
                  E(
                    "sh_lines: flag '" +
                    label +
                    "' must be Bool, got " +
                    arg.value.to_string(),
                  ),
                )
            }
        }
      }
      match cmd_value {
        Some(@core.Value::String(cmd)) => {
          if not(rt.caps().can_spawn("sh")) {
            raise EvalError::PermissionDenied("process_spawn")
          }
          // Reconstruct full command with flags
          let full_cmd = if short_flags.length() == 0 &&
            long_flags.length() == 0 {
            cmd
          } else {
            let parts : Array[String] = [cmd]
            if short_flags.length() > 0 {
              short_flags.sort_by(fn(a, b) { a.compare(b) })
              parts.push("-" + short_flags.join(""))
            }
            long_flags.sort_by(fn(a, b) { a.compare(b) })
            for flag in long_flags {
              parts.push("--" + flag)
            }
            parts.join(" ")
          }
          let effects = out.effects
          effects.push(Effect::ShellExec(full_cmd))
          let lines = execute_shell_lines(full_cmd) catch { e => raise e }
          let values : Array[@core.Value] = []
          for line in lines {
            values.push(@core.Value::String(line))
          }
          { value: @core.Value::Array(values), effects }
        }
        _ =>
          raise EvalError::BadCall(
            E(
              "sh_lines: expected String argument, got " + cmd_value.to_string(),
            ),
          )
      }
    }
    "Stdout::write_char" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Stdout::write_char")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Stdout::write_char", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(code) => {
          let effects = out.effects
          effects.push(Effect::StdoutWriteChar(code.to_int()))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Stdout::write_char", detail="bad call"),
          )
      }
    }
    "Stdin::read_char" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Stdin::read_char")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Stdin::read_char", detail="bad call"),
        )
      }
      let code = -1
      let effects = out.effects
      effects.push(Effect::StdinReadChar(code))
      { value: @core.Value::Int(code.to_int64()), effects }
    }
    "Stdout::write_stream" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Stdout::write_stream")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Stdout::write_stream", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(text) => {
          let effects = out.effects
          effects.push(Effect::StdoutWriteStream(text))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Stdout::write_stream", detail="bad call"),
          )
      }
    }
    "Stdin::read_stream" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Stdin::read_stream")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Stdin::read_stream", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(len) => {
          if len < 0L {
            raise EvalError::BadCall(
              BuiltinDetail(fn_name="Stdin::read_stream", detail="bad call"),
            )
          }
          let chunk = ""
          let effects = out.effects
          effects.push(Effect::StdinReadStream(len.to_int(), chunk))
          { value: @core.Value::String(chunk), effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Stdin::read_stream", detail="bad call"),
          )
      }
    }
    "Fs::read_file" | "Fs::read_string" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::read_file")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::read_file", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          match @io.read_string(resolved) {
            Ok(content) => {
              let effects = out.effects
              effects.push(Effect::FsReadFile(resolved, content))
              { value: @core.Value::String(content), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::read_file", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::read_file", detail="bad call"),
          )
      }
    }
    "Fs::write_file" | "Fs::write_string" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::write_file")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::write_file", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(path), @core.Value::String(content)) => {
          let resolved = rt.resolve_path(path)
          match @io.write_string(resolved, content) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::FsWriteFile(resolved, content))
              { value: @core.Value::Unit, effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::write_file", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::write_file", detail="bad call"),
          )
      }
    }
    "Fs::exists" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::exists")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::exists", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          let exists = @io.path_exists(resolved)
          let effects = out.effects
          effects.push(Effect::FsExists(resolved, exists))
          { value: @core.Value::Bool(exists), effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::exists", detail="bad call"),
          )
      }
    }
    "Fs::stat_token" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::stat_token")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::stat_token", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          match @io.read_string(resolved) {
            Ok(content) => {
              let effects = out.effects
              effects.push(Effect::FsReadFile(resolved, content))
              {
                value: @core.Value::Int(
                  fs_stat_token_from_text(content).to_int64(),
                ),
                effects,
              }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::stat_token", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::stat_token", detail="bad call"),
          )
      }
    }
    "Fs::readdir" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::readdir")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::readdir", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_read(resolved)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved)
          }
          match @io.read_dir(resolved) {
            Ok(entries) => {
              let values : Array[@core.Value] = []
              for entry in entries {
                values.push(@core.Value::String(entry))
              }
              let effects = out.effects
              effects.push(Effect::FsReadDir(resolved, entries.length()))
              { value: @core.Value::Array(values), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::readdir", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::readdir", detail="bad call"),
          )
      }
    }
    "Fs::is_dir" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::is_dir")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::is_dir", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_read(resolved)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved)
          }
          let result = @io.is_directory(resolved)
          let effects = out.effects
          effects.push(Effect::FsIsDir(resolved, result))
          { value: @core.Value::Bool(result), effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::is_dir", detail="bad call"),
          )
      }
    }
    "Fs::mkdir" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::mkdir")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::mkdir", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_write(resolved)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved)
          }
          match @io.create_dir(resolved) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::FsMkdir(resolved))
              { value: @core.Value::Unit, effects }
            }
            Err(err) => raise EvalError::BadCall(Io(op="Fs::mkdir", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::mkdir", detail="bad call"),
          )
      }
    }
    "Fs::mkdir_p" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::mkdir_p")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::mkdir_p", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_write(resolved)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved)
          }
          mkdir_recursive(resolved)
          let effects = out.effects
          effects.push(Effect::FsMkdir(resolved))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::mkdir_p", detail="bad call"),
          )
      }
    }
    "Fs::getcwd" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::getcwd")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::getcwd", detail="bad call"),
        )
      }
      let effects = out.effects
      effects.push(Effect::FsGetCwd(rt.cwd))
      { value: @core.Value::String(rt.cwd), effects }
    }
    "Fs::chdir" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::chdir")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::chdir", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_read(resolved)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved)
          }
          rt.cwd = resolved
          let effects = out.effects
          effects.push(Effect::FsChdir(resolved))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::chdir", detail="bad call"),
          )
      }
    }
    "Fs::remove" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::remove")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::remove", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_write(resolved)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved)
          }
          if @io.is_file(resolved) {
            match @io.remove_file(resolved) {
              Ok(_) => ()
              Err(err) =>
                raise EvalError::BadCall(Io(op="Fs::remove", detail=err))
            }
          } else if @io.is_directory(resolved) {
            match @io.remove_dir(resolved) {
              Ok(_) => ()
              Err(err) =>
                raise EvalError::BadCall(Io(op="Fs::remove", detail=err))
            }
          } else {
            raise EvalError::BadCall(
              Io(op="Fs::remove", detail="not found: " + resolved),
            )
          }
          let effects = out.effects
          effects.push(Effect::FsRemove(resolved))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::remove", detail="bad call"),
          )
      }
    }
    "Fs::is_file" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::is_file")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::is_file", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_read(resolved)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved)
          }
          let result = @io.is_file(resolved)
          let effects = out.effects
          effects.push(Effect::FsIsFile(resolved, result))
          { value: @core.Value::Bool(result), effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::is_file", detail="bad call"),
          )
      }
    }
    "Fs::copy" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::copy")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::copy", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(src), @core.Value::String(dst)) => {
          let resolved_src = rt.resolve_path(src)
          let resolved_dst = rt.resolve_path(dst)
          if not(rt.caps().can_read(resolved_src)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved_src)
          }
          if not(rt.caps().can_write(resolved_dst)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved_dst)
          }
          match @io.read_string(resolved_src) {
            Ok(content) =>
              match @io.write_string(resolved_dst, content) {
                Ok(_) => ()
                Err(err) =>
                  raise EvalError::BadCall(Io(op="Fs::copy", detail=err))
              }
            Err(err) => raise EvalError::BadCall(Io(op="Fs::copy", detail=err))
          }
          let effects = out.effects
          effects.push(Effect::FsCopy(resolved_src, resolved_dst))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::copy", detail="bad call"),
          )
      }
    }
    "Fs::rename" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::rename")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::rename", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(old_path), @core.Value::String(new_path)) => {
          let resolved_old = rt.resolve_path(old_path)
          let resolved_new = rt.resolve_path(new_path)
          if not(rt.caps().can_read(resolved_old)) {
            raise EvalError::PermissionDenied("fs_read:" + resolved_old)
          }
          if not(rt.caps().can_write(resolved_old)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved_old)
          }
          if not(rt.caps().can_write(resolved_new)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved_new)
          }
          match @io.read_string(resolved_old) {
            Ok(content) => {
              match @io.write_string(resolved_new, content) {
                Ok(_) => ()
                Err(err) =>
                  raise EvalError::BadCall(Io(op="Fs::rename", detail=err))
              }
              match @io.remove_file(resolved_old) {
                Ok(_) => ()
                Err(err) =>
                  raise EvalError::BadCall(Io(op="Fs::rename", detail=err))
              }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::rename", detail=err))
          }
          let effects = out.effects
          effects.push(Effect::FsRename(resolved_old, resolved_new))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::rename", detail="bad call"),
          )
      }
    }
    "Fs::append" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::append")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::append", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(path), @core.Value::String(content)) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_write(resolved)) {
            raise EvalError::PermissionDenied("fs_write:" + resolved)
          }
          let existing = if @io.path_exists(resolved) {
            match @io.read_string(resolved) {
              Ok(s) => s
              Err(err) =>
                raise EvalError::BadCall(Io(op="Fs::append", detail=err))
            }
          } else {
            ""
          }
          let new_content = existing + content
          match @io.write_string(resolved, new_content) {
            Ok(_) => ()
            Err(err) =>
              raise EvalError::BadCall(Io(op="Fs::append", detail=err))
          }
          let effects = out.effects
          effects.push(Effect::FsAppend(resolved, content))
          { value: @core.Value::Unit, effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Fs::append", detail="bad call"),
          )
      }
    }
    "Env::get" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Env::get")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Env::get", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(name) => {
          let value = match @io.get_env_var(name) {
            Some(v) => v
            None => ""
          }
          let effects = out.effects
          effects.push(Effect::EnvGet(name, value))
          { value: @core.Value::String(value), effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Env::get", detail="bad call"),
          )
      }
    }
    "Socket::tcp_connect" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Socket::tcp_connect")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Socket::tcp_connect", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(host), @core.Value::Int(port)) => {
          if not(rt.caps().can_connect(host, port.to_int())) {
            raise EvalError::PermissionDenied(
              "net_connect:" + host + ":" + port.to_string(),
            )
          }
          match @backend.tcp_connect(host, port.to_int()) {
            Ok(fd) => {
              let effects = out.effects
              let fd64 = fd.to_int64()
              effects.push(Effect::SocketTcpConnect(host, port, fd64))
              { value: @core.Value::Int(fd64), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Socket::tcp_connect", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Socket::tcp_connect", detail="bad call"),
          )
      }
    }
    "Socket::tcp_read" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Socket::tcp_read")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Socket::tcp_read", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(fd), @core.Value::Int(max_bytes)) =>
          match @backend.tcp_read(fd.to_int(), max_bytes.to_int()) {
            Ok(data) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpRead(fd, max_bytes, data))
              { value: @core.Value::String(data), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Socket::tcp_read", detail=err))
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Socket::tcp_read", detail="bad call"),
          )
      }
    }
    "Socket::tcp_write" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Socket::tcp_write")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Socket::tcp_write", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(fd), @core.Value::String(data)) =>
          match @backend.tcp_write(fd.to_int(), data) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpWrite(fd, data))
              { value: @core.Value::Unit, effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Socket::tcp_write", detail=err))
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Socket::tcp_write", detail="bad call"),
          )
      }
    }
    "Socket::tcp_close" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Socket::tcp_close")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Socket::tcp_close", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(fd) =>
          match @backend.tcp_close(fd.to_int()) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::SocketTcpClose(fd))
              { value: @core.Value::Unit, effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Socket::tcp_close", detail=err))
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Socket::tcp_close", detail="bad call"),
          )
      }
    }
    // --- HTTP Client builtins ---
    "Http::request" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::request")
      if pos_args.length() != 4 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::request", detail="bad call"),
        )
      }
      let meth = match pos_args[0] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request", detail="bad call"),
          )
      }
      let url = match pos_args[1] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request", detail="bad call"),
          )
      }
      let headers = match pos_args[2] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request", detail="bad call"),
          )
      }
      let body = match pos_args[3] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request", detail="bad call"),
          )
      }
      let (connect_host, connect_port) = match parse_http_connect_target(url) {
        Some(v) => v
        None =>
          raise EvalError::BadCall(
            Io(
              op="Http::request",
              detail="invalid URL for network capability check: " + url,
            ),
          )
      }
      if not(rt.caps().can_connect(connect_host, connect_port)) {
        raise EvalError::PermissionDenied(
          "net_connect:" + connect_host + ":" + connect_port.to_string(),
        )
      }
      match @backend.http_request(meth, url, headers, body) {
        Ok(handle) => {
          let effects = out.effects
          let h64 = handle.to_int64()
          effects.push(Effect::HttpRequest(meth, url, headers, body, h64))
          { value: @core.Value::Int(h64), effects }
        }
        Err(err) => raise EvalError::BadCall(Io(op="Http::request", detail=err))
      }
    }
    "Http::response_status" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "Http::response_status",
      )
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::response_status", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_connect_any()) {
            raise EvalError::PermissionDenied("net_response_status")
          }
          match @backend.http_response_status(handle.to_int()) {
            Ok(status) => {
              let effects = out.effects
              effects.push(Effect::HttpResponseStatus(handle, status))
              { value: @core.Value::Int(status.to_int64()), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(
                Io(op="Http::response_status", detail=err),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::response_status", detail="bad call"),
          )
      }
    }
    "Http::response_header" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "Http::response_header",
      )
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::response_header", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(handle), @core.Value::String(hdr_name)) => {
          if not(rt.caps().can_connect_any()) {
            raise EvalError::PermissionDenied("net_response_header")
          }
          match @backend.http_response_header(handle.to_int(), hdr_name) {
            Ok(hdr_val) => {
              let effects = out.effects
              effects.push(
                Effect::HttpResponseHeader(handle, hdr_name, hdr_val),
              )
              { value: @core.Value::String(hdr_val), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(
                Io(op="Http::response_header", detail=err),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::response_header", detail="bad call"),
          )
      }
    }
    "Http::response_body" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::response_body")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::response_body", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_connect_any()) {
            raise EvalError::PermissionDenied("net_response_body")
          }
          match @backend.http_response_body(handle.to_int()) {
            Ok(body) => {
              let effects = out.effects
              effects.push(Effect::HttpResponseBody(handle, body))
              { value: @core.Value::String(body), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::response_body", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::response_body", detail="bad call"),
          )
      }
    }
    "Http::close" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::close")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::close", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_connect_any()) {
            raise EvalError::PermissionDenied("net_close")
          }
          match @backend.http_close(handle.to_int()) {
            Ok(_) => {
              let effects = out.effects
              effects.push(Effect::HttpClose(handle))
              { value: @core.Value::Unit, effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::close", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::close", detail="bad call"),
          )
      }
    }
    // --- HTTP Server builtins ---
    "Http::listen" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::listen")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::listen", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(port) => {
          if not(rt.caps().can_listen(port.to_int())) {
            raise EvalError::PermissionDenied("net_listen:" + port.to_string())
          }
          match @backend.http_listen(port.to_int()) {
            Ok(handle) => {
              let effects = out.effects
              let h64 = handle.to_int64()
              effects.push(Effect::HttpListen(port.to_int(), h64))
              { value: @core.Value::Int(h64), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::listen", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::listen", detail="bad call"),
          )
      }
    }
    "Http::accept" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::accept")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::accept", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(server_handle) => {
          if not(rt.caps().can_listen_any()) {
            raise EvalError::PermissionDenied("net_accept")
          }
          match @backend.http_accept(server_handle.to_int()) {
            Ok(req_handle) => {
              let effects = out.effects
              let rh64 = req_handle.to_int64()
              effects.push(Effect::HttpAccept(server_handle, rh64))
              { value: @core.Value::Int(rh64), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::accept", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::accept", detail="bad call"),
          )
      }
    }
    "Http::request_method" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::request_method")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::request_method", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_listen_any()) {
            raise EvalError::PermissionDenied("net_request_method")
          }
          match @backend.http_request_method(handle.to_int()) {
            Ok(meth) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestMethod(handle, meth))
              { value: @core.Value::String(meth), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(
                Io(op="Http::request_method", detail=err),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request_method", detail="bad call"),
          )
      }
    }
    "Http::request_url" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::request_url")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::request_url", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_listen_any()) {
            raise EvalError::PermissionDenied("net_request_url")
          }
          match @backend.http_request_url(handle.to_int()) {
            Ok(url) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestUrl(handle, url))
              { value: @core.Value::String(url), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::request_url", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request_url", detail="bad call"),
          )
      }
    }
    "Http::request_header" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::request_header")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::request_header", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Int(handle), @core.Value::String(hdr_name)) => {
          if not(rt.caps().can_listen_any()) {
            raise EvalError::PermissionDenied("net_request_header")
          }
          match @backend.http_request_header(handle.to_int(), hdr_name) {
            Ok(hdr_val) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestHeader(handle, hdr_name, hdr_val))
              { value: @core.Value::String(hdr_val), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(
                Io(op="Http::request_header", detail=err),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request_header", detail="bad call"),
          )
      }
    }
    "Http::request_body" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::request_body")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::request_body", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Int(handle) => {
          if not(rt.caps().can_listen_any()) {
            raise EvalError::PermissionDenied("net_request_body")
          }
          match @backend.http_request_body(handle.to_int()) {
            Ok(body) => {
              let effects = out.effects
              effects.push(Effect::HttpRequestBody(handle, body))
              { value: @core.Value::String(body), effects }
            }
            Err(err) =>
              raise EvalError::BadCall(Io(op="Http::request_body", detail=err))
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::request_body", detail="bad call"),
          )
      }
    }
    "Http::respond" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Http::respond")
      if pos_args.length() != 4 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Http::respond", detail="bad call"),
        )
      }
      let handle = match pos_args[0] {
        @core.Value::Int(v) => v
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::respond", detail="bad call"),
          )
      }
      let status = match pos_args[1] {
        @core.Value::Int(v) => v
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::respond", detail="bad call"),
          )
      }
      let headers = match pos_args[2] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::respond", detail="bad call"),
          )
      }
      let body = match pos_args[3] {
        @core.Value::String(s) => s
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Http::respond", detail="bad call"),
          )
      }
      if not(rt.caps().can_listen_any()) {
        raise EvalError::PermissionDenied("net_respond")
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
        Err(err) => raise EvalError::BadCall(Io(op="Http::respond", detail=err))
      }
    }
    "Llm::complete" | "Rlm::run" | "Rlm::finalize" =>
      raise EvalError::BadCall(
        E("Llm/Rlm builtins removed (use compiled backend)"),
      )
    "addr" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "addr")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="addr", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::String(addr) =>
          match rt.get_by_addr(addr) {
            Some(v) => { value: v, effects: out.effects }
            None =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="addr", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="addr", detail="bad call"),
          )
      }
    }
    "StringBuilder::new" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "StringBuilder::new")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="StringBuilder::new", detail="bad call"),
        )
      }
      { value: @core.Value::StringBuilder([]), effects: out.effects }
    }
    "StringBuilder::push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "StringBuilder::push")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="StringBuilder::push", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::StringBuilder(chunks) =>
          match pos_args[1] {
            @core.Value::String(s) => {
              chunks.push(s)
              { value: @core.Value::Unit, effects: out.effects }
            }
            _ =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="StringBuilder::push", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="StringBuilder::push", detail="bad call"),
          )
      }
    }
    "StringBuilder::freeze" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(
        out.args,
        "StringBuilder::freeze",
      )
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="StringBuilder::freeze", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::StringBuilder(chunks) => {
          let mut result = ""
          for chunk in chunks {
            result = result + chunk
          }
          { value: @core.Value::String(result), effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="StringBuilder::freeze", detail="bad call"),
          )
      }
    }
    "Bytes::new" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::new")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::new", detail="bad call"),
        )
      }
      { value: @core.Value::Bytes([]), effects: out.effects }
    }
    "Bytes::push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::push")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::push", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::Bytes(data) =>
          match pos_args[1] {
            @core.Value::Int(n) => {
              data.push(n.to_int().to_byte())
              { value: @core.Value::Unit, effects: out.effects }
            }
            _ =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Bytes::push", detail="bad call"),
              )
          }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Bytes::push", detail="bad call"),
          )
      }
    }
    "Bytes::set" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::set")
      if pos_args.length() != 3 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::set", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1], pos_args[2]) {
        (
          @core.Value::Bytes(data),
          @core.Value::Int(index),
          @core.Value::Int(val),
        ) => {
          let i = index.to_int()
          if i < 0 || i >= data.length() {
            raise EvalError::BadCall(
              BuiltinDetail(fn_name="Bytes::set", detail="index out of bounds"),
            )
          }
          data[i] = val.to_int().to_byte()
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Bytes::set", detail="bad call"),
          )
      }
    }
    "Bytes::append" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::append")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::append", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Bytes(dst), @core.Value::Bytes(src)) => {
          for i in 0..<src.length() {
            dst.push(src[i])
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Bytes::append", detail="bad call"),
          )
      }
    }
    "Bytes::blit" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::blit")
      if pos_args.length() != 4 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::blit", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1], pos_args[2], pos_args[3]) {
        (
          @core.Value::Bytes(dst),
          @core.Value::Bytes(src),
          @core.Value::Int(start),
          @core.Value::Int(end_),
        ) => {
          let s = start.to_int()
          let e = end_.to_int()
          for i in s..<e {
            if i >= 0 && i < src.length() {
              dst.push(src[i])
            }
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Bytes::blit", detail="bad call"),
          )
      }
    }
    "Bytes::fill" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Bytes::fill")
      if pos_args.length() != 3 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Bytes::fill", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1], pos_args[2]) {
        (@core.Value::Bytes(dst), @core.Value::Int(val), @core.Value::Int(count)
        ) => {
          let byte = val.to_int().to_byte()
          let n = count.to_int()
          for _ in 0..<n {
            dst.push(byte)
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="Bytes::fill", detail="bad call"),
          )
      }
    }
    "ArrayBuilder::new" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "ArrayBuilder::new")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="ArrayBuilder::new", detail="bad call"),
        )
      }
      { value: @core.Value::ArrayBuilder([]), effects: out.effects }
    }
    "ArrayBuilder::push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "ArrayBuilder::push")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="ArrayBuilder::push", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::ArrayBuilder(items) => {
          items.push(pos_args[1])
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="ArrayBuilder::push", detail="bad call"),
          )
      }
    }
    "ArrayBuilder::freeze" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "ArrayBuilder::freeze")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="ArrayBuilder::freeze", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::ArrayBuilder(items) => {
          let snapshot = clone_value_array(items)
          { value: @core.Value::Array(snapshot), effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="ArrayBuilder::freeze", detail="bad call"),
          )
      }
    }
    "MapBuilder::new" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "MapBuilder::new")
      if pos_args.length() != 0 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="MapBuilder::new", detail="bad call"),
        )
      }
      { value: @core.Value::MapBuilder({}), effects: out.effects }
    }
    "MapBuilder::set" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "MapBuilder::set")
      if pos_args.length() != 3 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="MapBuilder::set", detail="bad call"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::MapBuilder(items), @core.Value::String(key)) => {
          items[key] = pos_args[2]
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="MapBuilder::set", detail="bad call"),
          )
      }
    }
    "MapBuilder::freeze" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "MapBuilder::freeze")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="MapBuilder::freeze", detail="bad call"),
        )
      }
      match pos_args[0] {
        @core.Value::MapBuilder(items) => {
          let snapshot = clone_value_map(items)
          { value: @core.Value::Map(snapshot), effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(fn_name="MapBuilder::freeze", detail="bad call"),
          )
      }
    }
    "Array::push" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Array::push")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Array::push", detail="expected 2 arguments"),
        )
      }
      match pos_args[0] {
        @core.Value::Array(arr) => {
          arr.push(pos_args[1])
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Array::push",
              detail="expected Array, got " + value_type_name(pos_args[0]),
            ),
          )
      }
    }
    "Array::push_all" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Array::push_all")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(
            fn_name="Array::push_all",
            detail="expected 2 arguments",
          ),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Array(dst), @core.Value::Array(src)) => {
          for item in src {
            dst.push(item)
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Array::push_all",
              detail="expected (Array, Array), got (" +
                value_type_name(pos_args[0]) +
                ", " +
                value_type_name(pos_args[1]) +
                ")",
            ),
          )
      }
    }
    "Array::set" | "FixedArray::set" | "FixedArray::unsafe_set" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Array::set")
      if pos_args.length() != 3 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Array::set", detail="expected 3 arguments"),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Array(arr), @core.Value::Int(idx)) => {
          let i = idx.to_int()
          if i < 0 || i >= arr.length() {
            raise EvalError::BadCall(
              BuiltinDetail(
                fn_name="Array::set",
                detail="index " +
                  i.to_string() +
                  " out of bounds (length " +
                  arr.length().to_string() +
                  ")",
              ),
            )
          }
          arr[i] = pos_args[2]
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Array::set",
              detail="expected (Array, Int, value)",
            ),
          )
      }
    }
    "FixedArray::blit" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "FixedArray::blit")
      if pos_args.length() != 5 {
        raise EvalError::BadCall(
          BuiltinDetail(
            fn_name="FixedArray::blit",
            detail="expected 5 arguments",
          ),
        )
      }
      match (pos_args[0], pos_args[1], pos_args[2], pos_args[3], pos_args[4]) {
        (
          @core.Value::Array(dst),
          @core.Value::Int(dst_off),
          @core.Value::Array(src),
          @core.Value::Int(src_off),
          @core.Value::Int(len),
        ) => {
          let d0 = dst_off.to_int()
          let s0 = src_off.to_int()
          let n = len.to_int()
          if d0 < 0 ||
            s0 < 0 ||
            n < 0 ||
            d0 + n > dst.length() ||
            s0 + n > src.length() {
            raise EvalError::BadCall(
              BuiltinDetail(fn_name="FixedArray::blit", detail="out of bounds"),
            )
          }
          for i in 0..<n {
            dst[d0 + i] = src[s0 + i]
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="FixedArray::blit",
              detail="expected (Array, Int, Array, Int, Int)",
            ),
          )
      }
    }
    "Array::truncate" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Array::truncate")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(
            fn_name="Array::truncate",
            detail="expected 2 arguments",
          ),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::Array(arr), @core.Value::Int(new_len)) => {
          let target = new_len.to_int()
          while arr.length() > target {
            let _ = arr.pop()
          }
          { value: @core.Value::Unit, effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Array::truncate",
              detail="expected (Array, Int)",
            ),
          )
      }
    }
    "Array::slice" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Array::slice")
      if pos_args.length() != 3 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Array::slice", detail="expected 3 arguments"),
        )
      }
      match (pos_args[0], pos_args[1], pos_args[2]) {
        (
          @core.Value::Array(arr),
          @core.Value::Int(start),
          @core.Value::Int(end_),
        ) => {
          let s = start.to_int()
          let e = end_.to_int()
          let result : Array[@core.Value] = []
          for i in s..<e {
            if i >= 0 && i < arr.length() {
              result.push(arr[i])
            }
          }
          { value: @core.Value::Array(result), effects: out.effects }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Array::slice",
              detail="expected (Array, Int, Int)",
            ),
          )
      }
    }
    "Fs::read_bytes" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::read_bytes")
      if pos_args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinDetail(fn_name="Fs::read_bytes", detail="expected 1 argument"),
        )
      }
      match pos_args[0] {
        @core.Value::String(path) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_read(resolved)) {
            raise EvalError::BadCall(
              BuiltinDetail(
                fn_name="Fs::read_bytes",
                detail="no read capability for " + resolved,
              ),
            )
          }
          match @io.read_bytes(resolved) {
            Ok(bytes) => {
              let arr : Array[Byte] = []
              for i in 0..<bytes.length() {
                arr.push(bytes[i])
              }
              { value: @core.Value::Bytes(arr), effects: out.effects }
            }
            Err(e) =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Fs::read_bytes", detail=e),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Fs::read_bytes",
              detail="expected String, got " + value_type_name(pos_args[0]),
            ),
          )
      }
    }
    "Fs::write_bytes" => {
      let out = eval_args(rt, args)
      let pos_args = extract_positional_values(out.args, "Fs::write_bytes")
      if pos_args.length() != 2 {
        raise EvalError::BadCall(
          BuiltinDetail(
            fn_name="Fs::write_bytes",
            detail="expected 2 arguments (path, bytes)",
          ),
        )
      }
      match (pos_args[0], pos_args[1]) {
        (@core.Value::String(path), @core.Value::Bytes(byte_arr)) => {
          let resolved = rt.resolve_path(path)
          if not(rt.caps().can_write(resolved)) {
            raise EvalError::BadCall(
              BuiltinDetail(
                fn_name="Fs::write_bytes",
                detail="no write capability for " + resolved,
              ),
            )
          }
          let bytes = Bytes::from_array(byte_arr[:])
          match @io.write_bytes(resolved, bytes) {
            Ok(_) => { value: @core.Value::Unit, effects: out.effects }
            Err(e) =>
              raise EvalError::BadCall(
                BuiltinDetail(fn_name="Fs::write_bytes", detail=e),
              )
          }
        }
        _ =>
          raise EvalError::BadCall(
            BuiltinDetail(
              fn_name="Fs::write_bytes",
              detail="expected (String, Bytes)",
            ),
          )
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
              None => raise EvalError::BadCall(NoField(field=name, on="Record"))
            }
          _ =>
            // Not a record — treat as unknown function so UFCS fallback can try
            raise EvalError::BadCall(UnknownFn(name~))
        }
      } else {
        raise EvalError::BadCall(UnknownFn(name~))
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
    let out : EvalOutput = eval_expr(rt, arg.expr) catch {
      e => rethrow_with_prior_effects(e, effects.length() > 0)
    }
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
      Some(_) =>
        raise EvalError::BadCall(
          BuiltinDetail(fn_name=name, detail="unexpected labeled argument"),
        )
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
  let body_out : EvalOutput = eval_block(scope, fn_val.body) catch {
    e => rethrow_with_prior_effects(e, out.effects.length() > 0)
  }
  // Propagate cwd changes back to caller (cd semantics)
  rt.cwd = scope.cwd
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
  let mut variadic_param : @core.FuncParam? = None
  for param in params {
    if not(@core.ParamLabel::is_positional(param.label)) {
      continue
    }
    match param.label {
      @core.ParamLabel::Variadic =>
        match variadic_param {
          Some(_) => raise EvalError::BadCall(DupVariadic)
          None => variadic_param = Some(param)
        }
      _ =>
        if variadic_param is Some(_) {
          raise EvalError::BadCall(
            E("positional param after variadic is unsupported"),
          )
        } else {
          positional.push(param)
        }
    }
  }
  let mut pos_index = 0
  let variadic_values : Array[@core.Value] = []
  let bound : Map[String, @core.Value] = {}
  let used_labels : Map[String, Bool] = {}
  for arg in args {
    match arg.label {
      None =>
        if pos_index < positional.length() {
          let param = positional[pos_index]
          pos_index += 1
          bound[param.name] = arg.value
        } else {
          match variadic_param {
            Some(_) => variadic_values.push(arg.value)
            None =>
              raise EvalError::BadCall(
                E(
                  "too many positional arguments: expected " +
                  positional.length().to_string() +
                  ", got more",
                ),
              )
          }
        }
      Some(label) => {
        if used_labels.contains(label) {
          raise EvalError::BadCall(DupLabel(label~))
        }
        let mut found : @core.FuncParam? = None
        for param in params {
          if not(@core.ParamLabel::is_positional(param.label)) &&
            param.name == label {
            found = Some(param)
            break
          }
        }
        match found {
          Some(param) => {
            used_labels[label] = true
            bound[param.name] = arg.value
          }
          None => raise EvalError::BadCall(UnknownLabel(label~))
        }
      }
    }
  }
  if pos_index != positional.length() {
    raise EvalError::BadCall(
      E(
        "missing positional arguments: expected " +
        positional.length().to_string() +
        ", got " +
        pos_index.to_string(),
      ),
    )
  }
  match variadic_param {
    Some(param) => bound[param.name] = @core.Value::Array(variadic_values)
    None => ()
  }
  for param in params {
    if param.label == @core.ParamLabel::Required &&
      not(bound.contains(param.name)) {
      raise EvalError::BadCall(MissingLabel(label=param.name))
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
fn value_type_name(value : @core.Value) -> String {
  match value {
    @core.Value::Int(_) => "Int"
    @core.Value::Float(_) => "Float"
    @core.Value::Double(_) => "Double"
    @core.Value::Bool(_) => "Bool"
    @core.Value::Char(_) => "Char"
    @core.Value::String(_) => "String"
    @core.Value::Path(_) => "Path"
    @core.Value::Unit => "Unit"
    @core.Value::Tuple(_) => "Tuple"
    @core.Value::Record(_) => "Record"
    @core.Value::Array(_) => "Array"
    @core.Value::Map(_) => "Map"
    @core.Value::Set(_) => "Set"
    @core.Value::Fn(_) => "Fn"
    @core.Value::ArrayBuilder(_) => "ArrayBuilder"
    @core.Value::MapBuilder(_) => "MapBuilder"
    @core.Value::StringBuilder(_) => "StringBuilder"
    @core.Value::Bytes(_) => "Bytes"
    @core.Value::PromptText(_) => "PromptText"
  }
}
