///|
priv struct TypeImportMeta {
  exported_names : Map[String, Bool]
  internal_exported_names : Map[String, Bool]
  trait_names : Map[String, Bool]
} derive(Eq)

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
fn collect_named_type_dependencies(
  ty : @core.Type,
  out : Map[String, Bool],
) -> Unit {
  match ty {
    @core.Type::Named(name~, args~) => {
      out[name] = true
      for arg in args {
        collect_named_type_dependencies(arg, out)
      }
    }
    @core.Type::Tuple(items) =>
      for item in items {
        collect_named_type_dependencies(item, out)
      }
    @core.Type::Record(fields) =>
      for _, field_ty in fields {
        collect_named_type_dependencies(field_ty, out)
      }
    @core.Type::Array(inner) | @core.Type::ArrayBuilder(inner) =>
      collect_named_type_dependencies(inner, out)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      collect_named_type_dependencies(inner, out)
    @core.Type::Variant(fields) =>
      for _, field_ty in fields {
        collect_named_type_dependencies(field_ty, out)
      }
    @core.Type::Func(params~, ret~, ..) => {
      for param in params {
        collect_named_type_dependencies(param.ty, out)
      }
      collect_named_type_dependencies(ret, out)
    }
    _ => ()
  }
}

///|
fn import_type_dependency_for_scheme(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  source_type_name : String,
  trait_aliases : Map[String, String],
  visiting : Map[String, Bool],
) -> Unit {
  if visiting.contains(source_type_name) {
    return
  }
  visiting[source_type_name] = true

  match imported_env.get_type_alias(source_type_name) {
    Some(type_alias) => {
      if env.get_type_alias(source_type_name) is None {
        env.set_type_alias(source_type_name, type_alias)
      }
      let nested : Map[String, Bool] = {}
      collect_named_type_dependencies(type_alias.target, nested)
      for nested_name, _ in nested {
        import_type_dependency_for_scheme(
          env, imported_env, nested_name, trait_aliases, visiting,
        )
      }
    }
    None => ()
  }

  match imported_env.get_struct(source_type_name) {
    Some(struct_def) => {
      if env.get_struct(source_type_name) is None {
        env.set_struct(source_type_name, struct_def)
      }
      import_trait_impls_for_type(
        env, imported_env, source_type_name, trait_aliases,
      )
      for field in struct_def.fields {
        let nested : Map[String, Bool] = {}
        collect_named_type_dependencies(field.ty, nested)
        for nested_name, _ in nested {
          import_type_dependency_for_scheme(
            env, imported_env, nested_name, trait_aliases, visiting,
          )
        }
      }
    }
    None => ()
  }

  match imported_env.get_enum_def(source_type_name) {
    Some(enum_def) => {
      if env.get_enum_def(source_type_name) is None {
        env.set_enum_def(source_type_name, enum_def)
      }
      import_trait_impls_for_type(
        env, imported_env, source_type_name, trait_aliases,
      )
      for ctor in enum_def.ctors {
        let nested : Map[String, Bool] = {}
        for arg_ty in ctor.args {
          collect_named_type_dependencies(arg_ty, nested)
        }
        for nested_name, _ in nested {
          import_type_dependency_for_scheme(
            env, imported_env, nested_name, trait_aliases, visiting,
          )
        }
      }
    }
    None => ()
  }
}

///|
fn import_scheme_type_dependencies(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  scheme : @checker.TypeScheme,
  trait_aliases : Map[String, String],
) -> Unit {
  let required_types : Map[String, Bool] = {}
  collect_named_type_dependencies(scheme.ty, required_types)
  let visiting : Map[String, Bool] = {}
  for type_name, _ in required_types {
    import_type_dependency_for_scheme(
      env, imported_env, type_name, trait_aliases, visiting,
    )
  }
}

///|
fn import_scheme_dependencies(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  scheme : @checker.TypeScheme,
  trait_aliases : Map[String, String],
  exported_names : Map[String, Bool],
) -> Unit {
  import_scheme_trait_dependencies(
    env, imported_env, scheme, trait_aliases, exported_names,
  )
  import_scheme_type_dependencies(env, imported_env, scheme, trait_aliases)
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
fn scheme_return_root_name(
  imported_env : @checker.TypeEnv,
  scheme : @checker.TypeScheme,
) -> String? {
  match scheme.ty {
    @core.Type::Func(ret~, ..) => imported_env.namespace_root(ret)
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
      @core.Stmt::ExportEffectDef(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::EffectDef(name~, ..) => defined[name] = true
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
      // Re-export: mark exported aliases (or original names) as exported.
      @core.Stmt::ReExport(spec~, ..) =>
        for item in spec.items {
          exports[@core.import_item_local_name(item)] = true
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

///|
fn collect_trait_names(ast : @core.Module) -> Map[String, Bool] {
  let trait_names : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::TraitDef(name~, ..) => trait_names[name] = true
      @core.Stmt::InternalTraitDef(name~, ..) => trait_names[name] = true
      _ => ()
    }
  }
  trait_names
}

///|
fn merge_visible_import_names(
  exported_names : Map[String, Bool],
  internal_exported_names : Map[String, Bool],
) -> Map[String, Bool] {
  let visible_names = exported_names.copy()
  for name, _ in internal_exported_names {
    visible_names[name] = true
  }
  visible_names
}

///|
fn copy_visible_enum_ctors(
  surface_env : @checker.TypeEnv,
  source_env : @checker.TypeEnv,
  enum_name : String,
) -> Unit {
  match source_env.get_enum_def(enum_name) {
    Some(enum_def) =>
      for ctor in enum_def.ctors {
        match source_env.get_ctor(ctor.name) {
          Some(ctor_info) => surface_env.set_ctor(ctor.name, ctor_info)
          None => ()
        }
        match source_env.get_scheme(ctor.name) {
          Some(scheme) => {
            surface_env.set_scheme(ctor.name, scheme)
            match source_env.get_purity_tier(ctor.name) {
              Some(tier) => surface_env.set_purity_tier(ctor.name, tier)
              None =>
                match source_env.get_purity(ctor.name) {
                  Some(pure) => surface_env.set_purity(ctor.name, pure)
                  None => ()
                }
            }
          }
          None => ()
        }
      }
    None => ()
  }
}

///|
fn project_type_import_env(
  source_env : @checker.TypeEnv,
  ast : @core.Module,
) -> @checker.TypeEnv {
  let surface_env = try! @checker.get_prelude_only_env_for_module()
  let meta = collect_type_import_meta(ast)
  let exported_names = meta.exported_names
  let internal_exported_names = meta.internal_exported_names
  let visible_names = merge_visible_import_names(
    exported_names, internal_exported_names,
  )
  let trait_aliases : Map[String, String] = {}
  let trait_visiting : Map[String, Bool] = {}
  for name, _ in visible_names {
    if source_env.has_trait(name) {
      import_trait_dependency_for_scheme(
        surface_env, source_env, name, trait_aliases, visible_names, trait_visiting,
      )
    }
  }
  let type_visiting : Map[String, Bool] = {}
  for name, _ in visible_names {
    import_type_dependency_for_scheme(
      surface_env, source_env, name, trait_aliases, type_visiting,
    )
    copy_visible_enum_ctors(surface_env, source_env, name)
    match source_env.effect_defs.get(name) {
      Some(effect_def) => surface_env.effect_defs[name] = effect_def
      None => ()
    }
  }
  for name, _ in visible_names {
    match source_env.get_scheme(name) {
      Some(scheme) => {
        import_scheme_dependencies(
          surface_env, source_env, scheme, trait_aliases, visible_names,
        )
        surface_env.set_exported_scheme(name, scheme)
        match source_env.get_purity_tier(name) {
          Some(tier) => surface_env.set_purity_tier(name, tier)
          None =>
            match source_env.get_purity(name) {
              Some(pure) => surface_env.set_purity(name, pure)
              None => ()
            }
        }
      }
      None =>
        match source_env.get_ctor(name) {
          Some(ctor_info) => surface_env.set_ctor(name, ctor_info)
          None => ()
        }
    }
  }
  surface_env
}

///|
fn collect_type_import_meta(ast : @core.Module) -> TypeImportMeta {
  {
    exported_names: collect_exported_names(ast),
    internal_exported_names: collect_internal_exported_names(ast),
    trait_names: collect_trait_names(ast),
  }
}
