///|
/// Cache for pure test results.
pub enum TestOutcome {
  Passed(@core.Value)
  Failed(String)
} derive(Eq)

///|
pub impl Show for TestOutcome with output(self, logger) {
  match self {
    TestOutcome::Passed(value) => {
      logger.write_string("Passed(")
      value.output(logger)
      logger.write_string(")")
    }
    TestOutcome::Failed(message) => {
      logger.write_string("Failed(")
      logger.write_string(message)
      logger.write_string(")")
    }
  }
}

///|
pub struct TestCacheEntry {
  deps : Map[String, String]
  outcome : TestOutcome
} derive(Eq)

///|
pub struct TestCache {
  entries : Map[String, TestCacheEntry]
} derive(Eq)

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
