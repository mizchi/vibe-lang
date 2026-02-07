///|
/// Document management for LSP

///|
pub(all) struct DocumentManager {
  contents : Map[String, String]
  versions : Map[String, Int]
} derive(Show, Eq)

///|
pub fn DocumentManager::new() -> DocumentManager {
  DocumentManager::{ contents: {}, versions: {} }
}

///|
pub fn DocumentManager::open(
  self : DocumentManager,
  uri : String,
  text : String,
  version : Int,
) -> Unit {
  self.contents[uri] = text
  self.versions[uri] = version
}

///|
pub fn DocumentManager::update(
  self : DocumentManager,
  uri : String,
  text : String,
  version : Int,
) -> Unit {
  self.contents[uri] = text
  self.versions[uri] = version
}

///|
pub fn DocumentManager::close(self : DocumentManager, uri : String) -> Unit {
  self.contents.remove(uri)
  self.versions.remove(uri)
}

///|
pub fn DocumentManager::get(self : DocumentManager, uri : String) -> String? {
  self.contents.get(uri)
}

///|
pub fn DocumentManager::get_version(
  self : DocumentManager,
  uri : String,
) -> Int? {
  self.versions.get(uri)
}
