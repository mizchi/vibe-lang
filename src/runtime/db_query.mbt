///|
pub fn VibeDb::new() -> VibeDb {
  let db = @ripple.Database::new()
  let rt = db.runtime()
  let sources : @ripple.Input[String, String] = db.input()
  sources.register(rt)
  let binary_sources : @ripple.Input[String, Bytes] = db.input()
  binary_sources.register(rt)
  let diags : @ripple.Accumulator[@core.Diagnostic] = db.accumulator()
  let cst_query : @ripple.Query[String, @cst.SyntaxNode] = db.query(fn(
    rt,
    path,
  ) {
    match sources.get(rt, path) {
      Some(content) => @parser.parse_cst(content)
      None => @parser.parse_cst("")
    }
  })
  cst_query.register(rt)
  // AST query wrapped in HashedModule for structural equality comparison
  // This enables backdate when only whitespace changes (same structural hash)
  let ast_query : @ripple.Query[String, HashedModule] = db.query(fn(rt, path) {
    match sources.get(rt, path) {
      Some(content) => {
        let parsed = @parser.parse_ast(content) catch {
          e => {
            diags.push(rt, e.diagnostic())
            { stmts: [] }
          }
        }
        HashedModule::new(parsed)
      }
      None => HashedModule::new({ stmts: [] })
    }
  })
  ast_query.register(rt)
  let import_query : @ripple.Query[String, Array[ImportSpec]] = db.query(fn(
    rt,
    file_path,
  ) {
    let ast = ast_query.fetch(rt, file_path).unwrap()
    let base_dir = @path.Path(file_path).dirname().to_string()
    let out : Array[ImportSpec] = []
    let mut has_imports = false
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Import(source~, span~, ..)
        | @core.Stmt::ReExport(source~, span~, ..) => {
          has_imports = true
          match source {
            @core.ModuleRef::Path(path~) => {
              let path_obj = normalize_path_obj(base_dir, path)
              let alias_name = @core.import_alias_name(path)
              let candidates : Array[String] = []
              let push_candidate = fn(candidate : String) {
                if not(array_has_string(candidates, candidate)) {
                  candidates.push(candidate)
                }
              }
              push_candidate(path_obj.normalized)
              if not(path_obj.normalized.has_suffix(".vibe")) {
                push_candidate(path_obj.normalized + ".vibe")
              }
              if not(path_obj.normalized.has_suffix(".xm")) {
                push_candidate(path_obj.normalized + ".xm")
              }
              push_candidate(path)
              if not(path.has_suffix(".vibe")) {
                push_candidate(path + ".vibe")
              }
              if not(path.has_suffix(".xm")) {
                push_candidate(path + ".xm")
              }
              let mut final_path = path_obj.normalized
              let mut text_opt : String? = None
              let mut binary_opt : Bytes? = None
              for candidate in candidates {
                match sources.get(rt, candidate) {
                  Some(c) => {
                    final_path = candidate
                    text_opt = Some(c)
                    break
                  }
                  None =>
                    match binary_sources.get(rt, candidate) {
                      Some(b) => {
                        final_path = candidate
                        binary_opt = Some(b)
                        break
                      }
                      None => ()
                    }
                }
              }
              let resolved_path_obj = normalize_path_obj(base_dir, final_path)
              let lock_expected = if path_lock_required(rt, sources) {
                Some(
                  sources.get(rt, path_ref_key(resolved_path_obj.normalized)),
                )
              } else {
                None
              }
              match text_opt {
                Some(content) => {
                  let hash = @core.content_address_hash_string(content)
                  let mut resolved_hash : String? = Some(hash)
                  let mut module_ref : String? = Some(
                    @core.module_ref_from_hash(hash),
                  )
                  match lock_expected {
                    Some(lock_entry_opt) =>
                      match lock_entry_opt {
                        Some(expected_hash_text) => {
                          let expected_hash = normalize_hash(expected_hash_text)
                          if expected_hash != hash {
                            diags.push(rt, @core.Diagnostic::{
                              stage: "import",
                              message: "lock mismatch for path: " +
                              resolved_path_obj.normalized +
                              " (expected " +
                              expected_hash +
                              ", got " +
                              hash +
                              ")",
                              span: Some(span),
                              hint: Some(
                                "run `vibe fetch <entry>` to refresh index.lock",
                              ),
                              note: None,
                            })
                            resolved_hash = None
                            module_ref = None
                          }
                        }
                        None => {
                          diags.push(rt, @core.Diagnostic::{
                            stage: "import",
                            message: "missing lock entry for path: " +
                            resolved_path_obj.normalized,
                            span: Some(span),
                            hint: Some(
                              "run `vibe fetch <entry>` to create index.lock",
                            ),
                            note: None,
                          })
                          resolved_hash = None
                          module_ref = None
                        }
                      }
                    None => ()
                  }
                  out.push(ImportSpec::{
                    path: final_path,
                    alias_name,
                    hash: resolved_hash,
                    module_ref,
                    path_obj: Some(resolved_path_obj),
                    source_hash: None,
                    source_version: None,
                    source_symbol: None,
                  })
                }
                None =>
                  match binary_opt {
                    Some(binary_content) => {
                      let hash = @core.git_blob_hash_bytes(binary_content)
                      let mut resolved_hash : String? = Some(hash)
                      let mut module_ref : String? = Some(
                        @core.module_ref_from_hash(hash),
                      )
                      match lock_expected {
                        Some(lock_entry_opt) =>
                          match lock_entry_opt {
                            Some(expected_hash_text) => {
                              let expected_hash = normalize_hash(
                                expected_hash_text,
                              )
                              if expected_hash != hash {
                                diags.push(rt, @core.Diagnostic::{
                                  stage: "import",
                                  message: "lock mismatch for path: " +
                                  resolved_path_obj.normalized +
                                  " (expected " +
                                  expected_hash +
                                  ", got " +
                                  hash +
                                  ")",
                                  span: Some(span),
                                  hint: Some(
                                    "run `vibe fetch <entry>` to refresh index.lock",
                                  ),
                                  note: None,
                                })
                                resolved_hash = None
                                module_ref = None
                              }
                            }
                            None => {
                              diags.push(rt, @core.Diagnostic::{
                                stage: "import",
                                message: "missing lock entry for path: " +
                                resolved_path_obj.normalized,
                                span: Some(span),
                                hint: Some(
                                  "run `vibe fetch <entry>` to create index.lock",
                                ),
                                note: None,
                              })
                              resolved_hash = None
                              module_ref = None
                            }
                          }
                        None => ()
                      }
                      out.push(ImportSpec::{
                        path: final_path,
                        alias_name,
                        hash: resolved_hash,
                        module_ref,
                        path_obj: Some(resolved_path_obj),
                        source_hash: None,
                        source_version: None,
                        source_symbol: None,
                      })
                    }
                    None => {
                      diags.push(rt, @core.Diagnostic::{
                        stage: "import",
                        message: "missing: " + resolved_path_obj.normalized,
                        span: Some(span),
                        hint: None,
                        note: None,
                      })
                      out.push(ImportSpec::{
                        path: final_path,
                        alias_name,
                        hash: None,
                        module_ref: None,
                        path_obj: Some(resolved_path_obj),
                        source_hash: None,
                        source_version: None,
                        source_symbol: None,
                      })
                    }
                  }
              }
            }
            @core.ModuleRef::Hash(hash~) => {
              let alias_name = hash_alias_name(hash)
              let (snapshot_key, resolved_hash) = resolve_hash_import(
                rt, sources, binary_sources, diags, hash, span,
              )
              out.push(ImportSpec::{
                path: snapshot_key,
                alias_name,
                hash: resolved_hash,
                module_ref: match resolved_hash {
                  Some(h) => Some(@core.module_ref_from_hash(h))
                  None => None
                },
                path_obj: None,
                source_hash: Some(normalize_hash(hash)),
                source_version: None,
                source_symbol: None,
              })
            }
            @core.ModuleRef::Version(name~) => {
              let alias_name = version_alias_name(name)
              match sources.get(rt, version_ref_key(name)) {
                Some(hash_text) => {
                  let (snapshot_key, resolved_hash) = resolve_hash_import(
                    rt, sources, binary_sources, diags, hash_text, span,
                  )
                  out.push(ImportSpec::{
                    path: snapshot_key,
                    alias_name,
                    hash: resolved_hash,
                    module_ref: match resolved_hash {
                      Some(h) => Some(@core.module_ref_from_hash(h))
                      None => None
                    },
                    path_obj: None,
                    source_hash: None,
                    source_version: Some(name),
                    source_symbol: None,
                  })
                }
                None => {
                  diags.push(rt, @core.Diagnostic::{
                    stage: "import",
                    message: "missing version ref: " + name,
                    span: Some(span),
                    hint: None,
                    note: None,
                  })
                  out.push(ImportSpec::{
                    path: version_ref_key(name),
                    alias_name,
                    hash: None,
                    module_ref: None,
                    path_obj: None,
                    source_hash: None,
                    source_version: Some(name),
                    source_symbol: None,
                  })
                }
              }
            }
            @core.ModuleRef::Symbol(name~) => {
              let alias_name = symbol_alias_name(name)
              match sources.get(rt, symbol_ref_key(name)) {
                Some(hash_text) => {
                  let (snapshot_key, resolved_hash) = resolve_hash_import(
                    rt, sources, binary_sources, diags, hash_text, span,
                  )
                  out.push(ImportSpec::{
                    path: snapshot_key,
                    alias_name,
                    hash: resolved_hash,
                    module_ref: match resolved_hash {
                      Some(h) => Some(@core.module_ref_from_hash(h))
                      None => None
                    },
                    path_obj: None,
                    source_hash: None,
                    source_version: None,
                    source_symbol: Some(name),
                  })
                }
                None => {
                  diags.push(rt, @core.Diagnostic::{
                    stage: "import",
                    message: "missing symbol ref: " + name,
                    span: Some(span),
                    hint: None,
                    note: None,
                  })
                  out.push(ImportSpec::{
                    path: symbol_ref_key(name),
                    alias_name,
                    hash: None,
                    module_ref: None,
                    path_obj: None,
                    source_hash: None,
                    source_version: None,
                    source_symbol: Some(name),
                  })
                }
              }
            }
          }
        }
        _ => ()
      }
    }
    if has_imports {
      match detect_import_cycle(rt, sources, ast_query, file_path) {
        Some(cycle) =>
          diags.push(rt, @core.Diagnostic::{
            stage: "import",
            message: "import cycle: " + render_import_cycle(cycle),
            span: None,
            hint: Some("break the cycle by extracting shared definitions"),
            note: None,
          })
        None => ()
      }
    }
    out
  })
  import_query.register(rt)
  let no_import_type_query : @ripple.Query[String, @checker.TypeEnv?] = db.query(fn(
      rt,
      hash,
    ) {
      match sources.get(rt, hash_source_key(hash)) {
        None => None
        Some(content) => {
          let ast_opt = try @parser.parse_ast(content) catch {
            _ => None
          } noraise {
            ast => Some(ast)
          }
          match ast_opt {
            None => None
            Some(ast) => {
              let mut has_import = false
              for stmt in ast.stmts {
                match stmt {
                  @core.Stmt::Import(..) => has_import = true
                  _ => ()
                }
              }
              if has_import {
                None
              } else {
                let desugared = desugar_method_calls(ast, {})
                let env = try
                  @checker.type_check_with_aliases(desugared, {})
                catch {
                  _ => None
                } noraise {
                  typed => Some(typed)
                }
                env
              }
            }
          }
        }
      }
    },
  )
  no_import_type_query.register(rt)
  // First, create a simple type query that only type checks a single module
  let simple_type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    path,
  ) {
    match sources.get(rt, path) {
      None => @checker.TypeEnv::new()
      Some(content) =>
        if not(content.contains("import")) && not(content.contains("use")) {
          let hash = @core.content_address_hash_string(content)
          match no_import_type_query.fetch(rt, hash) {
            Some(env) => env
            None => {
              let imports = import_query.fetch(rt, path)
              let ast = ast_query.fetch(rt, path).unwrap()
              let aliases = build_alias_map_from_ast(ast, imports)
              let desugared = desugar_method_calls(ast, aliases)
              let env = try! @checker.get_cached_prelude_env_for_module()
              @checker.type_check_with_env(env, desugared, aliases) catch {
                e => {
                  diags.push(rt, e.diagnostic())
                  @checker.TypeEnv::new()
                }
              }
            }
          }
        } else {
          let imports = import_query.fetch(rt, path)
          let ast = ast_query.fetch(rt, path).unwrap()
          let aliases = build_alias_map_from_ast(ast, imports)
          let desugared = desugar_method_calls(ast, aliases)
          let env = try! @checker.get_cached_prelude_env_for_module()
          @checker.type_check_with_env(env, desugared, aliases) catch {
            e => {
              diags.push(rt, e.diagnostic())
              @checker.TypeEnv::new()
            }
          }
        }
    }
  })
  simple_type_query.register(rt)
  let type_query_ref : Ref[@ripple.Query[String, @checker.TypeEnv]?] = @ref.new(
    None,
  )
  // Now create the main type query that handles imports
  let type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    file_path,
  ) {
    match sources.get(rt, file_path) {
      Some(content) =>
        if not(content.contains("import")) && not(content.contains("use")) {
          return simple_type_query.fetch(rt, file_path)
        }
      None => ()
    }
    let imports = import_query.fetch(rt, file_path)
    if imports.length() == 0 {
      return simple_type_query.fetch(rt, file_path)
    }
    let ast = ast_query.fetch(rt, file_path).unwrap()
    let aliases = build_alias_map_from_ast(ast, imports)
    let desugared = desugar_method_calls(ast, aliases)
    let base_dir = @path.Path(file_path).dirname().to_string()
    let env = try! @checker.get_cached_prelude_env_for_module()
    let local_value_decl_spans = collect_local_value_decl_spans(ast)
    let imported_value_decl_spans : Map[String, @core.Span] = {}
    let report_duplicate_import_value = fn(name : String, span : @core.Span) {
      diags.push(rt, @core.Diagnostic::{
        stage: "import",
        message: "duplicate declaration: " + name,
        span: Some(span),
        hint: None,
        note: None,
      })
    }
    let can_bind_import_value = fn(name : String, span : @core.Span) -> Bool {
      if name == "_" {
        return true
      }
      if local_value_decl_spans.contains(name) {
        report_duplicate_import_value(name, span)
        return false
      }
      if imported_value_decl_spans.contains(name) {
        report_duplicate_import_value(name, span)
        return false
      }
      imported_value_decl_spans[name] = span
      true
    }
    // Import types from imported modules
    for imp in imports {
      match sources.get(rt, imp.path) {
        Some(_) => {
          // Use full type query when available so transitive imports contribute
          // trait/type exports from dependency modules.
          let imported_env = match type_query_ref.val {
            Some(q) => q.fetch(rt, imp.path)
            None => simple_type_query.fetch(rt, imp.path)
          }
          // Get the AST of the imported module to find exports
          let imported_ast = ast_query.fetch(rt, imp.path).unwrap()
          let exported_names = collect_exported_names(imported_ast)
          // Now look up the import items in the main AST's Import or ReExport statement
          for stmt in ast.stmts {
            match stmt {
              @core.Stmt::ReExport(names~, source~, span~) =>
                if import_stmt_matches_spec(base_dir, source, imp) {
                  // Build import items from re-export names and import them
                  let reexport_items : Array[@core.ImportItem] = names.map(fn(
                    name,
                  ) {
                    @core.ImportItem::{
                      kind: @core.ImportKind::Value,
                      name,
                      rename: None,
                    }
                  })
                  let reexport_spec = @core.ImportSpec::{
                    items: reexport_items,
                  }
                  let trait_aliases = collect_import_trait_aliases(
                    reexport_spec, imported_env,
                  )
                  for name in names {
                    if exported_names.contains(name) {
                      let item = @core.ImportItem::{
                        kind: @core.ImportKind::Value,
                        name,
                        rename: None,
                      }
                      // Import value
                      if import_item_accepts_value(item, name) {
                        match imported_env.get_scheme(name) {
                          Some(scheme) => {
                            import_scheme_trait_dependencies(
                              env, imported_env, scheme, trait_aliases, exported_names,
                            )
                            if can_bind_import_value(name, span) {
                              env.set_scheme(name, scheme)
                              env.set_exported_scheme(name, scheme)
                            }
                          }
                          None => ()
                        }
                      }
                      // Import type (struct)
                      match imported_env.get_struct(name) {
                        Some(struct_def) => {
                          env.set_struct(name, struct_def)
                          import_trait_impls_for_type(
                            env, imported_env, name, trait_aliases,
                          )
                        }
                        None => ()
                      }
                      // Import type (enum)
                      match imported_env.get_enum_def(name) {
                        Some(enum_def) => {
                          env.set_enum_def(name, enum_def)
                          import_trait_impls_for_type(
                            env, imported_env, name, trait_aliases,
                          )
                          for ctor in enum_def.ctors {
                            match imported_env.get_ctor(ctor.name) {
                              Some(ctor_info) =>
                                env.set_ctor(ctor.name, ctor_info)
                              None => ()
                            }
                            match imported_env.get_scheme(ctor.name) {
                              Some(scheme) =>
                                if can_bind_import_value(ctor.name, span) {
                                  env.set_scheme(ctor.name, scheme)
                                  env.set_exported_scheme(ctor.name, scheme)
                                }
                              None => ()
                            }
                          }
                        }
                        None => ()
                      }
                      // Import type alias
                      match imported_env.get_type_alias(name) {
                        Some(type_alias) => env.set_type_alias(name, type_alias)
                        None => ()
                      }
                      // Import trait
                      if imported_env.has_trait(name) {
                        let local_supertraits = imported_env.trait_supertraits(
                          name,
                        )
                        env.import_trait(
                          name,
                          imported_env.trait_is_open(name),
                          local_supertraits,
                        )
                        let impls = imported_env.trait_impls_for(name)
                        for impl_def in impls {
                          env.add_trait_impl(name, impl_def)
                        }
                      }
                    }
                  }
                }
              @core.Stmt::Import(spec~, source~, span~) =>
                if import_stmt_matches_spec(base_dir, source, imp) {
                  let trait_aliases = collect_import_trait_aliases(
                    spec, imported_env,
                  )
                  let import_symbol = fn(
                    item : @core.ImportItem,
                    source_name : String,
                    target_name : String,
                  ) -> Bool {
                    if item.kind == @core.ImportKind::Module {
                      match imported_env.get_scheme(source_name) {
                        Some(scheme) => {
                          import_scheme_trait_dependencies(
                            env, imported_env, scheme, trait_aliases, exported_names,
                          )
                          if can_bind_import_value(target_name, span) {
                            env.set_scheme(target_name, scheme)
                          }
                          return true
                        }
                        None => return false
                      }
                    }
                    let mut imported_any = false
                    if import_item_accepts_trait(item) &&
                      imported_env.has_trait(source_name) {
                      let local_supertraits = resolve_imported_trait_supertraits(
                        source_name,
                        target_name,
                        imported_env.trait_supertraits(source_name),
                        trait_aliases,
                      )
                      env.import_trait(
                        target_name,
                        imported_env.trait_is_open(source_name),
                        local_supertraits,
                      )
                      let impls = imported_env.trait_impls_for(source_name)
                      for impl_def in impls {
                        env.add_trait_impl(target_name, impl_def)
                      }
                      imported_any = true
                    }
                    if import_item_accepts_value(item, source_name) {
                      match imported_env.get_scheme(source_name) {
                        Some(scheme) => {
                          import_scheme_trait_dependencies(
                            env, imported_env, scheme, trait_aliases, exported_names,
                          )
                          if can_bind_import_value(target_name, span) {
                            env.set_scheme(target_name, scheme)
                          }
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                    if import_item_accepts_type(item) {
                      match imported_env.get_struct(source_name) {
                        Some(struct_def) => {
                          env.set_struct(target_name, struct_def)
                          import_trait_impls_for_type(
                            env, imported_env, source_name, trait_aliases,
                          )
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                    if import_item_accepts_type(item) {
                      match imported_env.get_type_alias(source_name) {
                        Some(type_alias) => {
                          env.set_type_alias(target_name, type_alias)
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                    // If it's an enum, also import the enum definition and all constructors.
                    // Constructors always keep canonical names.
                    if import_item_accepts_type(item) {
                      match imported_env.get_enum_def(source_name) {
                        Some(enum_def) => {
                          env.set_enum_def(target_name, enum_def)
                          imported_any = true
                          import_trait_impls_for_type(
                            env, imported_env, source_name, trait_aliases,
                          )
                          for ctor in enum_def.ctors {
                            match imported_env.get_ctor(ctor.name) {
                              Some(ctor_info) =>
                                env.set_ctor(ctor.name, ctor_info)
                              None => ()
                            }
                            match imported_env.get_scheme(ctor.name) {
                              Some(scheme) =>
                                if can_bind_import_value(ctor.name, span) {
                                  import_scheme_trait_dependencies(
                                    env, imported_env, scheme, trait_aliases, exported_names,
                                  )
                                  env.set_scheme(ctor.name, scheme)
                                }
                              None => ()
                            }
                          }
                        }
                        None => ()
                      }
                    }
                    imported_any
                  }
                  let report_kind_mismatch = fn(
                    item : @core.ImportItem,
                    name : String,
                  ) {
                    if item.kind == @core.ImportKind::Value {
                      return
                    }
                    diags.push(rt, @core.Diagnostic::{
                      stage: "import",
                      message: "expected " +
                      import_kind_expected_label(item.kind) +
                      " export: " +
                      name,
                      span: Some(span),
                      hint: None,
                      note: None,
                    })
                  }
                  let report_non_exported_trait = fn(name : String) {
                    diags.push(rt, @core.Diagnostic::{
                      stage: "import",
                      message: "[TROP002] non-exported trait: " + name,
                      span: Some(span),
                      hint: Some(
                        "export `" +
                        name +
                        "` as `export trait` (or `export open trait` for external impls)",
                      ),
                      note: None,
                    })
                  }
                  let import_namespace_members = fn(
                    item : @core.ImportItem,
                    source_root : String,
                    target_root : String,
                  ) -> Bool {
                    let source_prefix = source_root + "::"
                    let target_prefix = target_root + "::"
                    let mut imported_any = false
                    for exported_name, _ in exported_names {
                      if exported_name.has_prefix(source_prefix) {
                        let suffix = exported_name.unsafe_substring(
                          start=source_prefix.length(),
                          end=exported_name.length(),
                        )
                        let target_name = target_prefix + suffix
                        imported_any = true
                        if not(import_symbol(item, exported_name, target_name)) {
                          report_kind_mismatch(item, exported_name)
                        }
                      }
                    }
                    // Auto-forward receiver-first exported functions as
                    // namespace members so `use { Type }` can activate
                    // method-style calls without manual `Type::...` wrappers.
                    for exported_name, _ in exported_names {
                      if exported_name.contains("::") {
                        continue
                      }
                      if exported_name == source_root {
                        continue
                      }
                      let target_name = target_prefix + exported_name
                      if not(import_item_accepts_value(item, target_name)) {
                        continue
                      }
                      if imported_value_decl_spans.contains(target_name) {
                        continue
                      }
                      match imported_env.get_scheme(exported_name) {
                        Some(scheme) =>
                          match
                            scheme_receiver_root_name(imported_env, scheme) {
                            Some(recv_root) =>
                              if recv_root == source_root {
                                import_scheme_trait_dependencies(
                                  env, imported_env, scheme, trait_aliases, exported_names,
                                )
                                if can_bind_import_value(target_name, span) {
                                  env.set_scheme(target_name, scheme)
                                  imported_any = true
                                }
                              }
                            None => ()
                          }
                        None => ()
                      }
                    }
                    imported_any
                  }
                  // For each imported item, copy symbols by declared kind.
                  for item in spec.items {
                    let name = item.name
                    if item.kind == @core.ImportKind::Module {
                      if not(supports_module_namespace_import(imp.path)) {
                        diags.push(rt, @core.Diagnostic::{
                          stage: "import",
                          message: "module import is only supported for .xm source: " +
                          imp.path,
                          span: Some(span),
                          hint: Some(
                            "use `.xm` for multi-module files, or import explicit exported symbols from `.vibe`",
                          ),
                          note: None,
                        })
                        continue
                      }
                      let source_prefix = name + "::"
                      let local_ns = match item.rename {
                        Some(n) => n
                        None => name
                      }
                      let target_prefix = local_ns + "::"
                      let mut imported_any = false
                      for exported_name, _ in exported_names {
                        if exported_name.has_prefix(source_prefix) {
                          let suffix = exported_name.unsafe_substring(
                            start=source_prefix.length(),
                            end=exported_name.length(),
                          )
                          let target_name = target_prefix + suffix
                          imported_any = true
                          if not(
                              import_symbol(item, exported_name, target_name),
                            ) {
                            report_kind_mismatch(item, exported_name)
                          }
                        }
                      }
                      if not(imported_any) {
                        report_kind_mismatch(item, name)
                      }
                      continue
                    }
                    let local_name = match item.rename {
                      Some(n) => n
                      None => name
                    }
                    if exported_names.contains(name) {
                      if not(import_symbol(item, name, local_name)) {
                        report_kind_mismatch(item, name)
                      }
                      // Also bring namespace members (`Type::...`) when using
                      // the namespace root itself (e.g. `use <ref> { Option }`).
                      let _ = import_namespace_members(item, name, local_name)
                    } else if item.rename is None {
                      // Namespace import: `use <ref> { Int }` or `use <ref> { type Int }`
                      // brings all `Int::...` exports.
                      let imported_any = import_namespace_members(
                        item, name, name,
                      )
                      if not(imported_any) {
                        if import_item_accepts_trait(item) &&
                          imported_env.has_trait(name) {
                          report_non_exported_trait(name)
                        } else if item.kind != @core.ImportKind::Value {
                          report_kind_mismatch(item, name)
                        }
                      }
                    } else if import_item_accepts_trait(item) &&
                      imported_env.has_trait(name) {
                      report_non_exported_trait(name)
                    }
                  }
                }
              _ => ()
            }
          }
        }
        None =>
          match binary_sources.get(rt, imp.path) {
            Some(wasm_bytes) => {
              let exported_types = match
                parse_wasm_exported_function_types(wasm_bytes) {
                Ok(types) => types
                Err(msg) => {
                  for stmt in ast.stmts {
                    match stmt {
                      @core.Stmt::Import(source~, span~, ..) =>
                        if import_stmt_matches_spec(base_dir, source, imp) {
                          diags.push(rt, @core.Diagnostic::{
                            stage: "import",
                            message: "failed to parse wasm import: " + imp.path,
                            span: Some(span),
                            hint: None,
                            note: Some(msg),
                          })
                        }
                      _ => ()
                    }
                  }
                  continue
                }
              }
              for stmt in ast.stmts {
                match stmt {
                  @core.Stmt::Import(spec~, source~, span~) =>
                    if import_stmt_matches_spec(base_dir, source, imp) {
                      for item in spec.items {
                        let source_name = item.name
                        let target_name = match item.rename {
                          Some(rename) => rename
                          None => source_name
                        }
                        if item.kind == @core.ImportKind::Module {
                          diags.push(rt, @core.Diagnostic::{
                            stage: "import",
                            message: "module import is not supported for wasm import: " +
                            source_name,
                            span: Some(span),
                            hint: Some(
                              "wasm import currently exposes flat value exports only",
                            ),
                            note: None,
                          })
                          continue
                        }
                        if item.kind != @core.ImportKind::Value {
                          diags.push(rt, @core.Diagnostic::{
                            stage: "import",
                            message: "expected value export: " + source_name,
                            span: Some(span),
                            hint: Some(
                              "wasm import currently exposes values only",
                            ),
                            note: None,
                          })
                          continue
                        }
                        match exported_types.get(source_name) {
                          Some(ty) => env.set(target_name, ty)
                          None =>
                            diags.push(rt, @core.Diagnostic::{
                              stage: "import",
                              message: "missing wasm export: " + source_name,
                              span: Some(span),
                              hint: Some(
                                "available exports are read from wasm export section",
                              ),
                              note: None,
                            })
                        }
                      }
                    }
                  _ => ()
                }
              }
            }
            None => ()
          }
      }
    }
    // Type check with the enriched environment
    @checker.type_check_with_env(env, desugared, aliases) catch {
      e => {
        diags.push(rt, e.diagnostic())
        @checker.TypeEnv::new()
      }
    }
  })
  type_query_ref.val = Some(type_query)
  type_query.register(rt)
  {
    db,
    rt,
    sources,
    binary_sources,
    cst_query,
    ast_query,
    type_query,
    import_query,
    diags,
  }
}
