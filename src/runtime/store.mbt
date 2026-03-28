///|
/// Content-addressed store and runtime for vibe
pub struct Store {
  values : Map[String, @core.Value]
  mut next_uid : Int
} derive(Show, Eq)

///|
pub struct RuntimeFeatureFlags {
  unstable_async : Bool
  unstable_threads : Bool
} derive(Show, Eq)

///|
pub fn RuntimeFeatureFlags::new(
  unstable_async : Bool,
  unstable_threads : Bool,
) -> RuntimeFeatureFlags {
  { unstable_async, unstable_threads }
}

///|
pub fn RuntimeFeatureFlags::stable() -> RuntimeFeatureFlags {
  RuntimeFeatureFlags::new(false, false)
}

///|
pub fn RuntimeFeatureFlags::unstable_async_only() -> RuntimeFeatureFlags {
  RuntimeFeatureFlags::new(true, false)
}

///|
pub fn RuntimeFeatureFlags::unstable_threads_only() -> RuntimeFeatureFlags {
  RuntimeFeatureFlags::new(false, true)
}

///|
pub fn RuntimeFeatureFlags::is_unstable_async_enabled(
  self : RuntimeFeatureFlags,
) -> Bool {
  self.unstable_async
}

///|
pub fn RuntimeFeatureFlags::is_unstable_threads_enabled(
  self : RuntimeFeatureFlags,
) -> Bool {
  self.unstable_threads
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
pub struct ThreadChannel {
  capacity : Int
  queue : Array[String]
} derive(Show, Eq)

///|
pub struct ThreadTask {
  name : String
  mailbox : Int
  done : Bool
} derive(Show, Eq)

///|
pub struct ThreadRuntime {
  mut next_channel_id : Int
  mut next_task_id : Int
  channels : Map[String, ThreadChannel]
  tasks : Map[String, ThreadTask]
} derive(Show, Eq)

///|
fn thread_runtime_key(id : Int) -> String {
  id.to_string()
}

///|
fn ThreadRuntime::new() -> ThreadRuntime {
  { next_channel_id: 0, next_task_id: 0, channels: {}, tasks: {} }
}

///|
fn ThreadRuntime::channel_new(self : ThreadRuntime, capacity : Int) -> Int {
  let normalized = if capacity < 0 { 0 } else { capacity }
  let id = self.next_channel_id
  self.next_channel_id = id + 1
  self.channels[thread_runtime_key(id)] = { capacity: normalized, queue: [] }
  id
}

///|
fn ThreadRuntime::send(
  self : ThreadRuntime,
  channel_id : Int,
  message : String,
) -> Bool? {
  let key = thread_runtime_key(channel_id)
  match self.channels.get(key) {
    None => None
    Some(channel) =>
      if channel.queue.length() >= channel.capacity {
        Some(false)
      } else {
        channel.queue.push(message)
        self.channels[key] = channel
        Some(true)
      }
  }
}

///|
fn ThreadRuntime::recv(self : ThreadRuntime, channel_id : Int) -> String? {
  let key = thread_runtime_key(channel_id)
  match self.channels.get(key) {
    None => None
    Some(channel) =>
      if channel.queue.length() == 0 {
        Some("")
      } else {
        let next_queue = channel.queue
        let value = next_queue.remove(0)
        self.channels[key] = { capacity: channel.capacity, queue: next_queue }
        Some(value)
      }
  }
}

///|
fn ThreadRuntime::spawn(
  self : ThreadRuntime,
  name : String,
  mailbox : Int,
) -> Int? {
  let channel_key = thread_runtime_key(mailbox)
  if not(self.channels.contains(channel_key)) {
    None
  } else {
    let id = self.next_task_id
    self.next_task_id = id + 1
    self.tasks[thread_runtime_key(id)] = { name, mailbox, done: false }
    Some(id)
  }
}

///|
fn ThreadRuntime::wait(self : ThreadRuntime, task_id : Int) -> Int? {
  let key = thread_runtime_key(task_id)
  match self.tasks.get(key) {
    None => None
    Some(task) => {
      self.tasks[key] = { name: task.name, mailbox: task.mailbox, done: true }
      Some(0)
    }
  }
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
  test_cache : TestCache
  mut type_env : @checker.TypeEnv
  mut_vars : Map[String, Bool]
  thread_runtime : ThreadRuntime
  // Module cache for import resolution: hash -> Module
  module_cache : Map[String, @core.Module]
  // Evaluated module cache: hash -> evaluated Runtime (avoids redundant eval_module calls)
  import_eval_cache : Map[String, Runtime]
  perform_resume_overrides : Map[String, @core.Value]
  mut active_handle_scope : String?
  mut prelude_loaded : Bool
  mut cwd : String
  mut loop_fuel : Int
}

///|
fn default_loop_fuel() -> Int {
  100_000
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
    test_cache: TestCache::new(),
    type_env: @checker.TypeEnv::new(),
    mut_vars: {},
    thread_runtime: ThreadRuntime::new(),
    module_cache: {},
    import_eval_cache: {},
    perform_resume_overrides: {},
    active_handle_scope: None,
    prelude_loaded: false,
    cwd: @io.current_dir_or_root(),
    loop_fuel: match @io.get_env_var("VIBE_LOOP_FUEL") {
      Some(s) => {
        let n = @strconv.parse_int(s) catch { _ => default_loop_fuel() }
        if n > 0 {
          n
        } else {
          default_loop_fuel()
        }
      }
      None => default_loop_fuel()
    },
  }
  let env = @checker.TypeEnv::new()
  let _ = try! @checker.ensure_prelude_option(env)
  let _ = try! @checker.ensure_prelude_functions(env, {})
  @checker.ensure_builtin_modules(env, {})
  rt.type_env = env
  rt.ensure_prelude()
  rt
}

///|
fn Runtime::ensure_prelude(self : Runtime) -> Unit {
  if not(self.prelude_loaded) {
    let _ = try? self.eval_module(@checker.prelude_ast())
    self.prelude_loaded = true
  }
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
fn Runtime::threads_channel_new(self : Runtime, capacity : Int) -> Int {
  self.thread_runtime.channel_new(capacity)
}

///|
fn Runtime::threads_send(
  self : Runtime,
  channel_id : Int,
  message : String,
) -> Bool? {
  self.thread_runtime.send(channel_id, message)
}

///|
fn Runtime::threads_recv(self : Runtime, channel_id : Int) -> String? {
  self.thread_runtime.recv(channel_id)
}

///|
fn Runtime::threads_spawn(self : Runtime, name : String, mailbox : Int) -> Int? {
  self.thread_runtime.spawn(name, mailbox)
}

///|
fn Runtime::threads_wait(self : Runtime, task_id : Int) -> Int? {
  self.thread_runtime.wait(task_id)
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
    features: self.features,
    aliases: clone_ref_map(self.aliases),
    pure_cache: self.pure_cache,
    test_cache: self.test_cache,
    type_env: self.type_env.clone(),
    mut_vars: self.mut_vars.copy(),
    thread_runtime: self.thread_runtime,
    module_cache: self.module_cache,
    import_eval_cache: self.import_eval_cache,
    perform_resume_overrides: self.perform_resume_overrides.copy(),
    active_handle_scope: self.active_handle_scope,
    prelude_loaded: self.prelude_loaded,
    cwd: self.cwd,
    loop_fuel: self.loop_fuel,
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
    features: self.features,
    aliases: clone_ref_map(self.aliases),
    pure_cache: self.pure_cache,
    test_cache: self.test_cache,
    type_env: self.type_env.clone(),
    mut_vars: self.mut_vars.copy(),
    thread_runtime: self.thread_runtime,
    module_cache: self.module_cache,
    import_eval_cache: self.import_eval_cache,
    perform_resume_overrides: self.perform_resume_overrides.copy(),
    active_handle_scope: self.active_handle_scope,
    prelude_loaded: self.prelude_loaded,
    cwd: self.cwd,
    loop_fuel: self.loop_fuel,
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
pub fn Runtime::set_cwd(self : Runtime, cwd : String) -> Unit {
  self.cwd = cwd
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
