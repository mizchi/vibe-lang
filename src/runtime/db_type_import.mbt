///|
fn collect_import_trait_aliases(
  spec : @core.ImportSpec,
  imported_env : @checker.TypeEnv,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for item in spec.items {
    if import_item_accepts_trait(item) && imported_env.has_trait(item.name) {
      let local_name = match item.rename {
        Some(rename) => rename
        None => item.name
      }
      out[item.name] = local_name
    }
  }
  out
}

///|
fn resolve_imported_trait_supertraits(
  source_name : String,
  local_name : String,
  source_supertraits : Array[String],
  trait_aliases : Map[String, String],
) -> Array[String] {
  let out : Array[String] = []
  for supertrait in source_supertraits {
    let local_super = match trait_aliases.get(supertrait) {
      Some(alias_name) => alias_name
      None => supertrait
    }
    if not(array_has_string(out, local_super)) {
      out.push(local_super)
    }
  }
  if local_name != source_name && not(array_has_string(out, source_name)) {
    // Preserve canonical source relation so renamed traits still satisfy
    // built-in canonical bounds like Eq/Ord.
    out.push(source_name)
  }
  out
}

///|
fn maybe_add_trait_impl(
  env : @checker.TypeEnv,
  trait_name : String,
  impl_def : @checker.TraitImplDef,
) -> Unit {
  for existing in env.trait_impls_for(trait_name) {
    if existing == impl_def {
      return
    }
  }
  env.add_trait_impl(trait_name, impl_def)
}

///|
fn impl_target_root_name(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Named(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn import_trait_impls_for_type(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  source_type_name : String,
  trait_aliases : Map[String, String],
) -> Unit {
  for source_trait_name in imported_env.trait_names() {
    let local_trait_name = match trait_aliases.get(source_trait_name) {
      Some(alias_name) => alias_name
      None => source_trait_name
    }
    if env.has_trait(local_trait_name) {
      for impl_def in imported_env.trait_impls_for(source_trait_name) {
        match impl_target_root_name(impl_def.target) {
          Some(root_name) =>
            if root_name == source_type_name {
              maybe_add_trait_impl(env, local_trait_name, impl_def)
            }
          None => ()
        }
      }
    }
  }
}

///|
fn collect_scheme_trait_bounds(scheme : @checker.TypeScheme) -> Array[String] {
  let out : Array[String] = []
  for _, bounds in scheme.trait_bounds {
    for bound in bounds {
      if not(array_has_string(out, bound)) {
        out.push(bound)
      }
    }
  }
  out
}

///|
fn import_trait_dependency_for_scheme(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  source_trait_name : String,
  trait_aliases : Map[String, String],
  exported_names : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  if visiting.contains(source_trait_name) {
    return
  }
  visiting[source_trait_name] = true
  if not(imported_env.has_trait(source_trait_name)) {
    return
  }
  if not(exported_names.contains(source_trait_name)) {
    return
  }
  let local_trait_name = match trait_aliases.get(source_trait_name) {
    Some(alias_name) => alias_name
    None => source_trait_name
  }
  let source_supertraits = imported_env.trait_supertraits(source_trait_name)
  for supertrait in source_supertraits {
    import_trait_dependency_for_scheme(
      env, imported_env, supertrait, trait_aliases, exported_names, visiting,
    )
  }
  let local_supertraits = resolve_imported_trait_supertraits(
    source_trait_name, local_trait_name, source_supertraits, trait_aliases,
  )
  if not(env.has_trait(local_trait_name)) {
    env.import_trait(
      local_trait_name,
      imported_env.trait_is_open(source_trait_name),
      local_supertraits,
    )
  }
  for impl_def in imported_env.trait_impls_for(source_trait_name) {
    maybe_add_trait_impl(env, local_trait_name, impl_def)
  }
}

///|
fn import_scheme_trait_dependencies(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  scheme : @checker.TypeScheme,
  trait_aliases : Map[String, String],
  exported_names : Map[String, Bool],
) -> Unit {
  let required_traits = collect_scheme_trait_bounds(scheme)
  let visiting : Map[String, Bool] = {}
  for trait_name in required_traits {
    import_trait_dependency_for_scheme(
      env, imported_env, trait_name, trait_aliases, exported_names, visiting,
    )
  }
}

///|
fn scheme_receiver_root_name(
  imported_env : @checker.TypeEnv,
  scheme : @checker.TypeScheme,
) -> String? {
  match scheme.ty {
    @core.Type::Func(params~, ..) =>
      if params.length() == 0 {
        None
      } else {
        imported_env.namespace_root(params[0].ty)
      }
    _ => None
  }
}

///|
fn collect_exported_names(ast : @core.Module) -> Map[String, Bool] {
  let exports : Map[String, Bool] = {}
  let defined : Map[String, Bool] = {}
  let mut has_late_exports = false
  // First pass: collect all definitions
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) | @core.Stmt::LetMut(name~, ..) =>
        defined[name] = true
      @core.Stmt::EnumDef(name~, ..) => defined[name] = true
      @core.Stmt::TypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::StructDef(name~, ..) => defined[name] = true
      @core.Stmt::TraitDef(name~, exported~, ..) => {
        defined[name] = true
        if exported {
          exports[name] = true
        }
      }
      @core.Stmt::ExportLet(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => {
        defined[name] = true
        exports[name] = true
        // Also export all constructor names
        for ctor in ctors {
          defined[ctor.name] = true
          exports[ctor.name] = true
        }
      }
      @core.Stmt::ExportTypeAlias(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::ExportStructDef(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        has_late_exports = true
      _ => ()
    }
  }
  if not(has_late_exports) {
    return exports
  }
  // Second pass: handle export and re-export statements
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          if defined.contains(name) {
            exports[name] = true
          }
        }
      // Re-export: mark names as exported (actual definitions come from source module)
      @core.Stmt::ReExport(names~, ..) =>
        for name in names {
          exports[name] = true
        }
      _ => ()
    }
  }
  exports
}

///|
fn collect_internal_exported_names(ast : @core.Module) -> Map[String, Bool] {
  let internal_exports : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::InternalExportLet(name~, ..) => internal_exports[name] = true
      @core.Stmt::InternalExportEnumDef(name~, ctors~, ..) => {
        internal_exports[name] = true
        for ctor in ctors {
          internal_exports[ctor.name] = true
        }
      }
      @core.Stmt::InternalExportTypeAlias(name~, ..) =>
        internal_exports[name] = true
      @core.Stmt::InternalExportStructDef(name~, ..) =>
        internal_exports[name] = true
      @core.Stmt::InternalTraitDef(name~, ..) => internal_exports[name] = true
      _ => ()
    }
  }
  internal_exports
}
