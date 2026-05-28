///|
/// Check if a type contains any Named nodes (the only nodes normalize_type_inner transforms).
/// Used to skip normalization walks for types that cannot change.
fn type_has_named_node(ty : @core.Type) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Named(..) => true
      _ => false
    }
  })
}

///|
fn normalize_type(env : TypeEnv, ty : @core.Type) -> @core.Type raise TypeError {
  normalize_type_with_mode(env, ty, false)
}

///|
fn normalize_type_expand_enum(
  env : TypeEnv,
  ty : @core.Type,
) -> @core.Type raise TypeError {
  normalize_type_with_mode(env, ty, true)
}

///|
/// Extract a cheap cache key for Named types.
/// Returns the type name string instead of expensive structural_hash.
fn normalize_type_cache_key(ty : @core.Type) -> String {
  match ty {
    @core.Type::Named(name~, ..) => name
    _ => ""
  }
}

///|
fn normalize_type_cacheable(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(..) => true
    _ => false
  }
}

///|
fn normalize_type_cache_refresh(env : TypeEnv) -> Unit {
  if env.normalize_type_cache_subs_version != env.subs_version {
    env.invalidate_normalize_type_cache()
  }
}

///|
fn normalize_type_cache_lookup_from(
  cache : Map[String, Array[(@core.Type, @core.Type)]],
  ty : @core.Type,
) -> @core.Type? {
  let key = normalize_type_cache_key(ty)
  match cache.get(key) {
    Some(entries) => {
      for entry in entries {
        let (cached_source, cached_normalized) = entry
        if cached_source == ty {
          return Some(cached_normalized)
        }
      }
      None
    }
    None => None
  }
}

///|
fn normalize_type_cache_store_to(
  cache : Map[String, Array[(@core.Type, @core.Type)]],
  source : @core.Type,
  normalized : @core.Type,
) -> Unit {
  let key = normalize_type_cache_key(source)
  if cache.length() >= 8192 && !cache.contains(key) {
    return
  }
  let entry = (source, normalized)
  match cache.get(key) {
    Some(entries) => if entries.length() < 4 { entries.push(entry) }
    None => cache[key] = [entry]
  }
}

///|
fn normalize_type_cache_lookup(
  env : TypeEnv,
  ty : @core.Type,
  expand_enum : Bool,
) -> @core.Type? {
  if !normalize_type_cacheable(ty) {
    return None
  }
  // Fast path: ground cache for 0-arg Named types.
  // These don't depend on type variable substitutions, so they survive
  // subs_version changes (only invalidated on type definition changes).
  match ty {
    @core.Type::Named(name~, args~) =>
      if args.is_empty() {
        let ground = if expand_enum {
          env.normalize_type_cache_expand_ground
        } else {
          env.normalize_type_cache_preserve_ground
        }
        match ground.get(name) {
          Some(hit) => return Some(hit)
          None => ()
        }
      }
    _ => ()
  }
  if expand_enum {
    normalize_type_cache_lookup_from(env.normalize_type_cache_expand, ty)
  } else {
    normalize_type_cache_lookup_from(env.normalize_type_cache_preserve, ty)
  }
}

///|
fn normalize_type_cache_store(
  env : TypeEnv,
  source : @core.Type,
  normalized : @core.Type,
  expand_enum : Bool,
) -> Unit {
  if !normalize_type_cacheable(source) || !normalize_type_cacheable(normalized) {
    return
  }
  // Store in ground cache for 0-arg Named types (survives subs_version changes).
  match source {
    @core.Type::Named(name~, args~) =>
      if args.is_empty() {
        if expand_enum {
          env.normalize_type_cache_expand_ground[name] = normalized
        } else {
          env.normalize_type_cache_preserve_ground[name] = normalized
        }
        return
      }
    _ => ()
  }
  if expand_enum {
    normalize_type_cache_store_to(
      env.normalize_type_cache_expand,
      source,
      normalized,
    )
  } else {
    normalize_type_cache_store_to(
      env.normalize_type_cache_preserve,
      source,
      normalized,
    )
  }
}

///|
fn normalize_type_with_mode(
  env : TypeEnv,
  ty : @core.Type,
  expand_enum : Bool,
) -> @core.Type raise TypeError {
  normalize_type_with_mode_resolved(env, resolve_type(env, ty), expand_enum)
}

///|
/// Core normalization logic operating on an already-resolved type.
fn normalize_type_with_mode_resolved(
  env : TypeEnv,
  resolved : @core.Type,
  expand_enum : Bool,
) -> @core.Type raise TypeError {
  // Fast path: ground types need no normalization
  match resolved {
    Int
    | Float
    | Double
    | Bool
    | Char
    | String
    | Path
    | PromptText
    | Unit
    | StringBuilder
    | Never
    | Var(_)
    | Param(_) => return resolved
    _ => ()
  }
  normalize_type_cache_refresh(env)
  match normalize_type_cache_lookup(env, resolved, expand_enum) {
    Some(hit) => return hit
    None => ()
  }
  let visiting : Map[String, Bool] = {}
  let normalized = normalize_type_inner(env, resolved, visiting, expand_enum)
  normalize_type_cache_store(env, resolved, normalized, expand_enum)
  normalized
}

///|
/// Resolve builtin type names that the parser now emits as Named(name, args).
fn resolve_builtin_type_name(
  name : String,
  args : Array[@core.Type],
) -> @core.Type? {
  match name {
    "Int" | "i32" => if args.is_empty() { Some(@core.Type::Int) } else { None }
    "Float" | "f32" =>
      if args.is_empty() {
        Some(@core.Type::Float)
      } else {
        None
      }
    "Double" | "f64" =>
      if args.is_empty() {
        Some(@core.Type::Double)
      } else {
        None
      }
    "Bool" => if args.is_empty() { Some(@core.Type::Bool) } else { None }
    "Char" => if args.is_empty() { Some(@core.Type::Char) } else { None }
    "String" => if args.is_empty() { Some(@core.Type::String) } else { None }
    "@core.Path" => if args.is_empty() { Some(@core.Type::Path) } else { None }
    "PromptText" =>
      if args.is_empty() {
        Some(@core.Type::PromptText)
      } else {
        None
      }
    "Unit" => if args.is_empty() { Some(@core.Type::Unit) } else { None }
    "Array" =>
      if args.length() == 1 {
        Some(@core.Type::Array(args[0]))
      } else {
        None
      }
    "Map" =>
      if args.length() == 2 {
        Some(@core.Type::Map(args[0], args[1]))
      } else {
        None
      }
    "Set" =>
      if args.length() == 1 {
        Some(@core.Type::Set(args[0]))
      } else {
        None
      }
    "ArrayBuilder" =>
      if args.length() == 1 {
        Some(@core.Type::ArrayBuilder(args[0]))
      } else {
        None
      }
    "MapBuilder" =>
      if args.length() == 2 {
        Some(@core.Type::MapBuilder(args[0], args[1]))
      } else {
        None
      }
    "StringBuilder" =>
      if args.is_empty() {
        Some(@core.Type::StringBuilder)
      } else {
        None
      }
    "Bytes" => if args.is_empty() { Some(@core.Type::Bytes) } else { None }
    "V128" => if args.is_empty() { Some(@core.Type::V128) } else { None }
    "anyref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="anyref", args=[]))
      } else {
        None
      }
    "eqref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="eqref", args=[]))
      } else {
        None
      }
    "i31ref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="i31ref", args=[]))
      } else {
        None
      }
    "structref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="structref", args=[]))
      } else {
        None
      }
    "arrayref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="arrayref", args=[]))
      } else {
        None
      }
    "funcref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="funcref", args=[]))
      } else {
        None
      }
    "externref" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="externref", args=[]))
      } else {
        None
      }
    // WASM numeric primitives (kept as Named for codegen-level use)
    "i64" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="i64", args=[]))
      } else {
        None
      }
    "u8" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="u8", args=[]))
      } else {
        None
      }
    "u16" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="u16", args=[]))
      } else {
        None
      }
    "u32" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="u32", args=[]))
      } else {
        None
      }
    "u64" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="u64", args=[]))
      } else {
        None
      }
    "i16" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="i16", args=[]))
      } else {
        None
      }
    "v128" =>
      if args.is_empty() {
        Some(@core.Type::Named(name="v128", args=[]))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Check if a type name is a WASM opaque type that should not be expanded.
fn is_wasm_opaque_type(name : String) -> Bool {
  match name {
    "anyref"
    | "eqref"
    | "i31ref"
    | "structref"
    | "arrayref"
    | "funcref"
    | "externref"
    | "i64"
    | "u8"
    | "u16"
    | "u32"
    | "u64"
    | "i16"
    | "v128" => true
    _ => false
  }
}

///|
fn normalize_type_inner(
  env : TypeEnv,
  ty : @core.Type,
  visiting : Map[String, Bool],
  expand_enum : Bool,
) -> @core.Type raise TypeError {
  match ty {
    @core.Type::Named(name~, args~) => {
      let normalized_args : Array[@core.Type] = []
      for arg in args {
        normalized_args.push(
          normalize_type_inner(env, arg, visiting, expand_enum),
        )
      }
      if name == "Ref" {
        if normalized_args.length() != 1 {
          raise TypeError::BadTypeDef(
            message="type arity: Ref",
            span=unknown_span(),
          )
        }
        return @core.Type::Named(name~, args=normalized_args)
      }
      // Json is a builtin opaque type - preserve as-is (unless user defines their own Json)
      if name == "Json" &&
        normalized_args.length() == 0 &&
        env.get_type_alias(name) is None &&
        env.get_enum_def(name) is None &&
        env.get_struct(name) is None {
        return @core.Type::Named(name~, args=normalized_args)
      }
      // WASM opaque types (wasm ref types + numeric primitives) - preserve as-is
      if normalized_args.is_empty() && is_wasm_opaque_type(name) {
        return @core.Type::Named(name~, args=normalized_args)
      }
      if visiting.contains(name) {
        match env.get_enum_def(name) {
          Some(_) => @core.Type::Named(name~, args=normalized_args)
          None =>
            raise TypeError::BadTypeDef(
              message="recursive type: " + name,
              span=unknown_span(),
            )
        }
      } else {
        visiting[name] = true
        let normalized = match env.get_type_alias(name) {
          Some(type_alias) => {
            if type_alias.params.length() != normalized_args.length() {
              raise TypeError::BadTypeDef(
                message="type arity: " + name,
                span=unknown_span(),
              )
            }
            let mapping : Map[String, @core.Type] = {}
            for i in 0..<type_alias.params.length() {
              mapping[type_alias.params[i]] = normalized_args[i]
            }
            let substituted = substitute_type(type_alias.target, mapping)
            normalize_type_inner(env, substituted, visiting, expand_enum)
          }
          None =>
            match env.get_enum_def(name) {
              Some(def) => {
                if def.params.length() != normalized_args.length() {
                  raise TypeError::BadTypeDef(
                    message="type arity: " + name,
                    span=unknown_span(),
                  )
                }
                let mapping : Map[String, @core.Type] = {}
                for i in 0..<def.params.length() {
                  mapping[def.params[i]] = normalized_args[i]
                }
                if !expand_enum {
                  return @core.Type::Named(name~, args=normalized_args)
                }
                let ctor_map : Map[String, @core.Type] = {}
                for ctor in def.ctors {
                  let base_payload = if ctor.args.length() == 0 {
                    @core.Type::Unit
                  } else if ctor.args.length() == 1 {
                    ctor.args[0]
                  } else {
                    @core.Type::Tuple(ctor.args)
                  }
                  let substituted = substitute_type(base_payload, mapping)
                  ctor_map[ctor.name] = normalize_type_inner(
                    env, substituted, visiting, expand_enum,
                  )
                }
                @core.Type::Variant(ctor_map)
              }
              None =>
                match env.get_struct(name) {
                  Some(struct_def) => {
                    if struct_def.params.length() != normalized_args.length() {
                      raise TypeError::BadTypeDef(
                        message="type arity: " + name,
                        span=unknown_span(),
                      )
                    }
                    // For struct types, return Named type with normalized args
                    @core.Type::Named(name~, args=normalized_args)
                  }
                  None =>
                    match resolve_builtin_type_name(name, normalized_args) {
                      Some(builtin) => builtin
                      None =>
                        raise TypeError::UnknownType(
                          name~,
                          span=unknown_span(),
                          suggestion=find_type_suggestion(env, name),
                        )
                    }
                }
            }
        }
        visiting.remove(name)
        normalized
      }
    }
    @core.Type::Tuple(items) =>
      if !type_has_named_node(ty) {
        ty
      } else {
        let out : Array[@core.Type] = []
        for item in items {
          out.push(normalize_type_inner(env, item, visiting, expand_enum))
        }
        @core.Type::Tuple(out)
      }
    @core.Type::Record(fields) =>
      if !type_has_named_node(ty) {
        ty
      } else {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = normalize_type_inner(env, item, visiting, expand_enum)
        }
        @core.Type::Record(out)
      }
    @core.Type::Array(inner) =>
      if !type_has_named_node(inner) {
        ty
      } else {
        @core.Type::Array(
          normalize_type_inner(env, inner, visiting, expand_enum),
        )
      }
    @core.Type::Map(key, inner) =>
      if !type_has_named_node(key) && !type_has_named_node(inner) {
        ty
      } else {
        @core.Type::Map(
          normalize_type_inner(env, key, visiting, expand_enum),
          normalize_type_inner(env, inner, visiting, expand_enum),
        )
      }
    @core.Type::Set(inner) =>
      if !type_has_named_node(inner) {
        ty
      } else {
        @core.Type::Set(normalize_type_inner(env, inner, visiting, expand_enum))
      }
    @core.Type::ArrayBuilder(inner) =>
      if !type_has_named_node(inner) {
        ty
      } else {
        @core.Type::ArrayBuilder(
          normalize_type_inner(env, inner, visiting, expand_enum),
        )
      }
    @core.Type::MapBuilder(key, inner) =>
      if !type_has_named_node(key) && !type_has_named_node(inner) {
        ty
      } else {
        @core.Type::MapBuilder(
          normalize_type_inner(env, key, visiting, expand_enum),
          normalize_type_inner(env, inner, visiting, expand_enum),
        )
      }
    @core.Type::Variant(fields) =>
      if !type_has_named_node(ty) {
        ty
      } else {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = normalize_type_inner(env, item, visiting, expand_enum)
        }
        @core.Type::Variant(out)
      }
    @core.Type::Param(_) => ty
    @core.Type::Var(_) => ty
    @core.Type::Func(params~, ret~, effects~) =>
      if !type_has_named_node(ty) {
        ty
      } else {
        let out : Array[@core.FuncParam] = []
        for param in params {
          out.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: normalize_type_inner(env, param.ty, visiting, expand_enum),
            bounds: param.bounds,
          })
        }
        @core.Type::Func(
          params=out,
          ret=normalize_type_inner(env, ret, visiting, expand_enum),
          effects~,
        )
      }
    _ => ty
  }
}

///|
/// Quick heuristic: could this type possibly contain a Ref?
/// Returns true for user-defined Named types (aliases may hide Ref),
/// false for builtins. Compound types recurse via type_tree_any.
fn type_may_contain_scoped_ref_hint(ty : @core.Type) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Named(name~, ..) =>
        match name {
          "Ref" => true
          "Int"
          | "i32"
          | "Float"
          | "f32"
          | "Double"
          | "f64"
          | "Bool"
          | "Char"
          | "String"
          | "@core.Path"
          | "PromptText"
          | "Unit"
          | "StringBuilder"
          | "Bytes"
          | "Array"
          | "Map"
          | "Set"
          | "ArrayBuilder"
          | "MapBuilder"
          | "i64"
          | "u8"
          | "u16"
          | "u32"
          | "u64"
          | "i16"
          | "v128"
          | "anyref"
          | "eqref"
          | "i31ref"
          | "structref"
          | "arrayref"
          | "funcref"
          | "externref" => false
          _ => true
        }
      _ => false
    }
  })
}

///|
/// Extract a cheap cache key for scoped ref checking.
/// Uses type name for Named types instead of expensive structural_hash.
/// The cache is cleared on invalidation, so version is not needed in the key.
fn scoped_ref_cache_key(_env : TypeEnv, ty : @core.Type) -> String {
  match ty {
    @core.Type::Named(name~, ..) => name
    _ => ""
  }
}

///|
fn scoped_ref_cache_lookup(env : TypeEnv, ty : @core.Type) -> Bool? {
  let key : String = scoped_ref_cache_key(env, ty)
  match env.scoped_ref_contains_cache.get(key) {
    Some(entries) => {
      for entry in entries {
        if entry.ty == ty {
          return Some(entry.has_scoped_ref)
        }
      }
      None
    }
    None => None
  }
}

///|
fn scoped_ref_cache_store(env : TypeEnv, ty : @core.Type, value : Bool) -> Unit {
  let key : String = scoped_ref_cache_key(env, ty)
  let next = ScopedRefContainsCacheEntry::{ ty, has_scoped_ref: value }
  if env.scoped_ref_contains_cache.length() >= 4096 &&
    !env.scoped_ref_contains_cache.contains(key) {
    return
  }
  match env.scoped_ref_contains_cache.get(key) {
    Some(entries) => {
      for i in 0..<entries.length() {
        if entries[i].ty == ty {
          entries[i] = next
          return
        }
      }
      if entries.length() < 4 {
        entries.push(next)
      }
    }
    None => env.scoped_ref_contains_cache[key] = [next]
  }
}

///|
fn type_contains_scoped_ref(
  env : TypeEnv,
  ty : @core.Type,
) -> Bool raise TypeError {
  if !env.scoped_ref_checks_enabled {
    return false
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_contains_calls += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn(result : Bool) -> Bool {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_contains_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
    result
  }
  let resolved = resolve_type(env, ty)
  if !type_may_contain_scoped_ref_hint(resolved) {
    return finish(false)
  }
  match scoped_ref_cache_lookup(env, resolved) {
    Some(hit) => {
      if env.scoped_ref_profile_enabled {
        env.scoped_ref_contains_cache_hits += 1
      }
      return finish(hit)
    }
    None =>
      if env.scoped_ref_profile_enabled {
        env.scoped_ref_contains_cache_misses += 1
      }
  }
  let visiting : Map[String, Bool] = {}
  // Use name-based cache instead of structural-hash-based cache to avoid
  // expensive O(type_size) hash/equality on large Type values.
  let name_cache : Map[String, Bool] = {}
  let result = type_contains_scoped_ref_inner_fast(
    env, resolved, visiting, name_cache,
  )
  scoped_ref_cache_store(env, resolved, result)
  finish(result)
}

///|
/// Fast version of type_contains_scoped_ref_inner that uses name-based caching
/// instead of structural-hash-based caching.  The old approach used
/// `visiting_types: Map[Int, Array[Type]]` and `local_cache: Map[Int,
/// Array[ScopedRefContainsCacheEntry]]` keyed by `ty.structural_hash()`, causing
/// O(type_size) hash+equality per call — catastrophic for large enum types.
/// Named-type cycles are caught by `visiting: Map[String, Bool]`, so the
/// expensive `visiting_types` is unnecessary.
fn type_contains_scoped_ref_inner_fast(
  env : TypeEnv,
  ty : @core.Type,
  visiting : Map[String, Bool],
  name_cache : Map[String, Bool],
) -> Bool raise TypeError {
  match ty {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::Char
    | @core.Type::String
    | @core.Type::Path
    | @core.Type::PromptText
    | @core.Type::Unit
    | @core.Type::Infer
    | @core.Type::StringBuilder
    | @core.Type::Bytes
    | @core.Type::V128
    | @core.Type::Param(_)
    | @core.Type::Var(_)
    | @core.Type::Never => false
    @core.Type::Named(name~, args~) =>
      if name == "Ref" {
        true
      } else {
        // Check name-based cache first (O(1) string hash, not O(type_size))
        match name_cache.get(name) {
          Some(cached) => cached
          None =>
            if visiting.contains(name) {
              false
            } else {
              // Check args first
              let mut hit_from_args = false
              for arg in args {
                if type_contains_scoped_ref_inner_fast(
                    env, arg, visiting, name_cache,
                  ) {
                  hit_from_args = true
                  break
                }
              }
              if hit_from_args {
                name_cache[name] = true
                true
              } else {
                visiting[name] = true
                let found = match env.get_type_alias(name) {
                  Some(type_alias) =>
                    if type_alias.params.length() != args.length() {
                      false
                    } else {
                      let mapping : Map[String, @core.Type] = {}
                      for i in 0..<type_alias.params.length() {
                        mapping[type_alias.params[i]] = args[i]
                      }
                      type_contains_scoped_ref_inner_fast(
                        env,
                        substitute_type(type_alias.target, mapping),
                        visiting,
                        name_cache,
                      )
                    }
                  None =>
                    match env.get_struct(name) {
                      Some(struct_def) =>
                        if struct_def.params.length() != args.length() {
                          false
                        } else {
                          let mapping : Map[String, @core.Type] = {}
                          for i in 0..<struct_def.params.length() {
                            mapping[struct_def.params[i]] = args[i]
                          }
                          let mut hit = false
                          for field in struct_def.fields {
                            let field_ty = substitute_type(field.ty, mapping)
                            if type_contains_scoped_ref_inner_fast(
                                env, field_ty, visiting, name_cache,
                              ) {
                              hit = true
                              break
                            }
                          }
                          hit
                        }
                      None =>
                        match env.get_enum_def(name) {
                          Some(enum_def) =>
                            if enum_def.params.length() != args.length() {
                              false
                            } else {
                              let mapping : Map[String, @core.Type] = {}
                              for i in 0..<enum_def.params.length() {
                                mapping[enum_def.params[i]] = args[i]
                              }
                              let mut hit = false
                              for ctor in enum_def.ctors {
                                for arg_ty in ctor.args {
                                  let payload_ty = substitute_type(
                                    arg_ty, mapping,
                                  )
                                  if type_contains_scoped_ref_inner_fast(
                                      env, payload_ty, visiting, name_cache,
                                    ) {
                                    hit = true
                                    break
                                  }
                                }
                                if hit {
                                  break
                                }
                              }
                              hit
                            }
                          None => false
                        }
                    }
                }
                visiting.remove(name)
                name_cache[name] = found
                found
              }
            }
        }
      }
    @core.Type::Tuple(items) => {
      for item in items {
        if type_contains_scoped_ref_inner_fast(env, item, visiting, name_cache) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) | @core.Type::Variant(fields) => {
      for _, value in fields {
        if type_contains_scoped_ref_inner_fast(env, value, visiting, name_cache) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) =>
      type_contains_scoped_ref_inner_fast(env, inner, visiting, name_cache)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      type_contains_scoped_ref_inner_fast(env, inner, visiting, name_cache)
    @core.Type::Func(params~, ret~, ..) => {
      if type_contains_scoped_ref_inner_fast(env, ret, visiting, name_cache) {
        return true
      }
      for param in params {
        if type_contains_scoped_ref_inner_fast(
            env,
            param.ty,
            visiting,
            name_cache,
          ) {
          return true
        }
      }
      false
    }
  }
}

///|
fn ensure_no_scoped_ref_return_escape(
  env : TypeEnv,
  ret_ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if !env.scoped_ref_checks_enabled {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_return_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_return_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  if type_contains_scoped_ref(env, ret_ty) {
    finish()
    raise TypeError::ScopedRefEscape(context="function return", span~)
  }
  finish()
}

///|
fn ensure_no_toplevel_scoped_ref_escape(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if !env.scoped_ref_checks_enabled {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_toplevel_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_toplevel_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Func(ret~, ..) =>
      if type_contains_scoped_ref(env, ret) {
        finish()
        raise TypeError::ScopedRefEscape(
          context="top-level function return",
          span~,
        )
      }
    _ =>
      if type_contains_scoped_ref(env, resolved) {
        finish()
        raise TypeError::ScopedRefEscape(context="top-level binding", span~)
      }
  }
  finish()
}

///|
fn type_equal(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  unify_types(env, a, b)
}

///|
pub enum ApiVersionBump {
  Patch
  Minor
  Major
} derive(Debug, Eq)

///|
pub impl Show for ApiVersionBump with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
fn semver_init() -> ApiSemver {
  ApiSemver::{ major: 1, minor: 0, patch: 0 }
}

///|
fn semver_apply(version : ApiSemver, bump : ApiVersionBump) -> ApiSemver {
  match bump {
    ApiVersionBump::Patch =>
      ApiSemver::{
        major: version.major,
        minor: version.minor,
        patch: version.patch + 1,
      }
    ApiVersionBump::Minor =>
      ApiSemver::{ major: version.major, minor: version.minor + 1, patch: 0 }
    ApiVersionBump::Major =>
      ApiSemver::{ major: version.major + 1, minor: 0, patch: 0 }
  }
}

///|
fn effect_atom_key(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => "C:" + name
    @core.EffectAtom::Var(name) => "V:" + name
  }
}

///|
fn effects_subset(
  small : Array[@core.EffectAtom],
  large : Array[@core.EffectAtom],
) -> Bool {
  let large_keys : Map[String, Bool] = {}
  for effect in large {
    large_keys[effect_atom_key(effect)] = true
  }
  for effect in small {
    if !large_keys.contains(effect_atom_key(effect)) {
      return false
    }
  }
  true
}

///|
fn trait_bounds_subset(
  env : TypeEnv,
  small : Array[String],
  large : Array[String],
) -> Bool {
  let required = dedup_trait_bounds(small)
  let available = dedup_trait_bounds(large)
  for bound in required {
    if !trait_bound_satisfied(env, available, bound) {
      return false
    }
  }
  true
}

///|
fn try_type_equal(env : TypeEnv, left : @core.Type, right : @core.Type) -> Bool {
  let result : Result[Bool, TypeError] = try? type_equal(env, left, right)
  match result {
    Ok(v) => v
    Err(_) => false
  }
}

///|
pub fn is_type_subtype(
  env : TypeEnv,
  sub : @core.Type,
  sup : @core.Type,
) -> Bool {
  let left = resolve_type(env, sub)
  let right = resolve_type(env, sup)
  if try_type_equal(env, left, right) {
    return true
  }
  match (left, right) {
    (_, @core.Type::Named(name=trait_name, args=[])) if env.has_trait(
        trait_name,
      ) => type_implements_trait(env, left, trait_name)
    (@core.Type::Tuple(sub_items), @core.Type::Tuple(sup_items)) =>
      if sub_items.length() != sup_items.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_items.length() {
          if !is_type_subtype(env, sub_items[i], sup_items[i]) {
            ok = false
            break
          }
        }
        ok
      }
    (@core.Type::Record(sub_fields), @core.Type::Record(sup_fields)) => {
      let mut ok = true
      for name, sup_ty in sup_fields {
        match sub_fields.get(name) {
          Some(sub_ty) =>
            if !is_type_subtype(env, sub_ty, sup_ty) {
              ok = false
              break
            }
          None => {
            ok = false
            break
          }
        }
      }
      ok
    }
    (@core.Type::Array(sub_inner), @core.Type::Array(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::Set(sub_inner), @core.Type::Set(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::Map(sub_key, sub_inner), @core.Type::Map(sup_key, sup_inner)) =>
      is_type_subtype(env, sub_key, sup_key) &&
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::ArrayBuilder(sub_inner), @core.Type::ArrayBuilder(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (
      @core.Type::MapBuilder(sub_key, sub_inner),
      @core.Type::MapBuilder(sup_key, sup_inner),
    ) =>
      is_type_subtype(env, sub_key, sup_key) &&
      is_type_subtype(env, sub_inner, sup_inner)
    (
      @core.Type::Func(params=sub_params, ret=sub_ret, effects=sub_effects),
      @core.Type::Func(params=sup_params, ret=sup_ret, effects=sup_effects),
    ) =>
      if sub_params.length() != sup_params.length() {
        false
      } else if !effects_subset(sub_effects, sup_effects) {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_params.length() {
          let sub_param = sub_params[i]
          let sup_param = sup_params[i]
          if sub_param.label != sup_param.label {
            ok = false
            break
          }
          if !@core.ParamLabel::is_positional(sub_param.label) &&
            sub_param.name != sup_param.name {
            ok = false
            break
          }
          if !trait_bounds_subset(env, sub_param.bounds, sup_param.bounds) {
            ok = false
            break
          }
          // Function parameter types are contravariant:
          // new <: old requires old_param <: new_param
          if !is_type_subtype(env, sup_param.ty, sub_param.ty) {
            ok = false
            break
          }
        }
        ok && is_type_subtype(env, sub_ret, sup_ret)
      }
    _ => false
  }
}

///|
pub fn classify_function_api_change(
  env : TypeEnv,
  old_ty : @core.Type,
  new_ty : @core.Type,
) -> ApiVersionBump {
  let check_minor_env = clone_env(env)
  if is_type_subtype(check_minor_env, new_ty, old_ty) {
    let check_patch_env = clone_env(env)
    if is_type_subtype(check_patch_env, old_ty, new_ty) {
      ApiVersionBump::Patch
    } else {
      ApiVersionBump::Minor
    }
  } else {
    ApiVersionBump::Major
  }
}

///|
/// Completion helper: true if param type can accept receiver type.
pub fn completion_param_matches(
  env : TypeEnv,
  receiver : @core.Type,
  param : @core.Type,
) -> Bool {
  let recv = normalize_type(env, receiver) catch { _ => receiver }
  let param_ty = normalize_type(env, param) catch { _ => param }
  match param_ty {
    @core.Type::Var(_) | @core.Type::Param(_) => true
    _ =>
      match recv {
        @core.Type::Var(_) | @core.Type::Param(_) => true
        _ => type_equal(env, recv, param_ty) catch { _ => false }
      }
  }
}

///|
fn unify_pair_cache_key(left : @core.Type, right : @core.Type) -> (Int, Int) {
  (left.structural_hash(), right.structural_hash())
}

///|
fn type_has_unification_var(ty : @core.Type) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Var(_) => true
      _ => false
    }
  })
}

///|
fn unify_pair_cacheable(left : @core.Type, right : @core.Type) -> Bool {
  if type_has_unification_var(left) || type_has_unification_var(right) {
    false
  } else {
    match (left, right) {
      (@core.Type::Named(..), _) | (_, @core.Type::Named(..)) => true
      (@core.Type::Tuple(_), @core.Type::Tuple(_))
      | (@core.Type::Record(_), @core.Type::Record(_))
      | (@core.Type::Array(_), @core.Type::Array(_))
      | (@core.Type::Set(_), @core.Type::Set(_))
      | (@core.Type::Map(_, _), @core.Type::Map(_, _))
      | (@core.Type::ArrayBuilder(_), @core.Type::ArrayBuilder(_))
      | (@core.Type::MapBuilder(_, _), @core.Type::MapBuilder(_, _))
      | (@core.Type::Variant(_), @core.Type::Variant(_))
      | (@core.Type::Func(..), @core.Type::Func(..)) =>
        type_has_named_node(left) || type_has_named_node(right)
      _ => false
    }
  }
}

///|
fn unify_types(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  let cache : Map[(Int, Int), Bool] = {}
  unify_types_inner(env, a, b, cache)
}

///|
fn unify_types_inner(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
  cache : Map[(Int, Int), Bool],
) -> Bool raise TypeError {
  let left = resolve_type(env, a)
  let right = resolve_type(env, b)
  // Fast identity check for common types.
  // IMPORTANT: Do NOT use `left == right` here — MoonBit's structural equality
  // on Variant/Record types triggers Map::Eq::equal → contains_kv which is
  // O(type_size²) for large enums (e.g. Expr with 35 constructors).
  // Instead, check only cheap discriminant cases and let the match arms below
  // handle complex types via recursive unification.
  match (left, right) {
    (@core.Type::Int, @core.Type::Int)
    | (@core.Type::Float, @core.Type::Float)
    | (@core.Type::Double, @core.Type::Double)
    | (@core.Type::Bool, @core.Type::Bool)
    | (@core.Type::Char, @core.Type::Char)
    | (@core.Type::String, @core.Type::String)
    | (@core.Type::Path, @core.Type::Path)
    | (@core.Type::PromptText, @core.Type::PromptText)
    | (@core.Type::Unit, @core.Type::Unit)
    | (@core.Type::Never, @core.Type::Never)
    | (@core.Type::StringBuilder, @core.Type::StringBuilder)
    | (@core.Type::Bytes, @core.Type::Bytes)
    | (@core.Type::V128, @core.Type::V128) => return true
    (@core.Type::Named(name=an, args=aa), @core.Type::Named(name=bn, args=bb)) =>
      if an == bn && aa.is_empty() && bb.is_empty() {
        return true
      }
    (@core.Type::Var(a_id), @core.Type::Var(b_id)) =>
      if a_id == b_id {
        return true
      }
    (@core.Type::Param(a_name), @core.Type::Param(b_name)) =>
      if a_name == b_name {
        return true
      }
    _ => ()
  }
  let subs_size_before = env.subs.length()
  let effect_subs_size_before = env.effect_subs.length()
  let cacheable = unify_pair_cacheable(left, right)
  let cache_key : (Int, Int)? = if cacheable {
    let key = unify_pair_cache_key(left, right)
    match cache.get(key) {
      Some(hit) => return hit
      None => ()
    }
    // Recursive enum expansion can compare the same structural pair before the
    // outer comparison finishes. Treat the active pair coinductively; a later
    // mismatch in the same comparison overwrites this optimistic entry.
    cache[key] = true
    Some(key)
  } else {
    None
  }
  let result = match (left, right) {
    (@core.Type::Never, _) => true
    (_, @core.Type::Never) => true
    (@core.Type::Named(name=an, args=aa), @core.Type::Named(name=bn, args=bb)) =>
      if an == bn {
        if aa.length() != bb.length() {
          false
        } else {
          let mut ok = true
          for i in 0..<aa.length() {
            if !unify_types_inner(env, aa[i], bb[i], cache) {
              ok = false
              break
            }
          }
          ok
        }
      } else {
        let nl = normalize_type_expand_enum(env, left)
        let nr = normalize_type_expand_enum(env, right)
        // If both are still Named after expansion (opaque types), they can't unify
        match (nl, nr) {
          (@core.Type::Named(..), @core.Type::Named(..)) => false
          _ => unify_types_inner(env, nl, nr, cache)
        }
      }
    (@core.Type::Var(id), t) => bind_var(env, id, t)
    (t, @core.Type::Var(id)) => bind_var(env, id, t)
    (@core.Type::Param(a0), @core.Type::Param(b0)) => a0 == b0
    (@core.Type::Param(_), _) => false
    (_, @core.Type::Param(_)) => false
    (@core.Type::Named(..), _) => {
      let nl = normalize_type_expand_enum(env, left)
      // If normalization didn't change the type (opaque Named), it can't unify
      match nl {
        @core.Type::Named(..) => false
        _ => unify_types_inner(env, nl, right, cache)
      }
    }
    (_, @core.Type::Named(..)) => {
      let nr = normalize_type_expand_enum(env, right)
      match nr {
        @core.Type::Named(..) => false
        _ => unify_types_inner(env, left, nr, cache)
      }
    }
    (@core.Type::Int, @core.Type::Int) => true
    (@core.Type::Float, @core.Type::Float) => true
    (@core.Type::Double, @core.Type::Double) => true
    (@core.Type::Bool, @core.Type::Bool) => true
    (@core.Type::Char, @core.Type::Char) => true
    (@core.Type::String, @core.Type::String) => true
    (@core.Type::Path, @core.Type::Path) => true
    (@core.Type::PromptText, @core.Type::PromptText) => true
    (@core.Type::String, @core.Type::PromptText) => true
    (@core.Type::PromptText, @core.Type::String) => true
    (@core.Type::Unit, @core.Type::Unit) => true
    (@core.Type::Tuple(xs), @core.Type::Tuple(ys)) =>
      if xs.length() != ys.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<xs.length() {
          if !unify_types_inner(env, xs[i], ys[i], cache) {
            ok = false
            break
          }
        }
        ok
      }
    (@core.Type::Record(ax), @core.Type::Record(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if !unify_types_inner(env, ty, other, cache) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (@core.Type::Array(ae), @core.Type::Array(be)) =>
      unify_types_inner(env, ae, be, cache)
    (@core.Type::Set(ae), @core.Type::Set(be)) =>
      unify_types_inner(env, ae, be, cache)
    (@core.Type::Map(ak, av), @core.Type::Map(bk, bv)) =>
      unify_types_inner(env, ak, bk, cache) &&
      unify_types_inner(env, av, bv, cache)
    (@core.Type::ArrayBuilder(ae), @core.Type::ArrayBuilder(be)) =>
      unify_types_inner(env, ae, be, cache)
    (@core.Type::MapBuilder(ak, av), @core.Type::MapBuilder(bk, bv)) =>
      unify_types_inner(env, ak, bk, cache) &&
      unify_types_inner(env, av, bv, cache)
    (@core.Type::StringBuilder, @core.Type::StringBuilder) => true
    (@core.Type::Bytes, @core.Type::Bytes) => true
    (@core.Type::V128, @core.Type::V128) => true
    (@core.Type::Variant(ax), @core.Type::Variant(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if !unify_types_inner(env, ty, other, cache) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (
      @core.Type::Func(params=pa, ret=ra, effects=ea),
      @core.Type::Func(params=pb, ret=rb, effects=eb),
    ) =>
      if pa.length() != pb.length() {
        false
      } else if !unify_effects(env, ea, eb) {
        false
      } else if !unify_types_inner(env, ra, rb, cache) {
        false
      } else {
        let mut ok = true
        for i in 0..<pa.length() {
          if !param_unify(env, pa[i], pb[i], cache) {
            ok = false
            break
          }
        }
        ok
      }
    _ => false
  }
  match cache_key {
    Some(key) =>
      if env.subs.length() == subs_size_before &&
        env.effect_subs.length() == effect_subs_size_before {
        if cache.length() < 8192 || cache.contains(key) {
          cache[key] = result
        }
      }
    None => ()
  }
  result
}

///|
fn param_unify(
  env : TypeEnv,
  a : @core.FuncParam,
  b : @core.FuncParam,
  cache : Map[(Int, Int), Bool],
) -> Bool raise TypeError {
  if a.label != b.label {
    return false
  }
  if !@core.ParamLabel::is_positional(a.label) && a.name != b.name {
    return false
  }
  if !(trait_bounds_subset(env, a.bounds, b.bounds) &&
    trait_bounds_subset(env, b.bounds, a.bounds)) {
    return false
  }
  unify_types_inner(env, a.ty, b.ty, cache)
}

///|
fn bind_var(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  let resolved = resolve_type(env, ty)
  let required_bounds = match env.var_trait_bounds.get(id) {
    Some(bounds) => bounds
    None => []
  }
  if is_num_var(env, id) {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          mark_num_var(env, other)
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          env.subs_version += 1
          true
        }
      @core.Type::Int | @core.Type::Float | @core.Type::Double => {
        for bound in required_bounds {
          if !type_implements_trait(env, resolved, bound) {
            return false
          }
        }
        env.subs[id] = resolved
        env.subs_version += 1
        true
      }
      _ => false
    }
  } else {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          env.subs_version += 1
          true
        }
      _ =>
        if occurs_in(env, id, resolved) {
          false
        } else {
          for bound in required_bounds {
            if !type_implements_trait(env, resolved, bound) {
              return false
            }
          }
          env.subs[id] = resolved
          env.subs_version += 1
          true
        }
    }
  }
}

///|
fn occurs_in(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  match resolve_type(env, ty) {
    @core.Type::Var(other) => other == id
    @core.Type::Tuple(items) => {
      for item in items {
        if occurs_in(env, id, item) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) | @core.Type::Variant(fields) => {
      for _, item in fields {
        if occurs_in(env, id, item) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) => occurs_in(env, id, inner)
    @core.Type::Map(key, inner) | @core.Type::MapBuilder(key, inner) =>
      occurs_in(env, id, key) || occurs_in(env, id, inner)
    @core.Type::Named(args~, ..) => {
      for arg in args {
        if occurs_in(env, id, arg) {
          return true
        }
      }
      false
    }
    @core.Type::Func(params~, ret~, ..) => {
      if occurs_in(env, id, ret) {
        return true
      }
      for param in params {
        if occurs_in(env, id, param.ty) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn has_alias_prefix(name : String, aliases : Map[String, @core.Ref]) -> Bool {
  let len = name.length()
  let mut dot = -1
  for i in 0..<len {
    if name.unsafe_get(i) == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  aliases.contains(name.unsafe_substring(start=0, end=dot))
}
