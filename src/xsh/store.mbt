///|
/// Content-addressed store and runtime for xsh
pub struct Store {
  values : Map[String, @core.Value]
} derive(Show, Eq)

///|
fn Store::new() -> Store {
  { values: {} }
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
  aliases : Map[String, @core.Ref]
  pure_cache : PureCache
  test_cache : TestCache
  mut type_env : @checker.TypeEnv
  mut_vars : Map[String, Bool]
  // Module cache for import resolution: hash -> Module
  module_cache : Map[String, @core.Module]
}

///|
pub fn Runtime::new(caps : @capability.CapabilitySet) -> Runtime {
  let rt = {
    store: Store::new(),
    env: {},
    addr_env: {},
    names: {},
    caps,
    aliases: {},
    pure_cache: PureCache::new(),
    test_cache: TestCache::new(),
    type_env: @checker.TypeEnv::new(),
    mut_vars: {},
    module_cache: {},
  }
  let env = @checker.TypeEnv::new()
  let _ = try! @checker.ensure_prelude_option(env)
  let _ = try! @checker.ensure_prelude_functions(env, {})
  rt.type_env = env
  let _ = try! rt.eval_module(@checker.prelude_ast())
  rt
}

///|
fn Runtime::caps(self : Runtime) -> @capability.CapabilitySet {
  self.caps
}

///|
fn Runtime::bind(self : Runtime, name : String, value : @core.Value) -> String {
  let hash = value_hash(value)
  self.store.put(hash, value)
  self.env[name] = hash
  hash
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
fn Runtime::get_by_addr(self : Runtime, addr : String) -> @core.Value? {
  self.store.get(addr)
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
fn Runtime::get_alias(self : Runtime, name : String) -> @core.Ref? {
  self.aliases.get(name)
}

///|
fn Runtime::get_name_alias(self : Runtime, name : String) -> String? {
  self.names.get(name)
}

///|
fn Runtime::pure_cache_get(self : Runtime, key : String) -> @core.Value? {
  self.pure_cache.get(key)
}

///|
fn Runtime::pure_cache_set(
  self : Runtime,
  key : String,
  value : @core.Value,
) -> Unit {
  self.pure_cache.set(key, value)
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
/// Fork runtime for test execution (isolated env, shared store/cache).
fn Runtime::fork_for_test(self : Runtime) -> Runtime {
  {
    store: self.store,
    env: clone_string_map(self.env),
    addr_env: clone_string_map(self.addr_env),
    names: clone_string_map(self.names),
    caps: self.caps,
    aliases: clone_ref_map(self.aliases),
    pure_cache: self.pure_cache,
    test_cache: self.test_cache,
    type_env: self.type_env.clone(),
    mut_vars: self.mut_vars.copy(),
    module_cache: self.module_cache,
  }
}

///|
fn Runtime::env_snapshot(self : Runtime) -> Map[String, String] {
  clone_string_map(self.env)
}

///|
fn Runtime::fork_with_env(self : Runtime, env : Map[String, String]) -> Runtime {
  {
    store: self.store,
    env: clone_string_map(env),
    addr_env: clone_string_map(self.addr_env),
    names: clone_string_map(self.names),
    caps: self.caps,
    aliases: clone_ref_map(self.aliases),
    pure_cache: self.pure_cache,
    test_cache: self.test_cache,
    type_env: self.type_env.clone(),
    mut_vars: self.mut_vars.copy(),
    module_cache: self.module_cache,
  }
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
fn clone_string_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

///|
fn clone_ref_map(src : Map[String, @core.Ref]) -> Map[String, @core.Ref] {
  let out : Map[String, @core.Ref] = {}
  for k, v in src {
    out[k] = v
  }
  out
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
    if not(live.contains(hash)) {
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
    @core.Value::String(_) => "s:"
    @core.Value::Path(_) => "p:"
    @core.Value::Unit => "u:"
    @core.Value::Tuple(_) => "t:"
    @core.Value::Record(_) => "r:"
    @core.Value::Array(_) => "a:"
    @core.Value::Map(_) => "m:"
    @core.Value::ArrayBuilder(_) => "ab:"
    @core.Value::MapBuilder(_) => "mb:"
    @core.Value::Fn(_) => "fn:"
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

///|
/// Get a cached module by hash
fn Runtime::get_module(self : Runtime, hash : String) -> @core.Module? {
  self.module_cache.get(hash)
}
