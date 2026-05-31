///|
/// Content-addressed store and runtime for vibe
pub struct Store {
  values : Map[String, @core.Value]
  mut next_uid : Int
} derive(Eq)

///|
pub impl Show for Store with fn output(self, logger) {
  logger.write_string("Store(values=")
  logger.write_string(self.values.length().to_string())
  logger.write_string(", next_uid=")
  logger.write_string(self.next_uid.to_string())
  logger.write_string(")")
}

///|
pub struct RuntimeFeatureFlags {
  unstable_async : Bool
} derive(Debug, Eq)

///|
pub fn RuntimeFeatureFlags::new(unstable_async : Bool) -> RuntimeFeatureFlags {
  { unstable_async, }
}

///|
pub fn RuntimeFeatureFlags::stable() -> RuntimeFeatureFlags {
  RuntimeFeatureFlags::new(false)
}

///|
pub fn RuntimeFeatureFlags::unstable_async_only() -> RuntimeFeatureFlags {
  RuntimeFeatureFlags::new(true)
}

///|
pub fn RuntimeFeatureFlags::is_unstable_async_enabled(
  self : RuntimeFeatureFlags,
) -> Bool {
  self.unstable_async
}

///|
fn Store::new() -> Store {
  { values: {}, next_uid: 0 }
}

///|
fn Store::next_unique_id(self : Store) -> String {
  let id = self.next_uid
  self.next_uid = id + 1
  "__uid:" + id.to_string()
}

///|
fn Store::put(self : Store, hash : String, value : @core.Value) -> Unit {
  self.values[hash] = value
}

///|
fn Store::get(self : Store, hash : String) -> @core.Value? {
  self.values.get(hash)
}

///|
fn Store::contains(self : Store, hash : String) -> Bool {
  self.values.contains(hash)
}

///|
fn Store::remove(self : Store, hash : String) -> Unit {
  self.values.remove(hash)
}

///|
pub struct Runtime {
  store : Store
  env : Map[String, String]
  addr_env : Map[String, String]
  names : Map[String, String]
  caps : @capability.CapabilitySet
  features : RuntimeFeatureFlags
  aliases : Map[String, @core.Ref]
  pure_cache : PureCache
  mut type_env : @checker.TypeEnv
  mut_vars : Map[String, Bool]
  // Module cache for import resolution: hash -> Module
  module_cache : Map[String, @core.Module]
  perform_resume_overrides : Map[String, @core.Value]
  active_handle_scope : String?
  mut cwd : String
}

///|
pub fn Runtime::new(caps : @capability.CapabilitySet) -> Runtime {
  Runtime::new_with_features(caps, RuntimeFeatureFlags::stable())
}

///|
pub fn Runtime::new_with_features(
  caps : @capability.CapabilitySet,
  features : RuntimeFeatureFlags,
) -> Runtime {
  let rt = {
    store: Store::new(),
    env: {},
    addr_env: {},
    names: {},
    caps,
    features,
    aliases: {},
    pure_cache: PureCache::new(),
    type_env: hook_new_type_env(),
    mut_vars: {},
    module_cache: {},
    perform_resume_overrides: {},
    active_handle_scope: None,
    cwd: @io.current_dir_or_root(),
  }
  rt.type_env = hook_init_runtime_type_env()
  rt
}

///|
pub fn Runtime::resolve_path(self : Runtime, raw : String) -> String {
  if raw.has_prefix("/") {
    @path.Path(raw).normalize().to_string()
  } else {
    @path.Path(self.cwd).join(@path.Path(raw)).normalize().to_string()
  }
}

///|
fn Runtime::caps(self : Runtime) -> @capability.CapabilitySet {
  self.caps
}

///|
pub fn Runtime::feature_flags(self : Runtime) -> RuntimeFeatureFlags {
  self.features
}

///|
fn Runtime::bind(self : Runtime, name : String, value : @core.Value) -> String {
  // Mutable builder types need unique IDs to avoid content-hash collisions
  let key = if value.is_mutable_builder() {
    self.store.next_unique_id()
  } else {
    value_hash(value)
  }
  self.store.put(key, value)
  self.env[name] = key
  key
}

///|
/// Bind a mutable variable using a stable unique ID (not content hash).
/// This ensures closures that captured this variable via env snapshot
/// will see mutations through the shared store.
fn Runtime::bind_mut(
  self : Runtime,
  name : String,
  value : @core.Value,
) -> String {
  let key = self.store.next_unique_id()
  self.store.put(key, value)
  self.env[name] = key
  key
}

///|
/// Reassign a mutable variable in-place: update the store value at
/// the existing env key so closures sharing the key see the new value.
fn Runtime::rebind_mut(
  self : Runtime,
  name : String,
  value : @core.Value,
) -> Unit {
  match self.env.get(name) {
    Some(key) => self.store.put(key, value)
    None =>
      // Fallback: bind normally if no existing key
      self.bind(name, value) |> ignore
  }
}

///|
fn Runtime::bind_with_addr(
  self : Runtime,
  name : String,
  addr : String,
  value : @core.Value,
) -> Unit {
  self.store.put(addr, value)
  self.env[name] = addr
  self.addr_env[name] = addr
}

///|
pub fn Runtime::get(self : Runtime, name : String) -> @core.Value? {
  match self.env.get(name) {
    Some(hash) => self.store.get(hash)
    None => None
  }
}

///|
pub fn Runtime::get_addr(self : Runtime, name : String) -> String? {
  self.addr_env.get(name)
}

///|
pub fn Runtime::get_hash(self : Runtime, name : String) -> String? {
  self.env.get(name)
}

///|
pub fn Runtime::remove_binding(self : Runtime, name : String) -> Bool {
  let existed = self.env.contains(name)
  self.env.remove(name)
  self.addr_env.remove(name)
  existed
}

///|
pub fn Runtime::set_alias(
  self : Runtime,
  name : String,
  target : @core.Ref,
) -> Unit {
  self.aliases[name] = target
}

///|
pub fn Runtime::pure_cache_len(self : Runtime) -> Int {
  self.pure_cache.len()
}

///|
pub fn Runtime::pure_cache_snapshot(self : Runtime) -> String {
  self.pure_cache.snapshot()
}

///|
pub fn Runtime::load_pure_cache(self : Runtime, snapshot : String) -> Unit {
  self.pure_cache.load(snapshot)
}

///|
pub fn Runtime::type_env(self : Runtime) -> @checker.TypeEnv {
  self.type_env
}

///|
pub fn Runtime::set_type_env(self : Runtime, env : @checker.TypeEnv) -> Unit {
  self.type_env = env
}

///|
pub fn Runtime::set_cwd(self : Runtime, cwd : String) -> Unit {
  self.cwd = cwd
}

///|
pub fn Runtime::store_contains(self : Runtime, hash : String) -> Bool {
  self.store.contains(hash)
}

///|
/// Garbage collect unreferenced store entries.
pub fn Runtime::gc(self : Runtime) -> Unit {
  let live : Map[String, Bool] = {}
  for _, hash in self.env {
    live[hash] = true
  }
  let to_delete : Array[String] = []
  for hash, _ in self.store.values {
    if !live.contains(hash) {
      to_delete.push(hash)
    }
  }
  for hash in to_delete {
    self.store.remove(hash)
  }
}

///|
/// Hash a value for content-addressed storage
/// Includes type tag to distinguish Float(1.0) from Double(1.0) from Int(1)
/// For Fn values, includes body hash to distinguish functions with same signature
fn value_hash(value : @core.Value) -> String {
  let hasher = @bit.Sha1State::new()
  let type_tag = match value {
    @core.Value::Int(_) => "i:"
    @core.Value::Float(_) => "f:"
    @core.Value::Double(_) => "d:"
    @core.Value::Bool(_) => "b:"
    @core.Value::Char(_) => "c:"
    @core.Value::String(_) => "s:"
    @core.Value::Path(_) => "p:"
    @core.Value::PromptText(_) => "pt:"
    @core.Value::Unit => "u:"
    @core.Value::Tuple(_) => "t:"
    @core.Value::Record(_) => "r:"
    @core.Value::Array(_) => "a:"
    @core.Value::Map(_) => "m:"
    @core.Value::Set(_) => "set:"
    @core.Value::ArrayBuilder(_) => "ab:"
    @core.Value::MapBuilder(_) => "mb:"
    @core.Value::StringBuilder(_) => "sb:"
    @core.Value::Bytes(_) => "by:"
    @core.Value::Fn(_) => "fn:"
    @core.Value::Continuation(_) => "k:"
  }
  hasher.update_string(type_tag)
  // For Fn values, include body in hash since Show only outputs params
  match value {
    @core.Value::Fn(fn_val) => {
      hasher.update_string(value.to_string())
      hasher.update_string("\nbody:")
      hasher.update_string(fn_val.body.to_string())
    }
    _ => hasher.update_string(value.to_string())
  }
  hasher.finish().to_hex()
}

///|
/// Register a module in the cache by hash
pub fn Runtime::register_module(
  self : Runtime,
  hash : String,
  mod_ast : @core.Module,
) -> Unit {
  self.module_cache.set(hash, mod_ast)
}
