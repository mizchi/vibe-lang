///|
/// Cache for pure test results.
pub enum TestOutcome {
  Passed(@core.Value)
  Failed(String)
} derive(Show, Eq)

///|
pub struct TestCacheEntry {
  deps : Map[String, String]
  outcome : TestOutcome
} derive(Show, Eq)

///|
pub struct TestCache {
  entries : Map[String, TestCacheEntry]
} derive(Show, Eq)

///|
pub fn TestCache::new() -> TestCache {
  { entries: {} }
}

///|
pub fn TestCache::get(self : TestCache, key : String) -> TestCacheEntry? {
  self.entries.get(key)
}

///|
pub fn TestCache::set(
  self : TestCache,
  key : String,
  entry : TestCacheEntry,
) -> Unit {
  self.entries[key] = entry
}

///|
pub fn TestCache::len(self : TestCache) -> Int {
  self.entries.length()
}
