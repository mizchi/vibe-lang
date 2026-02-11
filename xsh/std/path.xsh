export struct PathRef {
  raw: String
}

export struct DynamicPath {
  raw: String
}

export let dynamic = (raw: String) -> DynamicPath {
  DynamicPath::{
    raw: raw
  }
}
export let from_literal = (literal: String) -> PathRef {
  PathRef::{
    raw: path_to_string(path_ref(literal))
  }
}
export let PathRef::as_string = (self: PathRef) -> String {
  self.raw
}
export let PathRef::is_absolute = (self: PathRef) -> Bool {
  path_is_absolute(path(self.raw))
}
export let DynamicPath::as_string = (path: DynamicPath) -> String {
  path.raw
}
export let resolve = (path: DynamicPath) -> PathRef with {
  Env
} {
  do {
    PathRef::{
      raw: path_to_string(dynamic_path_resolve(path.raw))
    }
  }
}
export let DynamicPath::resolve = (path: DynamicPath) -> PathRef with {
  Env
} {
  do {
    resolve(path)
  }
}
