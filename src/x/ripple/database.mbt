///|
/// Database is the main facade for the incremental computation system.
/// It manages the runtime, inputs, and queries.
pub struct Database {
  /// The runtime state
  runtime : Runtime
  /// Counter for assigning ingredient indices
  mut next_index : Int
}

///|
/// Create a new Database.
pub fn Database::new() -> Database {
  { runtime: Runtime::new(), next_index: 0 }
}

///|
/// Get the current revision.
pub fn Database::current_revision(self : Database) -> Revision {
  self.runtime.current_revision()
}

///|
/// Create a new Input registered with this database (default Low durability).
pub fn[K, V] Database::input(self : Database) -> Input[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Input::new(index)
}

///|
/// Create a new Input with specified durability.
pub fn[K, V] Database::input_with_durability(
  self : Database,
  durability : Durability,
) -> Input[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Input::new_with_durability(index, durability)
}

///|
/// Create a new Query registered with this database.
pub fn[K, V] Database::query(
  self : Database,
  compute : (Runtime, K) -> V,
) -> Query[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Query::new(index, compute)
}

///|
/// Get the runtime (for use with inputs and queries).
pub fn Database::runtime(self : Database) -> Runtime {
  self.runtime
}

///|
/// Create a new Intern registered with this database (default High durability).
pub fn[V] Database::intern(self : Database) -> Intern[V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Intern::new(index)
}

///|
/// Create a new Intern with specified durability.
pub fn[V] Database::intern_with_durability(
  self : Database,
  durability : Durability,
) -> Intern[V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Intern::new_with_durability(index, durability)
}

///|
/// Create a new CycleQuery with Panic strategy (same as regular Query).
pub fn[K, V] Database::cycle_query(
  self : Database,
  compute : (Runtime, K) -> V,
) -> CycleQuery[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  CycleQuery::new(index, compute)
}

///|
/// Create a new CycleQuery with a fallback value for cycle recovery.
pub fn[K, V] Database::cycle_query_with_fallback(
  self : Database,
  compute : (Runtime, K) -> V,
  fallback : V,
) -> CycleQuery[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  CycleQuery::new_with_fallback(index, compute, fallback)
}

///|
/// Create a new CycleQuery with a recovery function for cycle recovery.
pub fn[K, V] Database::cycle_query_with_recover(
  self : Database,
  compute : (Runtime, K) -> V,
  recover : (Runtime, K) -> V,
) -> CycleQuery[K, V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  CycleQuery::new_with_recover(index, compute, recover)
}

///|
/// Create a new Accumulator registered with this database.
pub fn[V] Database::accumulator(self : Database) -> Accumulator[V] {
  let index = self.next_index
  self.next_index = self.next_index + 1
  Accumulator::new(index)
}
