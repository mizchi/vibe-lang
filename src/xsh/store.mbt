///|
/// Content-addressed store and runtime for xsh
pub struct Store {
  values : Map[String, Value]
} derive(Show, Eq)

///|
pub fn Store::new() -> Store {
  { values: {} }
}

///|
pub fn Store::put(self : Store, hash : String, value : Value) -> Unit {
  self.values[hash] = value
}

///|
pub fn Store::get(self : Store, hash : String) -> Value? {
  self.values.get(hash)
}

///|
pub fn Store::contains(self : Store, hash : String) -> Bool {
  self.values.contains(hash)
}

///|
pub fn Store::len(self : Store) -> Int {
  self.values.length()
}

///|
pub fn Store::remove(self : Store, hash : String) -> Unit {
  self.values.remove(hash)
}

///|
pub struct Runtime {
  store : Store
  env : Map[String, String]
  addr_env : Map[String, String]
  names : Map[String, String]
  caps : @capability.CapabilitySet
  aliases : Map[String, Ref]
  pure_cache : PureCache
  test_cache : TestCache
  mut type_env : TypeEnv
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
    type_env: TypeEnv::new(),
  }
  let env = TypeEnv::new()
  let _ = try! ensure_prelude_option(env)
  let _ = try! ensure_prelude_functions(env, {})
  rt.type_env = env
  let _ = try! rt.eval_module(prelude_ast())
  rt
}

///|
pub fn Runtime::caps(self : Runtime) -> @capability.CapabilitySet {
  self.caps
}

///|
pub fn Runtime::bind(self : Runtime, name : String, value : Value) -> String {
  let hash = value_hash(value)
  self.store.put(hash, value)
  self.env[name] = hash
  hash
}

///|
pub fn Runtime::bind_with_addr(
  self : Runtime,
  name : String,
  addr : String,
  value : Value,
) -> Unit {
  self.store.put(addr, value)
  self.env[name] = addr
  self.addr_env[name] = addr
}

///|
pub fn Runtime::get(self : Runtime, name : String) -> Value? {
  match self.env.get(name) {
    Some(hash) => self.store.get(hash)
    None => None
  }
}

///|
pub fn Runtime::get_by_addr(self : Runtime, addr : String) -> Value? {
  self.store.get(addr)
}

///|
pub fn Runtime::get_hash(self : Runtime, name : String) -> String? {
  self.env.get(name)
}

///|
pub fn Runtime::get_addr(self : Runtime, name : String) -> String? {
  self.addr_env.get(name)
}

///|
pub fn Runtime::remove_binding(self : Runtime, name : String) -> Bool {
  let existed = self.env.contains(name)
  self.env.remove(name)
  self.addr_env.remove(name)
  existed
}

///|
pub fn Runtime::set_alias(self : Runtime, name : String, target : Ref) -> Unit {
  self.aliases[name] = target
}

///|
pub fn Runtime::get_alias(self : Runtime, name : String) -> Ref? {
  self.aliases.get(name)
}

///|
pub fn Runtime::set_name_alias(
  self : Runtime,
  name : String,
  addr : String,
) -> Unit {
  self.names[name] = addr
}

///|
pub fn Runtime::get_name_alias(self : Runtime, name : String) -> String? {
  self.names.get(name)
}

///|
pub fn Runtime::alias_count(self : Runtime) -> Int {
  self.aliases.length()
}

///|
pub fn Runtime::pure_cache_get(self : Runtime, key : String) -> Value? {
  self.pure_cache.get(key)
}

///|
pub fn Runtime::pure_cache_set(
  self : Runtime,
  key : String,
  value : Value,
) -> Unit {
  self.pure_cache.set(key, value)
}

///|
pub fn Runtime::pure_cache_len(self : Runtime) -> Int {
  self.pure_cache.len()
}

///|
pub fn Runtime::test_cache_len(self : Runtime) -> Int {
  self.test_cache.len()
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
pub fn Runtime::fork_for_test(self : Runtime) -> Runtime {
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
  }
}

///|
pub fn Runtime::env_snapshot(self : Runtime) -> Map[String, String] {
  clone_string_map(self.env)
}

///|
pub fn Runtime::fork_with_env(
  self : Runtime,
  env : Map[String, String],
) -> Runtime {
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
  }
}

///|
pub fn Runtime::type_env(self : Runtime) -> TypeEnv {
  self.type_env
}

///|
pub fn Runtime::set_type_env(self : Runtime, env : TypeEnv) -> Unit {
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
fn clone_ref_map(src : Map[String, Ref]) -> Map[String, Ref] {
  let out : Map[String, Ref] = {}
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
pub fn Runtime::store_len(self : Runtime) -> Int {
  self.store.len()
}

///|
/// Garbage collect unreferenced store entries
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
pub fn value_hash(value : Value) -> String {
  let hasher = @bit.Sha1State::new()
  hasher.update_string(value.to_string())
  hasher.finish().to_hex()
}
