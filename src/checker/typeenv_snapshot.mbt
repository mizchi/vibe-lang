///|
/// Issue #476: binary snapshot of the typechecked builtins `TypeEnv`.
///
/// #427 cached the *parsed AST* of the prelude/builtin sources, removing the
/// parse cost from the `type` stage. The remaining floor is the *typecheck*
/// of those sources (`ensure_prelude_functions` + `ensure_builtin_modules`):
/// every fresh process re-runs `type_check_stmts` over the prelude + 12
/// builtin modules to rebuild the same `cached_builtins_env`.
///
/// This serializes that env's *definitional* state — exactly the maps
/// `clone_for_module` copies into each per-module env — so a fresh process can
/// deserialize the typed env and skip the typecheck entirely.
///
/// What is and isn't captured:
/// - Captured: bindings (name -> TypeScheme), enum/struct/alias defs, the
///   constructor index, effect defs, the trait graph + impls, fn API
///   versions, and purity flags (incl. the `__prelude_loaded` /
///   `__builtins_loaded` sentinels that short-circuit re-loading).
/// - Excluded: per-instance / per-module state — the session typevar counter,
///   unification subs, all caches, profiling counters, `addr_types` and
///   `inferred_effects` (both cleared by `clone_for_module`).
///
/// Typevar-id safety: builtin schemes store generalized typevar ids, but
/// `instantiate_scheme` always remaps them to fresh vars before use, so the
/// stored ids are self-contained placeholders — serializing them as-is is
/// independent of the deserializing session's `type_var_counter`.

///|
/// Snapshot encoding version. Bump on ANY change that alters the typed env
/// produced for unchanged prelude/builtin source — checker semantics changes,
/// new env fields that must be captured, or a change to this encoding. This is
/// independent of `AST_BINARY_VERSION` (serializer wire format) and
/// `AST_CACHE_PARSER_VERSION` (parser output); the cache key folds in all
/// three plus the source hash, so any of them invalidates stale snapshots.
const TYPEENV_SNAPSHOT_VERSION : Int = 1

///|
/// Marker written at the head of a snapshot blob so a truncated / foreign blob
/// is rejected (→ deserialize raises → fall back to typechecking).
const TYPEENV_SNAPSHOT_MAGIC : Int = 0x564E5631 // "VNV1"

// ---------------------------------------------------------------------------
// Small array/map helpers over the @core binary facade
// ---------------------------------------------------------------------------

///|
fn snap_write_str_array(w : @core.TypeBinWriter, xs : Array[String]) -> Unit {
  w.uint(xs.length())
  for s in xs {
    w.str(s)
  }
}

///|
fn snap_read_str_array(
  r : @core.TypeBinReader,
) -> Array[String] raise @core.BinaryDeserializeError {
  let n = r.uint()
  let xs : Array[String] = []
  for _i in 0..<n {
    xs.push(r.str())
  }
  xs
}

///|
fn snap_write_int_array(w : @core.TypeBinWriter, xs : Array[Int]) -> Unit {
  w.uint(xs.length())
  for v in xs {
    w.int(v)
  }
}

///|
fn snap_read_int_array(
  r : @core.TypeBinReader,
) -> Array[Int] raise @core.BinaryDeserializeError {
  let n = r.uint()
  let xs : Array[Int] = []
  for _i in 0..<n {
    xs.push(r.int())
  }
  xs
}

///|
fn snap_write_type_array(w : @core.TypeBinWriter, xs : Array[@core.Type]) -> Unit {
  w.uint(xs.length())
  for t in xs {
    w.ty(t)
  }
}

///|
fn snap_read_type_array(
  r : @core.TypeBinReader,
) -> Array[@core.Type] raise @core.BinaryDeserializeError {
  let n = r.uint()
  let xs : Array[@core.Type] = []
  for _i in 0..<n {
    xs.push(r.ty())
  }
  xs
}

///|
/// Map[String, Array[String]] — used for trait-bound maps keyed by name.
fn snap_write_str_strarr_map(
  w : @core.TypeBinWriter,
  m : Map[String, Array[String]],
) -> Unit {
  w.uint(m.size())
  for k, v in m {
    w.str(k)
    snap_write_str_array(w, v)
  }
}

///|
fn snap_read_str_strarr_map(
  r : @core.TypeBinReader,
) -> Map[String, Array[String]] raise @core.BinaryDeserializeError {
  let n = r.uint()
  let m : Map[String, Array[String]] = {}
  for _i in 0..<n {
    let k = r.str()
    m[k] = snap_read_str_array(r)
  }
  m
}

// ---------------------------------------------------------------------------
// Value-type codecs
// ---------------------------------------------------------------------------

///|
fn snap_write_scheme(w : @core.TypeBinWriter, s : TypeScheme) -> Unit {
  snap_write_int_array(w, s.vars)
  snap_write_int_array(w, s.num_vars)
  snap_write_str_array(w, s.effect_vars)
  w.uint(s.trait_bounds.size())
  for k, v in s.trait_bounds {
    w.int(k)
    snap_write_str_array(w, v)
  }
  w.ty(s.ty)
}

///|
fn snap_read_scheme(
  r : @core.TypeBinReader,
) -> TypeScheme raise @core.BinaryDeserializeError {
  let vars = snap_read_int_array(r)
  let num_vars = snap_read_int_array(r)
  let effect_vars = snap_read_str_array(r)
  let nb = r.uint()
  let trait_bounds : Map[Int, Array[String]] = {}
  for _i in 0..<nb {
    let k = r.int()
    trait_bounds[k] = snap_read_str_array(r)
  }
  let ty = r.ty()
  { vars, num_vars, effect_vars, trait_bounds, ty }
}

///|
fn snap_write_ctor(w : @core.TypeBinWriter, c : @core.TypeCtor) -> Unit {
  w.str(c.name)
  snap_write_type_array(w, c.args)
  w.int(c.span.start)
  w.int(c.span.end)
}

///|
fn snap_read_ctor(
  r : @core.TypeBinReader,
) -> @core.TypeCtor raise @core.BinaryDeserializeError {
  let name = r.str()
  let args = snap_read_type_array(r)
  let start = r.int()
  let end = r.int()
  { name, args, span: @core.Span::{ start, end } }
}

///|
fn snap_write_enum_def(w : @core.TypeBinWriter, d : EnumDef) -> Unit {
  w.str(d.name)
  snap_write_str_array(w, d.params)
  w.uint(d.ctors.length())
  for c in d.ctors {
    snap_write_ctor(w, c)
  }
}

///|
fn snap_read_enum_def(
  r : @core.TypeBinReader,
) -> EnumDef raise @core.BinaryDeserializeError {
  let name = r.str()
  let params = snap_read_str_array(r)
  let n = r.uint()
  let ctors : Array[@core.TypeCtor] = []
  for _i in 0..<n {
    ctors.push(snap_read_ctor(r))
  }
  { name, params, ctors }
}

///|
fn snap_write_struct_def(w : @core.TypeBinWriter, d : StructDef) -> Unit {
  w.str(d.name)
  snap_write_str_array(w, d.params)
  w.uint(d.fields.length())
  for f in d.fields {
    w.str(f.name)
    w.ty(f.ty)
    w.bool(f.is_mut)
  }
}

///|
fn snap_read_struct_def(
  r : @core.TypeBinReader,
) -> StructDef raise @core.BinaryDeserializeError {
  let name = r.str()
  let params = snap_read_str_array(r)
  let n = r.uint()
  let fields : Array[StructFieldDef] = []
  for _i in 0..<n {
    let fname = r.str()
    let fty = r.ty()
    let is_mut = r.bool()
    fields.push({ name: fname, ty: fty, is_mut })
  }
  { name, params, fields }
}

///|
fn snap_write_type_alias(w : @core.TypeBinWriter, a : TypeAlias) -> Unit {
  w.str(a.name)
  snap_write_str_array(w, a.params)
  w.ty(a.target)
}

///|
fn snap_read_type_alias(
  r : @core.TypeBinReader,
) -> TypeAlias raise @core.BinaryDeserializeError {
  let name = r.str()
  let params = snap_read_str_array(r)
  let target = r.ty()
  { name, params, target }
}

///|
fn snap_write_ctor_info(w : @core.TypeBinWriter, c : CtorInfo) -> Unit {
  w.str(c.type_name)
  snap_write_str_array(w, c.params)
  w.ty(c.payload)
}

///|
fn snap_read_ctor_info(
  r : @core.TypeBinReader,
) -> CtorInfo raise @core.BinaryDeserializeError {
  let type_name = r.str()
  let params = snap_read_str_array(r)
  let payload = r.ty()
  { type_name, params, payload }
}

///|
fn snap_write_effect_def(w : @core.TypeBinWriter, d : @core.EffectDef_) -> Unit {
  w.str(d.name)
  snap_write_str_array(w, d.params)
  w.uint(d.ops.size())
  for k, sig in d.ops {
    w.str(k)
    snap_write_type_array(w, sig.params)
    w.ty(sig.ret)
  }
}

///|
fn snap_read_effect_def(
  r : @core.TypeBinReader,
) -> @core.EffectDef_ raise @core.BinaryDeserializeError {
  let name = r.str()
  let params = snap_read_str_array(r)
  let n = r.uint()
  let ops : Map[String, @core.EffectOpSig] = {}
  for _i in 0..<n {
    let k = r.str()
    let pparams = snap_read_type_array(r)
    let ret = r.ty()
    ops[k] = { params: pparams, ret }
  }
  { name, params, ops }
}

///|
fn snap_trait_origin_tag(o : TraitOrigin) -> Int {
  match o {
    TraitOrigin::DefinedHere => 0
    TraitOrigin::Imported => 1
    TraitOrigin::PreludeSeed => 2
  }
}

///|
fn snap_trait_origin_of(
  tag : Int,
) -> TraitOrigin raise @core.BinaryDeserializeError {
  match tag {
    0 => TraitOrigin::DefinedHere
    1 => TraitOrigin::Imported
    2 => TraitOrigin::PreludeSeed
    _ => raise @core.BinaryDeserializeError::UnknownTag("TraitOrigin", tag.to_byte())
  }
}

///|
fn snap_write_trait_def(w : @core.TypeBinWriter, d : TraitDefInfo) -> Unit {
  snap_write_str_array(w, d.supertraits)
  w.bool(d.open_impl)
  w.uint(snap_trait_origin_tag(d.origin))
}

///|
fn snap_read_trait_def(
  r : @core.TypeBinReader,
) -> TraitDefInfo raise @core.BinaryDeserializeError {
  let supertraits = snap_read_str_array(r)
  let open_impl = r.bool()
  let origin = snap_trait_origin_of(r.uint())
  { supertraits, open_impl, origin }
}

///|
fn snap_write_trait_impl(w : @core.TypeBinWriter, d : TraitImplDef) -> Unit {
  snap_write_str_array(w, d.type_params)
  snap_write_str_strarr_map(w, d.type_bounds)
  w.ty(d.target)
}

///|
fn snap_read_trait_impl(
  r : @core.TypeBinReader,
) -> TraitImplDef raise @core.BinaryDeserializeError {
  let type_params = snap_read_str_array(r)
  let type_bounds = snap_read_str_strarr_map(r)
  let target = r.ty()
  { type_params, type_bounds, target }
}

///|
fn snap_purity_tier_tag(t : TopLevelPurityTier) -> Int {
  match t {
    TopLevelPurityTier::Pure => 0
    TopLevelPurityTier::StateLocal => 1
    TopLevelPurityTier::Impure => 2
  }
}

///|
fn snap_purity_tier_of(
  tag : Int,
) -> TopLevelPurityTier raise @core.BinaryDeserializeError {
  match tag {
    0 => TopLevelPurityTier::Pure
    1 => TopLevelPurityTier::StateLocal
    2 => TopLevelPurityTier::Impure
    _ =>
      raise @core.BinaryDeserializeError::UnknownTag(
        "TopLevelPurityTier", tag.to_byte(),
      )
  }
}

// ---------------------------------------------------------------------------
// Env-level serialize / deserialize
// ---------------------------------------------------------------------------

///|
/// Collect a (possibly scoped) ScopedMap into a flat list of entries.
fn[V] snap_scoped_entries(m : @scoped_map.ScopedMap[V]) -> Array[(String, V)] {
  let out : Array[(String, V)] = []
  m.copy().iter2().each((k, v) => out.push((k, v)))
  out
}

///|
/// Serialize the definitional state of a typechecked builtins env — exactly
/// the maps `clone_for_module` propagates to per-module envs.
pub fn serialize_builtins_env(env : TypeEnv) -> Bytes {
  let w = @core.TypeBinWriter::new()
  w.uint(TYPEENV_SNAPSHOT_MAGIC)
  w.uint(TYPEENV_SNAPSHOT_VERSION)

  // bindings : ScopedMap[TypeScheme]
  let bindings = snap_scoped_entries(env.bindings)
  w.uint(bindings.length())
  for entry in bindings {
    w.str(entry.0)
    snap_write_scheme(w, entry.1)
  }

  // enum_defs
  w.uint(env.enum_defs.size())
  for k, v in env.enum_defs {
    w.str(k)
    snap_write_enum_def(w, v)
  }

  // struct_defs
  w.uint(env.struct_defs.size())
  for k, v in env.struct_defs {
    w.str(k)
    snap_write_struct_def(w, v)
  }

  // type_aliases
  w.uint(env.type_aliases.size())
  for k, v in env.type_aliases {
    w.str(k)
    snap_write_type_alias(w, v)
  }

  // ctor_index
  w.uint(env.ctor_index.size())
  for k, v in env.ctor_index {
    w.str(k)
    snap_write_ctor_info(w, v)
  }

  // effect_defs
  w.uint(env.effect_defs.size())
  for k, v in env.effect_defs {
    w.str(k)
    snap_write_effect_def(w, v)
  }

  // trait_state.traits
  w.uint(env.trait_state.traits.size())
  for k, v in env.trait_state.traits {
    w.str(k)
    snap_write_trait_def(w, v)
  }

  // trait_state.trait_impls : Map[String, Array[TraitImplDef]]
  w.uint(env.trait_state.trait_impls.size())
  for k, impls in env.trait_state.trait_impls {
    w.str(k)
    w.uint(impls.length())
    for d in impls {
      snap_write_trait_impl(w, d)
    }
  }

  // fn_versions : Map[String, ApiSemver]
  w.uint(env.fn_versions.size())
  for k, v in env.fn_versions {
    w.str(k)
    w.uint(v.major)
    w.uint(v.minor)
    w.uint(v.patch)
  }

  // purities : ScopedMap[Bool]
  let purities = snap_scoped_entries(env.purities)
  w.uint(purities.length())
  for entry in purities {
    w.str(entry.0)
    w.bool(entry.1)
  }

  // purity_tiers : ScopedMap[TopLevelPurityTier]
  let tiers = snap_scoped_entries(env.purity_tiers)
  w.uint(tiers.length())
  for entry in tiers {
    w.str(entry.0)
    w.uint(snap_purity_tier_tag(entry.1))
  }
  w.to_bytes()
}

///|
/// Reconstruct a builtins seed env from a snapshot. The result is equivalent
/// to `prelude_seed.clone_for_module()` + `ensure_builtin_modules(...)`, but
/// wired to a fresh session (fresh typevar counter, empty caches).
pub fn deserialize_builtins_env(
  session : TypecheckSession,
  bytes : Bytes,
) -> TypeEnv raise @core.BinaryDeserializeError {
  let r = @core.TypeBinReader::new(bytes)
  if r.uint() != TYPEENV_SNAPSHOT_MAGIC {
    raise @core.BinaryDeserializeError::BadMagic
  }
  let version = r.uint()
  if version != TYPEENV_SNAPSHOT_VERSION {
    raise @core.BinaryDeserializeError::UnsupportedVersion(version)
  }
  let env = session.new_env()
  // new_env() pre-registers builtin effects; the snapshot is authoritative.
  env.effect_defs.clear()

  // bindings
  let nb = r.uint()
  for _i in 0..<nb {
    let k = r.str()
    env.bindings[k] = snap_read_scheme(r)
  }
  // enum_defs
  let ne = r.uint()
  for _i in 0..<ne {
    let k = r.str()
    env.enum_defs[k] = snap_read_enum_def(r)
  }
  // struct_defs
  let ns = r.uint()
  for _i in 0..<ns {
    let k = r.str()
    env.struct_defs[k] = snap_read_struct_def(r)
  }
  // type_aliases
  let na = r.uint()
  for _i in 0..<na {
    let k = r.str()
    env.type_aliases[k] = snap_read_type_alias(r)
  }
  // ctor_index
  let nc = r.uint()
  for _i in 0..<nc {
    let k = r.str()
    env.ctor_index[k] = snap_read_ctor_info(r)
  }
  // effect_defs
  let nf = r.uint()
  for _i in 0..<nf {
    let k = r.str()
    env.effect_defs[k] = snap_read_effect_def(r)
  }
  // trait_state.traits
  let nt = r.uint()
  for _i in 0..<nt {
    let k = r.str()
    env.trait_state.traits[k] = snap_read_trait_def(r)
  }
  // trait_state.trait_impls
  let ni = r.uint()
  for _i in 0..<ni {
    let k = r.str()
    let m = r.uint()
    let impls : Array[TraitImplDef] = []
    for _j in 0..<m {
      impls.push(snap_read_trait_impl(r))
    }
    env.trait_state.trait_impls[k] = impls
  }
  // fn_versions
  let nv = r.uint()
  for _i in 0..<nv {
    let k = r.str()
    let major = r.uint()
    let minor = r.uint()
    let patch = r.uint()
    env.fn_versions[k] = { major, minor, patch }
  }
  // purities
  let np = r.uint()
  for _i in 0..<np {
    let k = r.str()
    env.purities[k] = r.bool()
  }
  // purity_tiers
  let npt = r.uint()
  for _i in 0..<npt {
    let k = r.str()
    env.purity_tiers[k] = snap_purity_tier_of(r.uint())
  }
  env
}
