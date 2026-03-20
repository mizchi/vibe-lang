///|
/// InputValue stores a value along with its revision metadata.
struct InputValue[V] {
  value : V
  changed_at : Revision
}

///|
/// Input represents an external input to the incremental computation system.
/// Values can be set at any time, which increments the revision.
pub struct Input[K, V] {
  /// Unique index for this input
  ingredient_index : Int
  /// Durability of this input (how often it changes)
  durability : Durability
  /// Stored values
  values : @hashmap.HashMap[K, InputValue[V]]
  /// Hash to changed_at mapping for verifier lookup
  hash_to_changed_at : @hashmap.HashMap[Int, Revision]
}

///|
/// Create a new Input with the given ingredient index and default Low durability.
pub fn[K, V] Input::new(ingredient_index : Int) -> Input[K, V] {
  {
    ingredient_index,
    durability: Durability::Low,
    values: @hashmap.new(),
    hash_to_changed_at: @hashmap.new(),
  }
}

///|
/// Create a new Input with the given ingredient index and durability.
pub fn[K, V] Input::new_with_durability(
  ingredient_index : Int,
  durability : Durability,
) -> Input[K, V] {
  {
    ingredient_index,
    durability,
    values: @hashmap.new(),
    hash_to_changed_at: @hashmap.new(),
  }
}

///|
/// Register this input's verifier with the runtime.
/// This enables deep verify for queries that depend on this input.
pub fn[K, V] Input::register(self : Input[K, V], rt : Runtime) -> Unit {
  // Create a verifier closure that captures the hash-to-revision mapping
  // key_index is the hash of the key (as recorded in record_dependency)
  let hash_to_changed_at = self.hash_to_changed_at
  rt.register_verifier(self.ingredient_index, fn(key_index, revision) {
    // Look up the specific key's changed_at by hash
    match hash_to_changed_at.get(key_index) {
      Some(changed_at) => changed_at.is_after(revision)
      None => true // Key not found, consider it changed (conservative)
    }
  })
}

///|
/// Get the ingredient index.
pub fn[K, V] Input::get_index(self : Input[K, V]) -> Int {
  self.ingredient_index
}

///|
/// Get the durability of this input.
pub fn[K, V] Input::get_durability(self : Input[K, V]) -> Durability {
  self.durability
}

///|
/// Set a value in the input. Returns the new revision.
/// If the value hasn't changed, no revision bump occurs.
pub fn[K : Hash + Eq, V : Eq] Input::set(
  self : Input[K, V],
  rt : Runtime,
  key : K,
  value : V,
) -> Revision {
  // Check if value actually changed
  match self.values.get(key) {
    Some(existing) =>
      if existing.value == value {
        // No change, return current revision
        return rt.current_revision()
      }
    None => ()
  }
  // Value changed, increment revision with durability
  let new_revision = rt.increment_revision(self.durability)
  self.values.set(key, { value, changed_at: new_revision })
  // Update hash-to-changed_at mapping for verifier lookup
  self.hash_to_changed_at.set(key.hash(), new_revision)
  new_revision
}

///|
/// Get a value from the input. Records a dependency if there's an active query.
pub fn[K : Hash + Eq, V] Input::get(
  self : Input[K, V],
  rt : Runtime,
  key : K,
) -> V? {
  match self.values.get(key) {
    Some(entry) => {
      // Record dependency for the active query with durability
      let key_hash = key.hash()
      rt.record_dependency(
        self.ingredient_index,
        key_hash,
        entry.changed_at,
        self.durability,
      )
      |> ignore
      Some(entry.value)
    }
    None => None
  }
}

///|
/// Check if a key exists in the input.
pub fn[K : Hash + Eq, V] Input::contains(self : Input[K, V], key : K) -> Bool {
  self.values.contains(key)
}

///|
/// Get the changed_at revision for a key.
pub fn[K : Hash + Eq, V] Input::changed_at(
  self : Input[K, V],
  key : K,
) -> Revision? {
  match self.values.get(key) {
    Some(entry) => Some(entry.changed_at)
    None => None
  }
}

///|
/// Check if the input might have changed after a given revision.
pub fn[K : Hash + Eq, V] Input::maybe_changed_after(
  self : Input[K, V],
  key : K,
  revision : Revision,
) -> Bool {
  match self.values.get(key) {
    Some(entry) => entry.changed_at.is_after(revision)
    None => true // Missing key is considered "changed"
  }
}
