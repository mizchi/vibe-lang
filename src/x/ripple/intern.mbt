///|
/// InternId is a lightweight identifier for interned values.
/// Same value always gets the same ID, enabling O(1) comparison.
pub(all) struct InternId(Int) derive(Eq, Compare, Hash, Show)

///|
/// Get the raw integer value of the InternId.
pub fn InternId::get(self : InternId) -> Int {
  self.0
}

///|
/// Create an InternId from a raw integer.
/// Warning: Only use this if you know the ID is valid.
pub fn InternId::from_raw(value : Int) -> InternId {
  InternId(value)
}

///|
/// Intern stores deduplicated values and assigns stable IDs.
/// - Same value always returns same ID
/// - ID can be used to retrieve original value
/// - Useful for strings, symbols, AST nodes
pub struct Intern[V] {
  /// Unique index for this ingredient
  ingredient_index : Int
  /// Durability (typically High since interned values rarely change)
  durability : Durability
  /// Value -> ID mapping
  value_to_id : @hashmap.HashMap[V, InternId]
  /// ID -> Value mapping (for reverse lookup)
  id_to_value : Array[V]
  /// Revision when this intern was last modified
  mut changed_at : Revision
}

///|
/// Create a new Intern with the given ingredient index.
/// Default durability is High (interned values rarely change).
pub fn[V] Intern::new(ingredient_index : Int) -> Intern[V] {
  {
    ingredient_index,
    durability: Durability::High,
    value_to_id: @hashmap.new(),
    id_to_value: [],
    changed_at: Revision::zero(),
  }
}

///|
/// Create a new Intern with custom durability.
pub fn[V] Intern::new_with_durability(
  ingredient_index : Int,
  durability : Durability,
) -> Intern[V] {
  {
    ingredient_index,
    durability,
    value_to_id: @hashmap.new(),
    id_to_value: [],
    changed_at: Revision::zero(),
  }
}

///|
/// Get the ingredient index.
pub fn[V] Intern::get_index(self : Intern[V]) -> Int {
  self.ingredient_index
}

///|
/// Get the durability of this intern.
pub fn[V] Intern::get_durability(self : Intern[V]) -> Durability {
  self.durability
}

///|
/// Intern a value and return its ID.
/// If the value was already interned, returns the existing ID.
/// Records a dependency if there's an active query.
pub fn[V : Hash + Eq] Intern::intern(
  self : Intern[V],
  rt : Runtime,
  value : V,
) -> InternId {
  match self.value_to_id.get(value) {
    Some(id) => {
      // Value already interned, record dependency and return existing ID
      if rt.has_active_query() {
        rt.record_dependency(
          self.ingredient_index,
          id.0,
          self.changed_at,
          self.durability,
        )
        |> ignore
      }
      id
    }
    None => {
      // New value, create ID and store
      let id = InternId(self.id_to_value.length())
      self.value_to_id.set(value, id)
      self.id_to_value.push(value)
      // Update changed_at (new value added)
      self.changed_at = rt.current_revision()
      // Record dependency
      if rt.has_active_query() {
        rt.record_dependency(
          self.ingredient_index,
          id.0,
          self.changed_at,
          self.durability,
        )
        |> ignore
      }
      id
    }
  }
}

///|
/// Look up a value by its ID.
/// Returns None if the ID is invalid.
/// Records a dependency if there's an active query.
pub fn[V] Intern::lookup(self : Intern[V], rt : Runtime, id : InternId) -> V? {
  if id.0 >= 0 && id.0 < self.id_to_value.length() {
    // Record dependency
    if rt.has_active_query() {
      rt.record_dependency(
        self.ingredient_index,
        id.0,
        self.changed_at,
        self.durability,
      )
      |> ignore
    }
    Some(self.id_to_value[id.0])
  } else {
    None
  }
}

///|
/// Check if a value has been interned.
pub fn[V : Hash + Eq] Intern::contains(self : Intern[V], value : V) -> Bool {
  self.value_to_id.contains(value)
}

///|
/// Get the ID for a value without recording a dependency.
/// Returns None if the value hasn't been interned.
pub fn[V : Hash + Eq] Intern::get_id(self : Intern[V], value : V) -> InternId? {
  self.value_to_id.get(value)
}

///|
/// Get the number of interned values.
pub fn[V] Intern::len(self : Intern[V]) -> Int {
  self.id_to_value.length()
}

///|
/// Check if the intern is empty.
pub fn[V] Intern::is_empty(self : Intern[V]) -> Bool {
  self.id_to_value.is_empty()
}

///|
/// Register this intern's verifier with the runtime.
pub fn[V] Intern::register(self : Intern[V], rt : Runtime) -> Unit {
  let intern = self
  rt.register_verifier(self.ingredient_index, fn(_key_index, revision) {
    intern.changed_at.is_after(revision)
  })
}
